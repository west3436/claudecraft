# ClaudeCraft

A Minecraft NeoForge mod that brings Claude AI into [CC: Tweaked](https://tweaked.cc/) computers and turtles.

Players interact with Claude through an in-game terminal — ask questions, run tools, automate tasks, and control turtles using natural language.

## Supported versions

| Minecraft | Loader | Status |
|---|---|---|
| **1.21.1** | **NeoForge 21.1.x** | **Supported.** Download the latest `-1.21.1` release from [Releases](https://github.com/west3436/claudecraft/releases). |
| 1.20.1 | Forge | No longer supported |
| 1.19.2 | Forge | No longer supported |
| 1.18.2 | Forge | No longer supported |
| 1.16.5 | Forge | No longer supported |

Only 1.21.1 gets new features and fixes. The 1.16.5, 1.18.2, 1.19.2 and 1.20.1 builds stopped at 1.2.1. Their branches and releases stay up but will not be updated, including for security fixes. In particular, they still store the API key in a server config that is sent to every player who joins (see [Setting the API key](#setting-the-api-key)). If you run one of them, move to 1.21.1.

## Requirements

- Minecraft 1.21.1
- NeoForge 21.1.x
- [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) 1.117.1+
- **One** of the following:
  - An [Anthropic API key](https://console.anthropic.com/) (API Key mode), **or**
  - [Claude Code](https://claude.ai/download) + [Bun](https://bun.sh) installed (Channel mode — no API key needed)

## Installation

1. Install NeoForge and CC: Tweaked.
2. Drop the ClaudeCraft `.jar` into your `mods/` folder.
3. Open any CC: Tweaked computer or turtle and run:
   ```
   claude
   ```
4. Choose your connection mode:
   - **API Key** — set your key first (see [Setting the API key](#setting-the-api-key) below)
   - **Claude Code** — requires Bun and Claude Code installed on the host, and an operator must enable it and allow the computer with `/claudecraft channel enable` and `/claudecraft channel allow <computerId>` ([setup guide](docs/channel-mode.md))

### Setting the API key

The key stays on the server and is never sent to clients. ClaudeCraft looks for it in this order:

1. **The `CLAUDECRAFT_API_KEY` environment variable**, set on the server process. ClaudeCraft never writes it. `ANTHROPIC_API_KEY` is ignored on purpose: Claude Code processes spawned for Channel mode would inherit it.
2. **The secrets file `<game dir>/claudecraft/api-key`.** `/claudecraft setkey sk-ant-...` writes it, and `/claudecraft clearkey` deletes it. The file sits outside the world save and `config/`, so it doesn't end up in world backups or shared modpack configs. ClaudeCraft makes it owner-only where the OS allows: mode `600` on Linux/macOS, an owner-only ACL on Windows.

If you use `setkey`, run it from the server console where you can. Chat commands are kept in the client's command history.

> **Upgrading from an older version?** Older versions stored the key as `apiKey` in `claudecraft-server.toml`, which lives in `config/` or a world's `serverconfig/` folder. NeoForge sends that file to every player who joins. On the first start after upgrading, ClaudeCraft moves the key to the secrets file, clears it from the config and from NeoForge's automatic `.bak` backups of it, and logs a warning. **Rotate that key** at [console.anthropic.com](https://console.anthropic.com/), because any player who joined before the upgrade could have read it. Check `defaultconfigs/claudecraft-server.toml` and any other copies of the config too.

## Features

- **Two connection modes** — use an API key or connect through Claude Code (no key needed)
- **Streaming responses** — see Claude's output in real time (API key mode)
- **Tool use** — Claude can read/write files, run shell commands, control redstone, interact with peripherals, and pilot turtles
- **Inventory scanning** — scan chests, barrels, and shulker boxes for items via peripherals
- **GPS navigation** — turtles can navigate to coordinates with pathfinding, digging through obstacles
- **Blueprint building** — execute multi-block builds from blueprints with relative coordinates
- **Multi-computer messaging** — send messages between computers and turtles for coordinated automation
- **Per-computer sessions** — each computer gets its own Claude Code session in channel mode, limited to the in-game tools
- **Monitor support** — automatically uses connected monitors for a larger display
- **Conversation history** — persistent chat history stored per computer
- **Configurable** — choose model, max tokens, system prompt, and concurrency limits

## Tools

### General

| Tool | Description |
|---|---|
| `reply` | Send a message back to the player |
| `read_file` | Read a file from the computer's filesystem |
| `write_file` | Write content to a file |
| `edit_file` | Edit an existing file with find-and-replace |
| `list_files` | List files and directories |
| `find_files` | Search for files by name pattern |
| `search_content` | Search file contents with pattern matching |
| `run_command` | Execute a shell command on the computer |
| `delete_path` | Delete a file or directory |
| `move_path` | Move or rename a file or directory |
| `get_info` | Get information about the computer and world |
| `redstone` | Read or set redstone signals |
| `peripheral_call` | Call methods on attached peripherals |
| `get_recipes` | Look up crafting recipes for items |
| `scan_inventory` | Scan containers (chests, barrels, shulker boxes) for items |
| `send_message` | Send messages to other computers or turtles |

### Turtle

| Tool | Description |
|---|---|
| `turtle_move` | Move the turtle (forward, back, up, down, turn) |
| `turtle_dig` | Dig blocks in any direction |
| `turtle_place` | Place blocks or items |
| `turtle_inspect` | Inspect blocks around the turtle |
| `turtle_inventory` | Manage the turtle's inventory |
| `turtle_goto` | Navigate to GPS coordinates with pathfinding |
| `build_structure` | Build from shapes (box, hollow box, wall, floor, cylinder, sphere/dome, gable roof) or single blocks, in coordinates relative to the turtle. `dry_run` reports size, materials vs inventory and fuel without moving; optional restock chest and monitor preview |

### Memory & Base Atlas

| Tool | Description |
|---|---|
| `remember` / `forget` | Per-computer notes in `/.claude/memory.md`, shown to Claude every turn (`/memory` to view) |
| `set_waypoint` / `list_waypoints` / `remove_waypoint` | Named locations in a world-saved atlas shared by all computers |
| `atlas_search` | "Where are my diamonds?" from stored `scan_inventory` results, with scan age |

See [docs/memory-and-atlas.md](docs/memory-and-atlas.md).

## In-Game Commands

| Command | Description |
|---|---|
| `/claudecraft setkey <key>` | Save your Anthropic API key to the server-only secrets file |
| `/claudecraft clearkey` | Delete the secrets file |
| `/claudecraft model <model>` | Change the Claude model |
| `/claudecraft status` | Show where the API key comes from (never the key), the model, and channel mode status |
| `/claudecraft channel enable` \| `disable` | Turn channel mode on or off. Disabling stops every running session |
| `/claudecraft channel allow <computerId>` | Let a computer use channel mode |
| `/claudecraft channel deny <computerId>` | Remove a computer from the allowlist and stop its session |
| `/claudecraft channel list` | Show whether channel mode is on, the session limit, and the allowed computers |
| `/claudecraft channel sessions` | List running Claude Code sessions with status, port, PID and uptime |
| `/claudecraft channel kill <computerId>` | Stop one computer's Claude Code session |

All `/claudecraft` commands need operator level 3.

## Building from Source

```bash
cd forge
./gradlew build
```

The built jar will be in `forge/build/libs/`.

## License

MIT
