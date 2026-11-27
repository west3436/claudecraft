package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.channel.ChannelAccess;
import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.*;
import dan200.computercraft.api.lua.*;
import net.minecraft.core.RegistryAccess;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.neoforged.neoforge.server.ServerLifecycleHooks;
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
 *   claude.getRecipes(item, type, limit, maxAlts) -> JSON string (needs item or type filter)
 *
 * Events pushed to the computer:
 *   -- API key mode (streaming):
 *   "claude_delta"      requestId, text
 *   "claude_tool_start" requestId, toolId, toolName
 *   "claude_tool_done"  requestId, toolId, toolName, inputJson
 *   "claude_done"       requestId, stopReason, inputTokens, outputTokens,
 *                       cacheCreationTokens, cacheReadTokens
 *                       (inputTokens is the uncached remainder; channel mode omits the cache fields)
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

    private final IComputerSystem computer;
    private final Map<String, ClaudeBackend.StreamHandle> activeRequests = new ConcurrentHashMap<>();

    /** Per-computer channel backend, created when startChannel() is called. */
    private volatile ChannelBackend channelBackend;

    /** The session channelBackend talks to. Checked before each use: it may have been stopped or replaced. */
    private volatile ChannelProcessManager.SessionInfo channelSession;

    public ClaudeAPI(IComputerSystem computer) {
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
        closeChannel();
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
     * <p>Refused unless channel mode is enabled and this computer is on the
     * allowlist (see {@link ChannelAccess}), or when the session cap is reached.
     * The label is read from the computer itself; the Lua label argument is
     * ignored.
     *
     * @param args Lua arguments: isTurtle (boolean), label (string, ignored), termW (int), termH (int)
     * @return {success: boolean, portOrError: number|string}
     */
    @LuaFunction
    public final Object[] startChannel(@NotNull IArguments args) throws LuaException {
        boolean isTurtle = args.optBoolean(0).orElse(false);
        int termW = args.optInt(2).orElse(51);
        int termH = args.optInt(3).orElse(19);

        int computerId = computer.getID();

        String refusal = ChannelAccess.refusalFor(computerId);
        if (refusal != null) {
            ClaudeCraft.LOGGER.info("Refused channel session for computer #{}: {}", computerId, refusal);
            return new Object[]{false, refusal};
        }

        // Label from the computer, not from Lua; the manager sanitizes it
        String label = computer.getLabel();

        // Drop any backend from an earlier startChannel before replacing it
        ChannelBackend oldBackend = channelBackend;
        channelBackend = null;
        channelSession = null;
        if (oldBackend != null) {
            oldBackend.shutdown();
        }

        try {
            ChannelProcessManager.SessionInfo session =
                    ChannelProcessManager.getInstance().startSession(
                            computerId, isTurtle, label, termW, termH);

            ChannelBackend backend = new ChannelBackend(session.port);

            // Start a persistent global SSE listener for incoming inter-computer messages.
            backend.connectGlobalSSE(createChannelCallbacks("incoming"));

            channelSession = session;
            channelBackend = backend;

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
        boolean hadSession = channelSession != null;
        closeChannel();
        if (!hadSession) {
            ChannelProcessManager.getInstance().stopSession(computer.getID());
        }
    }

    /**
     * Check if a channel session is active and connected.
     */
    @LuaFunction
    public final boolean isChannelReady() {
        ChannelBackend backend = channelBackend;
        return backend != null && channelProblem() == null && backend.isConfigured();
    }

    /**
     * Why this computer's channel can't be used right now, or null if it can.
     * The session may have been stopped (by an operator, a crash or a restart),
     * replaced, or channel access may have been withdrawn since it started.
     */
    private String channelProblem() {
        ChannelProcessManager.SessionInfo session = channelSession;
        if (session == null) {
            return "No channel session. Exit and run claude again.";
        }
        String refusal = ChannelAccess.refusalFor(computer.getID());
        if (refusal != null) {
            ChannelProcessManager.getInstance().stopSession(session);
            return refusal;
        }
        if (ChannelProcessManager.getInstance().getSession(computer.getID()) != session) {
            return "This computer's Claude Code session has ended. Exit and run claude again.";
        }
        return null;
    }

    /** Shut down this computer's backend and stop its session. */
    private void closeChannel() {
        ChannelBackend backend = channelBackend;
        ChannelProcessManager.SessionInfo session = channelSession;
        channelBackend = null;
        channelSession = null;
        if (backend != null) {
            backend.shutdown();
        }
        if (session != null) {
            ChannelProcessManager.getInstance().stopSession(session);
        }
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
        ChannelBackend backend = channelBackend;
        boolean useChannel = backend != null;

        if (!useChannel && !isApiKeyConfigured()) {
            throw new LuaException("API key not configured. Use /claudecraft setkey <key>");
        }

        if (useChannel) {
            // Report through the normal error event so the program can carry on
            String problem = channelProblem();
            if (problem != null) {
                String requestId = REQUEST_ID_PREFIX + REQUEST_COUNTER.incrementAndGet();
                queueEvent("claude_error", requestId, problem);
                return requestId;
            }
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
            handle = backend.sendMessage(request.toString(),
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
        ChannelBackend backend = channelBackend;
        if (backend == null) {
            throw new LuaException("sendToolResult is only available in channel mode");
        }

        String requestId = args.getString(0);
        String callId = args.getString(1);
        String resultJson = args.getString(2);

        // Don't deliver to a port this computer's session no longer owns
        String problem = channelProblem();
        if (problem != null) {
            ClaudeCraft.LOGGER.debug("Dropping tool result for computer #{}: {}",
                    computer.getID(), problem);
            return;
        }

        backend.sendToolResult(callId, resultJson);
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

    private static final int DEFAULT_RECIPE_LIMIT = 20;
    private static final int MAX_RECIPE_LIMIT = 100;

    /** A recipe that passed the filters, kept until we sort and cap the results. */
    private record RecipeMatch(RecipeHolder<?> holder, String type, String result, ItemStack resultStack, int rank) {}

    /**
     * Get Minecraft recipes filtered by output item name and/or recipe type.
     * <p>
     * At least one filter is required; an unfiltered call used to serialise every
     * recipe on the server. Results are capped, exact output matches sort first,
     * and a recipe that throws (broken modded recipe) is skipped rather than
     * aborting the whole call. Runs on the server thread because it reads the
     * RecipeManager and resolves ingredient tags.
     * <p>
     * Shaped recipes carry {@code width}, {@code height} and {@code grid}: a
     * row-major array of width*height entries, each 0 for an empty cell or the
     * 1-based index of that cell's entry in {@code ingredients}.
     *
     * @param args Lua arguments: itemFilter (string|nil), typeFilter (string|nil),
     *             limit (int|nil, default 20, max 100),
     *             maxAlternatives (int|nil, items listed per ingredient, 0 = all)
     * @return JSON string with matching recipes, or {"error": ...}
     */
    @LuaFunction(mainThread = true)
    public final String getRecipes(@NotNull IArguments args) throws LuaException {
        MinecraftServer server = ServerLifecycleHooks.getCurrentServer();
        if (server == null) {
            throw new LuaException("Server not available");
        }

        String itemFilter = normaliseFilter(args.optString(0).orElse(null));
        String typeFilter = normaliseFilter(args.optString(1).orElse(null));
        int limit = Math.max(1, Math.min(MAX_RECIPE_LIMIT, args.optInt(2).orElse(DEFAULT_RECIPE_LIMIT)));
        int maxAlternatives = Math.max(0, args.optInt(3).orElse(0));

        if (itemFilter == null && typeFilter == null) {
            JsonObject err = new JsonObject();
            err.addProperty("error", "Give an item filter (e.g. 'iron_pickaxe') or a type filter (e.g. 'smelting'). "
                    + "Listing every recipe on the server is not supported.");
            return GSON.toJson(err);
        }

        RecipeManager recipeManager = server.getRecipeManager();
        RegistryAccess registryAccess = server.registryAccess();

        List<RecipeMatch> matches = new ArrayList<>();
        int skipped = 0;

        for (RecipeHolder<?> holder : recipeManager.getRecipes()) {
            try {
                Recipe<?> recipe = holder.value();

                ResourceLocation typeId = BuiltInRegistries.RECIPE_TYPE.getKey(recipe.getType());
                String typeStr = typeId != null ? typeId.toString() : "unknown";
                if (typeFilter != null && !typeStr.contains(typeFilter)) continue;

                ItemStack result = recipe.getResultItem(registryAccess);
                // Special recipes (map cloning, firework stars, ...) have no fixed output.
                if (result.isEmpty()) continue;
                ResourceLocation resultId = BuiltInRegistries.ITEM.getKey(result.getItem());
                String resultName = resultId != null ? resultId.toString() : "unknown";

                int rank = 0;
                if (itemFilter != null) {
                    if (!resultName.contains(itemFilter)) continue;
                    String path = resultId != null ? resultId.getPath() : resultName;
                    if (resultName.equals(itemFilter) || path.equals(itemFilter)) rank = 0;
                    else if (path.startsWith(itemFilter)) rank = 1;
                    else rank = 2;
                }
                matches.add(new RecipeMatch(holder, typeStr, resultName, result, rank));
            } catch (Exception | LinkageError e) {
                skipped++;
            }
        }

        matches.sort(Comparator.comparingInt(RecipeMatch::rank)
                .thenComparingInt(m -> m.result().length())
                .thenComparing(m -> m.holder().id().toString()));

        JsonArray results = new JsonArray();
        for (RecipeMatch match : matches) {
            if (results.size() >= limit) break;
            try {
                results.add(recipeToJson(match, maxAlternatives));
            } catch (Exception | LinkageError e) {
                skipped++;
            }
        }

        JsonObject response = new JsonObject();
        response.add("recipes", results);
        response.addProperty("count", results.size());
        response.addProperty("total_matched", matches.size());
        if (matches.size() > results.size()) {
            response.addProperty("truncated", true);
        }
        if (skipped > 0) {
            response.addProperty("skipped_broken", skipped);
        }
        return GSON.toJson(response);
    }

    private static String normaliseFilter(String filter) {
        if (filter == null) return null;
        String f = filter.trim().toLowerCase(Locale.ROOT).replaceAll("\\s+", "_");
        return f.isEmpty() ? null : f;
    }

    private static JsonObject recipeToJson(RecipeMatch match, int maxAlternatives) {
        Recipe<?> recipe = match.holder().value();

        JsonObject recipeObj = new JsonObject();
        recipeObj.addProperty("id", match.holder().id().toString());
        recipeObj.addProperty("type", match.type());
        recipeObj.addProperty("result", match.result());
        recipeObj.addProperty("result_count", match.resultStack().getCount());
        recipeObj.addProperty("result_max_stack", match.resultStack().getMaxStackSize());

        List<Ingredient> all = recipe.getIngredients();
        JsonArray ingredients = new JsonArray();
        // Grid cell -> 1-based ingredient index (0 = empty), only for shaped recipes.
        int[] grid = new int[all.size()];
        boolean truncatedAlternatives = false;
        for (int i = 0; i < all.size(); i++) {
            Ingredient ingredient = all.get(i);
            if (ingredient.isEmpty()) continue;
            JsonArray items = new JsonArray();
            Set<String> seen = new HashSet<>();
            for (ItemStack item : ingredient.getItems()) {
                ResourceLocation itemId = BuiltInRegistries.ITEM.getKey(item.getItem());
                if (itemId == null || !seen.add(itemId.toString())) continue;
                if (maxAlternatives > 0 && items.size() >= maxAlternatives) {
                    truncatedAlternatives = true;
                    continue;
                }
                items.add(itemId.toString());
            }
            if (items.size() > 0) {
                ingredients.add(items);
                grid[i] = ingredients.size();
            }
        }
        recipeObj.add("ingredients", ingredients);
        if (truncatedAlternatives) {
            recipeObj.addProperty("alternatives_truncated", true);
        }

        if (recipe instanceof ShapedRecipe shaped) {
            recipeObj.addProperty("width", shaped.getWidth());
            recipeObj.addProperty("height", shaped.getHeight());
            if (all.size() == shaped.getWidth() * shaped.getHeight()) {
                JsonArray gridJson = new JsonArray();
                for (int cell : grid) gridJson.add(cell);
                recipeObj.add("grid", gridJson);
            }
        }
        return recipeObj;
    }

    /**
     * Turtle helper: is a player standing in the block next to this turtle?
     * build_structure calls this before attacking whatever blocks a move, so it
     * hits mobs but only waits for players. Lua: claude.isPlayerBlocking(dir).
     *
     * @param direction "front", "back", "up" or "down"
     * @return true if a (non-spectator) player's hitbox overlaps that block
     */
    @LuaFunction(mainThread = true)
    public final boolean isPlayerBlocking(String direction) throws LuaException {
        // Fully qualified names keep this helper self-contained (no import churn).
        dan200.computercraft.api.turtle.ITurtleAccess turtle =
                computer.getComponent(dan200.computercraft.api.component.ComputerComponents.TURTLE);
        if (turtle == null) throw new LuaException("Not a turtle");
        net.minecraft.core.Direction dir = switch (direction) {
            case "front", "forward" -> turtle.getDirection();
            case "back" -> turtle.getDirection().getOpposite();
            case "up", "top" -> net.minecraft.core.Direction.UP;
            case "down", "bottom" -> net.minecraft.core.Direction.DOWN;
            default -> throw new LuaException("Unknown direction: " + direction);
        };
        net.minecraft.core.BlockPos pos = turtle.getPosition().relative(dir);
        net.minecraft.world.phys.AABB box = new net.minecraft.world.phys.AABB(
                pos.getX(), pos.getY(), pos.getZ(), pos.getX() + 1, pos.getY() + 1, pos.getZ() + 1);
        return !turtle.getLevel().getEntitiesOfClass(
                net.minecraft.world.entity.player.Player.class, box, p -> !p.isSpectator()).isEmpty();
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
                onComplete(stopReason, inputTokens, outputTokens, 0, 0);
            }

            @Override
            public void onComplete(String stopReason, int inputTokens, int outputTokens,
                                   int cacheCreationTokens, int cacheReadTokens) {
                queueEvent("claude_done", requestId, stopReason, inputTokens, outputTokens,
                        cacheCreationTokens, cacheReadTokens);
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

            // Sort keys so identical Lua tables always serialize to identical bytes.
            // Prompt caching matches on the exact request prefix, and Lua table
            // iteration order is not guaranteed to be stable.
            TreeMap<String, Object> sorted = new TreeMap<>();
            for (Map.Entry<?, ?> entry : ((Map<Object, Object>) map).entrySet()) {
                String key = String.valueOf(entry.getKey());
                if (entry.getKey() instanceof Number n) {
                    double d = n.doubleValue();
                    if (d == Math.floor(d)) key = String.valueOf((long) d);
                }
                sorted.put(key, entry.getValue());
            }
            JsonObject obj = new JsonObject();
            for (Map.Entry<String, Object> entry : sorted.entrySet()) {
                obj.add(entry.getKey(), luaValueToJson(entry.getValue(), entry.getKey()));
            }
            return obj;
        }
        return new JsonPrimitive(value.toString());
    }
}
