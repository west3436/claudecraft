package com.claudecraft.api;

import com.google.gson.JsonObject;

/**
 * Abstraction for AI backends. Implementations handle either direct API key
 * communication (Anthropic API) or channel-based communication (Claude Code).
 */
public interface ClaudeBackend {

    /**
     * Callbacks for streaming/event-based responses.
     */
    interface StreamCallbacks {
        void onTextDelta(String text);
        void onToolUseStart(String id, String name);
        void onToolUseDelta(String id, String partialJson);
        void onToolUseComplete(String id, String name, JsonObject input);

        /**
         * Tool call finished streaming. {@code inputError} is non-null when the streamed
         * input could not be parsed (typically cut off by max_tokens); the tool must not
         * run and {@code input} is empty. Defaults to the 3-arg overload.
         */
        default void onToolUseComplete(String id, String name, JsonObject input, String inputError) {
            onToolUseComplete(id, name, input);
        }

        void onComplete(String stopReason, int inputTokens, int outputTokens);
        void onError(String message);

        /**
         * Completion with prompt-cache usage (API key mode). {@code inputTokens} is the
         * uncached remainder only; total prompt = input + cacheCreation + cacheRead.
         * Defaults to the cache-unaware overload.
         */
        default void onComplete(String stopReason, int inputTokens, int outputTokens,
                                int cacheCreationTokens, int cacheReadTokens) {
            onComplete(stopReason, inputTokens, outputTokens);
        }

        /**
         * Channel mode only: Claude Code requests execution of a Minecraft tool.
         * The receiver should execute the tool and call sendToolResult().
         */
        default void onToolExecRequest(String callId, String toolName, String inputJson) {}

        /**
         * Channel mode only: Claude Code sends a complete text reply.
         */
        default void onReply(String text) {}
    }

    /**
     * Handle for cancelling an in-flight request.
     */
    class StreamHandle {
        private volatile Thread requestThread;
        private volatile java.io.Closeable stream;
        private volatile boolean cancelled = false;

        public void cancel() {
            cancelled = true;
            // A read blocked on the HTTP body ignores interrupts; closing the body
            // stream is what wakes it.
            closeStream();
            Thread t = requestThread;
            if (t != null) {
                t.interrupt();
            }
        }

        public boolean isCancelled() {
            return cancelled;
        }

        public void setRequestThread(Thread t) {
            this.requestThread = t;
        }

        /** The response body being read, closed on cancel. Pass null when done. */
        public void setStream(java.io.Closeable s) {
            this.stream = s;
            if (cancelled) closeStream();
        }

        private void closeStream() {
            java.io.Closeable s = stream;
            if (s != null) {
                try {
                    s.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    /**
     * Start a request. Returns a handle for cancellation.
     */
    StreamHandle sendMessage(String requestJson, StreamCallbacks callbacks);

    /**
     * Send a tool execution result back to the backend (channel mode only).
     */
    default void sendToolResult(String callId, String resultJson) {}

    /**
     * Is this backend configured and ready to use?
     */
    boolean isConfigured();

    /**
     * Shut down resources.
     */
    void shutdown();
}
