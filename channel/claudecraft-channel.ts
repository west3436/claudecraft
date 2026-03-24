#!/usr/bin/env bun
/**
 * ClaudeCraft Channel Server
 *
 * An MCP channel server that bridges CC:Tweaked computers in Minecraft
 * to Claude Code sessions. Each computer gets its own server instance
 * and Claude Code process, ensuring complete isolation.
 *
 * Protocol:
 *   Minecraft Mod  ──HTTP──►  This Server  ──MCP/stdio──►  Claude Code
 *
 * HTTP endpoints (for the Java mod):
 *   POST /message       — Player sends a message, forwarded to Claude Code
 *   POST /tool-result   — Mod returns a tool execution result
 *   GET  /events        — SSE stream of events back to the mod
 *   GET  /health        — Health check
 *
 * MCP interface (for Claude Code):
 *   Channel notifications push player messages
 *   Minecraft tools registered as MCP tools
 *   Reply tool for Claude Code to send text back
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
function getArg(name: string, fallback: string): string {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : fallback;
}
function hasFlag(name: string): boolean {
  return args.includes(`--${name}`);
}

const PORT = parseInt(getArg("port", "8789"), 10);
const COMPUTER_ID = getArg("computer-id", "0");
const COMPUTER_LABEL = getArg("label", "Computer");
const IS_TURTLE = hasFlag("turtle");
const TERM_WIDTH = parseInt(getArg("term-width", "51"), 10);
const TERM_HEIGHT = parseInt(getArg("term-height", "19"), 10);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** Pending tool calls waiting for results from the Minecraft mod. */
const pendingToolCalls = new Map<
  string,
  { resolve: (result: string) => void }
>();

/** Active SSE connections keyed by request ID. */
const sseConnections = new Map<
  string,
  { controller: ReadableStreamDefaultController<Uint8Array> }
>();

/** Global SSE connection (mod connects once, receives all events). */
let globalSSE: {
  controller: ReadableStreamDefaultController<Uint8Array>;
} | null = null;

let toolCallCounter = 0;

/** Whether we have an active conversation turn in progress. */
let activeTurnRequestId: string | null = null;

/** Whether the MCP connection to Claude Code is alive. */
let mcpConnected = true;

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function sendSSE(
  data: Record<string, unknown>,
  requestId?: string
): void {
  const payload = `data: ${JSON.stringify(data)}\n\n`;
  const bytes = new TextEncoder().encode(payload);

  // Send to request-specific SSE if it exists
  if (requestId) {
    const conn = sseConnections.get(requestId);
    if (conn) {
      try {
        conn.controller.enqueue(bytes);
      } catch {
        sseConnections.delete(requestId);
      }
    }
  }

  // Also send to global SSE
  if (globalSSE) {
    try {
      globalSSE.controller.enqueue(bytes);
    } catch {
      globalSSE = null;
    }
  }
}

// ---------------------------------------------------------------------------
// Minecraft tool definitions
// ---------------------------------------------------------------------------

interface ToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const STANDARD_TOOLS: ToolDef[] = [
  {
    name: "read_file",
    description: "Read a file from the computer's filesystem.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string", description: "File path" } },
      required: ["path"],
    },
  },
  {
    name: "write_file",
    description: "Create or overwrite a file.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path" },
        content: { type: "string", description: "File content" },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "edit_file",
    description:
      "Replace a unique string in a file. old_text must appear exactly once.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path" },
        old_text: { type: "string", description: "Text to find (must be unique)" },
        new_text: { type: "string", description: "Replacement text" },
      },
      required: ["path", "old_text", "new_text"],
    },
  },
  {
    name: "list_files",
    description: "List directory contents.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string", description: "Directory path" } },
      required: ["path"],
    },
  },
  {
    name: "find_files",
    description: "Find files matching a wildcard pattern.",
    inputSchema: {
      type: "object",
      properties: {
        pattern: { type: "string", description: "Wildcard pattern" },
      },
      required: ["pattern"],
    },
  },
  {
    name: "search_content",
    description: "Search for a pattern in files (grep).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Root path to search" },
        pattern: { type: "string", description: "Search pattern" },
      },
      required: ["path", "pattern"],
    },
  },
  {
    name: "run_command",
    description: "Run a shell command on the CC:Tweaked computer.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", description: "Command to execute" },
      },
      required: ["command"],
    },
  },
  {
    name: "delete_path",
    description: "Delete a file or directory.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string", description: "Path to delete" } },
      required: ["path"],
    },
  },
  {
    name: "move_path",
    description: "Move or rename a file/directory.",
    inputSchema: {
      type: "object",
      properties: {
        from: { type: "string", description: "Source path" },
        to: { type: "string", description: "Destination path" },
      },
      required: ["from", "to"],
    },
  },
  {
    name: "get_info",
    description:
      "Get system info: computer ID, fuel level, peripherals, time.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "redstone",
    description:
      "Redstone I/O. Actions: getInput, getOutput, setOutput, getAnalogInput, setAnalogOutput.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Redstone action" },
        side: { type: "string", description: "Side (top/bottom/left/right/front/back)" },
        value: { type: "number", description: "Value for set operations" },
      },
      required: ["action", "side"],
    },
  },
  {
    name: "peripheral_call",
    description: "Call a method on a peripheral.",
    inputSchema: {
      type: "object",
      properties: {
        side: { type: "string", description: "Peripheral name or side" },
        method: { type: "string", description: "Method to call" },
        args: {
          type: "array",
          description: "Arguments to pass",
          items: {},
        },
      },
      required: ["side", "method"],
    },
  },
];

