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
    if not monitor then return end
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
local tools = {}

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
        {name="get_recipes", description="Get Minecraft crafting/smelting/smithing recipes from the server. Returns all recipes, optionally filtered by output item name or recipe type.", input_schema={type="object",properties={item={type="string",description="Filter by output item (e.g. 'iron_pickaxe', 'diamond')"},type={type="string",description="Filter by recipe type (e.g. 'crafting', 'smelting', 'smithing')"}}}},
    }
    if claude.isWebAccessEnabled() and http then
        d[#d+1] = {name="http_request", description="Make an HTTP request. Returns response body (max 64KB).", input_schema={type="object",properties={url={type="string",description="The URL to request"},method={type="string",description="HTTP method (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS). Default: GET"},body={type="string",description="Request body (for POST/PUT/PATCH)"},headers={type="object",description="Request headers as key-value pairs"}},required={"url"}}}
    end
    if turtle then
        d[#d+1] = {name="turtle_move", description="Move: forward/back/up/down/turnLeft/turnRight.", input_schema={type="object",properties={action={type="string"},count={type="number"}},required={"action"}}}
        d[#d+1] = {name="turtle_dig", description="Dig: dig/digUp/digDown.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_place", description="Place: place/placeUp/placeDown.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_inspect", description="Inspect: inspect/inspectUp/inspectDown/detect*.", input_schema={type="object",properties={action={type="string"}},required={"action"}}}
        d[#d+1] = {name="turtle_inventory", description="Inventory: select/getItemDetail/refuel/drop/suck/etc.", input_schema={type="object",properties={action={type="string"},slot={type="number"},count={type="number"}},required={"action"}}}
        d[#d+1] = {name="build_structure", description="Execute a multi-block build from a blueprint. Provide blocks as relative coords from turtle's current position. Turtle navigates, selects matching inventory items, and places each block. Uses bottom-up layer-by-layer construction. Block names must match inventory item names (e.g. 'minecraft:oak_planks').", input_schema={type="object",properties={blocks={type="array",description="Block placements: {x,y,z,block} relative to turtle start pos",items={type="object",properties={x={type="number"},y={type="number"},z={type="number"},block={type="string"}},required={"x","y","z","block"}}}},required={"blocks"}}}
    end
    return d
end

function tools.exec(name, input)
    local ok, r = pcall(tools._exec, name, input)
    if not ok then return {error=tostring(r)} end
    return r
end

function tools._exec(name, input)
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
        -- Block commands that could wipe the filesystem
        local cmd = input.command:match("^%s*(%S+)")
        if cmd == "rm" or cmd == "delete" then
            local target = input.command:match("%s+(.+)$")
            if target and (target:match("^/+$") or target:match("^%*") or target:match("%-r")) then
                return {error="Blocked: destructive command. Use delete_path tool instead."}
            end
        end
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
        if not turtle then return {error="Not a turtle"} end
        local blocks = input.blocks
        if not blocks or #blocks == 0 then return {error="No blocks in blueprint"} end

        -- Position and facing state (relative to start)
        local px, py, pz = 0, 0, 0
        -- Facing: 0=+z(forward), 1=+x(right), 2=-z(back), 3=-x(left)
        local face = 0
        local dxMap = {[0]=0, [1]=1, [2]=0, [3]=-1}
        local dzMap = {[0]=1, [1]=0, [2]=-1, [3]=0}

        local function turnTo(dir)
            dir = dir % 4
            while face ~= dir do
                local diff = (dir - face) % 4
                if diff == 1 then
                    turtle.turnRight()
                    face = (face + 1) % 4
                else
                    turtle.turnLeft()
                    face = (face + 3) % 4
                end
            end
        end

        local function tryForward()
            if turtle.forward() then
                px = px + dxMap[face]
                pz = pz + dzMap[face]
                return true
            end
            return false
        end

        local function tryUp()
            if turtle.up() then py = py + 1; return true end
            return false
        end

        local function tryDown()
            if turtle.down() then py = py - 1; return true end
            return false
        end

        local function digForward()
            turtle.dig()
            return tryForward()
        end

        local function digUp()
            turtle.digUp()
            return tryUp()
        end

        local function digDown()
            turtle.digDown()
            return tryDown()
        end

        local function goTo(tx, ty, tz)
            -- Move Y first (up before horizontal to clear obstacles)
            while py < ty do if not tryUp() then if not digUp() then return false end end end
            while py > ty do if not tryDown() then if not digDown() then return false end end end
            -- Move X
            if px ~= tx then
                if px < tx then turnTo(1) else turnTo(3) end
                while px ~= tx do if not tryForward() then if not digForward() then return false end end end
            end
            -- Move Z
            if pz ~= tz then
                if pz < tz then turnTo(0) else turnTo(2) end
                while pz ~= tz do if not tryForward() then if not digForward() then return false end end end
            end
            return true
        end

        local function findSlot(blockName)
            for s = 1, 16 do
                local item = turtle.getItemDetail(s)
                if item and (item.name == blockName or item.name == "minecraft:"..blockName or "minecraft:"..item.name == blockName) then
                    if turtle.getItemCount(s) > 0 then return s end
                end
            end
            return nil
        end

        -- Sort blocks: bottom-up by Y, then serpentine X/Z for efficiency
        table.sort(blocks, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            -- Serpentine: alternate Z direction per X row
            if a.x ~= b.x then return a.x < b.x end
            if a.x % 2 == 0 then return a.z < b.z
            else return a.z > b.z end
        end)

        local placed = 0
        local failed = {}
        local missing = {}

        for i, block in ipairs(blocks) do
            local slot = findSlot(block.block)
            if not slot then
                missing[#missing+1] = {x=block.x, y=block.y, z=block.z, block=block.block}
            else
                turtle.select(slot)
                -- Navigate to one above target and place down
                if goTo(block.x, block.y + 1, block.z) then
                    -- Dig down if something is in the way
                    if turtle.detectDown() then turtle.digDown() end
                    if turtle.placeDown() then
                        placed = placed + 1
                    else
                        failed[#failed+1] = {x=block.x, y=block.y, z=block.z, reason="place failed"}
                    end
                else
                    failed[#failed+1] = {x=block.x, y=block.y, z=block.z, reason="nav failed"}
                end
            end
            -- Yield periodically to avoid "too long without yielding"
            if i % 10 == 0 then os.queueEvent("bp_yield"); os.pullEvent("bp_yield") end
        end

        -- Return to origin
        goTo(0, math.max(py, 1), 0)
        goTo(0, 0, 0)
        turnTo(0)

        return {
            total=#blocks, placed=placed,
            failed=#failed > 0 and failed or nil,
            missing=#missing > 0 and missing or nil
        }
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
    elseif name == "get_recipes" then
        local json = claude.getRecipes(input.item, input.type)
        local ok2, data = pcall(textutils.unserialiseJSON, json)
        if ok2 and data then return data end
        return {error="Failed to parse recipe data"}
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
        sW, sH
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

-- System prompt
local sysPr = string.format(
    "You are Claude Code, an AI assistant inside a ComputerCraft computer in Minecraft. " ..
    "ID: %d. Label: %s. Terminal: %dx%d. %s" ..
    "You have tools for files, search, shell, %s%sredstone, peripherals, and Minecraft recipes.\n" ..
    "Be VERY concise (tiny terminal). Use tools proactively. Write idiomatic CC:Tweaked Lua.\n" ..
    "NEVER use emojis - the terminal cannot display them (they show as ?). " ..
    "NEVER use markdown formatting (no **, no ##, no ```) - this is a plain text terminal, not a markdown renderer. " ..
    "Use plain text only.",
    os.getComputerID(), os.getComputerLabel() or "unlabeled", sW, sH,
    turtle and string.format("TURTLE. Fuel: %s/%s. ", tostring(turtle.getFuelLevel()), tostring(turtle.getFuelLimit())) or "",
    (claude.isWebAccessEnabled() and http) and "HTTP requests, " or "",
    turtle and "turtle control, " or "")

local toolDefs = tools.getDefs()

-- Display helpers for tool calls/results
local function showToolCall(name, input)
    local s = "[tool] "..name
    if input then
        local d = input.path or input.pattern or input.command or input.action or ""
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
    ui.blank(); ui.drawBody()

    local msgs = hist.load() or {}
    if #msgs > 0 then ui.add("("..#msgs.." msgs loaded)", C.sep); ui.drawBody() end

    while true do
        local inp = ui.readInput()
        if not inp or inp == "exit" or inp == "quit" then break end
        if #inp == 0 then goto continue end

        if inp == "/clear" then msgs={}; hist.clear(); ui.clear(); ui.add("Cleared.", C.info); ui.drawBody(); goto continue end
        if inp == "/mode" then
            fs.delete(MODE_FILE)
            ui.add("Mode reset. Run 'claude' again.", C.info); ui.drawBody()
            break
        end
        if inp == "/help" then
            ui.add("Commands:", C.info)
            ui.add("  /clear - Reset conversation", C.ai)
            ui.add("  /mode  - Change connection mode", C.ai)
            ui.add("  /help  - This help", C.ai)
            ui.add("  exit   - Quit", C.ai)
            ui.add("Scroll: mouse wheel / PgUp/PgDn", C.ai)
            ui.blank()
            ui.add("Setup & FAQ:", C.info)
            ui.add("github.com/west3436/claudecraft", C.sep)
            ui.add("  /docs/channel-mode.md", C.sep)
            ui.blank(); ui.drawBody(); goto continue
        end

        ui.add("> "..inp, C.user); ui.blank(); ui.drawBody()
        msgs[#msgs+1] = {role="user", content=inp}

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
                    local r = tools.exec(p3, input)
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
                    local ev, p1, p2, p3, p4 = os.pullEvent()

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
                        -- p2=stopReason, p3=inputTokens, p4=outputTokens
                        if responseText and #responseText > 0 then
                            ui.add(responseText, C.ai); ui.blank()
                        end
                        if p3 and p4 and (p3 > 0 or p4 > 0) then
                            ui.add(string.format("(%s in / %s out)", tostring(p3), tostring(p4)), C.sep)
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
                        local r = tools.exec(tc.name, tc.input)
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
end)
