package com.claudecraft.config;

import net.neoforged.neoforge.common.ModConfigSpec;

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

        builder.pop();
        SPEC = builder.build();
    }
}
