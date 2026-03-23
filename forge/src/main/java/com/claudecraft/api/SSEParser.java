package com.claudecraft.api;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/**
 * Shared SSE (Server-Sent Events) line-level parser.
 * Handles accumulating multi-line data fields and detecting event boundaries.
 * Used by both {@link ApiKeyBackend} (Anthropic API SSE) and
 * {@link ChannelBackend} (channel server SSE).
 */
public class SSEParser implements AutoCloseable {
    private final BufferedReader reader;
    private String pendingEventType;
    private final StringBuilder dataBuilder = new StringBuilder();

    /**
     * Represents a single SSE event with its optional event type and data payload.
     */
    public static class SSEEvent {
        public final String eventType;
        public final String data;

        public SSEEvent(String eventType, String data) {
            this.eventType = eventType;
            this.data = data;
        }
    }

    public SSEParser(InputStream inputStream) {
        this.reader = new BufferedReader(
                new InputStreamReader(inputStream, StandardCharsets.UTF_8));
    }

    /**
     * Read the next complete SSE event from the stream.
     * Blocks until a full event (terminated by a blank line) is available.
     *
     * @param handle StreamHandle to check for cancellation
     * @return the next SSE event, or null if the stream ended or was cancelled
     */
    public SSEEvent next(ClaudeBackend.StreamHandle handle) throws Exception {
        String line;
        while ((line = reader.readLine()) != null) {
            if (handle.isCancelled()) return null;

            if (line.startsWith("event: ")) {
                pendingEventType = line.substring(7).trim();
            } else if (line.startsWith("data: ")) {
                dataBuilder.append(line.substring(6));
            } else if (line.isEmpty() && dataBuilder.length() > 0) {
                String data = dataBuilder.toString().trim();
                String type = pendingEventType;
                pendingEventType = null;
                dataBuilder.setLength(0);
                return new SSEEvent(type, data);
            }
        }
        return null; // Stream ended
    }

    @Override
    public void close() throws Exception {
        reader.close();
    }
}
