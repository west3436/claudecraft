package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.config.ClaudeCraftConfig;
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
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Direct Anthropic API backend using SSE streaming.
 * Uses Java 17's built-in HttpClient — no external dependencies.
 * Thread-safe. Shared across all computers.
 */
public class ApiKeyBackend implements ClaudeBackend {
    private static final String API_URL = "https://api.anthropic.com/v1/messages";
    private static final String API_VERSION = "2023-06-01";
    private static ApiKeyBackend INSTANCE;
    private final HttpClient httpClient;
    private final ExecutorService executor;
    private final AtomicInteger activeRequests = new AtomicInteger(0);

    private ApiKeyBackend() {
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "ClaudeCraft-API");
            t.setDaemon(true);
            return t;
        });
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(15))
                .executor(executor)
                .build();
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

        int maxConcurrent = ClaudeCraftConfig.MAX_CONCURRENT_REQUESTS.get();
        if (activeRequests.get() >= maxConcurrent) {
            callbacks.onError("Too many concurrent requests (max " + maxConcurrent + ")");
            return handle;
        }

        String apiKey = ClaudeCraftConfig.API_KEY.get();
        if (apiKey == null || apiKey.isEmpty()) {
            callbacks.onError("API key not configured. Use /claudecraft setkey <key>");
            return handle;
        }

        JsonObject body;
        try {
            body = JsonParser.parseString(requestJson).getAsJsonObject();
        } catch (Exception e) {
            callbacks.onError("Invalid request JSON: " + e.getMessage());
            return handle;
        }
        body.addProperty("stream", true);

        int timeout = ClaudeCraftConfig.REQUEST_TIMEOUT_SECONDS.get();

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(API_URL))
                .timeout(Duration.ofSeconds(timeout))
                .header("x-api-key", apiKey)
                .header("anthropic-version", API_VERSION)
                .header("content-type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                .build();

        activeRequests.incrementAndGet();

        executor.submit(() -> {
            handle.setRequestThread(Thread.currentThread());
            try {
                HttpResponse<java.io.InputStream> response = httpClient.send(
                        request, HttpResponse.BodyHandlers.ofInputStream());

                if (response.statusCode() != 200) {
                    String errorBody = new String(response.body().readAllBytes(), StandardCharsets.UTF_8);
                    String msg = "HTTP " + response.statusCode();
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

                parseSSEStream(response.body(), handle, callbacks);

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
    }

    private void parseSSEStream(java.io.InputStream inputStream, StreamHandle handle,
                                 StreamCallbacks callbacks) throws Exception {
        String currentToolId = null;
        String currentToolName = null;
        StringBuilder currentToolInput = new StringBuilder();
        int inputTokens = 0;

        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(inputStream, StandardCharsets.UTF_8))) {

            String eventType = null;
            StringBuilder dataBuilder = new StringBuilder();

            String line;
            while ((line = reader.readLine()) != null) {
                if (handle.isCancelled()) break;

                if (line.startsWith("event: ")) {
                    eventType = line.substring(7).trim();
                } else if (line.startsWith("data: ")) {
                    dataBuilder.append(line.substring(6));
                } else if (line.isEmpty()) {
                    if (eventType != null && dataBuilder.length() > 0) {
                        String data = dataBuilder.toString().trim();

                        try {
                            JsonObject json = JsonParser.parseString(data).getAsJsonObject();

                            switch (eventType) {
                                case "message_start" -> {
                                    JsonObject message = json.getAsJsonObject("message");
                                    if (message != null && message.has("usage")) {
                                        JsonObject usage = message.getAsJsonObject("usage");
                                        if (usage.has("input_tokens")) {
                                            inputTokens = usage.get("input_tokens").getAsInt();
                                        }
                                    }
                                }
                                case "content_block_start" -> {
                                    JsonObject block = json.getAsJsonObject("content_block");
                                    if (block != null && "tool_use".equals(
                                            block.get("type").getAsString())) {
                                        currentToolId = block.get("id").getAsString();
                                        currentToolName = block.get("name").getAsString();
                                        currentToolInput.setLength(0);
                                        callbacks.onToolUseStart(currentToolId, currentToolName);
                                    }
                                }
                                case "content_block_delta" -> {
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
                                }
                                case "content_block_stop" -> {
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
                                }
                                case "message_delta" -> {
                                    JsonObject delta = json.getAsJsonObject("delta");
                                    String stopReason = delta != null && delta.has("stop_reason")
                                            ? delta.get("stop_reason").getAsString() : "end_turn";
                                    JsonObject usage = json.getAsJsonObject("usage");
                                    int outTokens = usage != null && usage.has("output_tokens")
                                            ? usage.get("output_tokens").getAsInt() : 0;
                                    callbacks.onComplete(stopReason, inputTokens, outTokens);
                                }
                                case "message_stop" -> {
                                    // Stream complete
                                }
                                case "error" -> {
                                    JsonObject error = json.getAsJsonObject("error");
                                    String msg = error != null && error.has("message")
                                            ? error.get("message").getAsString()
                                            : "Unknown API error";
                                    callbacks.onError(msg);
                                }
                            }
                        } catch (Exception e) {
                            ClaudeCraft.LOGGER.debug("Skipping non-JSON SSE data: {}",
                                    data.substring(0, Math.min(data.length(), 100)));
                        }
                    }
                    eventType = null;
                    dataBuilder.setLength(0);
                }
            }
        }
    }
}
