package com.claudecraft.channel;

import com.claudecraft.ClaudeCraft;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.Set;

/**
 * Per-session secrets for the local channel server.
 *
 * <p>Each session gets two tokens:
 * <ul>
 *   <li><b>token</b>: known only to the mod and that computer's channel server. It
 *       authorizes the mod's endpoints ({@code /message}, {@code /tool-result},
 *       {@code /events}, {@code /health}).</li>
 *   <li><b>inbox token</b>: published in the channel registry so other ClaudeCraft
 *       channel servers can deliver to this computer's {@code /incoming-message}. It
 *       grants nothing else, and the receiver still applies its message allowlist.</li>
 * </ul>
 * Both reach the channel server as environment variables set in {@code .mcp.json},
 * never as command-line arguments (which other local users can see in process listings).
 */
public final class ChannelSecrets {
    /** Env var carrying the mod's token to the channel server. */
    public static final String TOKEN_ENV = "CLAUDECRAFT_CHANNEL_TOKEN";
    /** Env var carrying the inbox token to the channel server. */
    public static final String INBOX_TOKEN_ENV = "CLAUDECRAFT_INBOX_TOKEN";

    private static final SecureRandom RANDOM = new SecureRandom();
    private static final Set<PosixFilePermission> OWNER_FILE = PosixFilePermissions.fromString("rw-------");
    private static final Set<PosixFilePermission> OWNER_DIR = PosixFilePermissions.fromString("rwx------");

    private ChannelSecrets() {}

    /** A fresh 256-bit random token, URL-safe base64 without padding (43 chars). */
    public static String newToken() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    /**
     * Best effort: make a file or directory accessible only by its owner. Applies on
     * POSIX file systems (Linux/macOS homes are often world-readable). On Windows the
     * user profile is already private to the user, so this is a no-op there.
     */
    public static void restrictToOwner(Path path) {
        try {
            if (!Files.exists(path)
                    || !Files.getFileStore(path).supportsFileAttributeView("posix")) {
                return;
            }
            Files.setPosixFilePermissions(path, Files.isDirectory(path) ? OWNER_DIR : OWNER_FILE);
        } catch (Exception e) {
            ClaudeCraft.LOGGER.debug("Could not restrict permissions on {}: {}", path, e.getMessage());
        }
    }
}
