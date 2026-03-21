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

/**
 * Channel backend for a single CC:Tweaked computer. Communicates with
 * a local Claude Code channel server on a specific port.
 * NOT a singleton — one instance per computer session.
 */
public class ChannelBackend implements ClaudeBackend {
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

                // Open SSE connection for events.
                // No timeout — the stream stays open until Claude Code sends
                // a 'done' or 'error' event. Tool execution can take minutes.
                HttpRequest sseReq = HttpRequest.newBuilder()
                        .uri(URI.create(getBaseUrl() + "/events?request_id=" + requestId))
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

    @Override
    public void sendToolResult(String callId, String resultJson) {
        executor.submit(() -> {
            try {
                JsonObject body = new JsonObject();
                body.addProperty("callId", callId);
                body.addProperty("result", resultJson);

                HttpRequest request = HttpRequest.newBuilder()
                        .uri(URI.create(getBaseUrl() + "/tool-result"))
                        .timeout(Duration.ofSeconds(10))
                        .header("content-type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                        .build();

                httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            } catch (Exception e) {
                ClaudeCraft.LOGGER.warn("Failed to send tool result: {}", e.getMessage());
            }
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
            return response.statusCode() == 200;
        } catch (Exception e) {
            return false;
        }
    }

    @Override
    public void shutdown() {
        executor.shutdownNow();
    }

    private void parseChannelSSE(java.io.InputStream inputStream, StreamHandle handle,
                                  StreamCallbacks callbacks) throws Exception {
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(inputStream, StandardCharsets.UTF_8))) {

            StringBuilder dataBuilder = new StringBuilder();
            String line;

            while ((line = reader.readLine()) != null) {
                if (handle.isCancelled()) break;

                if (line.startsWith("data: ")) {
                    dataBuilder.append(line.substring(6));
                } else if (line.isEmpty() && dataBuilder.length() > 0) {
                    String data = dataBuilder.toString().trim();
                    dataBuilder.setLength(0);

                    try {
                        JsonObject event = JsonParser.parseString(data).getAsJsonObject();
                        String type = event.has("type") ? event.get("type").getAsString() : "";

                        switch (type) {
                            case "connected" -> {
                                ClaudeCraft.LOGGER.debug("Channel SSE connected on port {}", port);
                            }
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
                                return;
                            }
                            case "error" -> {
                                String msg = event.has("message")
                                        ? event.get("message").getAsString()
                                        : "Unknown channel error";
                                callbacks.onError(msg);
                                return;
                            }
                        }
                    } catch (Exception e) {
                        ClaudeCraft.LOGGER.debug("Skipping non-JSON channel SSE data: {}",
                                data.substring(0, Math.min(data.length(), 100)));
                    }
                }
            }
        }
    }
}
