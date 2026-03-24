package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.*;
import dan200.computercraft.api.lua.*;
import dan200.computercraft.api.peripheral.IComputerAccess;
import net.minecraft.core.RegistryAccess;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.*;
import net.minecraftforge.registries.ForgeRegistries;
import net.minecraftforge.server.ServerLifecycleHooks;
import org.jetbrains.annotations.NotNull;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Built-in Lua API available on all CC:Tweaked computers as 'claude'.
 *
 * Lua API:
 *   claude.isApiKeyConfigured()                   -> boolean
 *   claude.getModel()                             -> string
 *   claude.startChannel(isTurtle, label, w, h)    -> success, errorOrPort
 *   claude.stopChannel()                          -> nil
 *   claude.isChannelReady()                       -> boolean
 *   claude.sendMessage(messages, tools, system)   -> requestId (string)
 *   claude.sendToolResult(reqId, callId, result)  -> nil
 *   claude.cancelRequest(requestId)               -> nil
 *
 * Events pushed to the computer:
 *   -- API key mode (streaming):
 *   "claude_delta"      requestId, text
 *   "claude_tool_start" requestId, toolId, toolName
 *   "claude_tool_done"  requestId, toolId, toolName, inputJson
 *   "claude_done"       requestId, stopReason, inputTokens, outputTokens
 *   "claude_error"      requestId, errorMessage
 *
 *   -- Channel mode:
 *   "claude_tool_exec"  requestId, callId, toolName, inputJson
 *   "claude_text"       requestId, text
 */
public class ClaudeAPI implements ILuaAPI {
    private static final Gson GSON = new GsonBuilder().create();
    private static final AtomicLong REQUEST_COUNTER = new AtomicLong(0);

    /** Unique prefix per JVM lifetime to prevent request ID collisions across server restarts. */
    private static final String REQUEST_ID_PREFIX = "req_" +
            Long.toHexString(System.nanoTime()).substring(0, 6) + "_";

    /** JSON keys that should be arrays when their Lua table is empty. */
    private static final Set<String> ARRAY_KEYS = Set.of(
            "required", "content", "messages", "tools", "stop_sequences", "args", "items"
    );

    private final IComputerAccess computer;
    private final Map<String, ClaudeBackend.StreamHandle> activeRequests = new ConcurrentHashMap<>();

    /** Per-computer channel backend, created when startChannel() is called. */
    private volatile ChannelBackend channelBackend;

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
        for (ClaudeBackend.StreamHandle handle : activeRequests.values()) {
            handle.cancel();
        }
        activeRequests.clear();

