# ClaudeCraft

A Minecraft Forge mod that brings Claude AI into [CC: Tweaked](https://tweaked.cc/) computers and turtles.

Players interact with Claude through an in-game terminal — ask questions, run tools, automate tasks, and control turtles using natural language.

## Requirements

- Minecraft 1.16.5
- Minecraft Forge 36.2.39+
- [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) 1.101.2+
- An [Anthropic API key](https://console.anthropic.com/)

## Installation

1. Install Minecraft Forge and CC: Tweaked.
2. Drop the ClaudeCraft `.jar` into your `mods/` folder.
3. Launch the game and set your API key:
   ```
   /claudecraft setkey sk-ant-...
   ```
4. Open any CC: Tweaked computer or turtle and run:
   ```
   claude
   ```

## Features

- **Streaming responses** — see Claude's output in real time on the terminal
- **Tool use** — Claude can read/write files, run shell commands, control redstone, interact with peripherals, and pilot turtles
- **Inventory scanning** — scan chests, barrels, and shulker boxes for items via peripheral
- **Area scanning** — scan surrounding blocks using scanner peripherals or turtle inspect
- **GPS navigation** — turtles can navigate to coordinates with pathfinding, digging through obstacles
- **Blueprint building** — execute multi-block builds from blueprints with relative coordinates
- **Inter-computer messaging** — send messages between computers for multi-computer coordination and turtle swarms
- **Redstone automation** — gather redstone state and peripheral info to help design circuits
- **Personality system** — configure a custom personality for the AI via the mod config
- **Startup tasks** — place a `/.claude/startup` file to auto-send a message on launch for autonomous operation
- **Token & cost tracking** — track token usage and estimated costs per session with `/stats`
- **Progress tracking** — track blocks mined, placed, files written, and more with `/progress`
- **Chat search** — search conversation history with `/search <term>`
- **Auto-retry** — automatic retry with exponential backoff on rate limits and server errors
- **Configurable tool timeout** — adjust how long tools can run before timing out
- **Monitor support** — automatically uses connected monitors for a larger display
- **Conversation history** — persistent chat history stored per computer
- **Configurable** — choose model, max tokens, system prompt, personality, and concurrency limits

## Tools

### General

| Tool | Description |
|---|---|
| `reply` | Send a message back to the player |
| `read_file` | Read the contents of a file |
| `write_file` | Write content to a file |
| `edit_file` | Edit a file with find-and-replace |
| `list_files` | List files in a directory |
| `find_files` | Search for files by name pattern |
| `search_content` | Search file contents with pattern matching |
| `run_command` | Execute a shell command on the computer |
| `delete_path` | Delete a file or directory |
| `move_path` | Move or rename a file or directory |
| `get_info` | Get information about the computer or turtle |
| `redstone` | Read or set redstone signals |
| `peripheral_call` | Call a method on a connected peripheral |
| `get_recipes` | Look up crafting recipes |
| `scan_inventory` | Scan containers (chests, barrels, shulker boxes) for items via peripheral |
| `scan_area` | Scan surrounding blocks using scanner peripheral or turtle inspect |
| `automate_redstone` | Gather redstone state and peripheral info for circuit design |
| `send_message` | Send a message to another computer for multi-computer coordination |

### Turtle

| Tool | Description |
|---|---|
| `turtle_move` | Move the turtle in a direction |
| `turtle_dig` | Dig a block in a direction |
| `turtle_place` | Place a block in a direction |
| `turtle_inspect` | Inspect a block in a direction |
| `turtle_inventory` | Manage the turtle's inventory |
| `turtle_goto` | Navigate to GPS coordinates with pathfinding |
| `build_structure` | Execute multi-block builds from blueprints |

## Chat Commands

| Command | Description |
|---|---|
| `/clear` | Reset conversation history |
| `/mode` | Change connection mode |
| `/stats` | Show token usage and estimated cost |
| `/search <term>` | Search chat history |
| `/progress` | Show achievement statistics |
| `/help` | Show available commands |

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
