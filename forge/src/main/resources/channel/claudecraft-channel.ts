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
 *
 * Tool registry:
 *   The Minecraft tools are NOT defined here. claude.lua's tools.getDefs() is the
 *   single source of truth; the mod writes those defs to tools.json in this
 *   computer's sandbox (--tools-file) and this server lists them alongside its
 *   native tools (reply, send_message). The file is re-read on every message, and
 *   Claude Code is told via tools/list_changed when it changes.
 */

import { readFileSync } from "node:fs";
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

/** Default time to wait for the mod to return a tool result (config: toolTimeoutSeconds). */
const DEFAULT_TOOL_TIMEOUT_MS = (() => {
  const secs = parseInt(getArg("tool-timeout", "60"), 10);
  return (Number.isFinite(secs) && secs > 0 ? secs : 60) * 1000;
})();

const HOME_DIR = process.env.USERPROFILE || process.env.HOME || ".";

// Registry file for inter-computer messaging (written by the Java mod).
// The mod passes --registry: each world has its own registry.
const REGISTRY_PATH =
  getArg("registry", "") || `${HOME_DIR}/.claudecraft/channel-registry.json`;

// Lua tool registry for this computer (written by the Java mod on startChannel).
// The mod always passes --tools-file; the fallback suits launch.ts sandboxes.
const TOOLS_FILE = getArg(
  "tools-file",
  `${HOME_DIR}/.claudecraft/computers/${COMPUTER_ID}/tools.json`
);

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

/** Set of request IDs that originated from incoming inter-computer messages. */
const incomingRequestIds = new Set<string>();

/** Whether the MCP connection to Claude Code is alive. */
let mcpConnected = true;

/**
 * System prompt (personality, systemPromptPrefix, claude.lua's prompt) last
 * delivered to Claude Code. Claude Code keeps its own context, so the prompt
 * is sent with the first player message and again only when it changes.
 */
let deliveredSystemPrompt: string | null = null;
const SYSTEM_PROMPT_TAG = "claudecraft_system_prompt";

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

  // Send to global SSE only for incoming message events.
  // Regular user-initiated turns are handled by per-request SSE connections.
  if (globalSSE && requestId && incomingRequestIds.has(requestId)) {
    try {
      globalSSE.controller.enqueue(bytes);
    } catch {
      globalSSE = null;
    }
  }
}

// ---------------------------------------------------------------------------
// Tool registry (Lua defs from tools.json + native channel tools)
// ---------------------------------------------------------------------------

interface ToolDef {
  name: string;
  description: string;
  inputSchema: { type: "object"; [key: string]: unknown };
}

/** Tools implemented by this server itself rather than by the Lua program. */
const NATIVE_TOOLS: ToolDef[] = [
  {
    name: "reply",
    description:
      "Send a text reply back to the player. Call this when you are done processing.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "The reply text to display on the terminal",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "send_message",
    description:
      "Send a message to another CC:Tweaked computer or turtle running Claude Code. " +
      "Use this to coordinate with other computers — for example, a commander computer " +
      "can direct turtle swarms, or computers can collaborate on tasks. " +
      "The target computer's Claude Code session will receive your message and can reply back.",
    inputSchema: {
      type: "object",
      properties: {
        computerId: {
          type: "number",
          description: "The CC:Tweaked computer ID of the target computer",
        },
        message: {
          type: "string",
          description: "The message text to send to the target computer",
        },
      },
      required: ["computerId", "message"],
    },
  },
];
const NATIVE_TOOL_NAMES = new Set(NATIVE_TOOLS.map((t) => t.name));

/** Tools defined by claude.lua's tools.getDefs(), executed by the Lua program. */
let luaTools: ToolDef[] = [];
/** Per-tool timeout overrides in ms (from claude.lua's tools.timeouts). */
let luaToolTimeouts: Record<string, number> = {};
/** Raw tools.json content last loaded, used to detect changes. */
let registryRaw: string | null = null;

/**
 * Convert one Lua/Anthropic-style def ({name, description, input_schema})
 * into an MCP tool, or null if it is malformed or shadows a native tool.
 */
function toMcpTool(def: unknown): ToolDef | null {
  if (!def || typeof def !== "object") return null;
  const d = def as Record<string, unknown>;
  if (typeof d.name !== "string" || !/^[a-zA-Z0-9_-]{1,64}$/.test(d.name)) return null;
  if (NATIVE_TOOL_NAMES.has(d.name)) return null;
  const schema =
    d.input_schema && typeof d.input_schema === "object"
      ? (d.input_schema as Record<string, unknown>)
      : {};
  return {
    name: d.name,
    description: typeof d.description === "string" ? d.description : "",
    // MCP requires an object schema; Lua defs always are, but be defensive.
    inputSchema: { ...schema, type: "object" },
  };
}

