package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.*;
import dan200.computercraft.api.lua.*;
import dan200.computercraft.api.peripheral.IComputerAccess;
import org.jetbrains.annotations.NotNull;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Built-in Lua API available on all CC:Tweaked computers as 'claude'.
 *
 * Lua API:
 *   claude.isConfigured()                         -> boolean
 *   claude.getModel()                             -> string
 *   claude.sendMessage(messages, tools, system)   -> requestId (string)
 *   claude.cancelRequest(requestId)               -> nil
 *
 * Events pushed to the computer:
 *   "claude_delta"      requestId, text
 *   "claude_tool_start" requestId, toolId, toolName
 *   "claude_tool_done"  requestId, toolId, toolName, inputJson
 *   "claude_done"       requestId, stopReason, inputTokens, outputTokens
 *   "claude_error"      requestId, errorMessage
 */
public class ClaudeAPI implements ILuaAPI {
    private static final Gson GSON = new GsonBuilder().create();
    private static final AtomicLong REQUEST_COUNTER = new AtomicLong(0);

    /** JSON keys that should be arrays when their Lua table is empty. */
    private static final Set<String> ARRAY_KEYS = Set.of(
            "required", "content", "messages", "tools", "stop_sequences", "args", "items"
    );

    private final IComputerAccess computer;
    private final Map<String, ClaudeApiClient.StreamHandle> activeRequests = new ConcurrentHashMap<>();

    public ClaudeAPI(IComputerAccess computer) {
        this.computer = computer;
    }

    @Override
    public String[] getNames() {
        return new String[]{"claude"};
    }

    @Override
    public void startup() {
        // Nothing to do on startup
    }

    @Override
    public void shutdown() {
        for (ClaudeApiClient.StreamHandle handle : activeRequests.values()) {
            handle.cancel();
        }
        activeRequests.clear();
    }

    // -- Lua API Methods --

    /**
     * Check if the API key is configured.
     */
    @LuaFunction
    public final boolean isConfigured() {
        return ClaudeCraftConfig.isConfigured();
    }

    /**
     * Get the configured model name.
     */
    @LuaFunction
    public final String getModel() {
        return ClaudeCraftConfig.MODEL.get();
    }

    /**
     * Check if web access is enabled in the config.
     */
    @LuaFunction
    public final boolean isWebAccessEnabled() {
        return ClaudeCraftConfig.ENABLE_WEB_ACCESS.get();
    }

    /**
     * Send a message to Claude with streaming. Returns immediately with a request ID.
     * The response is delivered via events: claude_delta, claude_tool_start,
     * claude_tool_done, claude_done, claude_error.
     *
     * @param args Lua arguments: messages (table), tools (table|nil), system (string|nil)
     * @return Request ID string
     */
    @LuaFunction
    public final String sendMessage(@NotNull IArguments args) throws LuaException {
        if (!ClaudeCraftConfig.isConfigured()) {
            throw new LuaException("API key not configured. Use /claudecraft setkey <key>");
        }

        // Parse arguments from Lua tables
        Map<?, ?> messagesTable = args.getTable(0);
        Optional<Map<?, ?>> toolsOpt = args.optTable(1);
        String systemPrompt = args.optString(2).orElse(null);

        // Build the request JSON
        JsonObject request = new JsonObject();
        request.addProperty("model", ClaudeCraftConfig.MODEL.get());
        request.addProperty("max_tokens", ClaudeCraftConfig.MAX_TOKENS.get());

        // System prompt
        String prefix = ClaudeCraftConfig.SYSTEM_PROMPT_PREFIX.get();
        if (systemPrompt != null) {
            String fullSystem = (prefix != null && !prefix.isEmpty())
                    ? prefix + "\n" + systemPrompt : systemPrompt;
            request.addProperty("system", fullSystem);
        } else if (prefix != null && !prefix.isEmpty()) {
            request.addProperty("system", prefix);
        }

        // Convert messages Lua table to JSON array
        JsonArray messagesJson = luaMapToJsonArray(messagesTable);
        request.add("messages", messagesJson);

        // Convert tools Lua table to JSON array if provided
        if (toolsOpt.isPresent()) {
            JsonArray toolsJson = luaMapToJsonArray(toolsOpt.get());
            request.add("tools", toolsJson);
        }

        // Generate request ID
        String requestId = "req_" + REQUEST_COUNTER.incrementAndGet();

        // Start the streaming request
        ClaudeApiClient client = ClaudeApiClient.getInstance();
        ClaudeApiClient.StreamHandle handle = client.streamRequest(
                request.toString(),
                new ClaudeApiClient.StreamCallbacks() {
                    @Override
                    public void onTextDelta(String text) {
                        queueEvent("claude_delta", requestId, text);
                    }

                    @Override
                    public void onToolUseStart(String id, String name) {
                        queueEvent("claude_tool_start", requestId, id, name);
                    }

                    @Override
                    public void onToolUseDelta(String id, String partialJson) {
                        // Accumulate only — don't send partial tool input to Lua
                    }

                    @Override
                    public void onToolUseComplete(String id, String name, JsonObject input) {
                        String inputJson = GSON.toJson(input);
                        queueEvent("claude_tool_done", requestId, id, name, inputJson);
                    }

                    @Override
                    public void onComplete(String stopReason, int inputTokens, int outputTokens) {
                        queueEvent("claude_done", requestId, stopReason, inputTokens, outputTokens);
                        activeRequests.remove(requestId);
                    }

                    @Override
                    public void onError(String message) {
                        queueEvent("claude_error", requestId, message);
                        activeRequests.remove(requestId);
                    }
                }
        );

        activeRequests.put(requestId, handle);
        return requestId;
    }

