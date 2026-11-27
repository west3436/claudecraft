package com.claudecraft.api;

import com.claudecraft.ClaudeCraft;
import com.claudecraft.config.ClaudeCraftConfig;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;
import dan200.computercraft.api.lua.LuaException;

import java.util.ArrayList;
import java.util.List;

/**
 * Server-side policy for the tools a Lua program may send to the Anthropic API (API key mode).
 *
 * <p>claude.lua only offers tools the config allows, but any Lua program can call
 * {@code claude.sendMessage} with whatever tool list it likes, so the server enforces the
 * policy itself:
 * <ul>
 *   <li>Anthropic-defined tools (any entry whose {@code type} is set to something other than
 *       {@code "custom"}, e.g. {@code web_search_*}, {@code web_fetch_*},
 *       {@code code_execution_*}) run on Anthropic's side and are billed to the server's key.
 *       They are removed unless {@code api.allowServerTools} is true. Web search and fetch also
 *       need {@code api.enableWebAccess}.</li>
 *   <li>The bundled {@code http_request} tool is removed unless {@code api.enableWebAccess} is
 *       true.</li>
 * </ul>
 * Removed tools are logged at debug level. A malformed tool entry, or a request whose tools are
 * all removed, fails with a {@link LuaException} rather than being sent.
 */
final class ToolPolicy {
    static final String HTTP_TOOL = "http_request";

    private ToolPolicy() {}

    /** Apply the policy from the current server config. */
    static JsonArray apply(JsonArray tools, int computerId) throws LuaException {
        return apply(tools, ClaudeCraftConfig.ALLOW_SERVER_TOOLS.get(),
                ClaudeCraftConfig.ENABLE_WEB_ACCESS.get(), computerId);
    }

    static JsonArray apply(JsonArray tools, boolean allowServerTools, boolean webAccess,
                           int computerId) throws LuaException {
        JsonArray allowed = new JsonArray();
        List<String> removed = new ArrayList<>();

        for (int i = 0; i < tools.size(); i++) {
            JsonElement element = tools.get(i);
            if (!element.isJsonObject()) {
                throw new LuaException("Invalid tool #" + (i + 1) + ": expected a table");
            }
            JsonObject tool = element.getAsJsonObject();
            String name = stringField(tool, "name");

            String reason;
            if (isCustom(tool)) {
                if (name == null || name.isBlank()) {
                    throw new LuaException("Invalid tool #" + (i + 1) + ": missing 'name'");
                }
                reason = HTTP_TOOL.equals(name) && !webAccess ? "enableWebAccess is off" : null;
            } else {
                String type = stringField(tool, "type");
                if (!allowServerTools) {
                    reason = "allowServerTools is off";
                } else if (isWebTool(type) && !webAccess) {
                    reason = "enableWebAccess is off";
                } else {
                    reason = null;
                }
                if (name == null || name.isBlank()) {
                    name = type != null ? type : "#" + (i + 1);
                }
            }

            if (reason != null) {
                removed.add(name + " (" + reason + ")");
            } else {
                allowed.add(tool);
            }
        }

        if (!removed.isEmpty()) {
            ClaudeCraft.LOGGER.debug("Computer #{}: removed {} tool(s) by server policy: {}",
                    computerId, removed.size(), String.join(", ", removed));
            if (allowed.isEmpty()) {
                throw new LuaException("Request rejected: every tool was blocked by server policy: "
                        + String.join(", ", removed));
            }
        }
        return allowed;
    }

    /** A tool is custom when it has no {@code type} or its type is exactly {@code "custom"}. */
    private static boolean isCustom(JsonObject tool) {
        if (!tool.has("type")) return true;
        JsonElement type = tool.get("type");
        return type.isJsonPrimitive() && "custom".equals(type.getAsString());
    }

    private static boolean isWebTool(String type) {
        return type != null && (type.startsWith("web_search") || type.startsWith("web_fetch"));
    }

    private static String stringField(JsonObject obj, String key) {
        JsonElement value = obj.get(key);
        if (value instanceof JsonPrimitive p && p.isString()) return p.getAsString();
        return null;
    }
}
