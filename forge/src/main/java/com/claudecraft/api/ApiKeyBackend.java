package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.config.ApiKeyProvider;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.JsonElement;
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
import java.util.concurrent.atomic.AtomicBoolean;
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
    public StreamHandle sendMessage(String requestJson, StreamCallbacks rawCallbacks) {
        StreamHandle handle = new StreamHandle();
        // Lua waits for exactly one claude_done or claude_error per request
        StreamCallbacks callbacks = new TerminalOnce(rawCallbacks);

        // Bug 1 fix: Atomic increment-then-check prevents race condition where
        // two threads both pass a get() check before either increments.
        int maxConcurrent = ClaudeCraftConfig.MAX_CONCURRENT_REQUESTS.get();
        int current = activeRequests.incrementAndGet();
        if (current > maxConcurrent) {
            activeRequests.decrementAndGet();
            callbacks.onError("Too many concurrent requests (max " + maxConcurrent + ")");
            return handle;
        }

        String apiKey = ApiKeyProvider.get();
        if (!ApiKeyProvider.isValidFormat(apiKey)) {
            activeRequests.decrementAndGet();
            callbacks.onError("API key not configured. Use /claudecraft setkey <key>");
            return handle;
        }

        JsonObject body;
        try {
            body = JsonParser.parseString(requestJson).getAsJsonObject();
        } catch (Exception e) {
            activeRequests.decrementAndGet();
            callbacks.onError("Invalid request JSON: " + e.getMessage());
            return handle;
        }
        body.addProperty("stream", true);
        PromptCaching.apply(body);

        int timeout = ClaudeCraftConfig.REQUEST_TIMEOUT_SECONDS.get();

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(API_URL))
                .timeout(Duration.ofSeconds(timeout))
                .header("x-api-key", apiKey)
                .header("anthropic-version", API_VERSION)
                .header("content-type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                .build();

        executor.submit(() -> {
            handle.setRequestThread(Thread.currentThread());
            try {
                int maxRetries = 2;
                int attempt = 0;
                while (true) {
                    if (handle.isCancelled()) return;

                    HttpResponse<java.io.InputStream> response = httpClient.send(
                            request, HttpResponse.BodyHandlers.ofInputStream());

                    int statusCode = response.statusCode();

                    // Retry on 429 (rate limit) or 5xx (server error) with exponential backoff
                    if ((statusCode == 429 || statusCode >= 500) && attempt < maxRetries) {
                        response.body().close();
                        attempt++;
                        long backoffMs = 1000L * (1L << (attempt - 1)); // 1s, 2s
                        ClaudeCraft.LOGGER.warn("HTTP {} from API, retrying in {}ms (attempt {}/{})",
                                statusCode, backoffMs, attempt, maxRetries);
                        Thread.sleep(backoffMs);
                        continue;
                    }

                    if (statusCode != 200) {
                        String errorBody = new String(response.body().readAllBytes(), StandardCharsets.UTF_8);
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

                    java.io.InputStream stream = response.body();
                    handle.setStream(stream);
                    parseSSEStream(stream, handle, callbacks, timeout);
                    return;
                }

            } catch (InterruptedException e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Request interrupted");
                }
            } catch (Exception e) {
                if (!handle.isCancelled()) {
                    callbacks.onError("Connection failed: " + e.getMessage());
                }
            } finally {
                // Never leave Lua waiting: a no-op if a terminal callback already fired
                if (!handle.isCancelled()) {
                    callbacks.onError("Request ended without a response.");
                }
                activeRequests.decrementAndGet();
                handle.setStream(null);
                handle.setRequestThread(null);
            }
        });

        return handle;
    }

    @Override
    public boolean isConfigured() {
        return ApiKeyProvider.isConfigured();
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

    /** Read an integer usage field, tolerating absent or null values. */
    private static int usageInt(JsonObject usage, String key, int fallback) {
        if (usage == null || !usage.has(key) || usage.get(key).isJsonNull()) return fallback;
        try {
            return usage.get(key).getAsInt();
        } catch (Exception e) {
            return fallback;
        }
    }

    /**
     * Parse an Anthropic API SSE stream using the shared {@link SSEParser}.
     * The stream is closed (and the request fails) if nothing arrives for
     * {@code idleSeconds}; the API sends ping events while a response is pending.
     */
    private void parseSSEStream(java.io.InputStream inputStream, StreamHandle handle,
                                 StreamCallbacks callbacks, int idleSeconds) throws Exception {
        String currentToolId = null;
        String currentToolName = null;
        StringBuilder currentToolInput = new StringBuilder();
        int inputTokens = 0;
        int cacheCreationTokens = 0;
        int cacheReadTokens = 0;

        try (StreamWatchdog.Watch watch = StreamWatchdog.watch(inputStream, idleSeconds * 1000L);
             SSEParser parser = new SSEParser(inputStream)) {
            SSEParser.SSEEvent event;
            while (true) {
                try {
                    event = parser.next(handle);
                } catch (java.io.IOException e) {
                    if (watch.stalled() && !handle.isCancelled()) {
                        callbacks.onError("The API stream stalled (no data for "
                                + idleSeconds + "s).");
                        return;
                    }
                    throw e;
                }
                if (event == null) break;
                watch.touch();
                String eventType = event.eventType();
                String data = event.data();

                try {
                    JsonObject json = JsonParser.parseString(data).getAsJsonObject();

                    switch (eventType != null ? eventType : "") {
                        case "message_start" -> {
                            JsonObject message = json.getAsJsonObject("message");
                            if (message != null && message.has("usage")) {
                                JsonObject usage = message.getAsJsonObject("usage");
                                inputTokens = usageInt(usage, "input_tokens", inputTokens);
                                cacheCreationTokens = usageInt(usage,
                                        "cache_creation_input_tokens", cacheCreationTokens);
                                cacheReadTokens = usageInt(usage,
                                        "cache_read_input_tokens", cacheReadTokens);
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
                                String raw = currentToolInput.toString().trim();
                                JsonObject parsedInput = new JsonObject();
                                String inputError = null;
                                // An empty buffer is a tool called with no arguments
                                if (!raw.isEmpty()) {
                                    try {
                                        JsonElement parsed = JsonParser.parseString(raw);
                                        if (parsed.isJsonObject()) {
                                            parsedInput = parsed.getAsJsonObject();
                                        } else {
                                            inputError = "Tool input was not a JSON object.";
                                        }
                                    } catch (Exception e) {
                                        inputError = "Tool input was cut off or malformed "
                                                + "(the response may have hit max_tokens).";
                                    }
                                }
                                callbacks.onToolUseComplete(
                                        currentToolId, currentToolName, parsedInput, inputError);
                                currentToolId = null;
                                currentToolName = null;
                                currentToolInput.setLength(0);
                            }
                        }
                        case "message_delta" -> {
                            JsonObject delta = json.getAsJsonObject("delta");
                            String stopReason = "end_turn";
                            if (delta != null && delta.has("stop_reason")
                                    && !delta.get("stop_reason").isJsonNull()) {
                                stopReason = delta.get("stop_reason").getAsString();
                            }
                            JsonObject usage = json.getAsJsonObject("usage");
                            // message_delta usage is cumulative. When it repeats the input
                            // and cache counts, take the larger of it and message_start.
                            int outTokens = usageInt(usage, "output_tokens", 0);
                            inputTokens = Math.max(inputTokens,
                                    usageInt(usage, "input_tokens", 0));
                            cacheCreationTokens = Math.max(cacheCreationTokens,
                                    usageInt(usage, "cache_creation_input_tokens", 0));
                            cacheReadTokens = Math.max(cacheReadTokens,
                                    usageInt(usage, "cache_read_input_tokens", 0));
                            callbacks.onComplete(stopReason, inputTokens, outTokens,
                                    cacheCreationTokens, cacheReadTokens);
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
                    ClaudeCraft.LOGGER.debug("Skipping unusable SSE event {} ({}): {}",
                            eventType, e.toString(),
                            data.substring(0, Math.min(data.length(), 100)));
                }
            }
        }

        // Stream ended without a terminal event — connection was lost. A no-op when
        // message_delta or an error event already ended the request.
        if (!handle.isCancelled()) {
            callbacks.onError("Connection closed unexpectedly. The API stream " +
                    "may have been interrupted or the response exceeded limits.");
        }
    }

    /**
     * Delegates to the wrapped callbacks but lets only the first onComplete/onError
     * through, so every request ends with exactly one claude_done or claude_error.
     */
    private static final class TerminalOnce implements StreamCallbacks {
        private final StreamCallbacks delegate;
        private final AtomicBoolean ended = new AtomicBoolean(false);

        TerminalOnce(StreamCallbacks delegate) {
            this.delegate = delegate;
        }

        @Override
        public void onTextDelta(String text) {
            if (!ended.get()) delegate.onTextDelta(text);
        }

        @Override
        public void onToolUseStart(String id, String name) {
            if (!ended.get()) delegate.onToolUseStart(id, name);
        }

        @Override
        public void onToolUseDelta(String id, String partialJson) {
            if (!ended.get()) delegate.onToolUseDelta(id, partialJson);
        }

        @Override
        public void onToolUseComplete(String id, String name, JsonObject input) {
            if (!ended.get()) delegate.onToolUseComplete(id, name, input);
        }

        @Override
        public void onToolUseComplete(String id, String name, JsonObject input,
                                      String inputError) {
            if (!ended.get()) delegate.onToolUseComplete(id, name, input, inputError);
        }

        @Override
        public void onComplete(String stopReason, int inputTokens, int outputTokens) {
            if (ended.compareAndSet(false, true)) {
                delegate.onComplete(stopReason, inputTokens, outputTokens);
            }
        }

        @Override
        public void onComplete(String stopReason, int inputTokens, int outputTokens,
                               int cacheCreationTokens, int cacheReadTokens) {
            if (ended.compareAndSet(false, true)) {
                delegate.onComplete(stopReason, inputTokens, outputTokens,
                        cacheCreationTokens, cacheReadTokens);
            }
        }

        @Override
        public void onError(String message) {
            if (ended.compareAndSet(false, true)) delegate.onError(message);
        }
    }
}
