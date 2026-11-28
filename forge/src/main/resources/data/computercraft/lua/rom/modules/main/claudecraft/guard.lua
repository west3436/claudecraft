-- claudecraft.guard - confirm mode and hard limits for Claude's destructive tools.
--
-- rom/programs/claude.lua sends every tool call through guard.run(). The guard can:
--   * refuse outright: deleting /, /rom or a whole drive; run_command starting claude;
--     op-level commands on command computers (unless the player opted in)
--   * ask the player y/n first (confirm mode), on the terminal or by tapping the monitor
--   * otherwise run the tool unchanged
-- A refusal or a "no" goes back to Claude as a tool error, so it can adapt.
--
-- Note: require() loads this file into claude.lua's own environment, so keep everything local.

local M = {}

local SETTINGS_FILE = "/.claude/guard.json"
local RISKY_METHODS = { shutdown = true, reboot = true, runCommand = true, setCommand = true }
local DETAIL_MAX = 200
local DEBOUNCE_MS = 500

local ui, C, getMonitor, sh
local timeoutSecs = 60
local selfPath = "rom/programs/claude.lua"
local realCommands, isCommandComputer = nil, false
local settings = { confirm = true, commands = false }
local busy = false       -- a prompt is on screen; others wait so one keypress can't answer two
local hideDepth = 0      -- nested run_command calls that have the commands API hidden

local REFUSE_ROOT = "Refused: deleting /, /rom or a whole drive is never allowed. Delete specific files or folders instead."
local REFUSE_CLAUDE = "Refused: run_command cannot start the claude program. A second copy would break this session. Ask the player to run it themselves."
local REFUSE_OP = "Refused: op-level commands are blocked for Claude on this computer. Only the player can allow them, with /confirm commands allow."

----------------------------------------------------------------------
-- Settings (/.claude/guard.json). Missing or unreadable file = safe defaults.
----------------------------------------------------------------------
local function loadSettings()
    settings = { confirm = true, commands = false }
    if not fs.exists(SETTINGS_FILE) then return end
    local f = fs.open(SETTINGS_FILE, "r"); if not f then return end
    local ok, d = pcall(textutils.unserialiseJSON, f.readAll()); f.close()
    if ok and type(d) == "table" then
        settings.confirm = d.confirm ~= false
        settings.commands = d.commands == true
    end
end

local function saveSettings()
    if not fs.exists("/.claude") then fs.makeDir("/.claude") end
    local f = fs.open(SETTINGS_FILE, "w")
    if f then f.write(textutils.serialiseJSON(settings)); f.close() end
end

----------------------------------------------------------------------
-- Paths and command lines
----------------------------------------------------------------------
local function canon(p)
    if type(p) ~= "string" then return nil end
    local ok, c = pcall(fs.combine, "", p)
    return ok and c or nil
end

-- "", "rom", "disk", ... : the root of a mount.
local function isDriveRoot(c)
    if c == "" then return true end
    local ok, r = pcall(fs.isDriveRoot, c)
    return ok and r == true
end

-- Paths whose edits change what runs later: boot scripts, the guard's own settings,
-- and files that would shadow the claude program on the shell path.
local function protectedReason(p)
    local c = canon(p); if not c then return nil end
    local lc = c:lower()
    if lc == ".claude" or lc:sub(1, 8) == ".claude/" then return "ClaudeCraft settings" end
    local name = fs.getName(lc)
    if name == "claude" or name == "claude.lua" then return "replaces the claude program" end
    local a = c
    for _ = 1, 64 do
        if a == "" or a:sub(1, 2) == ".." then break end
        local n = fs.getName(a):lower()
        if (n == "startup" or n == "startup.lua") and isDriveRoot(fs.getDir(a)) then
            return "startup file, runs on boot"
        end
        a = fs.getDir(a)
    end
    return nil
end

