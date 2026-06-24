# ClaudeCraft

A Minecraft NeoForge mod that brings Claude AI into [CC: Tweaked](https://tweaked.cc/) computers and turtles.

Players interact with Claude through an in-game terminal — ask questions, run tools, automate tasks, and control turtles using natural language.

## Requirements

- Minecraft 1.21.1
- NeoForge 21.1.0+
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
   - **API Key** — set your key with `/claudecraft setkey sk-ant-...` first
   - **Claude Code** — requires Bun and Claude Code installed on the host ([setup guide](docs/channel-mode.md))

## Features

- **Two connection modes** — use an API key or connect through Claude Code (no key needed)
- **Streaming responses** — see Claude's output in real time (API key mode)
- **Tool use** — Claude can read/write files, run shell commands, control redstone, interact with peripherals, and pilot turtles
- **Inventory scanning** — scan chests, barrels, and shulker boxes for items via peripherals
- **GPS navigation** — turtles can navigate to coordinates with pathfinding, digging through obstacles
- **Blueprint building** — execute multi-block builds from blueprints with relative coordinates
- **Multi-computer messaging** — send messages between computers and turtles for coordinated automation
- **Per-computer isolation** — each computer gets its own Claude session in channel mode
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
| `build_structure` | Execute multi-block builds from blueprints |

## In-Game Commands

| Command | Description |
|---|---|
| `/claudecraft setkey <key>` | Set your Anthropic API key |
| `/claudecraft model <model>` | Change the Claude model |
| `/claudecraft status` | Show current configuration |

## Building from Source

```bash
cd forge
./gradlew build
```

The built jar will be in `forge/build/libs/`.

## License

MIT
