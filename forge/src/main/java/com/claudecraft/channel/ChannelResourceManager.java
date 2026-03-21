package com.claudecraft.channel;

import com.claudecraft.ClaudeCraft;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Extracts bundled channel server files from the mod jar to
 * ~/.claudecraft/channel/ and runs 'bun install' if needed.
 */
public class ChannelResourceManager {
    private static final String[] CHANNEL_FILES = {
            "package.json",
            "claudecraft-channel.ts",
            "launch.ts"
    };

    private static ChannelResourceManager INSTANCE;
    private final Path channelDir;
    private volatile boolean ready = false;
    private volatile String lastError = null;

    private ChannelResourceManager() {
        this.channelDir = Path.of(System.getProperty("user.home"), ".claudecraft", "channel");
    }

    public static synchronized ChannelResourceManager getInstance() {
        if (INSTANCE == null) {
            INSTANCE = new ChannelResourceManager();
        }
        return INSTANCE;
    }

    public Path getChannelDir() {
        return channelDir;
    }

    public boolean isReady() {
        return ready;
    }

    public String getLastError() {
        return lastError;
    }

    /**
     * Extract channel files and install dependencies. Blocking call.
     * Returns null on success, or an error message string.
     */
    public synchronized String setup() {
        lastError = null;

        try {
            // Create directory
            Files.createDirectories(channelDir);

            // Extract files from jar resources
            for (String fileName : CHANNEL_FILES) {
                extractResource("channel/" + fileName, channelDir.resolve(fileName));
            }

            // Check if bun is available
            if (!isBunInstalled()) {
                lastError = "Bun is not installed. Install it from https://bun.sh";
                return lastError;
            }

            // Run bun install if node_modules missing
            Path nodeModules = channelDir.resolve("node_modules");
            if (!Files.exists(nodeModules)) {
                ClaudeCraft.LOGGER.info("Running bun install in {}", channelDir);
                String installError = runBunInstall();
                if (installError != null) {
                    lastError = installError;
                    return lastError;
                }
            }

            ready = true;
            return null;

        } catch (Exception e) {
            lastError = "Channel setup failed: " + e.getMessage();
            ClaudeCraft.LOGGER.error("Channel setup failed", e);
            return lastError;
        }
    }

    private void extractResource(String resourcePath, Path target) throws IOException {
        try (InputStream is = getClass().getClassLoader().getResourceAsStream(resourcePath)) {
            if (is == null) {
                throw new IOException("Resource not found in jar: " + resourcePath);
            }
            Files.copy(is, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private boolean isBunInstalled() {
        try {
            Process p = new ProcessBuilder("bun", "--version")
                    .redirectErrorStream(true)
                    .start();
            int exitCode = p.waitFor();
            return exitCode == 0;
        } catch (Exception e) {
            return false;
        }
    }

    private String runBunInstall() {
        try {
            ProcessBuilder pb = new ProcessBuilder("bun", "install")
                    .directory(channelDir.toFile())
                    .redirectErrorStream(true);
            Process p = pb.start();

            // Read output
            String output = new String(p.getInputStream().readAllBytes());
            int exitCode = p.waitFor();

            if (exitCode != 0) {
                ClaudeCraft.LOGGER.error("bun install failed: {}", output);
                return "bun install failed (exit " + exitCode + "): " + output;
            }

            ClaudeCraft.LOGGER.info("bun install completed successfully");
            return null;

        } catch (Exception e) {
            return "Failed to run bun install: " + e.getMessage();
        }
    }
}