-- Same word splitting as the CraftOS shell.
local function tokenise(line)
    local words, quoted = {}, false
    for match in (line .. "\""):gmatch("(.-)\"") do
        if quoted then words[#words + 1] = match
        else for m in match:gmatch("[^ \t]+") do words[#words + 1] = m end end
        quoted = not quoted
    end
    return words
end

local function resolveProgram(tok)
    if not (sh and tok) then return nil end
    local ok, p = pcall(sh.resolveProgram, tok)
    return ok and p or nil
end

local function shebang(path)
    local f = fs.open(path, "r"); if not f then return nil end
    local line = f.readLine() or ""; f.close()
    if line:sub(1, 2) == "#!" then return tokenise(line:sub(3)) end
    return nil
end

-- Every program a command line would start, following aliases, shell/bg/fg/monitor
-- wrappers and #! lines, plus the arguments given to the last one.
local function launchChain(line)
    local toks, i, chain = tokenise(line), 1, {}
    for _ = 1, 8 do
        local p = resolveProgram(toks[i])
        if not p then break end
        chain[#chain + 1] = p
        local base = p:find("^rom/programs/") and fs.getName(p)
        if base == "shell.lua" or base == "bg.lua" or base == "fg.lua" then
            i = i + 1
        elseif base == "monitor.lua" then
            i = i + (toks[i + 1] == "scale" and 4 or 2)
        else
            local bang = shebang(p)
            if not bang then break end
            bang[#bang + 1] = "/" .. p
            for k = i + 1, #toks do bang[#bang + 1] = toks[k] end
            toks, i = bang, 1
        end
    end
    local args = {}
    for k = i + 1, #toks do args[#args + 1] = toks[k] end
    return chain, args
end

-- An rm target that deletes a drive root, or everything directly inside one ("/*", "disk/*",
-- "*/*" from the root).
local function wipesDrive(c)
    if isDriveRoot(c) then return true end
    if not fs.getName(c):match("^[%*%?]+$") then return false end
    local parent = fs.getDir(c)
    if not parent:find("[%*%?]") then return isDriveRoot(parent) end
    local ok, matches = pcall(fs.find, parent)
    if ok and type(matches) == "table" then
        for _, m in ipairs(matches) do if isDriveRoot(m) then return true end end
    end
    return false
end

local function isClaude(p)
    local n = fs.getName(p):lower()
    return p == selfPath or n == "claude" or n == "claude.lua"
end

local function isCommandPeripheral(side)
    if type(side) ~= "string" then return false end
    local ok, r = pcall(peripheral.hasType, side, "command")
    return ok and r == true
end

----------------------------------------------------------------------
-- Policy
----------------------------------------------------------------------
-- Hard limits: apply whatever the confirm setting is, and are never prompted.
local function refusal(name, input)
    if name == "delete_path" then
        local c = canon(input.path)
        if c and isDriveRoot(c) then return REFUSE_ROOT end
    elseif name == "run_command" and type(input.command) == "string" then
        local chain, args = launchChain(input.command)
        for _, p in ipairs(chain) do
            if isClaude(p) then return REFUSE_CLAUDE end
            if isCommandComputer and not settings.commands and p:find("^rom/programs/command/") then
                return REFUSE_OP
            end
        end
        if chain[#chain] == "rom/programs/delete.lua" then
            for _, a in ipairs(args) do
                local ok, c = pcall(sh.resolve, a)
                if ok and type(c) == "string" and wipesDrive(c) then return REFUSE_ROOT end
            end
        end
    elseif name == "peripheral_call" and not settings.commands and isCommandPeripheral(input.side) then
        return REFUSE_OP
    end
    return nil
end

-- Why a call needs a y/n, or nil. forced = ask even when confirm mode is off.
local function confirmReason(name, input)
    if name == "delete_path" then
        return "deletes files"
    elseif name == "run_command" then
        if isCommandComputer and settings.commands then return "shell; op commands allowed", true end
        return "runs a shell command"
    elseif name == "write_file" or name == "edit_file" then
        return protectedReason(input.path)
    elseif name == "move_path" then
        local ok, exists = pcall(fs.exists, canon(input.to))
        if ok and exists then return "replaces an existing file" end
        return protectedReason(input.from) or protectedReason(input.to)
    elseif name == "peripheral_call" then
        if isCommandPeripheral(input.side) then return "command block", true end
        if RISKY_METHODS[input.method] then return "risky peripheral method" end
    end
    return nil
end

local function clip(v)
    v = tostring(v)
    if #v > DETAIL_MAX then v = v:sub(1, DETAIL_MAX) .. "..." end
    return v
end

local function describe(name, input)
    if name == "run_command" then return clip(input.command)
    elseif name == "delete_path" then
        local ok, dir = pcall(fs.isDir, tostring(input.path))
        return clip(input.path) .. ((ok and dir) and " (folder)" or "")
    elseif name == "write_file" then
        local n = type(input.content) == "string" and #input.content or 0
        local ok, ex = pcall(fs.exists, tostring(input.path))
        return clip(input.path) .. " (" .. n .. "b" .. ((ok and ex) and ", overwrite" or "") .. ")"
    elseif name == "move_path" then return clip(input.from) .. " -> " .. clip(input.to)
    elseif name == "peripheral_call" then
        local a = ""
        if type(input.args) == "table" then
            local ok, j = pcall(textutils.serialiseJSON, input.args)
            if ok and j then a = j:sub(2, -2) end
        end
        return clip(tostring(input.side) .. "." .. tostring(input.method) .. "(" .. a .. ")")
    end
    return clip(input.path or name)
end

----------------------------------------------------------------------
-- The y/n prompt
----------------------------------------------------------------------
local function requeue(list)
    for _, e in ipairs(list) do os.queueEvent(table.unpack(e, 1, e.n)) end
end

local function pad(label, width)
    if width <= 0 then return "" end
    label = label:sub(1, width)
    local left = math.floor((width - #label) / 2)
    return (" "):rep(left) .. label .. (" "):rep(width - #label - left)
end

-- Monitor bottom row: [ YES ] [ NO ] touch targets on advanced monitors.
local function drawBar(mon)
    local w, h = mon.getSize()
    local half = math.floor((w - 1) / 2)
    mon.setCursorPos(1, h)
    if mon.isColour and mon.isColour() then
        mon.setTextColour(colors.white)
        mon.setBackgroundColour(colors.green); mon.write(pad("YES", half))
        mon.setBackgroundColour(C.bg); mon.write(" ")
        mon.setBackgroundColour(colors.red); mon.write(pad("NO", w - half - 1))
    else
        mon.setBackgroundColour(C.bg); mon.setTextColour(colors.white)
        mon.write(pad("Answer y/n at computer", w))
    end
    mon.setBackgroundColour(C.bg)
end

local function touchAnswer(mon, x, y)
    local w, h = mon.getSize()
    if y ~= h then return nil end
    local half = math.floor((w - 1) / 2)
    if x <= half then return "yes" elseif x >= half + 2 then return "no" end
    return nil
end

-- Draws the question, waits for an answer, cleans up. Returns "yes", "no" or "timeout";
-- any error inside counts as "no". view: {title, detail, reason, timeoutText?}.
local function promptLoop(view, ctx, hold, deadline)
    local blink = term.getCursorBlink and term.getCursorBlink() or false
    local cx, cy = term.getCursorPos()
    local fg, bg = term.getTextColour(), term.getBackgroundColour()
    local origDraw = ui.drawMonitor
    local timer

    local function loop()
        ui.add((ctx.remote and "! Remote asks: " or "! Confirm: ") .. view.title, C.err)
        ui.add("  " .. view.detail, C.tool)
        ui.add("  (" .. view.reason .. ")", C.sep)
        ui.add("  Allow? y / n", C.info)
        -- Keep the YES/NO bar on the monitor even when something else redraws it.
        ui.drawMonitor = function(...)
            origDraw(...)
            local mon = getMonitor()
            if mon then drawBar(mon) end
        end
        term.setCursorBlink(false)
        ui.drawBody()

        local shown = os.epoch("utc")
        timer = os.startTimer(1)
        while true do
            local left = math.ceil((deadline - os.epoch("utc")) / 1000)
            if left <= 0 then return "timeout" end
            local w, h = term.getSize()
            term.setCursorPos(1, h); term.setBackgroundColour(C.bg); term.setTextColour(C.tool)
            term.clearLine(); term.write(("Allow? [y/n] " .. left .. "s"):sub(1, w))
            local mon, monName = getMonitor()
            if mon then drawBar(mon) end

            local e = table.pack(os.pullEventRaw())
            local ready = os.epoch("utc") - shown >= DEBOUNCE_MS
            if e[1] == "terminate" then return "no"
            elseif e[1] == "timer" and e[2] == timer then timer = os.startTimer(1)
            elseif e[1] == "key" and not e[3] and ready and (e[2] == keys.y or e[2] == keys.n) then
                -- A remote prompt can pop up while the player sits at the "> " input, where
                -- read() also got this letter. Erase it again.
                if ctx.remote then os.queueEvent("key", keys.backspace, false) end
                return e[2] == keys.y and "yes" or "no"
            elseif e[1] == "monitor_touch" and ready and mon and e[2] == monName then
                local a = touchAnswer(mon, e[3], e[4])
                if a then return a end
            else
                hold(e)
            end
        end
    end
    local ok, ans = pcall(loop)
    if timer then os.cancelTimer(timer) end
    ui.drawMonitor = origDraw
    if not ok then ans = "no" end

    pcall(function()
        local _, h = term.getSize()
        term.setCursorPos(1, h); term.setBackgroundColour(C.bg); term.clearLine()
        if blink then term.setTextColour(C.user); term.write("> ") end -- we drew over the input line
        term.setTextColour(fg); term.setBackgroundColour(bg)
        term.setCursorPos(cx, cy); term.setCursorBlink(blink)
        if ans == "yes" then ui.add("  -> allowed", C.ok)
        elseif ans == "timeout" then
            ui.add("  -> " .. (view.timeoutText or "no answer, denied"), view.timeoutText and C.info or C.err)
        else ui.add("  -> denied", C.err) end
        ui.drawBody()
    end)
    return ans
end

-- Ask the player. Returns "yes", "no" or "timeout".
-- Runs inside whichever coroutine asked (main loop, incoming handler, ...). parallel hands
-- every event to every coroutine, so we only hold back the claude_* events of the caller's
-- own request and requeue them afterwards; everything else the other coroutines already saw.
local function ask(view, ctx, deadline)
    if not ui then return "no" end
    local held = {}
    local function hold(e)
        if ctx.reqId ~= nil and e[2] == ctx.reqId and type(e[1]) == "string" and e[1]:find("^claude_") then
            held[#held + 1] = e
        end
    end
    while busy do
        local e = table.pack(os.pullEventRaw())
        if e[1] == "terminate" then requeue(held); return "no" end
        hold(e)
    end
    busy = true
    local ok, ans = pcall(promptLoop, view, ctx, hold, deadline)
    busy = false
    requeue(held)
    os.queueEvent("claudecraft_guard_free")
    if not ok then error(ans, 0) end
    return ans
end

----------------------------------------------------------------------
-- Command computers: hide the commands API while Claude's shell commands run,
-- so a script Claude wrote can't reach commands.exec either. Restored when the command
-- returns. (If claude itself is killed mid-command, it stays hidden until reboot.)
----------------------------------------------------------------------
local blockedCommands = setmetatable({}, {
    __index = function(_, k)
        error("commands." .. tostring(k) .. " is blocked for Claude here. Only the player can allow it, with /confirm commands allow.", 2)
    end,
    __metatable = false,
})

local function withCommandsHidden(exec, name, input)
    hideDepth = hideDepth + 1
    _G.commands = blockedCommands
    local res = table.pack(pcall(exec, name, input))
    hideDepth = hideDepth - 1
    if hideDepth == 0 then _G.commands = realCommands end
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Set up the guard. opts: ui (claude.lua's ui table), colors, getMonitor() -> monitor, name,
-- timeout (seconds to wait for an answer), shell.
function M.init(opts)
    ui, C = opts.ui, opts.colors
    getMonitor = opts.getMonitor or function() return nil end
    sh = opts.shell or shell
    timeoutSecs = opts.timeout or 60
    if sh and sh.getRunningProgram then selfPath = sh.getRunningProgram() end
    realCommands = commands
    isCommandComputer = realCommands ~= nil
    loadSettings()
end

--- Run tool `name` through the policy. exec(name, input) does the real work.
-- ctx: { reqId = request whose events the caller's loop is waiting on, remote = true when
-- another computer's message asked for this }.
-- Returns the tool result, plus true when the guard blocked the call.
function M.run(name, input, ctx, exec)
    ctx = ctx or {}
    if type(input) ~= "table" then input = {} end
    local deadline = os.epoch("utc") + timeoutSecs * 1000

    local why = refusal(name, input)
    if why then return { error = why }, true end

    local reason, forced = confirmReason(name, input)
    if reason and (forced or ctx.remote or settings.confirm) then
        local ans = ask({ title = name, detail = describe(name, input), reason = reason }, ctx, deadline)
        if ans == "timeout" then
            return { error = "Denied: nobody at this computer confirmed the " .. name .. " call within "
                .. timeoutSecs .. "s. Ask the player to be at the computer, or to do it themselves." }, true
        elseif ans ~= "yes" then
            return { error = "Denied: the player said no to this " .. name .. " call. Don't retry it unchanged; ask them what they want instead." }, true
        end
    end

    if name == "run_command" and isCommandComputer and not settings.commands then
        return withCommandsHidden(exec, name, input)
    end
    return exec(name, input)
end

--- Handle "/confirm ..." typed by the player. args is the text after "/confirm".
function M.command(args)
    local a, b = (args or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if a == "on" or a == "off" then
        settings.confirm = a == "on"; saveSettings()
    elseif a == "commands" and (b == "allow" or b == "deny") then
        settings.commands = b == "allow"; saveSettings()
    elseif a ~= "" and a ~= "status" then
        ui.add("Usage: /confirm on|off|status", C.err)
        ui.add("  /confirm commands allow|deny", C.err)
        return
    end
    -- Lines kept to 26 columns for pocket computers.
    ui.add("Confirm mode: " .. (settings.confirm and "ON" or "OFF"), C.info)
    if settings.confirm then
        ui.add("  Asks before deletes,", C.ai)
        ui.add("  shell commands, startup", C.ai)
        ui.add("  edits and overwrites.", C.ai)
    end
    ui.add("Other PCs: always ask", C.ai)
    ui.add("Op commands: " .. (settings.commands and "ask each time" or "blocked"), C.ai)
end

--- Current settings, for display or other modules.
function M.status()
    return { confirm = settings.confirm, commands = settings.commands, commandComputer = isCommandComputer }
end

----------------------------------------------------------------------
-- For modules that act without a tool call (claudecraft.jobs): the same prompt and
-- the same hard limits, so there is one policy and one prompt on screen at a time.
----------------------------------------------------------------------

--- Ask the player y/n with the prompt M.run uses (one at a time; keys or monitor touch;
-- the caller's claude_* events held back and requeued). view: {title, detail, reason,
-- timeoutText? (shown instead of "no answer, denied")}. secs defaults to the guard timeout.
-- Returns "yes", "no" or "timeout".
function M.confirm(view, ctx, secs)
    view = {
        title = clip(view.title or "?"), detail = clip(view.detail or ""),
        reason = clip(view.reason or "needs your OK"), timeoutText = view.timeoutText,
    }
    return ask(view, ctx or {}, os.epoch("utc") + (secs or timeoutSecs) * 1000)
end

--- The hard-limit refusal message for tool call `name`, or nil. Never prompts.
function M.refusal(name, input)
    return refusal(name, type(input) == "table" and input or {})
end

--- Why changing `path` changes what runs later (startup files, ClaudeCraft settings,
-- the claude program), or nil.
function M.protected(path)
    return protectedReason(path)
end

--- True while a y/n prompt is on screen (it owns the input line and monitor bottom row).
function M.prompting()
    return busy
end

return M
