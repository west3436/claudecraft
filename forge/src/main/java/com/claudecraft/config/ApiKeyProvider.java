package com.claudecraft.config;

import com.claudecraft.ClaudeCraft;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import net.neoforged.fml.config.ModConfig;
import net.neoforged.fml.config.ModConfigs;
import net.neoforged.fml.loading.FMLPaths;
import net.neoforged.neoforge.event.server.ServerStartingEvent;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.DirectoryStream;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.AclEntry;
import java.nio.file.attribute.AclEntryFlag;
import java.nio.file.attribute.AclEntryPermission;
import java.nio.file.attribute.AclEntryType;
import java.nio.file.attribute.AclFileAttributeView;
import java.nio.file.attribute.PosixFileAttributeView;
import java.nio.file.attribute.PosixFilePermissions;
import java.nio.file.attribute.UserPrincipal;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The single source of truth for the Anthropic API key used in API key mode.
 *
 * <p>The key is never read from the mod's SERVER config: NeoForge sends SERVER configs to every
 * client that joins, and the file sits in plaintext in {@code config/} (or a world's
 * {@code serverconfig/} override), which modpacks and backups copy around. Lookup order:
 * <ol>
 *   <li>The {@value #ENV_VAR} environment variable (never written by the mod).</li>
 *   <li>The secrets file {@code <gameDir>/claudecraft/api-key}, written by
 *       {@code /claudecraft setkey}. It lives outside the world save and the shareable
 *       {@code config/} folder, is never synced, and is made owner-only where the
 *       filesystem allows it.</li>
 * </ol>
 *
 * <p>{@code CLAUDECRAFT_API_KEY} is used instead of {@code ANTHROPIC_API_KEY} on purpose:
 * Claude Code processes spawned for channel mode inherit the server's environment and would
 * silently switch to API billing on an {@code ANTHROPIC_API_KEY}, and a key set for other
 * tools on the host should not be picked up by accident.
 */
@EventBusSubscriber(modid = ClaudeCraft.MOD_ID)
public final class ApiKeyProvider {
    public static final String ENV_VAR = "CLAUDECRAFT_API_KEY";

    public enum Source {
        ENVIRONMENT("environment variable " + ENV_VAR),
        FILE("secrets file"),
        NONE("none");

        private final String description;

        Source(String description) {
            this.description = description;
        }

        public String description() {
            return description;
        }
    }

    private static final Object LOCK = new Object();
    /** Cached secrets-file contents; null means no file or an empty file. */
    private static volatile String fileKey;
    private static volatile boolean fileLoaded;

    private ApiKeyProvider() {}

    // -- Lookup --

    /** The active API key, or null if none is set. Never log or display the result. */
    public static String get() {
        String env = envKey();
        return env != null ? env : fileKey();
    }

    /** True if a key is set and looks like an Anthropic key. */
    public static boolean isConfigured() {
        return isValidFormat(get());
    }

    public static boolean isValidFormat(String key) {
        return key != null && key.startsWith("sk-") && key.chars().noneMatch(Character::isWhitespace);
    }

    /** Where the active key comes from. */
    public static Source source() {
        if (envKey() != null) return Source.ENVIRONMENT;
        if (fileKey() != null) return Source.FILE;
        return Source.NONE;
    }

    public static boolean isEnvironmentKeySet() {
        return envKey() != null;
    }

    public static Path secretsFile() {
        return FMLPaths.GAMEDIR.get().resolve("claudecraft").resolve("api-key");
    }

    /** The secrets file path relative to the game directory, for messages shown to operators. */
    public static String secretsFileDisplay() {
        return gameRelative(secretsFile());
    }

    private static String envKey() {
        return blankToNull(System.getenv(ENV_VAR));
    }

    private static String fileKey() {
        if (!fileLoaded) {
            synchronized (LOCK) {
                if (!fileLoaded) {
                    fileKey = readSecretsFile();
                    fileLoaded = true;
                }
            }
        }
        return fileKey;
    }

    private static String readSecretsFile() {
        Path file = secretsFile();
        if (!Files.isRegularFile(file)) return null;
        try {
            return blankToNull(Files.readString(file, StandardCharsets.UTF_8));
        } catch (IOException e) {
            ClaudeCraft.LOGGER.warn("Could not read the API key file {}: {}", file, e.toString());
            return null;
        }
    }

    /** Forget the cached secrets file so the next lookup reads it from disk. */
    public static void reload() {
        synchronized (LOCK) {
            fileLoaded = false;
            fileKey = null;
        }
    }

    // -- Writing --

    /**
     * Write {@code key} to the secrets file, replacing any existing one. The file is written to a
     * temporary file first and moved into place, so a crash never leaves half a key behind.
     */
    public static void store(String key) throws IOException {
        String value = blankToNull(key);
        if (value == null) throw new IllegalArgumentException("key is empty");

        Path file = secretsFile();
        Path dir = file.getParent();
        synchronized (LOCK) {
            if (!Files.isDirectory(dir)) {
                Files.createDirectories(dir);
                restrictToOwner(dir, true);
            }
            Path tmp = Files.createTempFile(dir, "api-key", ".tmp");
            try {
                restrictToOwner(tmp, false);
                Files.writeString(tmp, value + System.lineSeparator(), StandardCharsets.UTF_8);
                try {
                    Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING,
                            StandardCopyOption.ATOMIC_MOVE);
                } catch (AtomicMoveNotSupportedException e) {
                    Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING);
                }
            } finally {
                Files.deleteIfExists(tmp);
            }
            fileKey = value;
            fileLoaded = true;
        }
    }

    /** Delete the secrets file. Returns true if a file was removed. */
    public static boolean clear() throws IOException {
        synchronized (LOCK) {
            boolean deleted = Files.deleteIfExists(secretsFile());
            fileKey = null;
            fileLoaded = true;
            return deleted;
        }
    }

    /**
     * Best-effort: make {@code path} readable and writable by its owner only. POSIX filesystems
     * get mode 600 (700 for directories). On Windows the ACL is replaced with a single entry for
     * the file owner (plus the current user if that is a different principal). Failures are
     * logged and ignored, because a key the server can still read is better than no key.
     */
    private static void restrictToOwner(Path path, boolean directory) {
        try {
            PosixFileAttributeView posix = Files.getFileAttributeView(path, PosixFileAttributeView.class);
            if (posix != null) {
                posix.setPermissions(PosixFilePermissions.fromString(directory ? "rwx------" : "rw-------"));
                return;
            }
            AclFileAttributeView acl = Files.getFileAttributeView(path, AclFileAttributeView.class);
            if (acl != null) {
                List<UserPrincipal> principals = new ArrayList<>();
                principals.add(Files.getOwner(path));
                try {
                    UserPrincipal current = FileSystems.getDefault().getUserPrincipalLookupService()
                            .lookupPrincipalByName(System.getProperty("user.name"));
                    if (!principals.contains(current)) principals.add(current);
                } catch (IOException | UnsupportedOperationException ignored) {
                    // Owner-only is still fine.
                }
                EnumSet<AclEntryFlag> flags = directory
                        ? EnumSet.of(AclEntryFlag.FILE_INHERIT, AclEntryFlag.DIRECTORY_INHERIT)
                        : EnumSet.noneOf(AclEntryFlag.class);
                List<AclEntry> entries = new ArrayList<>();
                for (UserPrincipal principal : principals) {
                    entries.add(AclEntry.newBuilder()
                            .setType(AclEntryType.ALLOW)
                            .setPrincipal(principal)
                            .setPermissions(EnumSet.allOf(AclEntryPermission.class))
                            .setFlags(flags)
                            .build());
                }
                acl.setAcl(entries);
            }
        } catch (IOException | UnsupportedOperationException | SecurityException e) {
            ClaudeCraft.LOGGER.warn("Could not restrict permissions on {}: {}", path, e.toString());
        }
    }

    // -- Migration from the synced SERVER config --

    @SubscribeEvent
    public static void onServerStarting(ServerStartingEvent event) {
        reload();
        migrateLegacyConfigKey();
    }

    /**
     * Older versions stored the key as {@code api.apiKey} in the SERVER config, which NeoForge
     * syncs to every client. If that value is set: move it to the secrets file (unless one already
     * exists), blank it in the config and save, and warn that the key should be rotated. The
     * config value is blanked even if the move fails, so it stops reaching clients. On every start,
     * any key left in FML's automatic backups of the config ({@code *-N.toml.bak}) is blanked too.
     */
    static void migrateLegacyConfigKey() {
        String legacy;
        try {
            legacy = blankToNull(ClaudeCraftConfig.API_KEY.get());
        } catch (IllegalStateException e) {
            return; // config not loaded
        }
        Path configPath = serverConfigPath();
        if (legacy == null) {
            // Nothing to move, but an older correction may have left a key in a backup.
            int scrubbed = configPath != null ? scrubBackups(configPath) : 0;
            if (scrubbed > 0) {
                ClaudeCraft.LOGGER.warn("ClaudeCraft removed an old API key from {} backup(s) of {}. "
                        + "If that key was ever used, rotate it at console.anthropic.com.",
                        scrubbed, gameRelative(configPath));
            }
            return;
        }

        String fileDisplay = secretsFileDisplay();
        String outcome;
        if (Files.exists(secretsFile())) {
            outcome = "The existing " + fileDisplay + " was kept, so the config's key was not used.";
        } else {
            try {
                store(legacy);
                outcome = "It was moved to " + fileDisplay + ".";
            } catch (IOException | RuntimeException e) {
                ClaudeCraft.LOGGER.error("Could not write the API key to {}: {}", fileDisplay, e.toString());
                outcome = "It could NOT be saved to " + fileDisplay
                        + ", so API key mode has no key until you set one.";
            }
        }

        ClaudeCraftConfig.API_KEY.set("");
        ClaudeCraftConfig.API_KEY.save();

        int scrubbed = configPath != null ? scrubBackups(configPath) : 0;

        ClaudeCraft.LOGGER.warn(
                "ClaudeCraft found an Anthropic API key in its SERVER config ({}). NeoForge sends that file to "
                        + "every client that joins, so treat the key as exposed. {} The config value has been cleared{}. "
                        + "Rotate the key at console.anthropic.com, then set the new one with /claudecraft setkey <key> "
                        + "from the server console or with the {} environment variable. If the key is also in "
                        + "defaultconfigs/{}-server.toml or in other copies of the config, remove it there.",
                configPath != null ? gameRelative(configPath) : ClaudeCraft.MOD_ID + "-server.toml",
                outcome,
                scrubbed > 0 ? " and removed from " + scrubbed + " config backup file(s)" : "",
                ENV_VAR, ClaudeCraft.MOD_ID);
    }

    /** The file the SERVER config was loaded from: config/ or a per-world serverconfig/ override. */
    private static Path serverConfigPath() {
        try {
            for (ModConfig config : ModConfigs.getConfigSet(ModConfig.Type.SERVER)) {
                if (config.getSpec() == ClaudeCraftConfig.SPEC) return config.getFullPath();
            }
        } catch (RuntimeException e) {
            ClaudeCraft.LOGGER.debug("Could not resolve the SERVER config path: {}", e.toString());
        }
        return null;
    }

    /** A non-empty {@code apiKey = "..."} (or single-quoted) line in a TOML file. */
    private static final Pattern LEGACY_KEY_LINE =
            Pattern.compile("(?m)^([ \\t]*apiKey[ \\t]*=[ \\t]*)(\"[^\"\\r\\n]+\"|'[^'\\r\\n]+')");

    /**
     * FML copies the config to {@code <name>-N.toml.bak} before correcting it (e.g. when a new
     * option is added), so old keys can survive there. Blank the apiKey value in any such backup.
     * Returns how many backup files were changed.
     */
    private static int scrubBackups(Path configPath) {
        Path dir = configPath.getParent();
        String fileName = configPath.getFileName().toString();
        String base = fileName.endsWith(".toml") ? fileName.substring(0, fileName.length() - 5) : fileName;
        String glob = base + "-*.toml.bak";
        int scrubbed = 0;
        try (DirectoryStream<Path> backups = Files.newDirectoryStream(dir, glob)) {
            for (Path backup : backups) {
                try {
                    String content = Files.readString(backup, StandardCharsets.UTF_8);
                    Matcher m = LEGACY_KEY_LINE.matcher(content);
                    if (m.find()) {
                        Files.writeString(backup, m.replaceAll("$1\"\""), StandardCharsets.UTF_8);
                        scrubbed++;
                    }
                } catch (IOException e) {
                    ClaudeCraft.LOGGER.warn("Could not remove the API key from config backup {}: {}",
                            gameRelative(backup), e.toString());
                }
            }
        } catch (IOException e) {
            ClaudeCraft.LOGGER.warn("Could not scan {} for config backups: {}", gameRelative(dir), e.toString());
        }
        return scrubbed;
    }

    private static String gameRelative(Path path) {
        try {
            Path gameDir = FMLPaths.GAMEDIR.get().toAbsolutePath().normalize();
            return gameDir.relativize(path.toAbsolutePath().normalize()).toString().replace('\\', '/');
        } catch (IllegalArgumentException e) {
            return path.toString();
        }
    }

    private static String blankToNull(String s) {
        if (s == null) return null;
        String trimmed = s.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
