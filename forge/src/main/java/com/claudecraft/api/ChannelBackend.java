package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Channel backend for a single CC:Tweaked computer. Communicates with
 * a local Claude Code channel server on a specific port.
 * NOT a singleton — one instance per computer session.
 */
public class ChannelBackend implements ClaudeBackend {
    private final int port;
    private final ExecutorService executor;

    public ChannelBackend(int port) {
        this.port = port;
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "ClaudeCraft-Channel-" + port);
            t.setDaemon(true);
            return t;
        });
    }

    private String getBaseUrl() {
        return "http://127.0.0.1:" + port;
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
                    com.google.gson.JsonArray messages = request.getAsJsonArray("messages");
                    for (int i = messages.size() - 1; i >= 0; i--) {
                        JsonObject msg = messages.get(i).getAsJsonObject();
                        if ("user".equals(msg.get("role").getAsString())) {
                            com.google.gson.JsonElement content = msg.get("content");
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
                String postResponse = httpPost(getBaseUrl() + "/message",
                        messageBody.toString(), 15000);
                if (postResponse == null) {
                    callbacks.onError("Channel server not reachable on port " + port);
                    return;
                }

                JsonObject respBody = JsonParser.parseString(postResponse).getAsJsonObject();
                String requestId = respBody.get("requestId").getAsString();

                // Open SSE connection for events
                URL sseUrl = new URL(getBaseUrl() + "/events?request_id=" + requestId);
                HttpURLConnection sseConn = (HttpURLConnection) sseUrl.openConnection();
                sseConn.setRequestMethod("GET");
                sseConn.setRequestProperty("Accept", "text/event-stream");
                sseConn.setReadTimeout(0); // No timeout — stream stays open

                int sseStatus = sseConn.getResponseCode();
                if (sseStatus != 200) {
                    callbacks.onError("Channel SSE error: HTTP " + sseStatus);
                    return;
                }

                parseChannelSSE(sseConn.getInputStream(), handle, callbacks);

            } catch (java.net.ConnectException e) {
                callbacks.onError("Channel server not reachable on port " + port +
                        ". Claude Code may still be starting.");
            } catch (InterruptedException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Request interrupted");
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

    @Override
    public void sendToolResult(String callId, String resultJson) {
        executor.submit(() -> {
            try {
                JsonObject body = new JsonObject();
                body.addProperty("callId", callId);
                body.addProperty("result", resultJson);

                httpPost(getBaseUrl() + "/tool-result", body.toString(), 10000);
            } catch (Exception e) {
                ClaudeCraft.LOGGER.warn("Failed to send tool result: {}", e.getMessage());
            }
        });
    }

    @Override
    public boolean isConfigured() {
        try {
            URL url = new URL(getBaseUrl() + "/health");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(2000);
            conn.setReadTimeout(2000);
            int code = conn.getResponseCode();
            if (code != 200) {
                conn.disconnect();
                return false;
            }

            // Check that Claude Code MCP connection is still alive
            try {
                String body = readFullStream(conn.getInputStream());
                JsonObject json = JsonParser.parseString(body).getAsJsonObject();
                if (json.has("mcpConnected") && !json.get("mcpConnected").getAsBoolean()) {
                    conn.disconnect();
                    return false;
                }
            } catch (Exception ignored) {
                // Old server format — treat 200 as healthy
            }
            conn.disconnect();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static String readFullStream(InputStream stream) throws IOException {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int length;
        while ((length = stream.read(buffer)) != -1) {
            result.write(buffer, 0, length);
        }
        return result.toString(StandardCharsets.UTF_8.name());
    }

    @Override
    public void shutdown() {
        executor.shutdownNow();
    }

    private String httpPost(String urlStr, String jsonBody, int timeoutMs) {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(timeoutMs);
            conn.setReadTimeout(timeoutMs);
            conn.setRequestProperty("Content-Type", "application/json");

            byte[] bodyBytes = jsonBody.getBytes(StandardCharsets.UTF_8);
            conn.setFixedLengthStreamingMode(bodyBytes.length);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(bodyBytes);
                os.flush();
            }

            int status = conn.getResponseCode();
            if (status != 200) {
                return null;
            }

            ByteArrayOutputStream result = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int length;
            try (InputStream is = conn.getInputStream()) {
                while ((length = is.read(buffer)) != -1) {
                    result.write(buffer, 0, length);
                }
            }
            return result.toString(StandardCharsets.UTF_8.name());
        } catch (Exception e) {
            return null;
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private void parseChannelSSE(InputStream inputStream, StreamHandle handle,
                                  StreamCallbacks callbacks) throws Exception {
        boolean receivedTerminalEvent = false;

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

                        if ("connected".equals(type)) {
                            ClaudeCraft.LOGGER.debug("Channel SSE connected on port {}", port);
                        } else if ("tool_call".equals(type)) {
                            String tcCallId = event.get("callId").getAsString();
                            String toolName = event.get("toolName").getAsString();
                            String input = event.get("input").getAsString();
                            callbacks.onToolExecRequest(tcCallId, toolName, input);
                        } else if ("reply".equals(type)) {
                            String text = event.get("text").getAsString();
                            callbacks.onReply(text);
                        } else if ("done".equals(type)) {
                            receivedTerminalEvent = true;
                            callbacks.onComplete("end_turn", 0, 0);
                            return;
                        } else if ("error".equals(type)) {
                            receivedTerminalEvent = true;
                            String msg = event.has("message")
                                    ? event.get("message").getAsString()
                                    : "Unknown channel error";
                            callbacks.onError(msg);
                            return;
                        } else if ("heartbeat".equals(type)) {
                            // Keepalive — ignore
                        }
                    } catch (Exception e) {
                        ClaudeCraft.LOGGER.debug("Skipping non-JSON channel SSE data: {}",
                                data.substring(0, Math.min(data.length(), 100)));
                    }
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