const TURTLE_TOOLS: ToolDef[] = [
  {
    name: "turtle_move",
    description:
      "Move the turtle: forward, back, up, down, turnLeft, turnRight.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Movement action" },
        count: { type: "number", description: "Number of times (default 1)" },
      },
      required: ["action"],
    },
  },
  {
    name: "turtle_dig",
    description: "Dig: dig, digUp, digDown.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Dig action" },
      },
      required: ["action"],
    },
  },
  {
    name: "turtle_place",
    description: "Place a block: place, placeUp, placeDown.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Place action" },
      },
      required: ["action"],
    },
  },
  {
    name: "turtle_inspect",
    description:
      "Inspect blocks: inspect, inspectUp, inspectDown, detect, detectUp, detectDown.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Inspect action" },
      },
      required: ["action"],
    },
  },
  {
    name: "turtle_inventory",
    description:
      "Inventory management: select, getItemDetail, getItemCount, transferTo, refuel, drop, suck, etc.",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Inventory action" },
        slot: { type: "number", description: "Slot number" },
        count: { type: "number", description: "Item count" },
      },
      required: ["action"],
    },
  },
  {
    name: "build_structure",
    description:
      "Execute a multi-block build from a blueprint. Provide blocks as relative coordinates from the turtle's current position. The turtle navigates to each position, selects the matching block from inventory, and places it. Builds bottom-up layer by layer. Block names must match inventory item names (e.g. 'minecraft:oak_planks'). The turtle must have the required blocks in its inventory before calling this tool.",
    inputSchema: {
      type: "object",
      properties: {
        blocks: {
          type: "array",
          description:
            "Array of block placements relative to turtle's starting position.",
          items: {
            type: "object",
            properties: {
              x: { type: "number", description: "X offset (right of turtle)" },
              y: {
                type: "number",
                description: "Y offset (up from turtle, 0 = turtle level - 1)",
              },
              z: {
                type: "number",
                description: "Z offset (forward from turtle)",
              },
              block: {
                type: "string",
                description:
                  "Minecraft block ID matching inventory item (e.g. 'minecraft:oak_planks')",
              },
            },
            required: ["x", "y", "z", "block"],
          },
        },
      },
      required: ["blocks"],
    },
  },
  {
    name: "turtle_goto",
    description:
      "Navigate the turtle to target coordinates using GPS and pathfinding. " +
      "Automatically determines facing direction, digs through obstacles, and " +
      "moves along each axis (Y first, then X, then Z). Requires GPS satellites " +
      "in the world. Returns final position and whether the turtle arrived.",
    inputSchema: {
      type: "object",
      properties: {
        x: { type: "number", description: "Target X coordinate" },
        y: { type: "number", description: "Target Y coordinate" },
        z: { type: "number", description: "Target Z coordinate" },
      },
      required: ["x", "y", "z"],
    },
  },
];

