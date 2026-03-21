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
        void onComplete(String stopReason, int inputTokens, int outputTokens);
        void onError(String message);

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
        private volatile boolean cancelled = false;

        public void cancel() {
            cancelled = true;
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
