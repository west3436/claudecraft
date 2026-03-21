# ClaudeCraft

A Minecraft Forge mod that brings Claude AI into [CC: Tweaked](https://tweaked.cc/) computers and turtles.

Players interact with Claude through an in-game terminal — ask questions, run tools, automate tasks, and control turtles using natural language.

## Requirements

- Minecraft 1.19.2
- Minecraft Forge 43.2.0+
- [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) 1.101.0+
- **One** of the following:
  - An [Anthropic API key](https://console.anthropic.com/) (API Key mode), **or**
  - [Claude Code](https://claude.ai/download) + [Bun](https://bun.sh) installed (Channel mode — no API key needed)

## Installation

1. Install Minecraft Forge and CC: Tweaked.
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
- **Per-computer isolation** — each computer gets its own Claude session in channel mode
- **Monitor support** — automatically uses connected monitors for a larger display
- **Conversation history** — persistent chat history stored per computer
- **Configurable** — choose model, max tokens, system prompt, and concurrency limits

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
