#!/usr/bin/env bun
/**
 * ClaudeCraft Channel Launcher
 *
 * Sets up an isolated sandbox directory for a CC:Tweaked computer and launches
 * Claude Code with the ClaudeCraft channel server configured.
 *
 * Usage:
 *   bun run launch.ts --computer-id 5 --port 8790 [--turtle] [--label "My Turtle"]
 *                      [--term-width 51] [--term-height 19]
 */

import { existsSync, mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { spawn } from "child_process";
import { fileURLToPath } from "url";
import { dirname } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ---------------------------------------------------------------------------
// Parse arguments
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);

function getArg(name: string, fallback: string): string {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : fallback;
}

function hasFlag(name: string): boolean {
  return args.includes(`--${name}`);
}

if (hasFlag("help")) {
  console.log(`
ClaudeCraft Channel Launcher

Usage:
  bun run launch.ts [options]

Options:
  --computer-id <id>     CC:Tweaked computer ID (default: 0)
  --port <port>          HTTP port for mod communication (default: 8789)
  --turtle               This computer is a turtle
  --label <name>         Computer label (default: "Computer")
  --term-width <w>       Terminal width (default: 51)
  --term-height <h>      Terminal height (default: 19)
  --help                 Show this help
`);
  process.exit(0);
}

const COMPUTER_ID = getArg("computer-id", "0");
const PORT = getArg("port", "8789");
const IS_TURTLE = hasFlag("turtle");
const LABEL = getArg("label", "Computer");
const TERM_WIDTH = getArg("term-width", "51");
const TERM_HEIGHT = getArg("term-height", "19");

// ---------------------------------------------------------------------------
// Set up sandbox directory
// ---------------------------------------------------------------------------

const sandboxRoot = join(homedir(), ".claudecraft", "computers");
const sandboxDir = join(sandboxRoot, COMPUTER_ID);

if (!existsSync(sandboxRoot)) {
  mkdirSync(sandboxRoot, { recursive: true });
}
if (!existsSync(sandboxDir)) {
  mkdirSync(sandboxDir, { recursive: true });
}

// Write CLAUDE.md for in-character enforcement
const claudeMd = `# ClaudeCraft Computer #${COMPUTER_ID}

You are Claude Code installed inside a ComputerCraft computer in Minecraft.

## MANDATORY RULES

1. You are IN CHARACTER at all times — you exist inside this CC:Tweaked computer.
2. NEVER use built-in Claude Code tools (Read, Write, Edit, Bash, Grep, Glob, Agent, etc.).
   You do NOT have access to the host filesystem.
3. ONLY use the Minecraft tools provided by the ClaudeCraft channel:
   read_file, write_file, edit_file, list_files, find_files, search_content,
   run_command, delete_path, move_path, get_info, redstone, peripheral_call${IS_TURTLE ? ",\n   turtle_move, turtle_dig, turtle_place, turtle_inspect, turtle_inventory" : ""}
4. Your filesystem IS the CC:Tweaked virtual filesystem. Paths start with /.
5. NEVER use emojis — the terminal cannot display them.
6. NEVER use markdown formatting — this is a plain text terminal.
7. Be VERY concise — your terminal is ${TERM_WIDTH}x${TERM_HEIGHT} characters.
8. Write idiomatic CC:Tweaked Lua when writing code.
9. When you are done responding, ALWAYS call the reply tool.

## Computer Info
- Computer ID: ${COMPUTER_ID}
- Label: ${LABEL}
- Type: ${IS_TURTLE ? "Turtle" : "Computer"}
- Terminal: ${TERM_WIDTH}x${TERM_HEIGHT}
`;

writeFileSync(join(sandboxDir, "CLAUDE.md"), claudeMd);

// Write .mcp.json for the channel server
const channelScript = join(__dirname, "claudecraft-channel.ts");
const mcpConfig = {
  mcpServers: {
    claudecraft: {
      command: "bun",
      args: [
        channelScript,
        "--port",
        PORT,
        "--computer-id",
        COMPUTER_ID,
        "--label",
        LABEL,
        "--term-width",
        TERM_WIDTH,
        "--term-height",
        TERM_HEIGHT,
        ...(IS_TURTLE ? ["--turtle"] : []),
      ],
    },
  },
};

writeFileSync(
  join(sandboxDir, ".mcp.json"),
  JSON.stringify(mcpConfig, null, 2)
);

// ---------------------------------------------------------------------------
// Launch Claude Code
// ---------------------------------------------------------------------------

console.log(`[ClaudeCraft] Launching Claude Code for computer #${COMPUTER_ID}`);
console.log(`[ClaudeCraft] Sandbox: ${sandboxDir}`);
console.log(`[ClaudeCraft] Channel port: ${PORT}`);
console.log(`[ClaudeCraft] Type: ${IS_TURTLE ? "Turtle" : "Computer"}`);
console.log();

const claude = spawn(
  "claude",
  ["--dangerously-load-development-channels", "server:claudecraft"],
  {
    cwd: sandboxDir,
    stdio: "inherit",
    shell: true,
  }
);

claude.on("error", (err) => {
  console.error(`[ClaudeCraft] Failed to launch Claude Code: ${err.message}`);
  console.error(
    "[ClaudeCraft] Make sure Claude Code is installed: npm install -g @anthropic-ai/claude-code"
  );
  process.exit(1);
});

claude.on("exit", (code) => {
  console.log(`[ClaudeCraft] Claude Code exited with code ${code}`);
  process.exit(code ?? 0);
});

// Forward signals
process.on("SIGINT", () => claude.kill("SIGINT"));
process.on("SIGTERM", () => claude.kill("SIGTERM"));
