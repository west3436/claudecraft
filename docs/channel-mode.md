# Channel Mode Setup Guide

Channel mode lets CC:Tweaked computers connect to Claude through [Claude Code](https://claude.ai/download) instead of requiring an Anthropic API key. Each computer gets its own isolated Claude Code session.

## Requirements

- [Bun](https://bun.sh) runtime installed on the server/host machine
- [Claude Code](https://claude.ai/download) CLI installed and logged in (`npm install -g @anthropic-ai/claude-code`)
- ClaudeCraft mod installed with CC:Tweaked

## Quick Start

1. **Install Bun** (if not already installed):
   - Windows: `powershell -Command "irm bun.sh/install.ps1 | iex"`
   - Linux/Mac: `curl -fsSL https://bun.sh/install | bash`

2. **Install Claude Code** (if not already installed):
   ```
   npm install -g @anthropic-ai/claude-code
   ```

3. **Log in to Claude Code** — run `claude` in a terminal once and complete the login flow.

4. **In Minecraft**, open any CC:Tweaked computer or turtle and run:
   ```
   claude
   ```

5. **Select "Claude Code"** (option 2) on the setup screen.

6. A Claude Code console window will open automatically. The in-game computer will connect once Claude Code is ready.

That's it. No API key needed.

## How It Works

When you select Channel mode on a CC:Tweaked computer:

1. The mod extracts a channel server to `~/.claudecraft/channel/` and runs `bun install` (first time only).
2. A sandbox directory is created at `~/.claudecraft/computers/<id>/` for that computer.
3. Claude Code launches in a new console window with the channel server configured as an MCP server.
4. The channel server bridges messages between the Minecraft mod and Claude Code:
   - Player messages go from the CC:Tweaked computer → Java mod → channel server → Claude Code
   - Claude Code's tool calls go back through the channel server → Java mod → CC:Tweaked computer for execution
   - Claude Code's replies travel the same path back to the in-game terminal

Each computer is fully isolated — its own Claude Code session, sandbox directory, and port.

## Switching Modes

Type `/mode` in the claude program to reset your connection mode. The next time you run `claude`, you'll see the setup screen again.

## FAQ

### "Bun is not installed"

Install Bun:
- **Windows**: `powershell -Command "irm bun.sh/install.ps1 | iex"`
- **Linux/Mac**: `curl -fsSL https://bun.sh/install | bash`

Restart your terminal (or Minecraft server) after installing so it appears in PATH.

### "Channel server did not start"

This means Claude Code didn't finish starting within 30 seconds. Common causes:

- **Claude Code not installed**: Run `npm install -g @anthropic-ai/claude-code`
- **Not logged in**: Run `claude` in a terminal and complete the login
- **Slow startup**: Claude Code can take a while on first launch. Try again — subsequent launches are faster.

Check the Claude Code console window that opened for error messages.

### "Channel server not reachable on port XXXX"

The channel server process started but isn't responding. Check the Claude Code console window for errors. The server may still be initializing — try sending your message again.

### "Channel connection failed: closed"

The connection to the channel server was lost. This can happen if:

- Claude Code crashed or was closed manually
- The channel server encountered an error

Run `claude` again on the computer to restart the session.

### The Claude Code window asks for permission

The mod pre-approves all ClaudeCraft MCP tools automatically. If you still see permission prompts:

1. Close the Claude Code window
2. Delete `~/.claudecraft/computers/<id>/.claude/settings.local.json`
3. Run `claude` in-game again — the mod will regenerate the settings file

### Can I use both modes on different computers?

Yes. Each computer independently chooses its mode. One computer can use API key mode while another uses Channel mode. The choice is stored per-computer in `/.claude/mode` on the CC:Tweaked filesystem.

### Where are the sandbox directories?

- Channel server files: `~/.claudecraft/channel/`
- Per-computer sandboxes: `~/.claudecraft/computers/<id>/`
- Each sandbox contains: `CLAUDE.md`, `.mcp.json`, `.claude/settings.local.json`

### Does channel mode support streaming?

No. In channel mode, Claude Code sends complete replies rather than streaming token-by-token. API key mode retains full streaming support.

### Can I see what Claude Code is doing?

Yes. Each computer's Claude Code session runs in its own console window. You can watch Claude Code process messages, call tools, and generate responses in real time.

### How do I stop a channel session?

- Type `exit` or `quit` in the CC:Tweaked computer — the session cleans up automatically
- Close the Claude Code console window manually
- The server stops all sessions when the Minecraft world is closed

### Does this work on dedicated servers?

Channel mode requires Bun and Claude Code installed on the server machine, and a logged-in Claude Code session. Since dedicated servers are typically headless, you would need to log in to Claude Code on that machine first. The console windows would appear on the server's display.

## Troubleshooting

If something isn't working:

1. Check the Claude Code console window for errors
2. Look at the Minecraft server log for `[claudecraft]` messages
3. Try deleting `~/.claudecraft/computers/<id>/` and running `claude` again
4. Delete `/.claude/mode` on the CC:Tweaked computer to reset the setup
