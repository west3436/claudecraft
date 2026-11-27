-- claude.lua - Claude Code for CC: Tweaked
-- Requires the ClaudeCraft mod on the server.
-- The mod provides the built-in 'claude' API for streaming Claude responses.

----------------------------------------------------------------------
-- HISTORY
----------------------------------------------------------------------
local hist = {}
local H_DIR, H_FILE = "/.claude", "/.claude/history.json"
local MAX_MSG = 40

local function ensureDir()
    if not fs.exists(H_DIR) then fs.makeDir(H_DIR) end
end

function hist.save(m)
    ensureDir()
    local t = m
    if #m > MAX_MSG then t = {}; for i = #m - MAX_MSG + 1, #m do t[#t+1] = m[i] end end
    local f = fs.open(H_FILE, "w"); if f then f.write(textutils.serialiseJSON(t)); f.close() end
end

function hist.load()
    if not fs.exists(H_FILE) then return nil end
    local f = fs.open(H_FILE, "r"); if not f then return nil end
    local c = f.readAll(); f.close()
    local ok, d = pcall(textutils.unserialiseJSON, c)
    return (ok and type(d) == "table") and d or nil
end

function hist.clear()
    if fs.exists(H_FILE) then fs.delete(H_FILE) end
end

----------------------------------------------------------------------
-- TOKEN & COST TRACKING
----------------------------------------------------------------------
-- Per-model prices live in /rom/modules/main/claudecraft/pricing.lua.
local pricing = require("claudecraft.pricing")

-- totalIn is uncached input only; total prompt = totalIn + cacheWrite + cacheRead.
local stats = {totalIn=0, totalOut=0, cacheWrite=0, cacheRead=0, requests=0, cost=0, uncachedCost=0}

-- Record one API response's usage. Cost is priced per request (some models are
-- tiered by prompt length). Returns that request's cost.
function stats.record(inp, out, cw, cr)
    inp, out, cw, cr = inp or 0, out or 0, cw or 0, cr or 0
    stats.requests = stats.requests + 1
    stats.totalIn = stats.totalIn + inp
    stats.totalOut = stats.totalOut + out
    stats.cacheWrite = stats.cacheWrite + cw
    stats.cacheRead = stats.cacheRead + cr
    local cost, uncached = pricing.requestCost(claude.getModel(), inp, out, cw, cr)
    stats.cost = stats.cost + cost
    stats.uncachedCost = stats.uncachedCost + uncached
    return cost
end

