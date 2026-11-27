-- claudecraft/memory.lua - per-computer persistent memory for claude.lua
--
-- Notes live in /.claude/memory.md on this computer, one per line:
--   - [3] The iron farm is at 120,64,-40
-- Lines in any other form (hand-written headings, prose) are kept as-is and
-- still shown to Claude. The file is put into the system prompt every user
-- turn, capped at MAX_BYTES with a note when truncated.

local M = {}

M.FILE = "/.claude/memory.md"
M.MAX_BYTES = 4096 -- prompt cap; remember refuses to grow the file past it
M.MAX_NOTE = 300   -- max characters per note

local function readAll()
    if not fs.exists(M.FILE) or fs.isDir(M.FILE) then return "" end
    local f = fs.open(M.FILE, "r"); if not f then return "" end
    local c = f.readAll() or ""; f.close()
    return (c:gsub("\r", ""))
end

local function writeAll(text)
    local dir = fs.getDir(M.FILE)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(M.FILE, "w"); if not f then return false end
    f.write(text); f.close()
    return true
end

local function splitLines(text)
    local out = {}
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out+1] = raw end
    while #out > 0 and not out[#out]:find("%S") do out[#out] = nil end
    return out
end

local function joinLines(ls)
    if #ls == 0 then return "" end
    return table.concat(ls, "\n") .. "\n"
end

local function noteId(line)
    local id = line:match("^%s*[-*]%s*%[(%d+)%]")
    return id and tonumber(id) or nil
end

local function noteText(line)
    return line:match("^%s*[-*]%s*%[%d+%]%s*(.*)$")
end

function M.read() return readAll() end

--- System-prompt section, rebuilt from the file each user turn.
function M.promptSection()
    local text = readAll()
    local s = "\n\nPERSISTENT MEMORY (this computer only; survives restarts and /clear): " ..
        "use remember to save durable facts worth knowing next session (locations, the user's preferences, " ..
        "ongoing projects) and forget to drop notes that are wrong or stale. One short fact per note. "
    if not text:find("%S") then return s .. "Memory is currently empty." end
    local body, note = text, ""
    if #body > M.MAX_BYTES then
        body = body:sub(1, M.MAX_BYTES)
        local cut = body:match("^.*()\n")
        if cut and cut > M.MAX_BYTES / 2 then body = body:sub(1, cut - 1) end
        note = string.format("\n[memory truncated: showing %d of %d bytes. Use forget to prune old notes.]", #body, #text)
    end
    body = body:gsub("%s+$", "")
    return s .. "Notes:\n" .. body .. note
end

function M.remember(note)
    if type(note) ~= "string" then return {error="note (string) required"} end
    note = note:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #note == 0 then return {error="note is empty"} end
    if #note > M.MAX_NOTE then
        return {error=string.format("note too long (%d chars, max %d); shorten it", #note, M.MAX_NOTE)}
    end
    local text = readAll()
    local ls = splitLines(text)
    local maxId, lower = 0, note:lower()
    for _, l in ipairs(ls) do
        local id = noteId(l)
        if id then
            if id > maxId then maxId = id end
            local t = noteText(l)
            if t and t:lower() == lower then
                return {success=true, id=id, duplicate=true, message="already remembered"}
            end
        end
    end
    local id = maxId + 1
    ls[#ls+1] = string.format("- [%d] %s", id, note)
    local out = joinLines(ls)
    if #out > M.MAX_BYTES then
        return {error=string.format("memory full (%d/%d bytes): forget stale notes first, then retry", #text, M.MAX_BYTES)}
    end
    if not writeAll(out) then return {error="could not write "..M.FILE} end
    return {success=true, id=id, path=M.FILE, bytes=#out}
end

function M.forget(input)
    input = input or {}
    local id = tonumber(input.id)
    local match = type(input.match) == "string" and input.match:match("^%s*(.-)%s*$") or nil
    if not id then
        if not match or #match == 0 then return {error="give id (number) or match (text)"} end
        if #match < 3 then return {error="match must be at least 3 characters"} end
    end
    local ml = match and match:lower()
    local keep, removed = {}, {}
    for _, l in ipairs(splitLines(readAll())) do
        local hit
        if id then hit = noteId(l) == id
        else hit = l:find("%S") ~= nil and l:lower():find(ml, 1, true) ~= nil end
        if hit then removed[#removed+1] = l else keep[#keep+1] = l end
    end
    if #removed == 0 then
        return {error = id and ("no note with id "..id) or ("no notes match '"..match.."'")}
    end
    if not writeAll(joinLines(keep)) then return {error="could not write "..M.FILE} end
    return {success=true, removed=removed, remaining=#keep}
end

function M.toolDefs()
    return {
        {name="remember", description="Save a short note to this computer's persistent memory (/.claude/memory.md). Notes are shown to you at the start of every future turn and survive restarts and /clear. Use for durable facts: locations, the user's preferences, project state. One fact per note.", input_schema={type="object",properties={note={type="string",description="The fact to remember (one line, max 300 chars)"}},required={"note"}}},
        {name="forget", description="Remove notes from persistent memory, by id (the [n] before each note) or by matching text. Use when a note is wrong or stale.", input_schema={type="object",properties={id={type="number",description="Id of the note to remove"},match={type="string",description="Remove every note containing this text (case-insensitive, min 3 chars)"}}}},
    }
end

--- Runs a memory tool. Returns nil if the tool is not a memory tool.
function M.exec(name, input)
    if name == "remember" then return M.remember((input or {}).note)
    elseif name == "forget" then return M.forget(input) end
    return nil
end

--- /memory and /memory clear
function M.command(inp, ui, C)
    local arg = inp:match("^/memory%s+(%S+)")
    if arg == "clear" then
        if fs.exists(M.FILE) then fs.delete(M.FILE) end
        ui.add("Memory cleared.", C.info)
    elseif arg == nil then
        local text = readAll()
        if not text:find("%S") then
            ui.add("Memory is empty.", C.sep)
        else
            ui.add(string.format("Memory (%d/%d bytes):", #text, M.MAX_BYTES), C.info)
            for _, l in ipairs(splitLines(text)) do ui.add("  "..l, C.ai) end
            if #text > M.MAX_BYTES then ui.add("  Over the cap: Claude sees a truncated copy.", C.err) end
        end
        ui.add("Hand-edit: edit "..M.FILE, C.sep)
    else
        ui.add("Usage: /memory [clear]", C.err)
    end
    ui.blank(); ui.drawBody()
end

return M