    /**
     * Cancel an in-flight request.
     */
    @LuaFunction
    public final void cancelRequest(@NotNull IArguments args) throws LuaException {
        String requestId = args.getString(0);
        ClaudeApiClient.StreamHandle handle = activeRequests.remove(requestId);
        if (handle != null) {
            handle.cancel();
        }
    }

    // -- Internal helpers --

    private void queueEvent(String name, Object... args) {
        try {
            computer.queueEvent(name, args);
        } catch (Exception e) {
            ClaudeCraft.LOGGER.warn("Failed to queue event to computer: {}", e.getMessage());
        }
    }

    /**
     * Convert a Lua table (Map from CC: Tweaked) to a Gson JsonArray.
     * Assumes sequential numeric keys starting at 1.0 (Lua convention).
     */
    private JsonArray luaMapToJsonArray(Map<?, ?> table) {
        JsonArray array = new JsonArray();
        for (int i = 1; ; i++) {
            Object value = table.get((double) i);
            if (value == null) break;
            array.add(luaValueToJson(value, null));
        }
        return array;
    }

    /**
     * Convert a Lua value to a JsonElement.
     * @param parentKey the JSON key this value belongs to (for context-aware conversion), or null
     */
    @SuppressWarnings("unchecked")
    private JsonElement luaValueToJson(Object value, String parentKey) {
        if (value == null) {
            return JsonNull.INSTANCE;
        } else if (value instanceof String s) {
            return new JsonPrimitive(s);
        } else if (value instanceof Number n) {
            double d = n.doubleValue();
            if (d == Math.floor(d) && !Double.isInfinite(d)) {
                return new JsonPrimitive((long) d);
            }
            return new JsonPrimitive(d);
        } else if (value instanceof Boolean b) {
            return new JsonPrimitive(b);
        } else if (value instanceof Map<?, ?> map) {
            // Empty table: decide based on context
            if (map.isEmpty()) {
                if (parentKey != null && ARRAY_KEYS.contains(parentKey)) {
                    return new JsonArray();
                }
                return new JsonObject();
            }

            // Check if it's an array-like table (all keys are sequential ints from 1)
            boolean isArray = true;
            int maxIndex = 0;
            for (Object key : map.keySet()) {
                if (key instanceof Number n) {
                    int idx = n.intValue();
                    if (idx == n.doubleValue() && idx >= 1) {
                        maxIndex = Math.max(maxIndex, idx);
                        continue;
                    }
                }
                isArray = false;
                break;
            }

            if (isArray && maxIndex > 0 && maxIndex == map.size()) {
                JsonArray arr = new JsonArray();
                for (int i = 1; i <= maxIndex; i++) {
                    Object v = map.get((double) i);
                    arr.add(luaValueToJson(v, null));
                }
                return arr;
            }

            // It's an object
            JsonObject obj = new JsonObject();
            for (Map.Entry<?, ?> entry : ((Map<Object, Object>) map).entrySet()) {
                String key = String.valueOf(entry.getKey());
                if (entry.getKey() instanceof Number n) {
                    double d = n.doubleValue();
                    if (d == Math.floor(d)) key = String.valueOf((long) d);
                }
                obj.add(key, luaValueToJson(entry.getValue(), key));
            }
            return obj;
        }
        return new JsonPrimitive(value.toString());
    }
}