/**
 * (Re)load tools.json. Returns true if the tool list changed since the
 * previous successful load (never true for the very first load).
 *
 * File format (written by ChannelProcessManager):
 *   { "tools": [ {name, description, input_schema}, ... ],
 *     "timeouts": { "<tool name>": <seconds>, ... } }
 */
function loadToolRegistry(): boolean {
  let raw: string;
  try {
    raw = readFileSync(TOOLS_FILE, "utf8");
  } catch (err) {
    if (registryRaw === null) {
      console.error(
        `[ClaudeCraft Channel] No tool registry at ${TOOLS_FILE} (${String(err)}); ` +
          `only native tools are available.`
      );
      registryRaw = "";
    }
    return false;
  }
  if (raw === registryRaw) return false;

  let parsed: { tools?: unknown; timeouts?: unknown };
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    // Probably caught mid-write; keep the previous list and retry next time.
    console.error(`[ClaudeCraft Channel] Ignoring unreadable ${TOOLS_FILE}: ${String(err)}`);
    return false;
  }

  const tools = Array.isArray(parsed.tools)
    ? parsed.tools.map(toMcpTool).filter((t): t is ToolDef => t !== null)
    : [];
  const timeouts: Record<string, number> = {};
  if (parsed.timeouts && typeof parsed.timeouts === "object") {
    for (const [name, secs] of Object.entries(parsed.timeouts as Record<string, unknown>)) {
      if (typeof secs === "number" && secs > 0) timeouts[name] = secs * 1000;
    }
  }

  // A file that was missing at startup and appears later counts as a change.
  const isFirstLoad = registryRaw === null;
  registryRaw = raw;
  luaTools = tools;
  luaToolTimeouts = timeouts;
  console.error(
    `[ClaudeCraft Channel] Loaded ${tools.length} Lua tools from ${TOOLS_FILE}`
  );
  return !isFirstLoad;
}

/** Reload the registry and tell Claude Code if the tool list changed. */
async function refreshToolRegistry(): Promise<void> {
  if (loadToolRegistry() && mcpConnected) {
    try {
      await mcp.sendToolListChanged();
    } catch (err) {
      console.error(`[ClaudeCraft Channel] tools/list_changed failed: ${String(err)}`);
    }
  }
}

/**
 * How long to wait for the mod to run a tool. Per-tool overrides (for long
 * tools such as build_structure or turtle_goto) only ever extend the
 * configured default, never shorten it.
 */
function toolTimeoutMs(name: string): number {
  return Math.max(DEFAULT_TOOL_TIMEOUT_MS, luaToolTimeouts[name] ?? 0);
}

loadToolRegistry();

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
  `You can send messages to other computers/turtles using send_message(computerId, message).`,
  `Messages from other computers arrive as "[Message from Computer #X]:" prefixed text.`,
  `When you receive a message from another computer, process it and reply — your reply goes to both the player terminal and completes the turn.`,
  `You can coordinate with other computers to build swarms, delegate tasks, or collaborate.`,
  ``,
  `Player messages arrive as <channel> events. Reply using the "reply" tool with the text you want to display.`,
  `You may call multiple Minecraft tools before replying. When you are done, ALWAYS call the reply tool.`,
  ``,
  `A player message may begin with a <${SYSTEM_PROMPT_TAG}> block. That is the computer's system prompt`,
  `(persona, server rules, context). Follow it for the rest of the session until a newer one arrives.`,
  `It is only re-sent when it changes.`,
].join("\n");

const mcp = new Server(
  { name: "claudecraft", version: "0.1.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: { listChanged: true },
    },
    instructions: systemInstructions,
  }
);

// -- Tool listing --

mcp.setRequestHandler(ListToolsRequestSchema, async () => {
  loadToolRegistry();
  return {
    tools: [...luaTools, ...NATIVE_TOOLS].map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema,
    })),
  };
});