-- One-line usage summary for a response, e.g. "(5242 in [4810 cached, 120 new] / 85 out)".
-- "cached" is cache_read_input_tokens; it should be > 0 from the second agent round on.
function stats.usageLine(inp, out, cw, cr)
    inp, out, cw, cr = inp or 0, out or 0, cw or 0, cr or 0
    local f = pricing.fmtTokens
    local parts = {}
    if cr > 0 then parts[#parts+1] = f(cr).." cached" end
    if cw > 0 then parts[#parts+1] = f(cw).." new" end
    local cache = #parts > 0 and (" ["..table.concat(parts, ", ").."]") or ""
    return string.format("(%s in%s / %s out)", f(inp + cw + cr), cache, f(out))
end

-- Lines for the /stats command.
function stats.report()
    local f = pricing.fmtTokens
    local model = claude.getModel()
    local r = pricing.lookup(model)
    local prompt = stats.totalIn + stats.cacheWrite + stats.cacheRead
    local hit = prompt > 0 and math.floor(stats.cacheRead * 100 / prompt + 0.5) or 0
    local L = {
        "  Model: "..model,
        string.format("  Requests:    %d", stats.requests),
        string.format("  Input:       %s (%s uncached)", f(prompt), f(stats.totalIn)),
        string.format("  Cache read:  %s (%d%% of input)", f(stats.cacheRead), hit),
        string.format("  Cache write: %s", f(stats.cacheWrite)),
        string.format("  Output:      %s", f(stats.totalOut)),
        string.format("  Est. cost:   $%.4f", stats.cost),
    }
    if stats.uncachedCost > stats.cost then
        L[#L+1] = string.format("  Cache saved: $%.4f", stats.uncachedCost - stats.cost)
    end
    local fr = pricing.fmtRate
    L[#L+1] = string.format("  $/MTok in %s out %s, cache w %s r %s",
        fr(r.input), fr(r.output), fr(r.write), fr(r.read))
    if not r.exact then L[#L+1] = "  (unknown model, priced as "..r.id..")" end
    return L
end

----------------------------------------------------------------------
-- ACHIEVEMENT / PROGRESS TRACKING
----------------------------------------------------------------------
local progress = {}
local PROGRESS_FILE = "/.claude/progress.json"

function progress.load()
    if not fs.exists(PROGRESS_FILE) then
        return {blocks_mined=0, blocks_placed=0, items_crafted=0, files_written=0, commands_run=0, moves=0, tools_used=0}
    end
    local f = fs.open(PROGRESS_FILE, "r"); if not f then return {blocks_mined=0, blocks_placed=0, items_crafted=0, files_written=0, commands_run=0, moves=0, tools_used=0} end
    local c = f.readAll(); f.close()
    local ok, d = pcall(textutils.unserialiseJSON, c)
    if ok and type(d) == "table" then return d end
    return {blocks_mined=0, blocks_placed=0, items_crafted=0, files_written=0, commands_run=0, moves=0, tools_used=0}
end

function progress.save(p)
    ensureDir()
    local f = fs.open(PROGRESS_FILE, "w"); if f then f.write(textutils.serialiseJSON(p)); f.close() end
end

function progress.track(toolName, result)
    local p = progress.load()
    p.tools_used = (p.tools_used or 0) + 1
    if toolName == "turtle_dig" and result and result.success then p.blocks_mined = (p.blocks_mined or 0) + 1
    elseif toolName == "turtle_place" and result and result.success then p.blocks_placed = (p.blocks_placed or 0) + 1
    elseif toolName == "build_structure" and result and result.placed then p.blocks_placed = (p.blocks_placed or 0) + result.placed
    elseif toolName == "write_file" and result and result.success then p.files_written = (p.files_written or 0) + 1
    elseif toolName == "run_command" then p.commands_run = (p.commands_run or 0) + 1
    elseif toolName == "turtle_move" and result and result.results then p.moves = (p.moves or 0) + (result.completed or 0)
    elseif toolName == "turtle_goto" and result and result.success then p.moves = (p.moves or 0) + (result.steps or 0)
    elseif toolName == "turtle_craft" and result and result.crafted then p.items_crafted = (p.items_crafted or 0) + result.crafted
    end
    progress.save(p)
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local ui = {}
local buf, scrOff, inpHist = {}, 0, {}
local sW, sH = term.getSize()
local BODY_H = sH - 3 -- header + separator + input

-- Monitor support
local monitor, monSide, monW, monH = nil, nil, 0, 0
local function findMonitor()
    monitor, monSide, monW, monH = nil, nil, 0, 0
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
        if peripheral.getType(side) == "monitor" then
            local m = peripheral.wrap(side); if m then
                m.setTextScale(0.5); local w,h = m.getSize()
                if w > monW then monitor,monSide,monW,monH = m,side,w,h end
            end
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name); if m then
                m.setTextScale(0.5); local w,h = m.getSize()
                if w > monW then monitor,monSide,monW,monH = m,name,w,h end
            end
        end
    end
end
findMonitor()

local isAdv = term.isColour and term.isColour() or false

local C = {
    hdr_bg = colors.blue, hdr_fg = colors.white,
    user = colors.white, ai = colors.lightGray,
    tool = colors.yellow, ok = colors.lime,
    err = colors.red, info = colors.cyan,
    sep = colors.gray, bg = colors.black,
}
if not isAdv then for k in pairs(C) do C[k] = k:find("bg") and colors.black or colors.white end end

local function wrap(text, w)
    local lines = {}
    for raw in (text.."\n"):gmatch("([^\n]*)\n") do
        if #raw == 0 then lines[#lines+1] = ""
        else
            while #raw > w do
                local b = w
                for i = w, math.max(1,w-15), -1 do if raw:sub(i,i)==" " then b=i; break end end
                lines[#lines+1] = raw:sub(1,b); raw = raw:sub(b+1)
            end
            lines[#lines+1] = raw
        end
    end
    return lines
end

function ui.add(text, color)
    for _, l in ipairs(wrap(text, sW)) do buf[#buf+1] = {text=l, color=color or C.ai} end
    scrOff = 0
end
function ui.blank() buf[#buf+1] = {text="", color=C.ai} end

function ui.drawHeader(text)
    term.setCursorPos(1,1); term.setBackgroundColour(C.hdr_bg); term.setTextColour(C.hdr_fg)
    term.clearLine()
    local x = math.max(1, math.floor((sW-#text)/2)+1)
    term.setCursorPos(x,1); term.write(text:sub(1,sW))
    term.setBackgroundColour(C.bg)
end

function ui.drawBody()
    -- Save cursor state so we don't disrupt read() during scrolling
    local oldX, oldY = term.getCursorPos()
    local oldColor = term.getTextColour()
    local oldBg = term.getBackgroundColour()

    term.setBackgroundColour(C.bg)
    local total = #buf
    local start = math.max(1, total - BODY_H - scrOff + 1)
    for row = 1, BODY_H do
        term.setCursorPos(1, 1+row); term.clearLine()
        local idx = start + row - 1
        if idx >= 1 and idx <= total then
            term.setTextColour(buf[idx].color)
            term.write(buf[idx].text:sub(1, sW))
        end
    end
    if scrOff > 0 then
        term.setCursorPos(sW-2, 2); term.setTextColour(C.info); term.write("[^]")
    end
    -- separator
    term.setCursorPos(1, sH-1); term.setTextColour(C.sep); term.setBackgroundColour(C.bg)
    term.clearLine(); term.write(string.rep("-", sW))

    -- Restore cursor state
    term.setCursorPos(oldX, oldY)
    term.setTextColour(oldColor)
    term.setBackgroundColour(oldBg)

    if monitor then ui.drawMonitor() end
end

function ui.drawMonitor()
    if not monitor or ui.monitorHold then return end
    local mW, mH = monitor.getSize()
    local mAdv = monitor.isColour and monitor.isColour() or false
    monitor.setBackgroundColour(C.bg); monitor.clear()
    monitor.setCursorPos(1,1); monitor.setBackgroundColour(C.hdr_bg); monitor.setTextColour(C.hdr_fg)
    monitor.clearLine()
    local t = "Claude Code"
    monitor.setCursorPos(math.max(1,math.floor((mW-#t)/2)+1),1); monitor.write(t:sub(1,mW))
    monitor.setBackgroundColour(C.bg)
    local ml = {}
    for _, e in ipairs(buf) do
        for _, l in ipairs(wrap(e.text, mW)) do ml[#ml+1] = {text=l, color=e.color} end
    end
    local mb = mH - 1
    local ms = math.max(1, #ml - mb + 1)
    for row = 1, mb do
        local idx = ms + row - 1
        if idx >= 1 and idx <= #ml then
            monitor.setCursorPos(1, 1+row)
            if mAdv then monitor.setTextColour(ml[idx].color) end
            monitor.write(ml[idx].text:sub(1, mW))
        end
    end
end

function ui.init(title)
    sW, sH = term.getSize(); BODY_H = sH - 3
    buf = {}; scrOff = 0
    term.setBackgroundColour(C.bg); term.clear()
    ui.drawHeader(title or "Claude Code"); ui.drawBody()
end

function ui.clear() buf={}; scrOff=0; term.setBackgroundColour(C.bg); term.clear(); ui.drawHeader("Claude Code"); ui.drawBody() end

function ui.readInput()
    term.setCursorPos(1,sH); term.setBackgroundColour(C.bg); term.setTextColour(C.user)
    term.clearLine(); term.write("> "); term.setCursorPos(3,sH); term.setCursorBlink(true)
    local inp = read(nil, inpHist)
    term.setCursorBlink(false)
    ui.monitorHold = nil -- resume mirroring chat after a build preview
    if inp and #inp > 0 then inpHist[#inpHist+1] = inp end
    return inp
end

function ui.scroll(dir)
    if dir > 0 then scrOff = math.min(scrOff+3, math.max(0, #buf-BODY_H))
    else scrOff = math.max(0, scrOff-3) end
    ui.drawBody()
end

----------------------------------------------------------------------
-- TOOLS (same as standalone, executed Lua-side)
----------------------------------------------------------------------
local memory = require("claudecraft.memory") -- per-computer memory: /.claude/memory.md
local atlas = require("claudecraft.atlas")   -- shared, world-saved base atlas
local tools = {}
local guard = require("claudecraft.guard") -- confirm mode + hard limits for destructive tools

-- Item logistics tools (find_item, move_items, sort_storage, fluid_tanks,
-- turtle_craft, turtle_equip): /rom/modules/main/claudecraft/logistics.lua
local okLogistics, logistics = pcall(require, "claudecraft.logistics")
local logisticsErr
if not okLogistics then logisticsErr, logistics = logistics, nil end

function tools.getDefs()
    local d = {
        {name="read_file", description="Read a file.", input_schema={type="object",properties={path={type="string"}},required={"path"}}},
        {name="write_file", description="Create/overwrite a file.", input_schema={type="object",properties={path={type="string"},content={type="string"}},required={"path","content"}}},
        {name="edit_file", description="Replace unique text in a file.", input_schema={type="object",properties={path={type="string"},old_text={type="string"},new_text={type="string"}},required={"path","old_text","new_text"}}},
        {name="list_files", description="List directory contents.", input_schema={type="object",properties={path={type="string"}},required={"path"}}},
        {name="find_files", description="Find files by wildcard.", input_schema={type="object",properties={pattern={type="string"}},required={"pattern"}}},
        {name="search_content", description="Grep for pattern in files.", input_schema={type="object",properties={path={type="string"},pattern={type="string"}},required={"path","pattern"}}},
        {name="run_command", description="Run a shell command.", input_schema={type="object",properties={command={type="string"}},required={"command"}}},
        {name="delete_path", description="Delete file/dir.", input_schema={type="object",properties={path={type="string"}},required={"path"}}},
        {name="move_path", description="Move/rename.", input_schema={type="object",properties={from={type="string"},to={type="string"}},required={"from","to"}}},
        {name="get_info", description="System info: ID, fuel, peripherals.", input_schema={type="object",properties={}}},
        {name="redstone", description="Redstone I/O.", input_schema={type="object",properties={action={type="string"},side={type="string"},value={type="number"}},required={"action","side"}}},
        {name="peripheral_call", description="Call peripheral method.", input_schema={type="object",properties={side={type="string"},method={type="string"},args={type="array",description="Arguments to pass"}},required={"side","method"}}},
        {name="get_recipes", description="Look up Minecraft recipes (crafting/smelting/smithing...) on the server. Needs an item or type filter. Exact output matches come first; results are capped. Shaped recipes have width, height and grid (row-major, 0 = empty, else 1-based index into ingredients). To craft on a turtle, use turtle_craft.", input_schema={type="object",properties={item={type="string",description="Output item (e.g. 'iron_pickaxe', 'minecraft:torch')"},type={type="string",description="Recipe type (e.g. 'crafting', 'smelting', 'smithing')"},limit={type="number",description="Max recipes (default 10, max 50)"}}}},
        {name="scan_inventory", description="Scan a container's inventory (chest, barrel, shulker box, etc.) via peripheral. Returns all items with slot, name, and count. Use with get_recipes to plan crafting sequences — find available materials across nearby chests, then craft intermediate and final items.", input_schema={type="object",properties={peripheral={type="string",description="Peripheral name or side (e.g. 'minecraft:chest_0', 'left')"},detailed={type="boolean",description="If true, fetch full item details per slot including displayName, nbt, tags (slower). Default: false"}},required={"peripheral"}}},
    }
    d[#d+1] = {name="scan_area", description="Scan surrounding area for blocks. Uses block scanner peripheral if available, otherwise turtle inspect on all 6 sides.", input_schema={type="object",properties={radius={type="number",description="Scan radius (default 1). Only used with block scanner peripheral."}}}}
    d[#d+1] = {name="automate_redstone", description="Gather redstone state and peripheral info from all sides to help design a redstone circuit. Describe desired behavior in natural language.", input_schema={type="object",properties={description={type="string",description="Natural language description of desired redstone behavior"}},required={"description"}}}
    if claude.isWebAccessEnabled() and http then
        d[#d+1] = {name="http_request", description="Make an HTTP request. Returns response body (max 64KB).", input_schema={type="object",properties={url={type="string",description="The URL to request"},method={type="string",description="HTTP method (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS). Default: GET"},body={type="string",description="Request body (for POST/PUT/PATCH)"},headers={type="object",description="Request headers as key-value pairs"}},required={"url"}}}
    end
    if turtle then
        d[#d+1] = {name="turtle_move", description="Move: forward/back/up/down/turnLeft/turnRight.", input_schema={type="object",properties={action={type="string"},count={type="number"}},required={"action"}}}
        d[#d+1] = {name="turtle_dig", description="Dig: dig/digUp/digDown.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_place", description="Place: place/placeUp/placeDown.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_inspect", description="Inspect: inspect/inspectUp/inspectDown/detect*.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_inventory", description="Inventory: select/getItemDetail/refuel/drop/suck/etc.", input_schema={type="object",properties={action={type="string"},slot={type="number"},count={type="number"}},required={"action"}}}
        local P = {x={type="number"},y={type="number"},z={type="number"}}
        local FACE = {type="string", enum={"forward","right","back","left"}, description="Turtle facing when placing (stairs ascend toward it). Roof stairs face up-slope automatically."}
        d[#d+1] = {name="build_structure",
            description="Build from shape primitives and/or single blocks. COORDINATES ARE RELATIVE to the turtle's position and facing when called: x=right, y=up, z=forward; (0,0,0) is the turtle's own cell, so y=0 is its level and y=-1 the block under it. This is NOT the world/GPS frame turtle_goto uses. " ..
                "Shapes apply in order (later ones overwrite earlier ones), then 'blocks'. Block 'air' carves cells out (doors, windows); it never digs. " ..
                "Builds bottom-up, placing each block from above. Never digs blocks it placed; returns to the start, or parks beside the build if it can't, and reports position, facing and home. " ..
                "Run dry_run=true first: bounding box, per-material need/have/short and a fuel estimate, without moving. A real run refuses if fuel is short and stops cleanly if it runs low. " ..
                "Existing blocks in target cells are kept and reported unless replace=true; blocks dug while moving are reported. Blocks are item ids (e.g. minecraft:stone_bricks). Doors, beds and other 2-block items can't be placed this way.",
            input_schema={type="object", properties={
                shapes={type="array", description="Shape primitives, applied in order", items={type="object", properties={
                    type={type="string", enum={"box","hollow_box","wall","line","floor","plane","cylinder","sphere","dome","roof"}, description="box, hollow_box, floor/plane, wall, line, roof use from+to (inclusive). cylinder, sphere, dome use center+radius. floor/plane is horizontal at from.y. wall runs from->to horizontally (diagonals ok), filled from.y..to.y. roof is a gable roof over the from..to footprint starting at from.y."},
                    block={type="string", description="Item id, or 'air' to carve"},
                    from={type="object", description="{x,y,z} corner or start", properties=P},
                    to={type="object", description="{x,y,z} opposite corner or end", properties=P},
                    center={type="object", description="{x,y,z}. For a cylinder, the middle of its bottom layer.", properties=P},
                    radius={type="number"},
                    height={type="number", description="cylinder: layers (default 1). wall: height from from.y instead of to.y."},
                    hollow={type="boolean", description="cylinder/sphere/dome: shell only (default false, dome true)"},
                    open={type="array", items={type="string", enum={"top","bottom","left","right","front","back"}}, description="hollow_box faces to leave out"},
                    axis={type="string", enum={"x","z"}, description="roof ridge direction (default: the longer side)"},
                    gable_block={type="string", description="roof: also fill the triangular gable ends with this block"},
                    facing=FACE,
                }, required={"type","block"}}},
                blocks={type="array", description="Single blocks {x,y,z,block}, applied after shapes", items={type="object", properties={x={type="number"},y={type="number"},z={type="number"},block={type="string"},facing=FACE}, required={"x","y","z","block"}}},
                dry_run={type="boolean", description="Plan only; the turtle does not move"},
                replace={type="boolean", description="Dig and replace existing blocks in target cells (default false)"},
                restock_chest={type="string", enum={"back","down","up","left","right","front"}, description="Inventory next to the start position. When a material runs out the turtle goes back, refills, returns unneeded items, and resumes. Keep only build materials in it."},
                preview={type="string", enum={"monitor","text","both"}, description="monitor: draw each layer on an attached monitor. text: ASCII layers in the result."},
                preview_monitor={type="string", description="Monitor peripheral name (default: one that isn't mirroring the chat)"},
            }}}
        d[#d+1] = {name="turtle_goto", description="Navigate to coordinates using GPS + pathfinding. Digs through obstacles. Requires GPS satellites.", input_schema={type="object",properties={x={type="number",description="Target X"},y={type="number",description="Target Y"},z={type="number",description="Target Z"}},required={"x","y","z"}}}
    end
    if logistics then for _, def in ipairs(logistics.getDefs()) do d[#d+1] = def end end
    for _, def in ipairs(memory.toolDefs()) do d[#d+1] = def end -- remember, forget
    for _, def in ipairs(atlas.toolDefs()) do d[#d+1] = def end  -- set/list/remove_waypoint, atlas_search
    return d
end

-- getDefs() is the single tool registry for both modes: channel mode gets it via
-- claude.startChannel. Channel-mode tool timeout overrides in seconds (they only
-- extend the toolTimeoutSeconds config). Add an entry for any long-running tool.
tools.timeouts = {
    build_structure = 600,
    turtle_goto = 300,
}

-- ctx: {reqId=request the caller is streaming, remote=true for another computer's message}
function tools.exec(name, input, ctx)
    local ok, r, blocked = pcall(guard.run, name, input, ctx, tools._exec)
    if not ok then return {error=tostring(r)} end
    if not blocked then progress.track(name, r) end
    if not blocked then atlas.observe(name, input, r) end -- index scan_inventory results in the base atlas
    return r
end

function tools._exec(name, input)
    if logistics and logistics.handlers[name] then return logistics.handlers[name](input) end
    local ext = memory.exec(name, input) or atlas.exec(name, input) -- module-provided tools
    if ext then return ext end
    if name == "read_file" then
        if not fs.exists(input.path) then return {error="Not found: "..input.path} end
        if fs.isDir(input.path) then return {error="Is a directory"} end
        local f = fs.open(input.path,"r"); local c = f.readAll(); f.close()
        local lines, n = {}, 1
        for line in (c.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = string.format("%3d| %s",n,line); n=n+1 end
        return {content=table.concat(lines,"\n"), size=#c, lines=n-1}
    elseif name == "write_file" then
        local dir = fs.getDir(input.path)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(input.path,"w"); f.write(input.content); f.close()
        return {success=true, path=input.path, bytes=#input.content}
    elseif name == "edit_file" then
        if not fs.exists(input.path) then return {error="Not found"} end
        local f = fs.open(input.path,"r"); local c = f.readAll(); f.close()
        local count, pos = 0, 1
        while true do local s = c:find(input.old_text, pos, true); if not s then break end; count=count+1; pos=s+1 end
        if count == 0 then return {error="old_text not found"} end
        if count > 1 then return {error="old_text found "..count.."x, must be unique"} end
        -- Bug 12 fix: Use plain string.find + string.sub instead of gsub to avoid
        -- pattern magic character issues with %, (, ), etc. in replacement text.
        local s, e = c:find(input.old_text, 1, true)
        local nc = c:sub(1, s-1) .. input.new_text .. c:sub(e+1)
        f = fs.open(input.path,"w"); f.write(nc); f.close()
        return {success=true, path=input.path}
    elseif name == "list_files" then
        if not fs.exists(input.path) then return {error="Not found"} end
        if not fs.isDir(input.path) then return {error="Not a directory"} end
        local items = fs.list(input.path); table.sort(items)
        local r = {}
        for _,item in ipairs(items) do
            local full = fs.combine(input.path, item); local d = fs.isDir(full)
            r[#r+1] = {name=d and (item.."/") or item, size=d and 0 or fs.getSize(full)}
        end
        return {files=r, count=#r}
    elseif name == "find_files" then
        local m = fs.find(input.pattern); table.sort(m)
        return {matches=m, count=#m}
    elseif name == "search_content" then
        if not fs.exists(input.path) then return {error="Not found"} end
        local results, MAX = {}, 50
        local function srch(fp)
            if #results >= MAX then return end
            if fs.isDir(fp) then
                for _,ch in ipairs(fs.list(fp)) do srch(fs.combine(fp,ch)); if #results>=MAX then return end end
            else
                local f = fs.open(fp,"r"); if not f then return end
                local ln = 0
                while true do local line = f.readLine(); if not line then break end; ln=ln+1
                    if line:find(input.pattern) then results[#results+1]=fp..":"..ln..": "..line; if #results>=MAX then f.close(); return end end
                end; f.close()
            end
        end
        srch(input.path)
        return {matches=results, count=#results, truncated=#results>=MAX}
    elseif name == "run_command" then
        -- Destructive commands are confirmed or refused by guard.run before we get here.
        local output, curY, curLine = {}, 1, ""
        local w = sW
        local fake = {}
        function fake.write(t) curLine=curLine..tostring(t) end
        function fake.setCursorPos(x,y)
            if curLine~="" then output[curY]=(output[curY] or "")..curLine; curLine="" end; curY=y
        end
        function fake.getCursorPos() return #curLine+1, curY end
        function fake.getSize() return w, 100 end
        function fake.scroll(n) if curLine~="" then output[curY]=(output[curY] or "")..curLine; curLine="" end; curY=curY-n end
        function fake.isColour() return true end; fake.isColor=fake.isColour
        function fake.setTextColour() end; fake.setTextColor=fake.setTextColour
        function fake.setBackgroundColour() end; fake.setBackgroundColor=fake.setBackgroundColour
        function fake.clear() end; function fake.clearLine() end; function fake.setCursorBlink() end
        function fake.blit(t) fake.write(t) end
        function fake.getTextColour() return colors.white end; fake.getTextColor=fake.getTextColour
        function fake.getBackgroundColour() return colors.black end; fake.getBackgroundColor=fake.getBackgroundColour
        function fake.getPaletteColour() return 0,0,0 end; fake.getPaletteColor=fake.getPaletteColour
        function fake.setPaletteColour() end; fake.setPaletteColor=fake.setPaletteColour
        local old = term.redirect(fake); local ok = shell.run(input.command); term.redirect(old)
        if curLine~="" then output[curY]=(output[curY] or "")..curLine end
        local lines, keys = {}, {}
        for k in pairs(output) do keys[#keys+1]=k end; table.sort(keys)
        for _,k in ipairs(keys) do if output[k]:match("%S") then lines[#lines+1]=output[k] end end
        return {success=ok, output=table.concat(lines,"\n"), lines=#lines}
    elseif name == "delete_path" then
        if not fs.exists(input.path) then return {error="Not found"} end
        if fs.isReadOnly(input.path) then return {error="Read-only"} end
        fs.delete(input.path); return {success=true}
    elseif name == "move_path" then
        if not fs.exists(input.from) then return {error="Not found"} end
        fs.move(input.from, input.to); return {success=true}
    elseif name == "get_info" then
        local info = {computerID=os.getComputerID(), label=os.getComputerLabel() or "unlabeled",
            isTurtle=turtle~=nil, time=textutils.formatTime(os.time()), day=os.day(),
            freeSpace=fs.getFreeSpace("/"), peripherals={}}
        if turtle then info.fuelLevel=turtle.getFuelLevel(); info.fuelLimit=turtle.getFuelLimit() end
        for _,n in ipairs(peripheral.getNames()) do
            info.peripherals[#info.peripherals+1] = {name=n, type=peripheral.getType(n)}
        end
        return info
    elseif name == "redstone" then
        local a,s = input.action, input.side
        if a=="getInput" then return {value=redstone.getInput(s)}
        elseif a=="getOutput" then return {value=redstone.getOutput(s)}
        elseif a=="setOutput" then redstone.setOutput(s, input.value~=0); return {success=true}
        elseif a=="getAnalogInput" then return {value=redstone.getAnalogInput(s)}
        elseif a=="setAnalogOutput" then redstone.setAnalogOutput(s, math.floor(input.value)); return {success=true}
        else return {error="Unknown: "..a} end
    elseif name == "peripheral_call" then
        if not peripheral.isPresent(input.side) then return {error="No peripheral: "..input.side} end
        local r = {peripheral.call(input.side, input.method, table.unpack(input.args or {}))}
        return {results=r}
    elseif name == "turtle_move" then
        if not turtle then return {error="Not a turtle"} end
        local fn = turtle[input.action]; if not fn then return {error="Unknown: "..input.action} end
        local r = {}
        for i=1,(input.count or 1) do local ok,err=fn(); r[#r+1]={step=i,success=ok,error=err}; if not ok then break end end
        return {results=r, completed=#r}
    elseif name=="turtle_dig" or name=="turtle_place" then
        if not turtle then return {error="Not a turtle"} end
        local fn=turtle[input.action]; if not fn then return {error="Unknown: "..input.action} end
        local ok,err=fn(); return {success=ok, error=err}
    elseif name == "turtle_inspect" then
        if not turtle then return {error="Not a turtle"} end
        local fn=turtle[input.action]; if not fn then return {error="Unknown: "..input.action} end
        local ok,data=fn(); return ok and {found=true,data=data} or {found=false}
    elseif name == "turtle_inventory" then
        if not turtle then return {error="Not a turtle"} end
        local a = input.action
        if a=="select" then return {success=turtle.select(input.slot or 1)}
        elseif a=="getItemDetail" then local d=turtle.getItemDetail(input.slot); return d or {empty=true}
        elseif a=="getItemCount" then return {count=turtle.getItemCount(input.slot)}
        elseif a=="transferTo" then return {success=turtle.transferTo(input.slot,input.count)}
        elseif a=="getFuelLevel" then return {level=turtle.getFuelLevel()}
        elseif a=="refuel" then local ok,err=turtle.refuel(input.count); return {success=ok,error=err,level=turtle.getFuelLevel()}
        else local fn=turtle[a]; if fn then local ok,err=fn(input.count); return {success=ok,error=err} end
            return {error="Unknown: "..a}
        end
    elseif name == "build_structure" then
        -- Shapes, dry run, safe routing and restock: rom/modules/main/claudecraft/build.lua
        if not turtle then return {error="Not a turtle"} end
        return require("claudecraft.build").handle(input, {
            log = function(s) ui.add("  "..s, C.info); ui.drawBody() end,
            chatMonitor = monSide,
            -- a preview drawn on the chat mirror monitor stays up until the next prompt
            onPreview = function(n) if n == monSide then ui.monitorHold = true end end,
        })
    elseif name == "turtle_goto" then
        if not turtle then return {error="Not a turtle"} end
        local tx, ty, tz = input.x, input.y, input.z
        if not (tx and ty and tz) then return {error="x, y, z coordinates required"} end
        tx, ty, tz = math.floor(tx), math.floor(ty), math.floor(tz)

        -- Get current position via GPS
        local cx, cy, cz = gps.locate(5)
        if not cx then return {error="GPS failed - need 4+ GPS hosts in the world"} end
        cx, cy, cz = math.floor(cx + 0.5), math.floor(cy + 0.5), math.floor(cz + 0.5)

        -- Check fuel
        local fuel = turtle.getFuelLevel()
        if fuel ~= "unlimited" then
            local dist = math.abs(tx - cx) + math.abs(ty - cy) + math.abs(tz - cz)
            if fuel < dist then
                return {error="Not enough fuel. Need ~"..dist..", have "..fuel}
            end
        end

        -- Facing: 0=south(+z), 1=west(-x), 2=north(-z), 3=east(+x)
        local facing = nil

        local function detectFacing()
            local sx, sz = cx, cz
            -- Try to move forward to detect facing
            local moved = turtle.forward()
            if not moved then turtle.dig(); moved = turtle.forward() end
            if not moved then return false end
            local nx, ny, nz = gps.locate(5)
            if not nx then turtle.back(); return false end
            nx, nz = math.floor(nx + 0.5), math.floor(nz + 0.5)
            local dx, dz = nx - sx, nz - sz
            if dz == 1 then facing = 0
            elseif dx == -1 then facing = 1
            elseif dz == -1 then facing = 2
            elseif dx == 1 then facing = 3
            else turtle.back(); return false end
            cx, cy, cz = nx, math.floor(ny + 0.5), nz
            return true
        end

        local function turnTo(dir)
            if facing == dir then return end
            local diff = (dir - facing) % 4
            if diff == 1 then turtle.turnRight()
            elseif diff == 2 then turtle.turnRight(); turtle.turnRight()
            elseif diff == 3 then turtle.turnLeft() end
            facing = dir
        end

        local function tryForward()
            if turtle.forward() then return true end
            turtle.dig(); if turtle.forward() then return true end
            -- Entity might be blocking, attack and retry
            turtle.attack(); return turtle.forward()
        end

        local function tryUp()
            if turtle.up() then return true end
            turtle.digUp(); if turtle.up() then return true end
            turtle.attackUp(); return turtle.up()
        end

        local function tryDown()
            if turtle.down() then return true end
            turtle.digDown(); if turtle.down() then return true end
            turtle.attackDown(); return turtle.down()
        end

        if not detectFacing() then
            return {error="Could not determine facing direction (blocked on all sides?)"}
        end

        -- Already there?
        if cx == tx and cy == ty and cz == tz then
            return {success=true, position={x=cx, y=cy, z=cz}, steps=0}
        end

        local steps = 0
        local maxSteps = math.abs(tx - cx) + math.abs(ty - cy) + math.abs(tz - cz) + 50
        local stuck = false

        -- Move Y first (safest, avoids terrain)
        while cy ~= ty and steps < maxSteps and not stuck do
            steps = steps + 1
            if ty > cy then
                if tryUp() then cy = cy + 1 else stuck = true end
            else
                if tryDown() then cy = cy - 1 else stuck = true end
            end
        end

        -- Move X
        while cx ~= tx and steps < maxSteps and not stuck do
            steps = steps + 1
            if tx > cx then turnTo(3) else turnTo(1) end
            if tryForward() then
                cx = cx + (tx > cx and 1 or -1)
            else stuck = true end
        end

        -- Move Z
        while cz ~= tz and steps < maxSteps and not stuck do
            steps = steps + 1
            if tz > cz then turnTo(0) else turnTo(2) end
            if tryForward() then
                cz = cz + (tz > cz and 1 or -1)
            else stuck = true end
        end

        local arrived = cx == tx and cy == ty and cz == tz
        local result = {
            success=arrived,
            position={x=cx, y=cy, z=cz},
            target={x=tx, y=ty, z=tz},
            steps=steps,
            fuelRemaining=turtle.getFuelLevel()
        }
        if stuck then result.stuck=true end
        if steps >= maxSteps then result.error="Exceeded max steps" end
        return result
    elseif name == "http_request" then
        if not claude.isWebAccessEnabled() then return {error="Web access is disabled in server config"} end
        if not http then return {error="HTTP API not available"} end
        local method = (input.method or "GET"):upper()
        local url = input.url
        if not url:match("^https?://") then return {error="URL must start with http:// or https://"} end
        local headers = input.headers or {}
        local response, err
        if method == "GET" then
            response, err = http.get(url, headers)
        elseif method == "POST" then
            response, err = http.post(url, input.body or "", headers)
        else
            response, err = http.request({url=url, method=method, body=input.body, headers=headers})
            if response == true then
                -- http.request returns true and fires http_success/http_failure events
                local timer = os.startTimer(30)
                while true do
                    -- Bug 11 fix: Capture all event args and re-queue unrelated events
                    -- so they aren't silently lost (e.g. peripheral, timer, redstone events).
                    local ev, p1, p2, p3 = os.pullEvent()
                    if ev == "http_success" and p1 == url then response = p2; break
                    elseif ev == "http_failure" and p1 == url then return {error="HTTP request failed: "..(p2 or "unknown error")}
                    elseif ev == "timer" and p1 == timer then return {error="HTTP request timed out"}
                    else os.queueEvent(ev, p1, p2, p3) end
                end
            end
        end
        if not response then return {error="HTTP request failed: "..(err or "unknown error")} end
        local code = response.getResponseCode()
        local respHeaders = response.getResponseHeaders()
        local body = response.readAll()
        response.close()
        if body and #body > 65536 then body = body:sub(1, 65536) .. "\n...(truncated at 64KB)" end
        return {status=code, headers=respHeaders, body=body}
    elseif name == "scan_inventory" then
        local pName = input.peripheral
        if not peripheral.isPresent(pName) then return {error="No peripheral: "..pName} end
        local inv = peripheral.wrap(pName)
        if not inv or not inv.list then return {error="Not an inventory peripheral: "..pName} end
        local items = inv.list()
        local size = inv.size and inv.size() or 0
        local result = {slots={}, size=size, peripheral=pName}
        for slot, item in pairs(items) do
            if input.detailed and inv.getItemDetail then
                local detail = inv.getItemDetail(slot)
                if detail then
                    result.slots[#result.slots+1] = {slot=slot, name=detail.name, count=detail.count, displayName=detail.displayName, nbt=detail.nbt, tags=detail.tags}
                else
                    result.slots[#result.slots+1] = {slot=slot, name=item.name, count=item.count}
                end
            else
                result.slots[#result.slots+1] = {slot=slot, name=item.name, count=item.count}
            end
        end
        table.sort(result.slots, function(a,b) return a.slot < b.slot end)
        result.itemCount = #result.slots
        return result
    elseif name == "get_recipes" then
        local limit = math.max(1, math.min(50, math.floor(tonumber(input.limit) or 10)))
        local json = claude.getRecipes(input.item, input.type, limit, 8)
        local ok2, data = pcall(textutils.unserialiseJSON, json)
        if ok2 and data then return data end
        return {error="Failed to parse recipe data"}
    elseif name == "scan_area" then
        local radius = input.radius or 1
        local result = {blocks={}}
        -- Try block scanner peripheral first
        local scanner = nil
        for _, pName in ipairs(peripheral.getNames()) do
            local pType = peripheral.getType(pName)
            if pType and (pType:find("scanner") or pType:find("plethora")) then
                scanner = peripheral.wrap(pName)
                break
            end
        end
        if scanner and scanner.scan then
            local ok2, data = pcall(scanner.scan, radius)
            if ok2 and data then
                for _, block in ipairs(data) do
                    result.blocks[#result.blocks+1] = {x=block.x, y=block.y, z=block.z, name=block.name or "unknown"}
                end
                result.method = "scanner"
                result.radius = radius
                result.count = #result.blocks
                return result
            end
        end
        -- Fall back to turtle inspect on all sides
        if turtle then
            local sides = {
                {action="inspect", dir="front"}, {action="inspectUp", dir="up"}, {action="inspectDown", dir="down"},
            }
            for _, s in ipairs(sides) do
                local ok2, data = turtle[s.action]()
                if ok2 then result.blocks[#result.blocks+1] = {direction=s.dir, name=data.name, state=data.state} end
            end
            -- Also inspect left, right, back by turning
            turtle.turnLeft()
            local ok2, data = turtle.inspect()
            if ok2 then result.blocks[#result.blocks+1] = {direction="left", name=data.name, state=data.state} end
            turtle.turnRight(); turtle.turnRight()
            ok2, data = turtle.inspect()
            if ok2 then result.blocks[#result.blocks+1] = {direction="right", name=data.name, state=data.state} end
            turtle.turnRight(); turtle.turnRight()
            ok2, data = turtle.inspect()
            if ok2 then result.blocks[#result.blocks+1] = {direction="back", name=data.name, state=data.state} end
            turtle.turnLeft() -- return to original facing
            result.method = "turtle_inspect"
        else
            -- Standard computer: check peripherals
            local sides = {"top","bottom","left","right","front","back"}
            for _, s in ipairs(sides) do
                if peripheral.isPresent(s) then
                    result.blocks[#result.blocks+1] = {direction=s, type=peripheral.getType(s)}
                end
            end
            result.method = "peripheral_scan"
        end
        result.count = #result.blocks
        return result
    elseif name == "automate_redstone" then
        local result = {description=input.description, sides={}, peripherals={}}
        local sides = {"top","bottom","left","right","front","back"}
        for _, s in ipairs(sides) do
            result.sides[s] = {
                input=redstone.getInput(s),
                output=redstone.getOutput(s),
                analogInput=redstone.getAnalogInput(s),
                analogOutput=redstone.getAnalogOutput(s),
            }
            if peripheral.isPresent(s) then
                result.peripherals[#result.peripherals+1] = {side=s, type=peripheral.getType(s)}
            end
        end
        result.time = os.time()
        result.day = os.day()
        result.hint = "Use the redstone tool with setOutput/setAnalogOutput to implement the circuit. For time-based automation, write a Lua program that runs in a loop."
        return result
    else
        return {error="Unknown tool: "..name}
    end
end

----------------------------------------------------------------------
-- MODE SELECTION & SETUP
----------------------------------------------------------------------

local MODE_FILE = "/.claude/mode"

local function readMode()
    if not fs.exists(MODE_FILE) then return nil end
    local f = fs.open(MODE_FILE, "r"); if not f then return nil end
    local m = f.readAll(); f.close()
    m = m and m:match("^%s*(%S+)") or nil
    if m == "apikey" or m == "channel" then return m end
    return nil
end

local function saveMode(m)
    ensureDir()
    local f = fs.open(MODE_FILE, "w"); if f then f.write(m); f.close() end
end

local function showSetupScreen()
    term.clear()
    term.setBackgroundColour(colors.black)

    -- Header
    term.setCursorPos(1,1)
    term.setBackgroundColour(colors.blue); term.setTextColour(colors.white)
    term.clearLine()
    local title = "Claude Code Setup"
    term.setCursorPos(math.max(1,math.floor((sW-#title)/2)+1),1)
    term.write(title)
    term.setBackgroundColour(colors.black)

    local y = 3
    local function ln(text, col)
        term.setCursorPos(1,y); term.setTextColour(col or colors.white)
        term.write(text); y = y + 1
    end

    ln("Choose how to connect to Claude:")
    y = y + 1
    term.setTextColour(colors.cyan)
    ln("  1. API Key", colors.cyan)
    ln("     Server operator provides an", colors.lightGray)
    ln("     Anthropic API key. Streaming.", colors.lightGray)
    y = y + 1
    ln("  2. Claude Code", colors.cyan)
    ln("     Uses Claude Code on the server.", colors.lightGray)
    ln("     No API key needed.", colors.lightGray)
    y = y + 1
    ln("Type 1 or 2:", colors.yellow)

    term.setCursorPos(14, y-1)
    term.setTextColour(colors.white)
    term.setCursorBlink(true)

    while true do
        local ev, key = os.pullEvent("key")
        if key == keys.one then
            term.setCursorBlink(false)
            return "apikey"
        elseif key == keys.two then
            term.setCursorBlink(false)
            return "channel"
        end
    end
end

----------------------------------------------------------------------
-- MAIN
----------------------------------------------------------------------

local backendMode = readMode()

-- First-time setup: show mode selection screen
if not backendMode then
    backendMode = showSetupScreen()
    saveMode(backendMode)
end

-- Channel mode: auto-start Claude Code session
if backendMode == "channel" then
    term.clear(); term.setCursorPos(1,1)
    term.setTextColour(colors.cyan)
    print("Starting Claude Code session...")
    print("This may take a moment...")

    local ok, portOrErr = claude.startChannel(
        turtle ~= nil,
        os.getComputerLabel() or "Computer",
        sW, sH,
        tools.getDefs(), tools.timeouts
    )

    if not ok then
        term.setTextColour(colors.red)
        print("")
        print("Failed to start channel:")
        print(tostring(portOrErr))
        print("")
        term.setTextColour(colors.yellow)
        print("Type 'claude' to try again, or")
        print("delete /.claude/mode to reconfigure.")
        return
    end

    -- Poll for channel server readiness (os.sleep yields properly in CC)
    term.setTextColour(colors.lightGray)
    print("Waiting for channel server...")
    local ready = false
    for i = 1, 60 do
        if claude.isChannelReady() then
            ready = true
            break
        end
        os.sleep(0.5)
    end

    if not ready then
        term.setTextColour(colors.red)
        print("Channel server did not start.")
        print("")
        term.setTextColour(colors.yellow)
        print("Type 'claude' to try again.")
        claude.stopChannel()
        return
    end

    term.setTextColour(colors.lime)
    print("Connected on port "..tostring(portOrErr))
    os.sleep(0.5)
end

-- API key mode: check configuration
if backendMode == "apikey" and not claude.isApiKeyConfigured() then
    term.clear(); term.setCursorPos(1,1)
    printError("API key not set.")
    printError("An operator must run:")
    printError("  /claudecraft setkey <key>")
    printError("")
    print("Or delete /.claude/mode to switch")
    print("to Claude Code channel mode.")
    return
end

local model = claude.getModel()

-- Personality support
local personality = claude.getPersonality()

-- System prompt
local sysPr = ""
if personality and #personality > 0 then
    sysPr = personality .. "\n\n"
end
sysPr = sysPr .. string.format(
    "You are Claude Code, an AI assistant inside a ComputerCraft computer in Minecraft. " ..
    "ID: %d. Label: %s. Terminal: %dx%d. %s" ..
    "You have tools for files, search, shell, %s%sredstone, peripherals, inventory scanning, area scanning, and Minecraft recipes.\n" ..
    "Be VERY concise (tiny terminal). Use tools proactively. Write idiomatic CC:Tweaked Lua.\n" ..
    "NEVER use emojis - the terminal cannot display them (they show as ?). " ..
    "NEVER use markdown formatting (no **, no ##, no ```) - this is a plain text terminal, not a markdown renderer. " ..
    "Use plain text only.",
    os.getComputerID(), os.getComputerLabel() or "unlabeled", sW, sH,
    turtle and string.format("TURTLE. Fuel: %s/%s. ", tostring(turtle.getFuelLevel()), tostring(turtle.getFuelLimit())) or "",
    (claude.isWebAccessEnabled() and http) and "HTTP requests, " or "",
    turtle and "turtle control, " or "")
local baseSysPr = sysPr -- memory.promptSection() is appended fresh each user turn

local toolDefs = tools.getDefs()

-- Channel mode: Claude Code gives up on a tool call after 60s, so answer well before that.
guard.init{ui=ui, colors=C, shell=shell, timeout=(backendMode == "channel") and 45 or 60,
    getMonitor=function() return monitor, monSide end}

-- Display helpers for tool calls/results
local function showToolCall(name, input)
    local s = "[tool] "..name
    if input then
        local d = input.path or input.pattern or input.command or input.action or input.query or input.item or ""
        if #d > 0 then s = s.." "..d end
    end
    ui.add(s, C.tool); ui.drawBody()
end

local function showToolResult(name, result)
    if result.error then ui.add("  x "..result.error, C.err)
    elseif result.output and #result.output > 0 then
        local lines = wrap(result.output, sW-4)
        for i,l in ipairs(lines) do
            if i > 10 then ui.add("  ...("..(#lines-10).." more lines)", C.ok); break end
            ui.add("  "..l, C.ok)
        end
    elseif result.success ~= nil then
        local m = "  ok"; if result.path then m=m.." "..result.path end; if result.bytes then m=m.." ("..result.bytes.."b)" end
        ui.add(m, C.ok)
    elseif result.content then
        local lines = wrap(result.content, sW-4)
        for i=1, math.min(#lines, 8) do ui.add("  "..lines[i], C.ok) end
        if #lines > 8 then ui.add("  ...("..(#lines-8).." more lines)", C.ok) end
    elseif result.files then
        for i,f in ipairs(result.files) do
            if i > 15 then ui.add("  ...("..(result.count-15).." more items)", C.ok); break end
            ui.add("  "..f.name, C.ok)
        end
    elseif result.matches then
        for i,m in ipairs(result.matches) do
            if i > 10 then ui.add("  ...("..(result.count-10).." more matches)", C.ok); break end
            ui.add("  "..tostring(m), C.ok)
        end
    else
        local t = textutils.serialiseJSON(result)
        ui.add("  "..(t and t:sub(1,200) or "ok"), C.ok)
    end
    ui.drawBody()
end

local function main()
    local title
    if backendMode == "channel" then
        title = "Claude Code // Channel"
    else
        title = "Claude Code // "..model
    end
    ui.init(title)
    ui.add("Claude Code for ComputerCraft", C.info)
    if backendMode == "channel" then
        ui.add("Connected via Claude Code Channel", C.sep)
    else
        ui.add("Streaming via ClaudeCraft API", C.sep)
    end
    if monitor then ui.add("Monitor: "..monSide.." ("..monW.."x"..monH..")", C.info) end
    ui.add("Type /help for commands.", C.sep)
    if logisticsErr then ui.add("Logistics tools not loaded: "..tostring(logisticsErr), C.err) end
    ui.blank(); ui.drawBody()

    local msgs = hist.load() or {}
    if #msgs > 0 then ui.add("("..#msgs.." msgs loaded)", C.sep); ui.drawBody() end

    -- Startup task / autonomous mode: auto-send /.claude/startup file contents
    local STARTUP_FILE = "/.claude/startup"
    if fs.exists(STARTUP_FILE) then
        local sf = fs.open(STARTUP_FILE, "r")
        if sf then
            local startupMsg = sf.readAll(); sf.close()
            if startupMsg and #startupMsg > 0 then
                startupMsg = startupMsg:match("^%s*(.-)%s*$") -- trim
                if #startupMsg > 0 then
                    ui.add("Auto-startup: "..startupMsg:sub(1, sW-15), C.info); ui.drawBody()
                    os.queueEvent("paste", startupMsg)
                end
            end
        end
    end

    while true do
        local inp = ui.readInput()
        if not inp or inp == "exit" or inp == "quit" then break end
        if #inp == 0 then goto continue end

        -- Inter-computer message allowlist (channel mode): /allow, /deny, /allowlist
        do
            local acmd, arest = inp:match("^/(%a+)%s*(.*)$")
            if acmd == "allow" or acmd == "deny" or acmd == "allowlist" then
                local ids, bad = {}, false
                for tok in arest:gmatch("%S+") do
                    local n = tonumber(tok)
                    if n and n >= 0 and n == math.floor(n) then ids[#ids+1] = n else bad = true end
                end
                if acmd ~= "allowlist" and (bad or #ids == 0) then
                    ui.add("Usage: /"..acmd.." <computer id> [more ids]", C.err)
                else
                    if acmd ~= "allowlist" then
                        local set = {}
                        for _, id in ipairs(claude.getMessageAllowlist()) do set[id] = true end
                        for _, id in ipairs(ids) do set[id] = (acmd == "allow") or nil end
                        local list = {}
                        for id in pairs(set) do list[#list+1] = id end
                        local ok, err = pcall(claude.setMessageAllowlist, list)
                        if not ok then ui.add("Error: "..tostring(err), C.err) end
                    end
                    local shown = {}
                    for i, id in ipairs(claude.getMessageAllowlist()) do shown[i] = "#"..id end
                    if #shown == 0 then ui.add("No computer may message this one.", C.info)
                    else ui.add("Accepting messages from: "..table.concat(shown, ", "), C.info) end
                    ui.add("/allow <id> or /deny <id> to change.", C.sep)
                end
                ui.blank(); ui.drawBody(); goto continue
            end
        end

        if inp == "/clear" then msgs={}; hist.clear(); ui.clear(); ui.add("Cleared.", C.info); ui.drawBody(); goto continue end
        if inp == "/mode" then
            fs.delete(MODE_FILE)
            ui.add("Mode reset. Run 'claude' again.", C.info); ui.drawBody()
            break
        end
        if inp == "/help" then
            ui.add("Commands:", C.info)
            ui.add("  /clear    - Reset conversation", C.ai)
            ui.add("  /mode     - Change connection mode", C.ai)
            ui.add("  /stats    - Token usage & cost", C.ai)
            ui.add("  /search X - Search chat history", C.ai)
            ui.add("  /progress - Achievement stats", C.ai)
            ui.add("  /memory   - Show memory (/memory clear)", C.ai)
            ui.add("  /confirm  - Ask before risky tools", C.ai)
            ui.add("  /help     - This help", C.ai)
            ui.add("  exit      - Quit", C.ai)
            ui.add("Scroll: mouse wheel / PgUp/PgDn", C.ai)
            ui.blank()
            ui.add("Setup & FAQ:", C.info)
            ui.add("github.com/west3436/claudecraft", C.sep)
            ui.add("  /docs/channel-mode.md", C.sep)
            ui.blank(); ui.drawBody(); goto continue
        end

        if inp == "/confirm" or inp:match("^/confirm%s") then
            guard.command(inp:sub(9)); ui.blank(); ui.drawBody(); goto continue
        end

        if inp == "/stats" then
            ui.add("Session Stats:", C.info)
            for _, line in ipairs(stats.report()) do ui.add(line, C.ai) end
            ui.blank(); ui.drawBody(); goto continue
        end

        if inp:match("^/search%s+") then
            local term = inp:match("^/search%s+(.+)$")
            if not term then ui.add("Usage: /search <term>", C.err); ui.drawBody(); goto continue end
            local found = 0
            for i, m in ipairs(msgs) do
                local content = type(m.content) == "string" and m.content or ""
                if content:lower():find(term:lower(), 1, true) then
                    found = found + 1
                    local prefix = m.role == "user" and "> " or "  "
                    local line = prefix .. content:sub(1, sW - 4)
                    ui.add(line, m.role == "user" and C.user or C.ai)
                    if found >= 10 then ui.add("  ...(more matches)", C.sep); break end
                end
            end
            if found == 0 then ui.add("No matches for: "..term, C.sep) end
            ui.blank(); ui.drawBody(); goto continue
        end

        if inp == "/progress" then
            local p = progress.load()
            ui.add("Progress:", C.info)
            ui.add(string.format("  Tools used:    %d", p.tools_used or 0), C.ai)
            ui.add(string.format("  Blocks mined:  %d", p.blocks_mined or 0), C.ai)
            ui.add(string.format("  Blocks placed: %d", p.blocks_placed or 0), C.ai)
            ui.add(string.format("  Files written: %d", p.files_written or 0), C.ai)
            ui.add(string.format("  Commands run:  %d", p.commands_run or 0), C.ai)
            ui.add(string.format("  Steps moved:   %d", p.moves or 0), C.ai)
            ui.blank(); ui.drawBody(); goto continue
        end

        if inp == "/memory" or inp:match("^/memory%s") then memory.command(inp, ui, C); goto continue end

        ui.add("> "..inp, C.user); ui.blank(); ui.drawBody()
        msgs[#msgs+1] = {role="user", content=inp}
        sysPr = baseSysPr .. memory.promptSection() -- reload /.claude/memory.md every turn

        if backendMode == "channel" then
            ----------------------------------------------------------------
            -- CHANNEL MODE: Claude Code manages the agentic loop.
            -- We send the message, then react to tool_exec and reply events.
            ----------------------------------------------------------------
            term.setCursorPos(1,sH); term.setTextColour(C.info); term.setBackgroundColour(C.bg)
            term.clearLine(); term.write("  Thinking...")

            local reqId = claude.sendMessage(msgs, nil, sysPr)
            local responseText = ""
            local done = false

            while not done do
                local ev, p1, p2, p3, p4 = os.pullEvent()

                if ev == "claude_tool_exec" and p1 == reqId then
                    -- Channel wants us to execute a Minecraft tool
                    -- p2=callId, p3=toolName, p4=inputJson
                    term.setCursorPos(1,sH); term.clearLine()
                    local input = {}
                    if p4 then
                        local ok2, parsed = pcall(textutils.unserialiseJSON, p4)
                        if ok2 and parsed then input = parsed end
                    end
                    showToolCall(p3, input)
                    local r = tools.exec(p3, input, {reqId=reqId})
                    showToolResult(p3, r)
                    claude.sendToolResult(reqId, p2, textutils.serialiseJSON(r))

                elseif ev == "claude_text" and p1 == reqId then
                    -- Full reply text from Claude Code
                    responseText = responseText .. p2
                    term.setCursorPos(1,sH); term.clearLine()

                elseif ev == "claude_done" and p1 == reqId then
                    done = true
                    term.setCursorPos(1,sH); term.clearLine()
                    if #responseText > 0 then
                        ui.add(responseText, C.ai); ui.blank()
                    end
                    -- p2=stopReason, p3=inputTokens, p4=outputTokens
                    stats.requests = stats.requests + 1
                    if p3 and p4 then
                        stats.totalIn = stats.totalIn + (p3 or 0)
                        stats.totalOut = stats.totalOut + (p4 or 0)
                    end
                    ui.drawBody()

                elseif ev == "claude_error" and p1 == reqId then
                    done = true
                    term.setCursorPos(1,sH); term.clearLine()
                    ui.add("Error: "..(p2 or "unknown"), C.err); ui.blank(); ui.drawBody()
                    table.remove(msgs) -- remove failed user message
                    break

                elseif ev == "key" and p1 == keys.q then
                    claude.cancelRequest(reqId)
                    done = true
                    term.setCursorPos(1,sH); term.clearLine()
                    ui.add("(cancelled)", C.sep); ui.drawBody()
                end
            end

            if #responseText > 0 then
                msgs[#msgs+1] = {role="assistant", content=responseText}
            end
        else
            ----------------------------------------------------------------
            -- API KEY MODE: Lua-side agentic loop with streaming.
            ----------------------------------------------------------------
            local round = 0
            while round < 15 do
                round = round + 1

                -- Show thinking
                term.setCursorPos(1,sH); term.setTextColour(C.info); term.setBackgroundColour(C.bg)
                term.clearLine(); term.write("  Streaming...")

                -- Send via peripheral (streaming)
                local reqId = claude.sendMessage(msgs, toolDefs, sysPr)

                local responseText = ""
                local toolCalls = {}
                local done = false

                -- Collect streaming events
                while not done do
                    local ev, p1, p2, p3, p4, p5, p6 = os.pullEvent()

                    if ev == "claude_delta" and p1 == reqId then
                        responseText = responseText .. p2
                        -- Live-render: clear thinking and show text accumulating
                        term.setCursorPos(1,sH); term.clearLine()

                    elseif ev == "claude_tool_start" and p1 == reqId then
                        -- p2=toolId, p3=toolName
                        -- Will be completed by claude_tool_done

                    elseif ev == "claude_tool_done" and p1 == reqId then
                        -- p2=toolId, p3=toolName, p4=inputJson
                        local input = {}
                        if p4 then
                            local ok2, parsed = pcall(textutils.unserialiseJSON, p4)
                            if ok2 and parsed then input = parsed end
                        end
                        toolCalls[#toolCalls+1] = {id=p2, name=p3, input=input}

                    elseif ev == "claude_done" and p1 == reqId then
                        done = true
                        term.setCursorPos(1,sH); term.clearLine()
                        -- p2=stopReason, p3=inputTokens (uncached), p4=outputTokens,
                        -- p5=cacheCreationTokens, p6=cacheReadTokens
                        if responseText and #responseText > 0 then
                            ui.add(responseText, C.ai); ui.blank()
                        end
                        stats.record(p3, p4, p5, p6)
                        if (p3 or 0) + (p4 or 0) + (p5 or 0) + (p6 or 0) > 0 then
                            ui.add(stats.usageLine(p3, p4, p5, p6), C.sep)
                        end
                        ui.drawBody()

                    elseif ev == "claude_error" and p1 == reqId then
                        done = true
                        term.setCursorPos(1,sH); term.clearLine()
                        ui.add("Error: "..(p2 or "unknown"), C.err); ui.blank(); ui.drawBody()
                        table.remove(msgs) -- remove failed user message
                        break

                    elseif ev == "key" and p1 == keys.q then
                        claude.cancelRequest(reqId)
                        done = true
                        term.setCursorPos(1,sH); term.clearLine()
                        ui.add("(cancelled)", C.sep); ui.drawBody()
                    end
                end

                if #toolCalls > 0 then
                    -- Build assistant message with content blocks
                    local blocks = {}
                    if #responseText > 0 then blocks[#blocks+1] = {type="text", text=responseText} end
                    for _, tc in ipairs(toolCalls) do
                        blocks[#blocks+1] = {type="tool_use", id=tc.id, name=tc.name, input=tc.input}
                    end
                    msgs[#msgs+1] = {role="assistant", content=blocks}

                    -- Execute tools locally
                    local results = {}
                    for _, tc in ipairs(toolCalls) do
                        showToolCall(tc.name, tc.input)
                        local r = tools.exec(tc.name, tc.input, {reqId=reqId})
                        showToolResult(tc.name, r)
                        results[#results+1] = {type="tool_result", tool_use_id=tc.id, content=textutils.serialiseJSON(r)}
                    end
                    msgs[#msgs+1] = {role="user", content=results}
                    -- Continue loop for Claude to process results
                else
                    if #responseText > 0 then
                        msgs[#msgs+1] = {role="assistant", content=responseText}
                    end
                    break
                end
            end
        end

        hist.save(msgs)
        ::continue::
    end

    -- Clean up channel session on exit
    if backendMode == "channel" then
        claude.stopChannel()
    end

    term.setBackgroundColour(colors.black); term.setTextColour(colors.white)
    term.clear(); term.setCursorPos(1,1); print("Session ended.")
end

-- Background handler for incoming inter-computer messages (channel mode only).
local function incomingMessageHandler()
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()

        if ev == "claude_tool_exec" and p1 == "incoming" then
            local input = {}
            if p4 then
                local ok2, parsed = pcall(textutils.unserialiseJSON, p4)
                if ok2 and parsed then input = parsed end
            end
            showToolCall(p3, input)
            -- No player asked for this: destructive tools always need a y/n here.
            local r = tools.exec(p3, input, {reqId=p1, remote=true})
            showToolResult(p3, r)
            claude.sendToolResult(p1, p2, textutils.serialiseJSON(r))

        elseif ev == "claude_text" and p1 == "incoming" then
            ui.add(p2, C.ai)
            ui.blank()
            ui.drawBody()

        elseif ev == "claude_done" and p1 == "incoming" then
            ui.drawBody()
            ui.drawInput()
        end
    end
end

parallel.waitForAny(main, function()
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "mouse_scroll" then ui.scroll(-p1)
        elseif ev == "key" then
            if p1 == keys.pageUp then ui.scroll(1)
            elseif p1 == keys.pageDown then ui.scroll(-1) end
        elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
            monitor,monSide,monW,monH = nil,nil,0,0
            findMonitor()
            if monitor then ui.drawMonitor() end
        end
    end
end, incomingMessageHandler)