const ALL_TOOLS = IS_TURTLE
  ? [...STANDARD_TOOLS, ...TURTLE_TOOLS]
  : STANDARD_TOOLS;

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const systemInstructions = [
  `You are Claude Code, an AI assistant installed inside a ComputerCraft computer in Minecraft.`,
  `Computer ID: ${COMPUTER_ID}. Label: ${COMPUTER_LABEL}. Terminal: ${TERM_WIDTH}x${TERM_HEIGHT}.`,
  IS_TURTLE
    ? `This is a TURTLE — you can move, dig, place blocks, and manage inventory.`
    : `This is a standard computer.`,
  ``,
  `RULES:`,
  `- You exist INSIDE this CC:Tweaked computer. Stay in character at all times.`,
  `- ONLY use the Minecraft tools provided here. Do NOT use any built-in Claude Code tools (Read, Write, Edit, Bash, Grep, Glob, etc).`,
  `- You do NOT have access to the host filesystem. Your filesystem is the CC:Tweaked virtual FS.`,
  `- NEVER use emojis — the terminal cannot display them (they show as ?).`,
  `- NEVER use markdown formatting (no **, no ##, no \`\`\`) — this is a plain text terminal.`,
  `- Be VERY concise — the terminal is only ${TERM_WIDTH}x${TERM_HEIGHT} characters.`,
  `- Write idiomatic CC:Tweaked Lua when writing code.`,
  `- Use tools proactively to explore and accomplish tasks.`,
  ``,
  `Player messages arrive as <channel> events. Reply using the "reply" tool with the text you want to display.`,
  `You may call multiple Minecraft tools before replying. When you are done, ALWAYS call the reply tool.`,
].join("\n");

const mcp = new Server(
  { name: "claudecraft", version: "0.1.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: {},
    },
    instructions: systemInstructions,
  }
);

// -- Tool listing --

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    // Minecraft tools
    ...ALL_TOOLS.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema,
    })),
    // Reply tool
    {
      name: "reply",
      description:
        "Send a text reply back to the player. Call this when you are done processing.",
      inputSchema: {
        type: "object" as const,
        properties: {
          text: {
            type: "string" as const,
            description: "The reply text to display on the terminal",
          },
        },
        required: ["text"],
      },
    },
  ],
}));

// -- Tool execution --

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: toolArgs } = req.params;

  // Handle reply tool
  if (name === "reply") {
    const text = (toolArgs as { text: string }).text;
    const reqId = activeTurnRequestId;
    if (reqId) {
      sendSSE({ type: "reply", text }, reqId);
      sendSSE({ type: "done" }, reqId);
      activeTurnRequestId = null;
    }
    return { content: [{ type: "text" as const, text: "Reply sent." }] };
  }

  // Handle Minecraft tools — forward to mod via SSE, await result
  const callId = `tc_${++toolCallCounter}`;
  const reqId = activeTurnRequestId;

  // Push tool_call event to the mod
  sendSSE(
    {
      type: "tool_call",
      callId,
      toolName: name,
      input: JSON.stringify(toolArgs ?? {}),
    },
    reqId ?? undefined
  );

  // Wait for the mod to POST the result
  // build_structure can take several minutes for large blueprints;
  // turtle_goto may travel long distances, allow 5 minutes
  const timeoutMs = name === "build_structure" ? 600_000
    : name === "turtle_goto" ? 300_000
    : 60_000;
  const result = await new Promise<string>((resolve) => {
    pendingToolCalls.set(callId, { resolve });

    setTimeout(() => {
      if (pendingToolCalls.has(callId)) {
        pendingToolCalls.delete(callId);
        resolve(JSON.stringify({ error: "Tool execution timed out" }));
      }
    }, timeoutMs);
  });

  return { content: [{ type: "text" as const, text: result }] };
});

// ---------------------------------------------------------------------------
// Connect MCP over stdio
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await mcp.connect(transport);

// Detect MCP disconnection (Claude Code crash or exit)
mcp.onclose = () => {
  mcpConnected = false;
  console.error("[ClaudeCraft Channel] MCP connection closed — Claude Code has disconnected.");

  // Notify any active SSE connections that the session is dead
  const reqId = activeTurnRequestId;
  if (reqId) {
    sendSSE({ type: "error", message: "Claude Code process disconnected." }, reqId);
    activeTurnRequestId = null;
  }

  // Resolve all pending tool calls so they don't hang
  for (const [callId, pending] of pendingToolCalls) {
    pending.resolve(JSON.stringify({ error: "Claude Code disconnected" }));
  }
  pendingToolCalls.clear();
};

// ---------------------------------------------------------------------------
// HTTP Server (for the Minecraft mod)
// ---------------------------------------------------------------------------

