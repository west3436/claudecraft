package com.claudecraft.config;

import net.minecraftforge.common.ForgeConfigSpec;

public class ClaudeCraftConfig {
    public static final ForgeConfigSpec SPEC;

    public static final ForgeConfigSpec.ConfigValue<String> API_KEY;
    public static final ForgeConfigSpec.ConfigValue<String> MODEL;
    public static final ForgeConfigSpec.IntValue MAX_TOKENS;
    public static final ForgeConfigSpec.IntValue MAX_CONCURRENT_REQUESTS;
    public static final ForgeConfigSpec.IntValue REQUEST_TIMEOUT_SECONDS;
    public static final ForgeConfigSpec.ConfigValue<String> SYSTEM_PROMPT_PREFIX;

    static {
        ForgeConfigSpec.Builder builder = new ForgeConfigSpec.Builder();

        builder.comment("ClaudeCraft Configuration").push("api");

        API_KEY = builder
                .comment("Anthropic API key (starts with sk-ant-). Set via /claudecraft setkey <key> in-game.")
                .define("apiKey", "");

        MODEL = builder
                .comment("Claude model to use for requests.")
                .define("model", "claude-sonnet-4-6");

        MAX_TOKENS = builder
                .comment("Maximum tokens in Claude's response.")
                .defineInRange("maxTokens", 4096, 256, 16384);

        MAX_CONCURRENT_REQUESTS = builder
                .comment("Maximum concurrent API requests across all computers.")
                .defineInRange("maxConcurrentRequests", 3, 1, 10);

        REQUEST_TIMEOUT_SECONDS = builder
                .comment("HTTP request timeout in seconds.")
                .defineInRange("requestTimeoutSeconds", 120, 10, 600);

        SYSTEM_PROMPT_PREFIX = builder
                .comment("Text prepended to the system prompt for all requests.")
                .define("systemPromptPrefix", "");

        builder.pop();
        SPEC = builder.build();
    }

    public static boolean isConfigured() {
        String key = API_KEY.get();
        return key != null && !key.isEmpty() && key.startsWith("sk-");
    }
}
