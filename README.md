# ClaudeCraft

A Minecraft Forge mod that brings Claude AI into [CC: Tweaked](https://tweaked.cc/) computers and turtles.

Players interact with Claude through an in-game terminal — ask questions, run tools, automate tasks, and control turtles using natural language.

## Requirements

- Minecraft 1.19.2
- Minecraft Forge 43.3.0+
- [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) 1.101.3+
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