let requestCounter = 0;

Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // --- Health check ---
    if (req.method === "GET" && url.pathname === "/health") {
      return new Response(
        JSON.stringify({
          status: mcpConnected ? "ok" : "degraded",
          mcpConnected,
          computerId: COMPUTER_ID,
          isTurtle: IS_TURTLE,
        }),
        { headers: { "content-type": "application/json" } }
      );
    }

    // --- SSE event stream ---
    if (req.method === "GET" && url.pathname === "/events") {
      const requestId = url.searchParams.get("request_id");

      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          if (requestId) {
            sseConnections.set(requestId, { controller });
          } else {
            // Global SSE connection
            globalSSE = { controller };
          }

          // Send initial connected event
          const msg = `data: ${JSON.stringify({ type: "connected", computerId: COMPUTER_ID })}\n\n`;
          controller.enqueue(new TextEncoder().encode(msg));
        },
        cancel() {
          if (requestId) {
            sseConnections.delete(requestId);
            // Bug 8 fix: If the disconnected SSE was the active turn,
            // clean up so pending tool calls don't hang forever.
            if (activeTurnRequestId === requestId) {
              activeTurnRequestId = null;
              // Resolve any pending tool calls that were part of this turn
              for (const [callId, pending] of pendingToolCalls) {
                pending.resolve(JSON.stringify({ error: "Client disconnected" }));
              }
              pendingToolCalls.clear();
            }
          } else {
            globalSSE = null;
          }
        },
      });

      return new Response(stream, {
        headers: {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
          "access-control-allow-origin": "*",
        },
      });
    }

    // --- Receive message from mod ---
    if (req.method === "POST" && url.pathname === "/message") {
      const body = (await req.json()) as {
        messages?: Array<{ role: string; content: string }>;
        system?: string;
        userMessage?: string;
      };

      if (!mcpConnected) {
        return new Response(
          JSON.stringify({ error: "Claude Code is not connected. Please restart the session." }),
          { status: 503, headers: { "content-type": "application/json" } }
        );
      }

      // Bug 5 fix: If there's already an active turn, end it before starting a new one.
      // This prevents the old request's SSE connection from hanging forever.
      if (activeTurnRequestId) {
        sendSSE(
          { type: "error", message: "New message received, previous turn cancelled." },
          activeTurnRequestId
        );
      }

      const requestId = `req_${++requestCounter}`;
      activeTurnRequestId = requestId;

      // Build the channel notification content
      // Send just the latest user message — Claude Code maintains its own context
      const userMessage =
        body.userMessage ??
        (body.messages
          ? body.messages
              .filter((m) => m.role === "user")
              .pop()?.content
          : "");

      try {
        await mcp.notification({
          method: "notifications/claude/channel",
          params: {
            content: userMessage ?? "",
            meta: {
              computer_id: COMPUTER_ID,
              request_id: requestId,
            },
          },
        });
      } catch (err) {
        mcpConnected = false;
        activeTurnRequestId = null;
        return new Response(
          JSON.stringify({ error: "Failed to reach Claude Code: " + String(err) }),
          { status: 502, headers: { "content-type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({ requestId }),
        { headers: { "content-type": "application/json" } }
      );
    }

    // --- Receive tool result from mod ---
    if (req.method === "POST" && url.pathname === "/tool-result") {
      const body = (await req.json()) as {
        callId: string;
        result: string;
      };

      const pending = pendingToolCalls.get(body.callId);
      if (pending) {
        pending.resolve(body.result);
        pendingToolCalls.delete(body.callId);
        return new Response(JSON.stringify({ ok: true }), {
          headers: { "content-type": "application/json" },
        });
      }

      return new Response(
        JSON.stringify({ error: "Unknown callId" }),
        { status: 404, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
});

// Heartbeat: send keepalive events every 15s to prevent idle connection drops
setInterval(() => {
  const heartbeat = `data: ${JSON.stringify({ type: "heartbeat" })}\n\n`;
  const bytes = new TextEncoder().encode(heartbeat);

  for (const [reqId, conn] of sseConnections) {
    try {
      conn.controller.enqueue(bytes);
    } catch {
      sseConnections.delete(reqId);
    }
  }

  if (globalSSE) {
    try {
      globalSSE.controller.enqueue(bytes);
    } catch {
      globalSSE = null;
    }
  }
}, 15_000);

// Log to stderr (stdout is reserved for MCP stdio transport)
console.error(
  `[ClaudeCraft Channel] Listening on http://127.0.0.1:${PORT} for computer #${COMPUTER_ID}${IS_TURTLE ? " (turtle)" : ""}`
);
