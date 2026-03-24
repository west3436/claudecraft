package com.claudecraft.channel;

import com.claudecraft.ClaudeCraft;

import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Manages Claude Code channel server processes — one per CC:Tweaked computer.
 * Auto-assigns ports and handles lifecycle (start, stop, cleanup).
 */
public class ChannelProcessManager {
    private static final int BASE_PORT = 8789;
    private static ChannelProcessManager INSTANCE;

    private final Map<Integer, SessionInfo> sessions = new ConcurrentHashMap<>();
    private final AtomicInteger nextPort = new AtomicInteger(BASE_PORT);

    public static synchronized ChannelProcessManager getInstance() {
        if (INSTANCE == null) {
            INSTANCE = new ChannelProcessManager();
        }
        return INSTANCE;
    }

    /**
     * Info about a running channel session.
     */
    public static class SessionInfo {
        public final int computerId;
        public final int port;
        public final Process process;

        SessionInfo(int computerId, int port, Process process) {
            this.computerId = computerId;
            this.port = port;
            this.process = process;
        }
    }

    /**
     * Start a channel session for a computer. Returns the session info.
     * If a session is already running for this computer and healthy, returns it.
     * If the existing session is dead, removes it and starts a fresh one.
     */
    public SessionInfo startSession(int computerId, boolean isTurtle, String label,
                                     int termWidth, int termHeight) throws Exception {
        // Bug 3 fix: Health-check existing session before returning it.
        SessionInfo existing = sessions.get(computerId);
        if (existing != null) {
            if (isPortReachable(existing.port)) {
                return existing;
            }
            // Session is dead — remove and start fresh
            ClaudeCraft.LOGGER.info(
                    "Channel session for computer #{} on port {} is unreachable, restarting",
                    computerId, existing.port);
            sessions.remove(computerId);
        }

        // Ensure channel resources are set up
        ChannelResourceManager resources = ChannelResourceManager.getInstance();
        if (!resources.isReady()) {
            String error = resources.setup();
            if (error != null) {
                throw new Exception(error);
            }
        }

        // Assign port
        int port = nextPort.getAndIncrement();

        // Create sandbox directory
        Path sandboxDir = Path.of(System.getProperty("user.home"),
                ".claudecraft", "computers", String.valueOf(computerId));
        Files.createDirectories(sandboxDir);

        // Write CLAUDE.md
        writeCLAUDEmd(sandboxDir, computerId, isTurtle, label, termWidth, termHeight);

        // Write .mcp.json
        writeMcpJson(sandboxDir, port, computerId, isTurtle, label, termWidth, termHeight);

        // Refactor R1: Generate permissions from ToolDefinitions instead of hardcoding
        Path claudeSettingsDir = sandboxDir.resolve(".claude");
        Files.createDirectories(claudeSettingsDir);
        Files.writeString(claudeSettingsDir.resolve("settings.local.json"),
                """
                {
                  "permissions": {
                    "allow": %s,
                    "deny": []
                  }
                }
                """.formatted(ToolDefinitions.permissionsJsonArray()));

        // Write a launcher batch script that Claude Code runs in its own window
        Path launchScript = sandboxDir.resolve("launch-claude.bat");
        Files.writeString(launchScript,
                "@echo off\r\n" +
                "title ClaudeCraft Computer #" + computerId + "\r\n" +
                "cd /d \"" + sandboxDir.toString() + "\"\r\n" +
                "claude --dangerously-load-development-channels server:claudecraft\r\n" +
                "pause\r\n");

        // Spawn Claude Code in its own console window.
        // Claude Code requires a TTY for interactive channel mode.
        String osName = System.getProperty("os.name", "").toLowerCase();
        ProcessBuilder pb;
        if (osName.contains("win")) {
            // 'start' with first quoted arg as window title, then the command
            pb = new ProcessBuilder(
                    "cmd", "/c", "start",
                    "\"ClaudeCraft\"",
                    "cmd", "/c", launchScript.toString()
            );
        } else {
            // On Linux/Mac, use script to provide a pseudo-terminal
            pb = new ProcessBuilder(
                    "script", "-qc",
                    "claude --dangerously-load-development-channels server:claudecraft",
                    "/dev/null"
            );
        }
        pb.directory(sandboxDir.toFile());
        pb.redirectErrorStream(true);
        pb.redirectOutput(ProcessBuilder.Redirect.DISCARD);

        ClaudeCraft.LOGGER.info("Starting Claude Code session for computer #{} on port {}",
                computerId, port);

        Process process = pb.start();

        SessionInfo session = new SessionInfo(computerId, port, process);
        sessions.put(computerId, session);
        writeRegistry();

        return session;
    }

    /**
     * Stop a channel session for a computer.
     */
    public void stopSession(int computerId) {
        SessionInfo session = sessions.remove(computerId);
        if (session == null) return;

        ClaudeCraft.LOGGER.info("Stopping Claude Code session for computer #{}", computerId);
        writeRegistry();

        // The 'start' command detaches the process, so Process.destroy() won't work.
        // Instead, kill any claude process that was started from this computer's sandbox.
        String osName = System.getProperty("os.name", "").toLowerCase();
        if (osName.contains("win")) {
            try {
                // Kill the window by title
                new ProcessBuilder("taskkill", "/FI",
                        "WINDOWTITLE eq ClaudeCraft Computer #" + computerId,
                        "/T", "/F")
                        .redirectErrorStream(true)
                        .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                        .start();
            } catch (Exception e) {
                ClaudeCraft.LOGGER.warn("Failed to kill channel session: {}", e.getMessage());
            }
        } else {
            if (session.process != null) {
                session.process.destroy();
                try {
                    if (!session.process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) {
                        session.process.destroyForcibly();
                    }
                } catch (InterruptedException ignored) {
                    session.process.destroyForcibly();
                }
            }
        }
    }

