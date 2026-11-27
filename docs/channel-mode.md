# Channel Mode Setup Guide

Channel mode lets CC:Tweaked computers connect to Claude through [Claude Code](https://claude.ai/download) instead of requiring an Anthropic API key. Each computer gets its own Claude Code session, running on the machine that hosts the world and using that machine's Claude Code login.

Channel mode is **off by default**. An operator has to turn it on and allow each computer that may use it (see [Enabling channel mode](#enabling-channel-mode)).

> **Multiplayer warning.** Every channel session runs on the host machine, as the OS user that runs Minecraft, signed in to that user's Claude account. Anyone who can type at an allowed computer is using that account and its usage limits. The mod can't tell which player is typing at a computer, so access is granted per computer, not per player. Only allow computers that sit somewhere you control, and read [Security](#security) before enabling channel mode on a server other people join.

## Requirements

- [Bun](https://bun.sh) runtime installed on the server/host machine
- [Claude Code](https://claude.ai/download) CLI installed and logged in (`npm install -g @anthropic-ai/claude-code`)
- ClaudeCraft mod installed with CC:Tweaked
- On Windows: PowerShell (included with Windows), which the mod uses to open each session's console window

## Quick Start

1. **Install Bun** (if not already installed):
   - Windows: `powershell -Command "irm bun.sh/install.ps1 | iex"`
   - Linux/Mac: `curl -fsSL https://bun.sh/install | bash`

2. **Install Claude Code** (if not already installed):
   ```
   npm install -g @anthropic-ai/claude-code
   ```

3. **Log in to Claude Code**: run `claude` in a terminal once and complete the login flow.

4. **Enable channel mode** as an operator (permission level 3):
   ```
   /claudecraft channel enable
   ```

5. **Allow the computer.** Find its ID by running `id` on the computer, then:
   ```
   /claudecraft channel allow <computerId>
   ```

6. **On that computer**, run:
   ```
   claude
   ```

7. **Select "Claude Code"** (option 2) on the setup screen.

8. On Windows, a Claude Code console window opens. The first time, Claude Code asks whether you trust the computer's sandbox folder: accept it in that window. The in-game computer connects once Claude Code is ready.

In singleplayer you need cheats on to run these commands. You can also edit the config file instead (see below), or set `allowAllInSingleplayer = true` so every computer is allowed while the world is not open to LAN.

## Enabling channel mode

The settings live in the `[channel]` section of the world's server config, `<world>/serverconfig/claudecraft-server.toml`. The commands below change it for you.

| Setting | Default | Meaning |
|---|---|---|
| `enableChannelMode` | `false` | Allow computers to use channel mode at all. |
| `maxChannelSessions` | `4` | How many Claude Code sessions may run at once (1-32). |
| `allowedComputers` | `[]` | Computer IDs allowed to use channel mode. |
| `allowAllInSingleplayer` | `false` | On a singleplayer world that is not open to LAN, allow every computer without listing it. `enableChannelMode` must still be true. |

Operator commands (permission level 3):

| Command | What it does |
|---|---|
| `/claudecraft channel enable` | Turn channel mode on. |
| `/claudecraft channel disable` | Turn channel mode off and stop every session. |
| `/claudecraft channel allow <computerId>` | Add a computer to the allowlist. |
| `/claudecraft channel deny <computerId>` | Remove a computer from the allowlist and stop its session. |
| `/claudecraft channel list` | Show whether channel mode is on, the session limit, and the allowlist. |
| `/claudecraft channel sessions` | Show running sessions: computer, state, port, process ID and uptime. |
| `/claudecraft channel kill <computerId>` | Stop a computer's session. |

`/claudecraft status` also shows whether channel mode is on and how many sessions are running.

A computer keeps its ID when it is broken and placed again, so an allowed computer stays allowed wherever it is carried.

## Security

### What the mod locks down

Each session's Claude Code is started with:

- `--tools ""`: no built-in tools. Claude Code can't run shell commands, read or write files on the host, or fetch web pages. It only has the ClaudeCraft tools, which act on the in-game computer.
- `--strict-mcp-config --mcp-config .mcp.json`: only the ClaudeCraft channel server, none of the host's other MCP servers.
- `--setting-sources project,local`: only the sandbox's own settings. The host user's settings, allow rules, permission mode, plugins and skills don't apply.
- `--append-system-prompt-file CLAUDE.md`: the sandbox's instructions (see the next point for why they are passed this way).

The sandbox's `.claude/settings.local.json` also denies the built-in tools by name (Bash, PowerShell, Read, Write, Edit, WebFetch, WebSearch, Agent and others) as a second layer. As a side effect, the `Read` rule stops Claude Code from loading CLAUDE.md files on its own, which keeps the host's CLAUDE.md files (one in a parent folder, and the user-level `~/.claude/CLAUDE.md`) out of the session. The same file turns off auto memory and hooks and disables bypass-permissions mode, and the mod also sets `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` for the session.

If Minecraft itself was started from inside a Claude Code session (for example `./gradlew runClient` from Claude Code), the mod removes that session's environment variables before starting a channel session, so the sandbox doesn't inherit its account details or messaging token.

### Known limits

- **It is not an OS sandbox.** Claude Code runs as the same OS user as Minecraft, and the restrictions above are Claude Code's own settings. A Claude Code bug, or a future change to how these flags work, could weaken them. The mod was checked against Claude Code 2.1.330.
- **Organization-managed Claude Code settings still apply** on the host, if it has any.
- **The ClaudeCraft tools are real.** Claude can run programs on the computer, edit its files, use redstone and peripherals, move turtles, and message other computers. Treat an allowed computer like a computer you've handed to whoever can reach it.
- **The `Read` deny rule is what keeps other CLAUDE.md files out.** Claude Code doesn't document this. It was confirmed for CLAUDE.md files in the sandbox and parent folders. The user-level `~/.claude/CLAUDE.md` goes through the same check, but that case wasn't tested. If a future version changes this, the host's CLAUDE.md files could load into sessions. Keep nothing private in them.
- **The trust prompt.** Claude Code asks once per new sandbox folder whether to trust it. Until you accept, it ignores the sandbox's allow rules (the deny rules apply right away).
- **Ports.** Channel servers listen on 127.0.0.1, on ports 8789-8988. Other programs on the host can connect to them.

## How It Works

When you select Channel mode on a CC:Tweaked computer:

1. The mod checks that channel mode is enabled, the computer is allowed, and the session limit isn't reached.
2. The mod extracts a channel server to `~/.claudecraft/channel/` and runs `bun install` (first time only).
3. A sandbox folder is created at `~/.claudecraft/worlds/<world>/computers/<id>/`. `<world>` is the world's save folder name plus a short hash of its full path, so different worlds and servers never share a session.
4. Claude Code starts, locked down as described above, with the channel server configured as its only MCP server:
   - On Windows it opens in its own console window.
   - On Linux and macOS it runs in the background under a pseudo-terminal (`script`). No window opens.
5. The channel server bridges messages between the Minecraft mod and Claude Code:
   - Player messages go from the CC:Tweaked computer → Java mod → channel server → Claude Code
   - Claude Code's tool calls go back through the channel server → Java mod → CC:Tweaked computer for execution
   - Claude Code's replies travel the same path back to the in-game terminal

Each computer has its own Claude Code session, sandbox folder and port. The computer's label is read by the mod itself, stripped of line breaks and control characters, and shortened to 32 characters before it goes into any generated file.

Channel mode offers the same tools as API key mode. The in-game `claude` program passes its tool list (`tools.getDefs()` in `claude.lua`) to the mod, which writes it to `tools.json` in the sandbox, and the channel server serves it to Claude Code. The system prompt (your `personality` and `systemPromptPrefix` config) goes with the first message and again whenever it changes. Tools time out after `toolTimeoutSeconds`. Long tools such as `build_structure` and `turtle_goto` get more time.

### Session lifecycle

- The mod tracks each session by the process ID of its launcher (the console window on Windows, `script` elsewhere) and kills that whole process tree when the session stops.
- A session stops when you exit the program in-game, the computer shuts down or its chunk unloads, an operator runs `kill`, `deny` or `disable`, or the server stops.
- If the server crashes, the next start of that world kills the sessions it left running.
- Running `claude` again while the computer's session is still starting reuses that session instead of starting a second one.

## Switching Modes

Type `/mode` in the claude program to reset your connection mode. The next time you run `claude`, you'll see the setup screen again.

## FAQ

### "Channel mode is disabled on this server"

An operator needs to run `/claudecraft channel enable`.

### "Computer #N is not allowed to use channel mode"

An operator needs to run `/claudecraft channel allow N`.

### "All N Claude Code sessions are in use"

The server is running as many sessions as `maxChannelSessions` allows. Wait for one to end, ask an operator to stop one (`/claudecraft channel sessions`, then `kill`), or raise the limit in the config.

### "Bun is not installed"

Install Bun:
- **Windows**: `powershell -Command "irm bun.sh/install.ps1 | iex"`
- **Linux/Mac**: `curl -fsSL https://bun.sh/install | bash`

Restart your terminal (or Minecraft server) after installing so it appears in PATH.

### "Channel server did not start"

This means Claude Code didn't finish starting within 30 seconds. Common causes:

- **Claude Code not installed**: Run `npm install -g @anthropic-ai/claude-code`
- **Not logged in**: Run `claude` in a terminal and complete the login
- **Waiting on the trust prompt**: accept it in the Claude Code window, then run `claude` in-game again
- **Slow startup**: Claude Code can take a while on first launch. Try again; subsequent launches are faster.

On Windows, check the Claude Code console window that opened for error messages. If Claude Code exits with an error, the window stays open so you can read it.

### "Channel server not reachable on port XXXX"

The channel server process started but isn't responding. Check the Claude Code console window for errors. The server may still be initializing; try sending your message again.

### "Channel connection failed: closed"

The connection to the channel server was lost. This can happen if:

- Claude Code crashed or was closed manually
- The channel server encountered an error

Run `claude` again on the computer to restart the session.

### "This computer's Claude Code session has ended"

The session was stopped (by an operator, a crash, or Claude Code exiting) while the program was still running. Exit and run `claude` again.

### The Claude Code window asks for permission

The mod pre-approves all ClaudeCraft MCP tools, but Claude Code only applies those approvals once you've accepted the trust prompt for the sandbox folder. If you still see permission prompts after trusting it:

1. Close the Claude Code window
2. Delete `~/.claudecraft/worlds/<world>/computers/<id>/.claude/settings.local.json`
3. Run `claude` in-game again; the mod regenerates the settings file

### Can I use both modes on different computers?

Yes. Each computer independently chooses its mode. One computer can use API key mode while another uses Channel mode. The choice is stored per-computer in `/.claude/mode` on the CC:Tweaked filesystem.

### Where are the sandbox directories?

- Channel server files: `~/.claudecraft/channel/`
- Per-world files: `~/.claudecraft/worlds/<world>/`
  - `channel-registry.json`: which port each computer's channel server uses (for `send_message`)
  - `sessions.json`: each session's process ID, used to clean up after a crash
- Per-computer sandboxes: `~/.claudecraft/worlds/<world>/computers/<id>/`
- Each sandbox contains: `CLAUDE.md`, `.mcp.json`, `tools.json` (the computer's tool list), `.claude/settings.local.json`, and on Windows `launch-claude.bat`

Older versions used `~/.claudecraft/computers/<id>/`, shared by every world. Those folders are no longer used and can be deleted. After upgrading, each computer starts in a new sandbox folder, so Claude Code asks for trust again.

### Does channel mode support streaming?

No. In channel mode, Claude Code sends complete replies rather than streaming token-by-token. API key mode retains full streaming support.

### Can I see what Claude Code is doing?

On Windows, yes: each computer's session runs in its own console window, titled `ClaudeCraft Computer #<id> - <world>`, where you can watch it process messages, call tools, and reply.

On Linux and macOS, sessions run in the background with no window. Use `/claudecraft channel sessions` to see what is running.

### How do I stop a channel session?

- Type `exit` or `quit` in the CC:Tweaked computer; the session cleans up automatically
- An operator can run `/claudecraft channel kill <computerId>`
- On Windows, close the Claude Code console window
- The server stops all sessions when the Minecraft world is closed

### Does this work on dedicated servers?

Channel mode needs Bun and Claude Code installed on the server machine, and Claude Code logged in there as the user that runs the server.

- **Windows**: each session opens a console window on the server's desktop, so the server must run in a logged-in desktop session.
- **Linux and macOS**: sessions run headless under a pseudo-terminal, with no window. If Claude Code stops at a prompt on first start (such as the folder trust prompt), nobody can answer it from the game. Run `claude` once from a terminal in that computer's sandbox folder, accept the prompt, then run `claude` in-game again.

Read [Security](#security) first: every player who can reach an allowed computer uses the server owner's Claude account.

## Troubleshooting

If something isn't working:

1. On Windows, check the Claude Code console window for errors
2. Look at the Minecraft server log for `[claudecraft]` messages
3. Run `/claudecraft channel list` and `/claudecraft channel sessions`
4. Try deleting `~/.claudecraft/worlds/<world>/computers/<id>/` and running `claude` again
5. Delete `/.claude/mode` on the CC:Tweaked computer to reset the setup