// -- Tool execution --

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: toolArgs } = req.params;

  // Handle send_message tool — deliver a message to another computer's channel server
  if (name === "send_message") {
    const { computerId, message } = toolArgs as {
      computerId: number;
      message: string;
    };

    try {
      const registryData = await Bun.file(REGISTRY_PATH).text();
      const registry: Record<string, number> = JSON.parse(registryData);
      const targetPort = registry[String(computerId)];

      if (targetPort === undefined) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                error: `Computer #${computerId} is not online or not running Claude Code in channel mode.`,
              }),
            },
          ],
        };
      }

      const resp = await fetch(
        `http://127.0.0.1:${targetPort}/incoming-message`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            fromComputerId: COMPUTER_ID,
            fromLabel: COMPUTER_LABEL,
            message,
          }),
        }
      );

      if (!resp.ok) {
        const errText = await resp.text();
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                error: `Failed to deliver message: HTTP ${resp.status} — ${errText}`,
              }),
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({
              success: true,
              delivered: true,
              targetComputerId: computerId,
            }),
          },
        ],
      };
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({
              error: `Could not send message: ${msg}`,
            }),
          },
        ],
      };
    }
  }

  // Handle reply tool
  if (name === "reply") {
    const text = (toolArgs as { text: string }).text;
    const reqId = activeTurnRequestId;
    if (reqId) {
      sendSSE({ type: "reply", text }, reqId);
      sendSSE({ type: "done" }, reqId);
      incomingRequestIds.delete(reqId);
      activeTurnRequestId = null;
    }
    return { content: [{ type: "text" as const, text: "Reply sent." }] };
  }

  // Handle Minecraft tools — forward to mod via SSE, await result
  if (!luaTools.some((t) => t.name === name)) {
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({ error: `Unknown tool: ${name}` }),
        },
      ],
      isError: true,
    };
  }

  const callId = `tc_${++toolCallCounter}`;
  const reqId = activeTurnRequestId;
  const timeoutMs = toolTimeoutMs(name);

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
  const result = await new Promise<string>((resolve) => {
    pendingToolCalls.set(callId, { resolve });

    // Config toolTimeoutSeconds, extended per tool by claude.lua's tools.timeouts
    setTimeout(() => {
      if (pendingToolCalls.has(callId)) {
        pendingToolCalls.delete(callId);
        resolve(
          JSON.stringify({
            error: `Tool execution timed out after ${Math.round(timeoutMs / 1000)}s`,
          })
        );
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
  // Disable idle timeout — SSE connections stay open while Claude thinks
  idleTimeout: 0,

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

      await refreshToolRegistry();

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

      // Prepend the system prompt on the first message and whenever it changes
      const system = typeof body.system === "string" ? body.system.trim() : "";
      const sendSystem = system.length > 0 && system !== deliveredSystemPrompt;
      const content = sendSystem
        ? `<${SYSTEM_PROMPT_TAG}>\n${system}\n</${SYSTEM_PROMPT_TAG}>\n\n${userMessage ?? ""}`
        : userMessage ?? "";

      try {
        await mcp.notification({
          method: "notifications/claude/channel",
          params: {
            content,
            meta: {
              computer_id: COMPUTER_ID,
              request_id: requestId,
              ...(sendSystem ? { system_prompt: "updated" } : {}),
            },
          },
        });
        if (sendSystem) deliveredSystemPrompt = system;
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

    // --- Incoming message from another computer ---
    if (req.method === "POST" && url.pathname === "/incoming-message") {
      const body = (await req.json()) as {
        fromComputerId: string;
        fromLabel: string;
        message: string;
      };

      await refreshToolRegistry();

      const requestId = `req_${++requestCounter}`;
      activeTurnRequestId = requestId;
      incomingRequestIds.add(requestId);

      const incomingText =
        `[Message from Computer #${body.fromComputerId} "${body.fromLabel}"]: ${body.message}`;

      await mcp.notification({
        method: "notifications/claude/channel",
        params: {
          content: incomingText,
          meta: {
            computer_id: COMPUTER_ID,
            request_id: requestId,
            from_computer_id: body.fromComputerId,
          },
        },
      });

      sendSSE(
        { type: "incoming_message", fromComputerId: body.fromComputerId, fromLabel: body.fromLabel },
        requestId
      );

      return new Response(
        JSON.stringify({ ok: true, requestId }),
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

// Heartbeat: send keepalive events every 5s to prevent idle connection drops.
// Kept short to survive any intermediary timeouts while Claude is thinking.
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
}, 5_000);

// Log to stderr (stdout is reserved for MCP stdio transport)
console.error(
  `[ClaudeCraft Channel] Listening on http://127.0.0.1:${PORT} for computer #${COMPUTER_ID}${IS_TURTLE ? " (turtle)" : ""}`
);
