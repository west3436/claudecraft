package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.BufferedReader;
import java.io.InputStreamReader;
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
    /** Maximum time to wait for the entire SSE stream (10 minutes). */
    private static final Duration SSE_TIMEOUT = Duration.ofMinutes(10);

    /** Maximum retries for sending tool results. */
    private static final int TOOL_RESULT_MAX_RETRIES = 2;

    private final int port;
    private final HttpClient httpClient;
    private final ExecutorService executor;

    public ChannelBackend(int port) {
        this.port = port;
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
                HttpRequest postReq = HttpRequest.newBuilder()
                        .uri(URI.create(getBaseUrl() + "/message"))
                        .timeout(Duration.ofSeconds(15))
                        .header("content-type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(messageBody.toString()))
                        .build();

                HttpResponse<String> postResp = httpClient.send(postReq,
                        HttpResponse.BodyHandlers.ofString());

                if (postResp.statusCode() != 200) {
                    callbacks.onError("Channel server error: HTTP " + postResp.statusCode());
                    return;
                }

                JsonObject respBody = JsonParser.parseString(postResp.body()).getAsJsonObject();
                String requestId = respBody.get("requestId").getAsString();

                // Bug 4 fix: Add a generous timeout to the SSE stream as a safety net.
                // The heartbeat (every 15s) keeps the connection alive for legitimate
                // long-running operations, but this prevents infinite hangs if the
                // channel server dies completely without closing the connection.
                HttpRequest sseReq = HttpRequest.newBuilder()
                        .uri(URI.create(getBaseUrl() + "/events?request_id=" + requestId))
                        .timeout(SSE_TIMEOUT)
                        .header("accept", "text/event-stream")
                        .GET()
                        .build();

                HttpResponse<java.io.InputStream> sseResp = httpClient.send(sseReq,
                        HttpResponse.BodyHandlers.ofInputStream());

                if (sseResp.statusCode() != 200) {
                    callbacks.onError("Channel SSE error: HTTP " + sseResp.statusCode());
                    return;
                }

                parseChannelSSE(sseResp.body(), handle, callbacks);

            } catch (InterruptedException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Request interrupted");
                }
            } catch (java.net.ConnectException e) {
                callbacks.onError("Channel server not reachable on port " + port +
                        ". Claude Code may still be starting.");
            } catch (java.net.http.HttpTimeoutException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Channel stream timed out after " +
                            SSE_TIMEOUT.toMinutes() + " minutes. The operation may still " +
                            "be running on the channel server.");
                }
            } catch (Exception e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Channel connection failed: " + e.getMessage());
                }
            } finally {
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

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(getBaseUrl() + "/tool-result"))
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

    @Override
    public boolean isConfigured() {
        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(getBaseUrl() + "/health"))
                    .timeout(Duration.ofSeconds(2))
                    .GET()
                    .build();

            HttpResponse<String> response = httpClient.send(request,
                    HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) return false;

            // Check that Claude Code MCP connection is still alive
            try {
                JsonObject body = JsonParser.parseString(response.body()).getAsJsonObject();
                if (body.has("mcpConnected") && !body.get("mcpConnected").getAsBoolean()) {
                    return false;
                }
            } catch (Exception ignored) {
                // Old server format — treat 200 as healthy
            }
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public void connectGlobalSSE(StreamCallbacks callbacks) {
        executor.submit(() -> {
            try {
                HttpRequest sseReq = HttpRequest.newBuilder()
                        .uri(URI.create(getBaseUrl() + "/events"))
                        .header("accept", "text/event-stream")
                        .GET().build();
                HttpResponse<java.io.InputStream> sseResp = httpClient.send(sseReq,
                        HttpResponse.BodyHandlers.ofInputStream());
                if (sseResp.statusCode() != 200) {
                    ClaudeCraft.LOGGER.warn("Global SSE failed: HTTP {}", sseResp.statusCode());
                    return;
                }
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(sseResp.body(), StandardCharsets.UTF_8))) {
                    StringBuilder dataBuilder = new StringBuilder();
                    String line;
                    while ((line = reader.readLine()) != null) {
                        if (line.startsWith("data: ")) {
                            dataBuilder.append(line.substring(6));
                        } else if (line.isEmpty() && dataBuilder.length() > 0) {
                            String data = dataBuilder.toString().trim();
                            dataBuilder.setLength(0);
                            try {
                                JsonObject event = JsonParser.parseString(data).getAsJsonObject();
                                String type = event.has("type") ? event.get("type").getAsString() : "";
                                switch (type) {
                                    case "tool_call" -> callbacks.onToolExecRequest(
                                            event.get("callId").getAsString(),
                                            event.get("toolName").getAsString(),
                                            event.get("input").getAsString());
                                    case "reply" -> callbacks.onReply(event.get("text").getAsString());
                                    case "done" -> callbacks.onComplete("end_turn", 0, 0);
                                    case "error" -> callbacks.onError(event.has("message")
                                            ? event.get("message").getAsString() : "Unknown channel error");
                                }
                            } catch (Exception e) {
                                ClaudeCraft.LOGGER.debug("Skipping non-JSON global SSE data");
                            }
                        }
                    }
                }
            } catch (Exception e) {
                ClaudeCraft.LOGGER.debug("Global SSE ended: {}", e.getMessage());
            }
        });
    }

    @Override
    public void shutdown() {
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

        try (SSEParser parser = new SSEParser(inputStream)) {
            SSEParser.SSEEvent event;
            while ((event = parser.next(handle)) != null) {
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
