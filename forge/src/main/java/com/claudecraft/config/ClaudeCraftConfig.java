package com.claudecraft.config;

import net.neoforged.neoforge.common.ModConfigSpec;

import java.util.List;

public class ClaudeCraftConfig {
    public static final ModConfigSpec SPEC;

    /**
     * Legacy key location. SERVER configs are synced to every client, so this is never used as a
     * key source. It stays in the spec only so {@link ApiKeyProvider} can migrate and blank it;
     * use {@link ApiKeyProvider} for the key.
     */
    public static final ModConfigSpec.ConfigValue<String> API_KEY;
    public static final ModConfigSpec.ConfigValue<String> MODEL;
    public static final ModConfigSpec.IntValue MAX_TOKENS;
    public static final ModConfigSpec.IntValue MAX_CONCURRENT_REQUESTS;
    public static final ModConfigSpec.IntValue REQUEST_TIMEOUT_SECONDS;
    public static final ModConfigSpec.ConfigValue<String> SYSTEM_PROMPT_PREFIX;
    public static final ModConfigSpec.BooleanValue ENABLE_WEB_ACCESS;
    public static final ModConfigSpec.BooleanValue ALLOW_SERVER_TOOLS;
    public static final ModConfigSpec.IntValue TOOL_TIMEOUT_SECONDS;
    public static final ModConfigSpec.ConfigValue<String> PERSONALITY;
    public static final ModConfigSpec.BooleanValue ENABLE_PROMPT_CACHING;

    public static final ModConfigSpec.BooleanValue ENABLE_CHANNEL_MODE;
    public static final ModConfigSpec.IntValue MAX_CHANNEL_SESSIONS;
    public static final ModConfigSpec.ConfigValue<List<? extends Number>> ALLOWED_COMPUTERS;
    public static final ModConfigSpec.BooleanValue ALLOW_ALL_IN_SINGLEPLAYER;

    static {
        var builder = new ModConfigSpec.Builder();

        builder.comment("ClaudeCraft Configuration").push("api");

        API_KEY = builder
                .comment("DEPRECATED - leave empty. This file is sent to every client that joins, so a key here is exposed.",
                        "Set the key with /claudecraft setkey <key> (saved to <gameDir>/claudecraft/api-key, never synced)",
                        "or the CLAUDECRAFT_API_KEY environment variable. A key found here is moved out and cleared on server start.")
                .define("apiKey", "");

        MODEL = builder
                .comment("Claude model to use for requests (API key mode only).")
                .define("model", "claude-sonnet-4-6");

        MAX_TOKENS = builder
                .comment("Maximum tokens in Claude's response (API key mode only).")
                .defineInRange("maxTokens", 4096, 256, 16384);

        MAX_CONCURRENT_REQUESTS = builder
                .comment("Maximum concurrent API requests across all computers (API key mode only).")
                .defineInRange("maxConcurrentRequests", 3, 1, 10);

        REQUEST_TIMEOUT_SECONDS = builder
                .comment("HTTP request timeout in seconds.")
                .defineInRange("requestTimeoutSeconds", 120, 10, 600);

        SYSTEM_PROMPT_PREFIX = builder
                .comment("Text prepended to the system prompt for all requests.")
                .define("systemPromptPrefix", "");

        ENABLE_WEB_ACCESS = builder
                .comment("Allow Claude to make HTTP requests using ComputerCraft's http API. Disabled by default for security.",
                        "Enforced on the server: when false, the http_request tool (and Anthropic web search/fetch) is removed",
                        "from every request, whichever Lua program sends it.")
                .define("enableWebAccess", false);

        ALLOW_SERVER_TOOLS = builder
                .comment("Allow Lua programs to send Anthropic-defined tools (any tool whose 'type' is not 'custom', e.g. web search,",
                        "web fetch, code execution) in API key mode. These run on Anthropic's side and are billed to the server's key.",
                        "Web search/fetch also need enableWebAccess. When false, such tools are removed from every request.")
                .define("allowServerTools", false);

        TOOL_TIMEOUT_SECONDS = builder
                .comment("Default timeout in seconds for tool execution. Mining, pathfinding, and large builds may need more time.")
                .defineInRange("toolTimeoutSeconds", 60, 10, 600);

        PERSONALITY = builder
                .comment("Personality prefix for the system prompt (e.g. 'You are a grumpy dwarf miner'). Empty for default behavior.")
                .define("personality", "");

        ENABLE_PROMPT_CACHING = builder
                .comment("Use Anthropic prompt caching (API key mode only). Caches the tool list, system prompt and",
                        "conversation so later agent rounds re-read them at a fraction of the input price.")
                .define("enablePromptCaching", true);

        builder.pop();

        builder.comment("Channel mode runs a local Claude Code session per computer on the machine hosting the world.",
                        "Each session runs as the OS user that runs Minecraft and uses that user's Claude login and usage.",
                        "See docs/channel-mode.md before enabling it on a multiplayer server.")
                .push("channel");

        ENABLE_CHANNEL_MODE = builder
                .comment("Allow computers to use channel mode. Off by default. Toggle in-game with /claudecraft channel enable|disable.")
                .define("enableChannelMode", false);

        MAX_CHANNEL_SESSIONS = builder
                .comment("Maximum number of Claude Code sessions running at once.")
                .defineInRange("maxChannelSessions", 4, 1, 32);

        ALLOWED_COMPUTERS = builder
                .comment("Computer IDs allowed to use channel mode. Manage in-game with /claudecraft channel allow|deny <computerId>.")
                .<Number>defineListAllowEmpty("allowedComputers", List.of(), () -> 0,
                        o -> o instanceof Number n && n.doubleValue() == n.intValue() && n.intValue() >= 0);

        ALLOW_ALL_IN_SINGLEPLAYER = builder
                .comment("Singleplayer convenience: on a singleplayer world that is not open to LAN, let every computer",
                        "use channel mode without being on allowedComputers. enableChannelMode must still be true.")
                .define("allowAllInSingleplayer", false);

        builder.pop();
        SPEC = builder.build();
    }
}
