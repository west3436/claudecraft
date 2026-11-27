package com.claudecraft.api;

import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.Set;

/**
 * Adds Anthropic prompt-caching breakpoints to a Messages API request body
 * (API key mode only; Claude Code does its own caching in channel mode).
 *
 * <p>The cached prefix renders in the order tools -> system -> messages, and a
 * breakpoint caches everything up to and including the marked block. We place
 * up to three explicit 5-minute ({@code {"type":"ephemeral"}}) breakpoints, well
 * under the API limit of four:
 * <ol>
 *   <li><b>Last tool definition</b> - the tool list is identical across every
 *       computer on the server, so this entry is shared between computers and
 *       across program restarts (caches are scoped to the API key's workspace).</li>
 *   <li><b>System prompt</b> - caches tools + system. The system prompt is built
 *       once per program run, so it is stable for the whole session.</li>
 *   <li><b>Last content block of the last message</b> - caches the conversation
 *       prefix incrementally. On the next agent round the previous marker
 *       position is a read point, so only the newly appended turn is written.</li>
 * </ol>
 *
 * <p>Prefixes shorter than the model's minimum are silently not cached; no error is
 * returned. Estimated from claude.lua on 2026-11-27 (char counts, not a token count):
 * tools + system is about 4.5k chars on a plain computer and about 7k on a turtle with
 * http. That is roughly 1.1k-2.3k tokens, plus the API's own tool-use preamble (286-675
 * tokens depending on the model). Against each minimum:
 * <ul>
 *   <li>512 (Claude 5.x models): clears.</li>
 *   <li>1024 (Sonnet 4.6, the default, plus Sonnet 4.5, Sonnet 5, Opus 4.8): clears.</li>
 *   <li>2048 (Opus 4.7): borderline on a plain computer.</li>
 *   <li>4096 (Opus 4.6/4.5, Haiku 4.5): does not clear. Only the conversation
 *       breakpoint caches, and only once the whole prompt passes 4096 tokens,
 *       usually after a tool round or two.</li>
 * </ul>
 */
public final class PromptCaching {
    public static final int MAX_BREAKPOINTS = 4;

    /** Block types that the API refuses to mark with cache_control. */
    private static final Set<String> UNMARKABLE_TYPES = Set.of("thinking", "redacted_thinking");

    private PromptCaching() {}

    /**
     * Mutate {@code body} in place, adding cache_control breakpoints.
     * No-op when caching is disabled in the config.
     */
    public static void apply(JsonObject body) {
        if (!ClaudeCraftConfig.ENABLE_PROMPT_CACHING.get()) return;
        addBreakpoints(body);
    }

    /** Config-independent core of {@link #apply}; mutates {@code body} in place. */
    static void addBreakpoints(JsonObject body) {
        int budget = MAX_BREAKPOINTS - countExistingMarkers(body);

        // 1. Last tool definition
        if (budget > 0 && body.has("tools") && body.get("tools").isJsonArray()) {
            JsonArray tools = body.getAsJsonArray("tools");
            if (!tools.isEmpty() && tools.get(tools.size() - 1).isJsonObject()) {
                if (mark(tools.get(tools.size() - 1).getAsJsonObject())) budget--;
            }
        }

        // 2. System prompt (string -> single text block so it can carry the marker)
        if (budget > 0 && body.has("system")) {
            JsonElement sys = body.get("system");
            if (sys.isJsonPrimitive() && sys.getAsJsonPrimitive().isString()) {
                String text = sys.getAsString();
                if (!text.isEmpty()) {
                    JsonObject block = textBlock(text);
                    mark(block);
                    JsonArray arr = new JsonArray();
                    arr.add(block);
                    body.add("system", arr);
                    budget--;
                }
            } else if (sys.isJsonArray()) {
                if (markLastEligible(sys.getAsJsonArray())) budget--;
            }
        }

        // 3. Final content block of the last message
        if (budget > 0 && body.has("messages") && body.get("messages").isJsonArray()) {
            JsonArray messages = body.getAsJsonArray("messages");
            if (!messages.isEmpty() && messages.get(messages.size() - 1).isJsonObject()) {
                JsonObject last = messages.get(messages.size() - 1).getAsJsonObject();
                JsonElement content = last.get("content");
                if (content != null && content.isJsonPrimitive()
                        && content.getAsJsonPrimitive().isString()) {
                    // A string is shorthand for one text block, so the rendered prompt
                    // (and therefore the cache key) is the same either way.
                    String text = content.getAsString();
                    if (!text.isEmpty()) {
                        JsonObject block = textBlock(text);
                        mark(block);
                        JsonArray arr = new JsonArray();
                        arr.add(block);
                        last.add("content", arr);
                    }
                } else if (content != null && content.isJsonArray()) {
                    markLastEligible(content.getAsJsonArray());
                }
            }
        }
    }

    private static JsonObject textBlock(String text) {
        JsonObject block = new JsonObject();
        block.addProperty("type", "text");
        block.addProperty("text", text);
        return block;
    }

    private static JsonObject ephemeral() {
        JsonObject cc = new JsonObject();
        cc.addProperty("type", "ephemeral");
        return cc;
    }

    /** Add a marker unless the object already has one. Returns true if one was added. */
    private static boolean mark(JsonObject obj) {
        if (obj.has("cache_control")) return false;
        obj.add("cache_control", ephemeral());
        return true;
    }

    /** Mark the last block in {@code blocks} that is allowed to carry cache_control. */
    private static boolean markLastEligible(JsonArray blocks) {
        for (int i = blocks.size() - 1; i >= 0; i--) {
            JsonElement el = blocks.get(i);
            if (!el.isJsonObject()) continue;
            JsonObject block = el.getAsJsonObject();
            if (block.has("cache_control")) return false; // already marked here
            String type = block.has("type") && block.get("type").isJsonPrimitive()
                    ? block.get("type").getAsString() : "";
            if (UNMARKABLE_TYPES.contains(type)) continue;
            if ("text".equals(type)) {
                JsonElement t = block.get("text");
                if (t == null || !t.isJsonPrimitive() || t.getAsString().isEmpty()) continue;
            }
            block.add("cache_control", ephemeral());
            return true;
        }
        return false;
    }

    /** Count cache_control markers already present, so we never exceed the API limit. */
    private static int countExistingMarkers(JsonObject body) {
        int n = 0;
        if (body.has("tools") && body.get("tools").isJsonArray()) {
            n += countInArray(body.getAsJsonArray("tools"));
        }
        if (body.has("system") && body.get("system").isJsonArray()) {
            n += countInArray(body.getAsJsonArray("system"));
        }
        if (body.has("messages") && body.get("messages").isJsonArray()) {
            for (JsonElement m : body.getAsJsonArray("messages")) {
                if (!m.isJsonObject()) continue;
                JsonElement c = m.getAsJsonObject().get("content");
                if (c != null && c.isJsonArray()) n += countInArray(c.getAsJsonArray());
            }
        }
        if (body.has("cache_control")) n++; // top-level automatic caching uses a slot
        return n;
    }

    private static int countInArray(JsonArray arr) {
        int n = 0;
        for (JsonElement el : arr) {
            if (el.isJsonObject() && el.getAsJsonObject().has("cache_control")) n++;
        }
        return n;
    }
}