    /**
     * Get session info for a computer, or null if not running.
     */
    public SessionInfo getSession(int computerId) {
        return sessions.get(computerId);
    }

    /**
     * Stop all sessions. Called on server shutdown.
     */
    public void shutdownAll() {
        ClaudeCraft.LOGGER.info("Stopping all Claude Code sessions ({} active)", sessions.size());
        for (int computerId : sessions.keySet()) {
            stopSession(computerId);
        }
    }

    /**
     * Bug 3 fix: Quick TCP check to see if a port is accepting connections.
     */
    private boolean isPortReachable(int port) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", port), 1000);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private void writeRegistry() {
        try {
            Path registryFile = Path.of(System.getProperty("user.home"),
                    ".claudecraft", "channel-registry.json");
            Files.createDirectories(registryFile.getParent());
            StringBuilder json = new StringBuilder("{\n");
            boolean first = true;
            for (var entry : sessions.entrySet()) {
                if (!first) json.append(",\n");
                json.append("  \"").append(entry.getKey()).append("\": ").append(entry.getValue().port);
                first = false;
            }
            json.append("\n}");
            Files.writeString(registryFile, json.toString());
        } catch (Exception e) {
            ClaudeCraft.LOGGER.warn("Failed to write channel registry: {}", e.getMessage());
        }
    }

    private void writeCLAUDEmd(Path dir, int computerId, boolean isTurtle, String label,
                                int termWidth, int termHeight) throws Exception {
        String turtleTools = isTurtle
                ? ",\n   turtle_move, turtle_dig, turtle_place, turtle_inspect, turtle_inventory"
                : "";
        String content = String.format("""
                # ClaudeCraft Computer #%d

                You are Claude Code installed inside a ComputerCraft computer in Minecraft.

                ## MANDATORY RULES

                1. You are IN CHARACTER at all times - you exist inside this CC:Tweaked computer.
                2. NEVER use built-in Claude Code tools (Read, Write, Edit, Bash, Grep, Glob, Agent, etc.).
                   You do NOT have access to the host filesystem.
                3. ONLY use the Minecraft tools provided by the ClaudeCraft channel:
                   read_file, write_file, edit_file, list_files, find_files, search_content,
                   run_command, delete_path, move_path, get_info, redstone, peripheral_call,
                   send_message%s
                4. Your filesystem IS the CC:Tweaked virtual filesystem. Paths start with /.
                5. NEVER use emojis - the terminal cannot display them.
                6. NEVER use markdown formatting - this is a plain text terminal.
                7. Be VERY concise - your terminal is %dx%d characters.
                8. Write idiomatic CC:Tweaked Lua when writing code.
                9. When you are done responding, ALWAYS call the reply tool.

                ## Inter-Computer Messaging
                You can send messages to other computers/turtles using send_message(computerId, message).
                Messages from other computers arrive as "[Message from Computer #X]:" prefixed text.
                Use this to coordinate with other AI agents — build turtle swarms, delegate tasks, or collaborate.

                ## Computer Info
                - Computer ID: %d
                - Label: %s
                - Type: %s
                - Terminal: %dx%d
                """,
                computerId, turtleTools, termWidth, termHeight,
                computerId, label, isTurtle ? "Turtle" : "Computer",
                termWidth, termHeight);

        Files.writeString(dir.resolve("CLAUDE.md"), content);
    }

    private void writeMcpJson(Path dir, int port, int computerId, boolean isTurtle,
                               String label, int termWidth, int termHeight) throws Exception {
        Path channelScript = ChannelResourceManager.getInstance()
                .getChannelDir().resolve("claudecraft-channel.ts");

        // Bug 13 fix: Properly escape both backslashes and quotes in label and path
        String escapedPath = channelScript.toString().replace("\\", "/");
        String escapedLabel = label.replace("\\", "\\\\").replace("\"", "\\\"");

        StringBuilder args = new StringBuilder();
        args.append("[\n");
        args.append("      \"").append(escapedPath).append("\",\n");
        args.append("      \"--port\", \"").append(port).append("\",\n");
        args.append("      \"--computer-id\", \"").append(computerId).append("\",\n");
        args.append("      \"--label\", \"").append(escapedLabel).append("\",\n");
        args.append("      \"--term-width\", \"").append(termWidth).append("\",\n");
        args.append("      \"--term-height\", \"").append(termHeight).append("\"");
        if (isTurtle) {
            args.append(",\n      \"--turtle\"");
        }
        args.append("\n    ]");

        String content = String.format("""
                {
                  "mcpServers": {
                    "claudecraft": {
                      "command": "bun",
                      "args": %s
                    }
                  }
                }
                """, args);

        Files.writeString(dir.resolve(".mcp.json"), content);
    }
}
