package com.claudecraft.channel;

import java.util.ArrayList;
import java.util.List;

/**
 * Single source of truth for ClaudeCraft MCP tool names.
 * Used by {@link ChannelProcessManager} for auto-approval permissions
 * and for generating consistent configuration files.
 *
 * NOTE: When adding a new tool, add it here AND in:
 *   - claudecraft-channel.ts (MCP tool definition + handler)
 *   - claude.lua (Lua-side tool definition + execution)
 */
public class ToolDefinitions {

    /** Standard tools available on all computers. */
    public static final List<String> STANDARD_TOOLS = List.of(
            "reply",
            "read_file",
            "write_file",
            "edit_file",
            "list_files",
            "find_files",
            "search_content",
            "run_command",
            "delete_path",
            "move_path",
            "get_info",
            "redstone",
            "peripheral_call",
            "send_message",
            "scan_area",
            "automate_redstone"
    );

    /** Additional tools available only on turtles. */
    public static final List<String> TURTLE_TOOLS = List.of(
            "turtle_move",
            "turtle_dig",
            "turtle_place",
            "turtle_inspect",
            "turtle_inventory"
    );

    /** MCP permission prefix for ClaudeCraft tools. */
    private static final String MCP_PREFIX = "mcp__claudecraft__";

    /**
     * Get all tool names (standard + turtle).
     */
    public static List<String> allToolNames() {
        var all = new ArrayList<>(STANDARD_TOOLS);
        all.addAll(TURTLE_TOOLS);
        return all;
    }

    /**
     * Generate the MCP permission string for a tool name.
     */
    public static String mcpPermission(String toolName) {
        return MCP_PREFIX + toolName;
    }

    /**
     * Generate a JSON array string of all MCP permission names,
     * suitable for embedding in settings.local.json.
     */
    public static String permissionsJsonArray() {
        var sb = new StringBuilder("[\n");
        var all = allToolNames();
        for (int i = 0; i < all.size(); i++) {
            sb.append("      \"").append(mcpPermission(all.get(i))).append("\"");
            if (i < all.size() - 1) sb.append(",");
            sb.append("\n");
        }
        sb.append("    ]");
        return sb.toString();
    }
}
