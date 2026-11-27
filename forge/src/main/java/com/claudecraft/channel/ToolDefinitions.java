package com.claudecraft.channel;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Derives channel-mode configuration from the Lua tool registry.
 *
 * <p>The single source of truth for Minecraft tools is {@code tools.getDefs()} in
 * claude.lua. {@code claude.startChannel()} passes those defs (plus the optional
 * {@code tools.timeouts} overrides) to the mod, and this class turns them into:
 * <ul>
 *   <li>{@code tools.json}, which the channel server serves from ListTools,</li>
 *   <li>the Claude Code permission allowlist, and</li>
 *   <li>the tool section of the sandbox CLAUDE.md.</li>
 * </ul>
 *
 * <p>To add a tool, add it to {@code tools.getDefs()} and {@code tools._exec} in
 * claude.lua. Nothing here needs to change. The only tools named in Java are the
 * ones the channel server implements itself ({@link #NATIVE_TOOLS}).
 */
public final class ToolDefinitions {

    /** File name of the tool registry inside a computer's sandbox directory. */
    public static final String TOOLS_FILE = "tools.json";

    /** Tools implemented natively by claudecraft-channel.ts, not by claude.lua. */
    public static final List<String> NATIVE_TOOLS = List.of("reply", "send_message");

    /** MCP server name, as configured in the sandbox .mcp.json. */
    private static final String MCP_SERVER = "claudecraft";

    /** MCP permission prefix for ClaudeCraft tools. */
    private static final String MCP_PREFIX = "mcp__" + MCP_SERVER + "__";

    /** Same constraint the Anthropic API and the channel server apply to tool names. */
    private static final Pattern VALID_NAME = Pattern.compile("^[a-zA-Z0-9_-]{1,64}$");

    /** Longest description excerpt written into CLAUDE.md per tool. */
    private static final int SUMMARY_MAX = 100;

    private ToolDefinitions() {}

    /**
     * All tool names for a session: the Lua defs (in order) followed by the native
     * tools. Malformed or duplicate entries are skipped.
     */
    public static List<String> toolNames(JsonArray defs) {
        Set<String> names = new LinkedHashSet<>();
        for (JsonElement el : defs) {
            String name = nameOf(el);
            if (name != null) names.add(name);
        }
        names.addAll(NATIVE_TOOLS);
        return List.copyOf(names);
    }

    /**
     * Generate the MCP permission string for a tool name.
     */
    public static String mcpPermission(String toolName) {
        return MCP_PREFIX + toolName;
    }

    /**
     * JSON array of permission rules for settings.local.json. The
     * {@code mcp__claudecraft__*} wildcard also covers tools added mid-session via
     * tools/list_changed; the explicit names keep older Claude Code builds that
     * lack wildcard support working.
     */
    public static String permissionsJsonArray(JsonArray defs) {
        JsonArray allow = new JsonArray();
        allow.add(MCP_PREFIX + "*");
        for (String name : toolNames(defs)) {
            allow.add(mcpPermission(name));
        }
        return new GsonBuilder().setPrettyPrinting().create().toJson(allow);
    }

    /**
     * Bullet list of tools for CLAUDE.md, one line per tool with the first
     * sentence of its description.
     */
    public static String claudeMdToolList(JsonArray defs) {
        StringBuilder sb = new StringBuilder();
        for (JsonElement el : defs) {
            String name = nameOf(el);
            if (name == null || NATIVE_TOOLS.contains(name)) continue;
            sb.append("- ").append(name);
            String summary = summaryOf(el.getAsJsonObject());
            if (!summary.isEmpty()) sb.append(": ").append(summary);
            sb.append('\n');
        }
        sb.append("- send_message: Message another computer running Claude Code.\n");
        sb.append("- reply: Show your reply on the player's terminal. Call it to finish every turn.\n");
        return sb.toString();
    }

    /**
     * Content of tools.json: the Lua defs exactly as API-key mode sends them,
     * plus per-tool timeout overrides in seconds.
     */
    public static String registryJson(JsonArray defs, JsonObject timeouts) {
        JsonObject root = new JsonObject();
        root.add("tools", defs);
        root.add("timeouts", timeouts);
        return new GsonBuilder().setPrettyPrinting().create().toJson(root);
    }

    private static String nameOf(JsonElement el) {
        if (el == null || !el.isJsonObject()) return null;
        JsonElement name = el.getAsJsonObject().get("name");
        if (name == null || !name.isJsonPrimitive() || !name.getAsJsonPrimitive().isString()) {
            return null;
        }
        String s = name.getAsString();
        return VALID_NAME.matcher(s).matches() ? s : null;
    }

    private static String summaryOf(JsonObject def) {
        JsonElement desc = def.get("description");
        if (desc == null || !desc.isJsonPrimitive()) return "";
        String s = desc.getAsString().replaceAll("\\s+", " ").trim();
        int dot = s.indexOf(". ");
        if (dot >= 0) s = s.substring(0, dot + 1);
        if (s.length() > SUMMARY_MAX) s = s.substring(0, SUMMARY_MAX - 3).trim() + "...";
        return s;
    }
}
