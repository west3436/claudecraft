package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Channel backend for a single CC:Tweaked computer. Communicates with
 * a local Claude Code channel server on a specific port.
 * NOT a singleton — one instance per computer session.
 */
public class ChannelBackend implements ClaudeBackend {
    /**
     * Time to wait for an SSE response's headers. HttpRequest.timeout() stops
     * applying once headers arrive, so the open stream is guarded by an idle
     * watchdog instead: the server sends a heartbeat every 5s.
     */
    private static final Duration SSE_HEADERS_TIMEOUT = Duration.ofSeconds(30);
    /** A turn's stream with no data (not even a heartbeat) for this long is dead. */
    private static final long REQUEST_SSE_IDLE_MS = 60_000;
    /** The global stream is reconnected after this long without data. */
    private static final long GLOBAL_SSE_IDLE_MS = 30_000;
    /** Consecutive failed global SSE connection attempts before giving up. */
    private static final int GLOBAL_SSE_MAX_FAILURES = 8;
    private static final long GLOBAL_SSE_MAX_BACKOFF_MS = 30_000;

    /** Maximum retries for sending tool results. */
    private static final int TOOL_RESULT_MAX_RETRIES = 2;

    private final int port;
    /** Per-session secret sent as a Bearer token; the server rejects requests without it. */
    private final String token;
    /** The computer this backend serves; /health must report the same ID. */
    private final int computerId;
    private final HttpClient httpClient;
    private final ExecutorService executor;
    /** Cancelled by shutdown(): stops the global SSE loop and closes its stream. */
    private final StreamHandle globalHandle = new StreamHandle();

