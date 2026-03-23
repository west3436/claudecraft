package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Direct Anthropic API backend using SSE streaming.
 * Uses HttpURLConnection for Java 8 compatibility.
 * Thread-safe. Shared across all computers.
 */
public class ApiKeyBackend implements ClaudeBackend {
    private static final String API_URL = "https://api.anthropic.com/v1/messages";
    private static final String API_VERSION = "2023-06-01";
    private static ApiKeyBackend INSTANCE;
    private final ExecutorService executor;
    private final AtomicInteger activeRequests = new AtomicInteger(0);

    private ApiKeyBackend() {
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "ClaudeCraft-API");
            t.setDaemon(true);
            return t;
        });
    }

    public static synchronized ApiKeyBackend getInstance() {
        if (INSTANCE == null) {
            INSTANCE = new ApiKeyBackend();
        }
        return INSTANCE;
    }

    @Override
    public StreamHandle sendMessage(String requestJson, StreamCallbacks callbacks) {
        StreamHandle handle = new StreamHandle();

        // Bug 1 fix: Atomic increment-then-check prevents race condition where
        // two threads both pass a get() check before either increments.
        int maxConcurrent = ClaudeCraftConfig.MAX_CONCURRENT_REQUESTS.get();
        int current = activeRequests.incrementAndGet();
        if (current > maxConcurrent) {
            activeRequests.decrementAndGet();
            callbacks.onError("Too many concurrent requests (max " + maxConcurrent + ")");
            return handle;
        }

        String apiKey = ClaudeCraftConfig.API_KEY.get();
        if (apiKey == null || apiKey.isEmpty()) {
            activeRequests.decrementAndGet();
            callbacks.onError("API key not configured. Use /claudecraft setkey <key>");
            return handle;
        }

        // Inject stream:true into the request
        JsonObject body;
        try {
            body = JsonParser.parseString(requestJson).getAsJsonObject();
        } catch (Exception e) {
            activeRequests.decrementAndGet();
            callbacks.onError("Invalid request JSON: " + e.getMessage());
            return handle;
        }
        body.addProperty("stream", true);

        int timeout = ClaudeCraftConfig.REQUEST_TIMEOUT_SECONDS.get();
        String bodyString = body.toString();

        executor.submit(() -> {
            handle.setRequestThread(Thread.currentThread());
            HttpURLConnection connection = null;
            try {
                URL url = new URL(API_URL);
                connection = (HttpURLConnection) url.openConnection();
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(timeout * 1000);
                connection.setRequestProperty("x-api-key", apiKey);
                connection.setRequestProperty("anthropic-version", API_VERSION);
                connection.setRequestProperty("content-type", "application/json");

                // Write request body
                byte[] bodyBytes = bodyString.getBytes(StandardCharsets.UTF_8);
                connection.setFixedLengthStreamingMode(bodyBytes.length);
                try (OutputStream os = connection.getOutputStream()) {
                    os.write(bodyBytes);
                    os.flush();
                }

                int statusCode = connection.getResponseCode();
                if (statusCode != 200) {
                    InputStream errorStream = connection.getErrorStream();
                    String errorBody = readFullStream(errorStream != null ? errorStream : connection.getInputStream());
                    String msg = "HTTP " + statusCode;
                    try {
                        JsonObject err = JsonParser.parseString(errorBody).getAsJsonObject();
                        if (err.has("error")) {
                            JsonObject errObj = err.getAsJsonObject("error");
                            if (errObj.has("message")) {
                                msg = errObj.get("message").getAsString();
                            }
                        }
                    } catch (Exception ignored) {
                        if (errorBody.length() < 300) msg = errorBody;
                    }
                    callbacks.onError(msg);
                    return;
                }

                // Parse SSE stream line-by-line
                parseSSEStream(connection.getInputStream(), handle, callbacks);

            } catch (InterruptedException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Request interrupted");
                }
            } catch (Exception e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Connection failed: " + e.getMessage());
                }
            } finally {
                activeRequests.decrementAndGet();
                handle.setRequestThread(null);
                if (connection != null) {
                    connection.disconnect();
                }
            }
        });

        return handle;
    }

    @Override
    public boolean isConfigured() {
        String key = ClaudeCraftConfig.API_KEY.get();
        return key != null && !key.isEmpty() && key.startsWith("sk-");
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
     * Read an entire InputStream into a String.
     */
    private static String readFullStream(InputStream stream) throws IOException {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int length;
        while ((length = stream.read(buffer)) != -1) {
            result.write(buffer, 0, length);
        }
        return result.toString(StandardCharsets.UTF_8.name());
    }

    /**
     * Parse an Anthropic API SSE stream using the shared {@link SSEParser}.
     */
    private void parseSSEStream(InputStream inputStream, StreamHandle handle,
                                 StreamCallbacks callbacks) throws Exception {
        String currentToolId = null;
        String currentToolName = null;
        StringBuilder currentToolInput = new StringBuilder();
        int inputTokens = 0;
        boolean receivedTerminalEvent = false;

        try (SSEParser parser = new SSEParser(inputStream)) {
            SSEParser.SSEEvent event;
            while ((event = parser.next(handle)) != null) {
                String eventType = event.eventType;
                String data = event.data;

                try {
                    JsonObject json = JsonParser.parseString(data).getAsJsonObject();

                    if ("message_start".equals(eventType)) {
                        JsonObject message = json.getAsJsonObject("message");
                        if (message != null && message.has("usage")) {
                            JsonObject usage = message.getAsJsonObject("usage");
                            if (usage.has("input_tokens")) {
                                inputTokens = usage.get("input_tokens").getAsInt();
                            }
                        }
                    } else if ("content_block_start".equals(eventType)) {
                        JsonObject block = json.getAsJsonObject("content_block");
                        if (block != null && "tool_use".equals(
                                block.get("type").getAsString())) {
                            currentToolId = block.get("id").getAsString();
                            currentToolName = block.get("name").getAsString();
                            currentToolInput.setLength(0);
                            callbacks.onToolUseStart(currentToolId, currentToolName);
                        }
                    } else if ("content_block_delta".equals(eventType)) {
                        JsonObject delta = json.getAsJsonObject("delta");
                        if (delta != null) {
                            String deltaType = delta.get("type").getAsString();
                            if ("text_delta".equals(deltaType)) {
                                callbacks.onTextDelta(
                                        delta.get("text").getAsString());
                            } else if ("input_json_delta".equals(deltaType)) {
                                String partial = delta.get("partial_json")
                                        .getAsString();
                                currentToolInput.append(partial);
                                if (currentToolId != null) {
                                    callbacks.onToolUseDelta(currentToolId, partial);
                                }
                            }
                        }
                    } else if ("content_block_stop".equals(eventType)) {
                        if (currentToolId != null) {
                            JsonObject parsedInput;
                            try {
                                parsedInput = JsonParser.parseString(
                                        currentToolInput.toString()).getAsJsonObject();
                            } catch (Exception e) {
                                parsedInput = new JsonObject();
                            }
                            callbacks.onToolUseComplete(
                                    currentToolId, currentToolName, parsedInput);
                            currentToolId = null;
                            currentToolName = null;
                            currentToolInput.setLength(0);
                        }
                    } else if ("message_delta".equals(eventType)) {
                        receivedTerminalEvent = true;
                        JsonObject delta = json.getAsJsonObject("delta");
                        String stopReason = delta != null && delta.has("stop_reason")
                                ? delta.get("stop_reason").getAsString() : "end_turn";
                        JsonObject usage = json.getAsJsonObject("usage");
                        int outTokens = usage != null && usage.has("output_tokens")
                                ? usage.get("output_tokens").getAsInt() : 0;
                        callbacks.onComplete(stopReason, inputTokens, outTokens);
                    } else if ("message_stop".equals(eventType)) {
                        // Stream complete
                    } else if ("error".equals(eventType)) {
                        receivedTerminalEvent = true;
                        JsonObject error = json.getAsJsonObject("error");
                        String msg = error != null && error.has("message")
                                ? error.get("message").getAsString()
                                : "Unknown API error";
                        callbacks.onError(msg);
                    }
                } catch (Exception e) {
                    ClaudeCraft.LOGGER.debug("Skipping non-JSON SSE data: {}",
                            data.substring(0, Math.min(data.length(), 100)));
                }
            }
        }

        // Stream ended without a terminal event — connection was lost
        if (!handle.isCancelled() && !receivedTerminalEvent) {
            callbacks.onError("Connection closed unexpectedly. The API stream " +
                    "may have been interrupted or the response exceeded limits.");
        }
    }
}
