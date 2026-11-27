package com.claudecraft.channel;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Collection;
import java.util.List;
import java.util.TreeSet;

/**
 * Which computers may send inter-computer messages to a computer (default: none).
 *
 * <p>Stored on the host in {@code ~/.claudecraft/computers/<id>/message-allowlist.json},
 * outside the CC:Tweaked file system, so Claude's file tools cannot edit it. The
 * receiving computer's channel server reads this file for every incoming message,
 * so changes take effect immediately and survive restarts.
 *
 * <p>Format: {@code {"allowedComputerIds": [3, 7]}}. Keep in sync with
 * {@code loadAllowlist()} in claudecraft-channel.ts.
 */
public final class MessageAllowlist {
    public static final String FILE_NAME = "message-allowlist.json";
    public static final String KEY = "allowedComputerIds";
    public static final int MAX_ENTRIES = 256;

    private MessageAllowlist() {}

    private static Path file(int computerId) {
        return Path.of(System.getProperty("user.home"),
                ".claudecraft", "computers", String.valueOf(computerId), FILE_NAME);
    }

    /** The computer IDs allowed to message {@code computerId}, sorted. Empty if none. */
    public static synchronized List<Integer> get(int computerId) {
        TreeSet<Integer> ids = new TreeSet<>();
        Path path = file(computerId);
        if (!Files.exists(path)) return List.of();
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

    /** Replace the allowlist for {@code computerId}. Returns the stored, sorted list. */
    public static synchronized List<Integer> set(int computerId, Collection<Integer> ids)
            throws Exception {
        TreeSet<Integer> sorted = new TreeSet<>(ids);
        if (sorted.size() > MAX_ENTRIES) {
            throw new IllegalArgumentException("Too many computer IDs (max " + MAX_ENTRIES + ")");
        }

        JsonArray arr = new JsonArray();
        sorted.forEach(arr::add);
        JsonObject root = new JsonObject();
        root.add(KEY, arr);

        Path target = file(computerId);
        Files.createDirectories(target.getParent());
        Path tmp = target.resolveSibling(FILE_NAME + ".tmp");
        Files.writeString(tmp, root.toString());
        try {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException e) {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
        }
        return List.copyOf(sorted);
    }
}