    public ChannelBackend(int port, String token, int computerId) {
        this.port = port;
        this.token = token;
        this.computerId = computerId;
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "ClaudeCraft-Channel-" + port);
            t.setDaemon(true);
            return t;
        });
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .executor(executor)
                .build();
    }

    private String getBaseUrl() {
        return "http://127.0.0.1:" + port;
    }

    /** A request to the channel server carrying this session's Bearer token. */
    private HttpRequest.Builder authorizedRequest(String pathAndQuery) {
        return HttpRequest.newBuilder()
                .uri(URI.create(getBaseUrl() + pathAndQuery))
                .header("authorization", "Bearer " + token);
    }

    /**
     * Wait for the channel server to become available (health check polling).
     * Returns true if connected, false if timed out.
     */
    public boolean waitForReady(int timeoutSeconds) {
        long deadline = System.currentTimeMillis() + (timeoutSeconds * 1000L);
        while (System.currentTimeMillis() < deadline) {
            if (isConfigured()) {
                return true;
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return false;
    }

    @Override
    public StreamHandle sendMessage(String requestJson, StreamCallbacks callbacks) {
        StreamHandle handle = new StreamHandle();

        executor.submit(() -> {
            handle.setRequestThread(Thread.currentThread());
            try {
                JsonObject request = JsonParser.parseString(requestJson).getAsJsonObject();
                JsonObject messageBody = new JsonObject();

                if (request.has("messages")) {
                    var messages = request.getAsJsonArray("messages");
                    for (int i = messages.size() - 1; i >= 0; i--) {
                        var msg = messages.get(i).getAsJsonObject();
                        if ("user".equals(msg.get("role").getAsString())) {
                            var content = msg.get("content");
                            if (content.isJsonPrimitive()) {
                                messageBody.addProperty("userMessage", content.getAsString());
                            } else {
                                messageBody.addProperty("userMessage", content.toString());
                            }
                            break;
                        }
                    }
                }

                if (request.has("system")) {
                    messageBody.addProperty("system", request.get("system").getAsString());
                }

                // POST /message
                HttpRequest postReq = authorizedRequest("/message")
                        .timeout(Duration.ofSeconds(15))
                        .header("content-type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(messageBody.toString()))
                        .build();

                HttpResponse<String> postResp = httpClient.send(postReq,
                        HttpResponse.BodyHandlers.ofString());

                if (postResp.statusCode() == 401) {
                    callbacks.onError("Channel server rejected this session's token. "
                            + "Exit and run 'claude' again to restart the session.");
                    return;
                }
                if (postResp.statusCode() != 200) {
                    callbacks.onError("Channel server error: HTTP " + postResp.statusCode());
                    return;
                }

                JsonObject respBody = JsonParser.parseString(postResp.body()).getAsJsonObject();
                String requestId = respBody.get("requestId").getAsString();

                HttpRequest sseReq = authorizedRequest("/events?request_id="
                                + java.net.URLEncoder.encode(requestId, StandardCharsets.UTF_8))
                        .timeout(SSE_HEADERS_TIMEOUT)
                        .header("accept", "text/event-stream")
                        .GET()
                        .build();

                HttpResponse<java.io.InputStream> sseResp = httpClient.send(sseReq,
                        HttpResponse.BodyHandlers.ofInputStream());

                if (sseResp.statusCode() != 200) {
                    sseResp.body().close();
                    callbacks.onError("Channel SSE error: HTTP " + sseResp.statusCode());
                    return;
                }

                java.io.InputStream body = sseResp.body();
                handle.setStream(body);
                parseChannelSSE(body, handle, callbacks);

            } catch (InterruptedException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Request interrupted");
                }
            } catch (java.net.ConnectException e) {
                callbacks.onError("Channel server not reachable on port " + port +
                        ". Claude Code may still be starting.");
            } catch (java.net.http.HttpTimeoutException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Channel server did not respond within " +
                            SSE_HEADERS_TIMEOUT.toSeconds() + "s.");
                }
            } catch (Exception e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Channel connection failed: " + e.getMessage());
                }
            } finally {
                handle.setStream(null);
                handle.setRequestThread(null);
            }
        });

        return handle;
    }

    /**
     * Bug 10 fix: Send tool result with retry logic and error logging.
     * Retries up to {@link #TOOL_RESULT_MAX_RETRIES} times on failure.
     */
    @Override
    public void sendToolResult(String callId, String resultJson) {
        executor.submit(() -> {
            JsonObject body = new JsonObject();
            body.addProperty("callId", callId);
            body.addProperty("result", resultJson);

            HttpRequest request = authorizedRequest("/tool-result")
                    .timeout(Duration.ofSeconds(10))
                    .header("content-type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                    .build();

            for (int attempt = 1; attempt <= TOOL_RESULT_MAX_RETRIES; attempt++) {
                try {
                    HttpResponse<String> resp = httpClient.send(request,
                            HttpResponse.BodyHandlers.ofString());
                    if (resp.statusCode() == 200) return; // Success
                    ClaudeCraft.LOGGER.warn(
                            "Tool result delivery got HTTP {} (attempt {}/{}), callId={}",
                            resp.statusCode(), attempt, TOOL_RESULT_MAX_RETRIES, callId);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    ClaudeCraft.LOGGER.warn("Tool result delivery interrupted, callId={}", callId);
                    return;
                } catch (Exception e) {
                    ClaudeCraft.LOGGER.warn(
                            "Tool result delivery failed (attempt {}/{}), callId={}: {}",
                            attempt, TOOL_RESULT_MAX_RETRIES, callId, e.getMessage());
                }

                // Brief pause before retry
                if (attempt < TOOL_RESULT_MAX_RETRIES) {
                    try {
                        Thread.sleep(500);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
            ClaudeCraft.LOGGER.error(
                    "Tool result delivery failed after {} attempts, callId={}. " +
                    "Claude Code will see a timeout for this tool call.",
                    TOOL_RESULT_MAX_RETRIES, callId);
        });
    }

    /**
     * Healthy only if the server accepts this session's token, reports this
     * computer's ID (so we never attach to another computer's orphaned server
     * on a reused port), and still has its MCP connection to Claude Code.
     */
    @Override
    public boolean isConfigured() {
        try {
            HttpRequest request = authorizedRequest("/health")
                    .timeout(Duration.ofSeconds(2))
                    .GET()
                    .build();

            HttpResponse<String> response = httpClient.send(request,
                    HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) return false;

            JsonObject body = JsonParser.parseString(response.body()).getAsJsonObject();
            if (!body.has("computerId")
                    || !String.valueOf(computerId).equals(body.get("computerId").getAsString())) {
                ClaudeCraft.LOGGER.warn("Channel server on port {} reports computer {}, expected {}",
                        port, body.has("computerId") ? body.get("computerId") : "none", computerId);
                return false;
            }
            return body.has("mcpConnected") && body.get("mcpConnected").getAsBoolean();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Start a persistent global SSE listener that handles events from
     * incoming inter-computer messages (tool calls, replies, done).
     * Unlike per-request SSE, this does NOT terminate on 'done' events.
     * A dropped or silent connection is reopened with backoff until
     * {@link #shutdown()}, or until the server keeps refusing connections.
     */
    public void connectGlobalSSE(StreamCallbacks callbacks) {
        executor.submit(() -> {
            int failures = 0;
            long backoffMs = 1000;
            while (!globalHandle.isCancelled()) {
                boolean connected = false;
                try {
                    HttpRequest sseReq = authorizedRequest("/events")
                            .timeout(SSE_HEADERS_TIMEOUT)
                            .header("accept", "text/event-stream")
                            .GET()
                            .build();

                    HttpResponse<java.io.InputStream> sseResp = httpClient.send(sseReq,
                            HttpResponse.BodyHandlers.ofInputStream());

                    if (sseResp.statusCode() == 401) {
                        sseResp.body().close();
                        ClaudeCraft.LOGGER.warn("Global SSE on port {} rejected this session's "
                                + "token; not reconnecting", port);
                        return;
                    }
                    if (sseResp.statusCode() != 200) {
                        sseResp.body().close();
                        ClaudeCraft.LOGGER.warn("Global SSE on port {} failed: HTTP {}",
                                port, sseResp.statusCode());
                    } else {
                        connected = true;
                        readGlobalSSE(sseResp.body(), callbacks);
                    }
                } catch (InterruptedException e) {
                    return;
                } catch (Exception e) {
                    if (!globalHandle.isCancelled()) {
                        ClaudeCraft.LOGGER.debug("Global SSE on port {} ended: {}", port, e.toString());
                    }
                } finally {
                    globalHandle.setStream(null);
                }

                if (globalHandle.isCancelled()) return;
                if (connected) {
                    failures = 0;
                    backoffMs = 1000;
                } else if (++failures >= GLOBAL_SSE_MAX_FAILURES) {
                    ClaudeCraft.LOGGER.warn("Global SSE on port {} gave up after {} failed attempts; "
                            + "messages from other computers will not arrive until claude restarts",
                            port, failures);
                    return;
                }
                try {
                    Thread.sleep(backoffMs);
                } catch (InterruptedException e) {
                    return;
                }
                backoffMs = Math.min(backoffMs * 2, GLOBAL_SSE_MAX_BACKOFF_MS);
            }
        });
    }

    /** Read one global SSE connection until it ends, fails, or goes quiet. */
    private void readGlobalSSE(java.io.InputStream body, StreamCallbacks callbacks) throws Exception {
        globalHandle.setStream(body);
        try (StreamWatchdog.Watch watch = StreamWatchdog.watch(body, GLOBAL_SSE_IDLE_MS);
             SSEParser parser = new SSEParser(body)) {
            while (true) {
                SSEParser.SSEEvent sse;
                try {
                    sse = parser.next(globalHandle);
                } catch (java.io.IOException e) {
                    if (watch.stalled()) {
                        ClaudeCraft.LOGGER.info("Global SSE on port {} went quiet; reconnecting", port);
                        return;
                    }
                    throw e;
                }
                if (sse == null) return;
                watch.touch();

                try {
                    JsonObject event = JsonParser.parseString(sse.data()).getAsJsonObject();
                    String type = event.has("type") ? event.get("type").getAsString() : "";

                    switch (type) {
                        case "tool_call" -> {
                            String callId = event.get("callId").getAsString();
                            String toolName = event.get("toolName").getAsString();
                            String input = event.get("input").getAsString();
                            callbacks.onToolExecRequest(callId, toolName, input);
                        }
                        case "reply" -> {
                            String text = event.get("text").getAsString();
                            callbacks.onReply(text);
                        }
                        case "done" -> {
                            callbacks.onComplete("end_turn", 0, 0);
                        }
                        case "error" -> {
                            String msg = event.has("message")
                                    ? event.get("message").getAsString()
                                    : "Unknown channel error";
                            callbacks.onError(msg);
                        }
                    }
                } catch (Exception e) {
                    ClaudeCraft.LOGGER.debug("Skipping unusable global SSE data: {}", e.toString());
                }
            }
        }
    }

    @Override
    public void shutdown() {
        globalHandle.cancel();
        executor.shutdownNow();
        try {
            executor.awaitTermination(5, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * Parse channel server SSE events using the shared {@link SSEParser}.
     */
    private void parseChannelSSE(java.io.InputStream inputStream, StreamHandle handle,
                                  StreamCallbacks callbacks) throws Exception {
        boolean receivedTerminalEvent = false;

        try (StreamWatchdog.Watch watch = StreamWatchdog.watch(inputStream, REQUEST_SSE_IDLE_MS);
             SSEParser parser = new SSEParser(inputStream)) {
            SSEParser.SSEEvent event;
            while (true) {
                try {
                    event = parser.next(handle);
                } catch (java.io.IOException e) {
                    if (watch.stalled() && !handle.isCancelled()) {
                        callbacks.onError("Lost contact with the channel server (no data for "
                                + (REQUEST_SSE_IDLE_MS / 1000) + "s). Claude Code may have "
                                + "stopped responding.");
                        return;
                    }
                    throw e;
                }
                if (event == null) break;
                watch.touch();
                String data = event.data();

                try {
                    JsonObject json = JsonParser.parseString(data).getAsJsonObject();
                    String type = json.has("type") ? json.get("type").getAsString() : "";

                    switch (type) {
                        case "connected" -> {
                            ClaudeCraft.LOGGER.debug("Channel SSE connected on port {}", port);
                        }
                        case "tool_call" -> {
                            String callId = json.get("callId").getAsString();
                            String toolName = json.get("toolName").getAsString();
                            String input = json.get("input").getAsString();
                            callbacks.onToolExecRequest(callId, toolName, input);
                        }
                        case "reply" -> {
                            String text = json.get("text").getAsString();
                            callbacks.onReply(text);
                        }
                        case "done" -> {
                            receivedTerminalEvent = true;
                            callbacks.onComplete("end_turn", 0, 0);
                            return;
                        }
                        case "error" -> {
                            receivedTerminalEvent = true;
                            String msg = json.has("message")
                                    ? json.get("message").getAsString()
                                    : "Unknown channel error";
                            callbacks.onError(msg);
                            return;
                        }
                        case "heartbeat" -> {
                            // Keepalive — ignore
                        }
                    }
                } catch (Exception e) {
                    ClaudeCraft.LOGGER.debug("Skipping non-JSON channel SSE data: {}",
                            data.substring(0, Math.min(data.length(), 100)));
                }
            }
        }

        // Stream ended without a terminal event — connection was lost
        if (!handle.isCancelled() && !receivedTerminalEvent) {
            callbacks.onError("Connection closed unexpectedly. " +
                    "Claude Code may have crashed or the response exceeded limits.");
        }
    }
}