        // Stop channel process if running
        if (channelBackend != null) {
            channelBackend.shutdown();
            ChannelProcessManager.getInstance().stopSession(computer.getID());
            channelBackend = null;
        }
    }

    // -- Lua API Methods --

    /**
     * Check if the API key is configured (for API key mode).
     */
    @LuaFunction
    public final boolean isApiKeyConfigured() {
        String key = ClaudeCraftConfig.API_KEY.get();
        return key != null && !key.isEmpty() && key.startsWith("sk-");
    }

    /**
     * Get the configured model name (API key mode).
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
     * Get the configured tool timeout in seconds.
     */
    @LuaFunction
    public final int getToolTimeout() {
        return ClaudeCraftConfig.TOOL_TIMEOUT_SECONDS.get();
    }

    /**
     * Get the configured personality string for the system prompt.
     */
    @LuaFunction
    public final String getPersonality() {
        String p = ClaudeCraftConfig.PERSONALITY.get();
        return p != null ? p : "";
    }

    /**
     * Start a Claude Code channel session for this computer.
     * Spawns a channel server and Claude Code process automatically.
     *
     * @param args Lua arguments: isTurtle (boolean), label (string), termW (int), termH (int)
     * @return {success: boolean, portOrError: number|string}
     */
    @LuaFunction
    public final Object[] startChannel(@NotNull IArguments args) throws LuaException {
        boolean isTurtle = args.optBoolean(0).orElse(false);
        String label = args.optString(1).orElse("Computer");
        int termW = args.optInt(2).orElse(51);
        int termH = args.optInt(3).orElse(19);

        int computerId = computer.getID();

        try {
            ChannelProcessManager.SessionInfo session =
                    ChannelProcessManager.getInstance().startSession(
                            computerId, isTurtle, label, termW, termH);

            channelBackend = new ChannelBackend(session.port);

            // Start a persistent global SSE listener for incoming inter-computer messages.
            channelBackend.connectGlobalSSE(createChannelCallbacks("incoming"));

            ClaudeCraft.LOGGER.info("Channel spawned for computer #{} on port {}",
                    computerId, session.port);
            return new Object[]{true, session.port};

        } catch (Exception e) {
            ClaudeCraft.LOGGER.error("Failed to start channel for computer #{}", computerId, e);
            return new Object[]{false, e.getMessage()};
        }
    }

    /**
     * Stop the channel session for this computer.
     */
    @LuaFunction
    public final void stopChannel() {
        if (channelBackend != null) {
            channelBackend.shutdown();
            channelBackend = null;
        }
        ChannelProcessManager.getInstance().stopSession(computer.getID());
    }

    /**
     * Check if a channel session is active and connected.
     */
    @LuaFunction
    public final boolean isChannelReady() {
        return channelBackend != null && channelBackend.isConfigured();
    }

    /**
     * Send a message to Claude. Returns immediately with a request ID.
     * Automatically routes to the active backend (API key or channel).
     *
     * @param args Lua arguments: messages (table), tools (table|nil), system (string|nil)
     * @return Request ID string
     */
    @LuaFunction
    public final String sendMessage(@NotNull IArguments args) throws LuaException {
        boolean useChannel = channelBackend != null;

        if (!useChannel && !isApiKeyConfigured()) {
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

        // Convert tools Lua table to JSON array if provided (API key mode only)
        if (toolsOpt.isPresent() && !useChannel) {
            JsonArray toolsJson = luaMapToJsonArray(toolsOpt.get());
            request.add("tools", toolsJson);
        }

        // Generate request ID
        String requestId = REQUEST_ID_PREFIX + REQUEST_COUNTER.incrementAndGet();

        // Route to active backend
        ClaudeBackend.StreamHandle handle;
        if (useChannel) {
            handle = channelBackend.sendMessage(request.toString(),
                    createChannelCallbacks(requestId));
        } else {
            handle = ApiKeyBackend.getInstance().sendMessage(request.toString(),
                    createApiKeyCallbacks(requestId));
        }

        activeRequests.put(requestId, handle);
        return requestId;
    }

    /**
     * Send a tool execution result back to the channel server.
     * Channel mode only.
     */
    @LuaFunction
    public final void sendToolResult(@NotNull IArguments args) throws LuaException {
        if (channelBackend == null) {
            throw new LuaException("sendToolResult is only available in channel mode");
        }

        String requestId = args.getString(0);
        String callId = args.getString(1);
        String resultJson = args.getString(2);

        channelBackend.sendToolResult(callId, resultJson);
    }

    /**
     * Cancel an in-flight request.
     */
    @LuaFunction
    public final void cancelRequest(@NotNull IArguments args) throws LuaException {
        String requestId = args.getString(0);
        ClaudeBackend.StreamHandle handle = activeRequests.remove(requestId);
        if (handle != null) {
            handle.cancel();
        }
    }

    /**
     * Get Minecraft recipes, optionally filtered by output item name or recipe type.
     *
     * @param args Lua arguments: itemFilter (string|nil), typeFilter (string|nil)
     * @return JSON string with matching recipes
     */
    @LuaFunction
    public final String getRecipes(@NotNull IArguments args) throws LuaException {
        MinecraftServer server = ServerLifecycleHooks.getCurrentServer();
        if (server == null) {
            throw new LuaException("Server not available");
        }

        String itemFilter = args.optString(0).orElse(null);
        String typeFilter = args.optString(1).orElse(null);

        RecipeManager recipeManager = server.getRecipeManager();
        RegistryAccess registryAccess = server.registryAccess();

        JsonArray results = new JsonArray();

        for (RecipeHolder<?> holder : recipeManager.getRecipes()) {
            Recipe<?> recipe = holder.value();

            ResourceLocation typeId = ForgeRegistries.RECIPE_TYPES.getKey(recipe.getType());
            String typeStr = typeId != null ? typeId.toString() : "unknown";

            if (typeFilter != null && !typeStr.contains(typeFilter)) continue;

            ItemStack result = recipe.getResultItem(registryAccess);
            ResourceLocation resultId = ForgeRegistries.ITEMS.getKey(result.getItem());
            String resultName = resultId != null ? resultId.toString() : "unknown";

            if (itemFilter != null && !resultName.contains(itemFilter)) continue;

            JsonObject recipeObj = new JsonObject();
            recipeObj.addProperty("id", holder.id().toString());
            recipeObj.addProperty("type", typeStr);
            recipeObj.addProperty("result", resultName);
            recipeObj.addProperty("result_count", result.getCount());

            JsonArray ingredients = new JsonArray();
            for (Ingredient ingredient : recipe.getIngredients()) {
                if (ingredient.isEmpty()) continue;
                JsonArray items = new JsonArray();
                for (ItemStack item : ingredient.getItems()) {
                    ResourceLocation itemId = ForgeRegistries.ITEMS.getKey(item.getItem());
                    if (itemId != null) items.add(itemId.toString());
                }
                if (items.size() > 0) ingredients.add(items);
            }
            recipeObj.add("ingredients", ingredients);

            if (recipe instanceof ShapedRecipe shaped) {
                recipeObj.addProperty("width", shaped.getWidth());
                recipeObj.addProperty("height", shaped.getHeight());
            }

            results.add(recipeObj);
        }

        JsonObject response = new JsonObject();
        response.add("recipes", results);
        response.addProperty("count", results.size());
        return GSON.toJson(response);
    }

    // -- Callback factories --

    private ClaudeBackend.StreamCallbacks createApiKeyCallbacks(String requestId) {
        return new ClaudeBackend.StreamCallbacks() {
            @Override
            public void onTextDelta(String text) {
                queueEvent("claude_delta", requestId, text);
            }

            @Override
            public void onToolUseStart(String id, String name) {
                queueEvent("claude_tool_start", requestId, id, name);
            }

            @Override
            public void onToolUseDelta(String id, String partialJson) {}

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
        };
    }

    private ClaudeBackend.StreamCallbacks createChannelCallbacks(String requestId) {
        return new ClaudeBackend.StreamCallbacks() {
            @Override
            public void onTextDelta(String text) {}

            @Override
            public void onToolUseStart(String id, String name) {}

            @Override
            public void onToolUseDelta(String id, String partialJson) {}

            @Override
            public void onToolUseComplete(String id, String name, JsonObject input) {}

            @Override
            public void onToolExecRequest(String callId, String toolName, String inputJson) {
                queueEvent("claude_tool_exec", requestId, callId, toolName, inputJson);
            }

            @Override
            public void onReply(String text) {
                queueEvent("claude_text", requestId, text);
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
        };
    }

    // -- Internal helpers --

    private void queueEvent(String name, Object... args) {
        try {
            computer.queueEvent(name, args);
        } catch (Exception e) {
            ClaudeCraft.LOGGER.warn("Failed to queue event to computer: {}", e.getMessage());
        }
    }

    private JsonArray luaMapToJsonArray(Map<?, ?> table) {
        JsonArray array = new JsonArray();
        for (int i = 1; ; i++) {
            Object value = table.get((double) i);
            if (value == null) break;
            array.add(luaValueToJson(value, null));
        }
        return array;
    }

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
            if (map.isEmpty()) {
                if (parentKey != null && ARRAY_KEYS.contains(parentKey)) {
                    return new JsonArray();
                }
                return new JsonObject();
            }

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
