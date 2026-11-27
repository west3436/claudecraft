package com.claudecraft.channel;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collection;
import java.util.List;
import java.util.TreeSet;

/**
 * Which computers may send inter-computer messages to a computer (default: none).
 *
 * <p>Stored on the host in the computer's sandbox,
 * {@code ~/.claudecraft/worlds/<world>/computers/<id>/message-allowlist.json},
 * outside the CC:Tweaked file system, so Claude's file tools cannot edit it.
 * The channel server gets the path with {@code --allowlist} and reads the file for
 * every incoming message, so changes take effect immediately and survive restarts.
 *
 * <p>Format: {@code {"allowedComputerIds": [3, 7]}}. Keep in sync with
 * {@code loadAllowlist()} in claudecraft-channel.ts.
 */
public final class MessageAllowlist {
    public static final String FILE_NAME = "message-allowlist.json";
    public static final String KEY = "allowedComputerIds";
    public static final int MAX_ENTRIES = 256;

    private MessageAllowlist() {}

    /** The computer IDs allowed to message the computer owning {@code sandboxDir}, sorted. */
    public static synchronized List<Integer> get(Path sandboxDir) {
        Path path = sandboxDir.resolve(FILE_NAME);
        if (!Files.exists(path)) return List.of();
        TreeSet<Integer> ids = new TreeSet<>();
        try {
            JsonElement root = JsonParser.parseString(Files.readString(path));
            if (root.isJsonObject() && root.getAsJsonObject().has(KEY)
                    && root.getAsJsonObject().get(KEY).isJsonArray()) {
                for (JsonElement el : root.getAsJsonObject().getAsJsonArray(KEY)) {
                    if (el.isJsonPrimitive() && el.getAsJsonPrimitive().isNumber()) {
                        double d = el.getAsDouble();
                        if (d >= 0 && d <= Integer.MAX_VALUE && d == Math.floor(d)) {
                            ids.add((int) d);
                        }
                    }
                }
            }
        } catch (Exception e) {
            // Unreadable file: treat as empty (deny all), matching the channel server.
            return List.of();
        }
        return List.copyOf(ids);
    }

    /** Replace the allowlist in {@code sandboxDir}. Returns the stored, sorted list. */
    public static synchronized List<Integer> set(Path sandboxDir, Collection<Integer> ids)
            throws Exception {
        TreeSet<Integer> sorted = new TreeSet<>(ids);
        if (sorted.size() > MAX_ENTRIES) {
            throw new IllegalArgumentException("Too many computer IDs (max " + MAX_ENTRIES + ")");
        }

        JsonArray arr = new JsonArray();
        sorted.forEach(arr::add);
        JsonObject root = new JsonObject();
        root.add(KEY, arr);

        Files.createDirectories(sandboxDir);
        ChannelProcessManager.writeAtomically(sandboxDir.resolve(FILE_NAME), root.toString());
        return List.copyOf(sorted);
    }
}
