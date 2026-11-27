-- claudecraft.jobs - long-running background jobs for claude.lua.
--
-- EVENTS. Jobs are coroutines driven by M.run(), which claude.lua runs in its
-- parallel.waitForAny next to the chat loop. parallel gives every event to
-- every top-level coroutine whose filter matches, so the runner sees all
-- events whatever the chat loop is blocked on, and the chat loop still gets
-- every claude_* stream event however a job pulls events. The runner then
-- filters per job (as parallel does), never passes "terminate" to jobs, and
-- catches job errors (including "Too long without yielding") so a broken job
-- fails on its own instead of killing the chat.
--
-- TURTLE LOCK. Only one turtle job runs at a time, and while it does, chat
-- tools that move the turtle or touch its inventory are refused
-- (M.turtleBusy). Cancelling only stops a job between turtle commands: every
-- turtle call a job makes goes through a proxy that checks for a pending
-- cancel first, so a cancelled job never leaves a command half-tracked.
--
-- PERSISTENCE. /.claude/jobs/<id>.json is the job record (params, progress,
-- state, nav position); code jobs keep their source in <id>.lua. A job found
-- "running" at startup was interrupted (reboot, chunk unload, exit) and is
-- shown as "paused". It resumes only when the player says so (/jobs resume),
-- or, if it was started with resume_on_boot, after a visible countdown the
-- player can stop. resume_on_boot also installs /startup/claudecraft_jobs.lua
-- so the computer relaunches claude after a reboot.

local navlib = require("claudecraft.jobs_nav")
local templates = require("claudecraft.jobs_templates")

local M = {}

local DIR = "/.claude/jobs"
local HOOK_DIR, HOOK = "/startup", "/startup/claudecraft_jobs.lua"
local KILL = "claudecraft_job_kill"   -- yielded by a cancelled job at a safe point
local WAKE = "claudecraft_job_wake"   -- makes the runner start newly spawned jobs
local YIELD = "claudecraft_job_yield"
local MAX_LOG, MAX_KEEP, MAX_CODE = 20, 25, 32768
local CONFIRM_SECS = 45 -- channel mode gives up on a tool call after 60s
local FINAL = { done = true, failed = true, cancelled = true }

local jobs = {}  -- id -> persisted record
local rt = {}    -- id -> runtime: {co, filter, started, cancel, resumed, homing}
local hooks = { add = function() end, refresh = function() end }
local C = {}
local mainCo
local loaded = false
local dirty, lastDraw = false, 0

local function now() return os.epoch("utc") end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local c = f.readAll()
    f.close()
    return c
end

local function writeFile(path, data)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

local function sortedIds(t)
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------

local function persist(j)
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    j.updated = now()
    local ok, data = pcall(textutils.serialiseJSON, j)
    if not ok then return false, data end
    writeFile(DIR .. "/" .. j.id .. ".json", data)
    return true
end

local function addLog(j, text)
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 0 then
            j.log[#j.log + 1] = line:sub(1, 200)
            while #j.log > MAX_LOG do table.remove(j.log, 1) end
        end
    end
end

local function nextId()
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    local n = tonumber(readFile(DIR .. "/next_id") or "") or 1
    for id in pairs(jobs) do if id >= n then n = id + 1 end end
    writeFile(DIR .. "/next_id", tostring(n + 1))
    return n
end

local function loadAll()
    jobs = {}
    if not fs.isDir(DIR) then return end
    for _, f in ipairs(fs.list(DIR)) do
        local id = tonumber(f:match("^(%d+)%.json$"))
        if id then
            local ok, j = pcall(textutils.unserialiseJSON, readFile(DIR .. "/" .. f) or "")
            if ok and type(j) == "table" then
                j.id = id
                if type(j.progress) ~= "table" then j.progress = {} end
                if type(j.state) ~= "table" then j.state = {} end
                if type(j.log) ~= "table" then j.log = {} end
                if j.status == "running" then
                    j.status = "paused"
                    addLog(j, "interrupted (reboot, chunk unload or exit)")
                    persist(j)
                elseif j.status == "cancelling" then
                    j.status, j.error, j.reported = "cancelled", "interrupted while returning home", false
                    persist(j)
                end
                jobs[id] = j
            end
        end
    end
end

local function prune()
    local old = {}
    for id, j in pairs(jobs) do
        if FINAL[j.status] and j.reported then old[#old + 1] = id end
    end
    table.sort(old)
    for k = 1, #old - MAX_KEEP do
        local id = old[k]
        jobs[id] = nil
        fs.delete(DIR .. "/" .. id .. ".json")
        if fs.exists(DIR .. "/" .. id .. ".lua") then fs.delete(DIR .. "/" .. id .. ".lua") end
    end
end

----------------------------------------------------------------------
-- Startup hook (only while a resume_on_boot job is unfinished)
----------------------------------------------------------------------

local HOOK_SRC = [[
-- Installed by ClaudeCraft: relaunches claude after a reboot or chunk reload
-- so background jobs started with resume_on_boot can resume. Safe to delete;
-- claude removes it by itself once no such job is left.
if _G.__claudecraft_session then return end
local dir = "/.claude/jobs"
if not fs.isDir(dir) then return end
for _, f in ipairs(fs.list(dir)) do
    if f:match("^%d+%.json$") then
        local h = fs.open(fs.combine(dir, f), "r")
        if h then
            local ok, j = pcall(textutils.unserialiseJSON, h.readAll())
            h.close()
            if ok and type(j) == "table" and j.resume_on_boot and (j.status == "running" or j.status == "paused") then
                shell.run("claude")
                return
            end
        end
    end
end
]]

local function updateHook()
    local need = false
    for _, j in pairs(jobs) do
        if j.resume_on_boot and not FINAL[j.status] then need = true end
    end
    if not need then
        if fs.exists(HOOK) then fs.delete(HOOK) end
        return true
    end
    if fs.exists(HOOK) then return true end
    if fs.exists(HOOK_DIR) and not fs.isDir(HOOK_DIR) then
        return false, "/startup is a file, so no boot hook was installed; add shell.run(\"claude\") to it to auto-resume"
    end
    if not fs.exists(HOOK_DIR) then fs.makeDir(HOOK_DIR) end
    writeFile(HOOK, HOOK_SRC)
    return true
end

----------------------------------------------------------------------
-- UI glue
----------------------------------------------------------------------

local function announce(text, kind)
    pcall(hooks.add, text, kind or "info")
    dirty, lastDraw = false, os.clock()
    pcall(hooks.refresh, true)
end

local function markDirty() dirty = true end

local function flush()
    if dirty and os.clock() - lastDraw >= 1 then
        dirty, lastDraw = false, os.clock()
        pcall(hooks.refresh, false)
    end
end

--- Ask the player y/n on the input line. Returns true/false, or nil on timeout.
local function ask(prompt, secs, default, onView)
    local _, h = term.getSize()
    local deadline = os.clock() + secs
    local timer = os.startTimer(0)
    local answer
    while answer == nil do
        local ev, p = os.pullEventRaw()
        if ev == "terminate" then
            answer = false
        elseif ev == "timer" and p == timer then
            local left = math.ceil(deadline - os.clock())
            if left <= 0 then break end
            local w = term.getSize()
            term.setCursorPos(1, h)
            term.setBackgroundColour(C.bg or colors.black)
            term.setTextColour(C.tool or colors.white)
            term.clearLine()
            term.write((prompt .. " (" .. left .. "s)"):sub(1, w))
            timer = os.startTimer(1)
        elseif ev == "char" then
            p = p:lower()
            if p == "y" then answer = true
            elseif p == "n" then answer = false
            elseif p == "v" and onView then onView()
            end
        end
    end
    term.setCursorPos(1, h)
    term.setBackgroundColour(C.bg or colors.black)
    term.clearLine()
    if answer == nil then return default end
    return answer
end

----------------------------------------------------------------------
-- Job api handed to templates and code jobs
----------------------------------------------------------------------

local function nullTerm()
    local t = {}
    function t.getSize() return 51, 19 end
    function t.getCursorPos() return 1, 1 end
    function t.isColour() return false end
    t.isColor = t.isColour
    function t.getTextColour() return colors.white end
    t.getTextColor = t.getTextColour
    function t.getBackgroundColour() return colors.black end
    t.getBackgroundColor = t.getBackgroundColour
    return setmetatable(t, { __index = function() return function() end end })
end

local function makeApi(j, r)
    local api = { id = j.id, params = j.params or {}, state = j.state, resumed = r.resumed == true }

    local function cancelPoint()
        if r.cancel then coroutine.yield(KILL) end
    end

    function api.save()
        local ok, err = persist(j)
        if not ok then error("job.state can't be saved as JSON: " .. tostring(err), 2) end
    end

    function api.log(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        addLog(j, table.concat(parts, " "))
    end

    --- progress(pct, text): either may be nil to leave it unchanged.
    function api.progress(pct, text)
        if pct ~= nil then
            pct = tonumber(pct)
            j.progress.pct = pct and math.max(0, math.min(100, math.floor(pct))) or nil
        end
        if text ~= nil then j.progress.text = tostring(text):sub(1, 60) end
        persist(j)
        markDirty()
        cancelPoint()
    end

    function api.sleep(secs)
        cancelPoint()
        local t = os.startTimer(tonumber(secs) or 0)
        repeat local _, id = os.pullEvent("timer") until id == t
        cancelPoint()
    end

    function api.yield()
        cancelPoint()
        os.queueEvent(YIELD)
        os.pullEvent(YIELD)
        cancelPoint()
    end

    --- Wait for event `ev`, or `timeout` seconds, whichever comes first.
    function api.waitFor(ev, timeout)
        cancelPoint()
        local t = timeout and os.startTimer(timeout)
        while true do
            local e, p = os.pullEvent()
            if e == ev or (e == "timer" and p == t) then break end
        end
        cancelPoint()
    end

    if turtle and j.turtle then
        local proxy = {}
        for k, v in pairs(turtle) do
            if type(v) == "function" then
                proxy[k] = function(...) cancelPoint(); return v(...) end
            else
                proxy[k] = v
            end
        end
        api.turtle = proxy
        if type(j.nav) ~= "table" then j.nav = {} end
        api.nav = navlib.new(api, j.nav)
        api.lib = navlib.bind(api)
    end
    return api
end

local function makeEnv(api)
    local env = setmetatable({}, { __index = _ENV })
    local function out(...) api.log(...) end
    env.job = api
    env.print, env.printError = out, out
    env.write = function(s) api.log(s) end
    env.term = nullTerm()
    env.sleep = api.sleep
    env.os = setmetatable({ sleep = api.sleep }, { __index = os })
    if turtle then env.turtle = api.turtle or false end
    return env
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

local function summarize(v)
    if v == nil then return nil end
    if type(v) ~= "table" then return tostring(v):sub(1, 500) end
    local ok, s = pcall(textutils.serialiseJSON, v)
    if ok and #s <= 1000 then return v end
    return ok and s:sub(1, 1000) or tostring(v)
end

local function finalize(j, status, info)
    rt[j.id] = nil
    j.status, j.finished, j.reported = status, now(), false
    if status == "done" then
        j.result = summarize(info)
        if j.progress.pct then j.progress.pct = 100 end
    elseif info ~= nil then
        j.error = tostring(info)
    end
    j.progress.text = status
    persist(j)
    updateHook()
    local msg = ("[job #%d] %s: %s"):format(j.id, j.name, status)
    if j.error then msg = msg .. " - " .. j.error end
    announce(msg, status == "done" and "ok" or (status == "failed" and "err" or "info"))
end

local function spawn(j, resumed)
    local r = { resumed = resumed }
    rt[j.id] = r
    r.co = coroutine.create(function()
        local api = makeApi(j, r)
        if api.nav and resumed then api.nav.reconcile() end
        if j.kind == "template" then
            return templates[j.template].run(api, j.params)
        end
        local src = readFile(DIR .. "/" .. j.id .. ".lua")
        if not src then error("job source file is missing", 0) end
        local fn, err = load(src, "=job" .. j.id, "t", makeEnv(api))
        if not fn then error(err, 0) end
        return fn()
    end)
    os.queueEvent(WAKE)
end

-- After a cancel with return_home: drive the turtle back along the job's route.
local function startHoming(j)
    j.status = "cancelling"
    j.progress.text = "returning home"
    persist(j)
    local h = { resumed = true, homing = true }
    rt[j.id] = h
    h.co = coroutine.create(function()
        local api = makeApi(j, h)
        api.nav.reconcile()
        local ok, e = api.nav.goHome()
        if not ok then error(e, 0) end
        api.nav.face(0)
    end)
    os.queueEvent(WAKE)
    announce(("[job #%d] cancelling: returning home"):format(j.id), "info")
end

local function kill(id)
    local r, j = rt[id], jobs[id]
    rt[id] = nil
    if not j then return end
    if r and r.cancel and r.cancel.home and j.turtle and turtle then
        startHoming(j)
    else
        finalize(j, "cancelled")
    end
end

local function step(id, ...)
    local r, j = rt[id], jobs[id]
    if not (r and j) then rt[id] = nil; return end
    local res = table.pack(coroutine.resume(r.co, ...))
    if not res[1] then
        return finalize(j, r.homing and "cancelled" or "failed",
            r.homing and ("could not return home: " .. tostring(res[2])) or res[2])
    end
    if coroutine.status(r.co) == "dead" then
        if r.homing then return finalize(j, "cancelled") end
        return finalize(j, "done", res[2])
    end
    r.filter = res[2]
    -- Never kill mid turtle-command: wait until the job yields for anything else.
    if r.cancel and (r.filter == KILL or r.filter ~= "turtle_response") then kill(id) end
end

local function safeStep(id, ...)
    local ok, err = pcall(step, id, ...)
    if not ok then
        rt[id] = nil
        if jobs[id] then pcall(finalize, jobs[id], "failed", "internal error: " .. tostring(err)) end
    end
end

--- The scheduler. Add to claude.lua's parallel.waitForAny.
function M.run()
    while true do
        for _, id in ipairs(sortedIds(rt)) do
            local r = rt[id]
            if r and not r.started then
                r.started = true
                safeStep(id)
            end
        end
        local ev = table.pack(os.pullEventRaw())
        if ev[1] ~= "terminate" and ev[1] ~= WAKE then
            for _, id in ipairs(sortedIds(rt)) do
                local r = rt[id]
                if r and r.started and (r.filter == nil or r.filter == ev[1]) then
                    safeStep(id, table.unpack(ev, 1, ev.n))
                end
            end
        end
        flush()
    end
end

function M.turtleOwner()
    for _, id in ipairs(sortedIds(rt)) do
        if jobs[id] and jobs[id].turtle then return id end
    end
    return nil
end

function M.resume(id)
    local j = jobs[id]
    if not j then return nil, "no job #" .. tostring(id) end
    if j.status ~= "paused" then return nil, ("job #%d is %s"):format(id, j.status) end
    if j.turtle and not turtle then return nil, "this job needs a turtle" end
    local owner = j.turtle and M.turtleOwner()
    if owner then return nil, ("the turtle is busy with job #%d"):format(owner) end
    j.status = "running"
    addLog(j, "resumed")
    persist(j)
    spawn(j, true)
    announce(("[job #%d] resuming %s"):format(id, j.name), "info")
    return true
end

--- Cancel a job. return_home (default true) sends a turtle job back home
-- along its route first. Returns the new status, or nil and an error.
function M.cancel(id, home)
    local j = jobs[id]
    if not j then return nil, "no job #" .. tostring(id) end
    if FINAL[j.status] then return nil, ("job #%d is already %s"):format(id, j.status) end
    if home == nil then home = true end
    local r = rt[id]
    if not r then -- paused: nothing running
        if home and j.turtle and turtle and not M.turtleOwner() then
            startHoming(j)
        else
            finalize(j, "cancelled")
        end
        return j.status
    end
    r.cancel = { home = home and not r.homing }
    if not r.started or r.filter ~= "turtle_response" then
        kill(id)
    else
        j.status = "cancelling" -- stops after the turtle command in flight
        persist(j)
    end
    return j.status
end

----------------------------------------------------------------------
-- Tools
----------------------------------------------------------------------

local RISKY = {
    { "fs%.delete", "fs.delete" }, { "fs%.move", "fs.move" }, { "fs%.open", "files" },
    { "shell%.", "shell" }, { "http", "http" }, { "os%.reboot", "reboot" },
    { "os%.shutdown", "shutdown" }, { "rednet", "rednet" }, { "peripheral", "peripherals" },
    { "redstone", "redstone" }, { "turtle", "turtle" }, { "nav%.", "movement" },
    { "settings%.", "settings" }, { "load", "load" },
}

local function riskSummary(code)
    local seen, uses = {}, {}
    for _, r in ipairs(RISKY) do
        if code:find(r[1]) and not seen[r[2]] then seen[r[2]] = true; uses[#uses + 1] = r[2] end
    end
    local lines = select(2, code:gsub("\n", "\n")) + 1
    return ("%d lines; uses: %s"):format(lines, #uses > 0 and table.concat(uses, ", ") or "nothing special")
end

local function startJob(input)
    local tpl, code = input.template, input.code
    if (tpl == nil) == (code == nil) then
        return { error = "Give either template (+params) or code, not both." }
    end
    local j
    if tpl then
        local T = templates[tpl]
        if type(T) ~= "table" or not T.run then
            return { error = "Unknown template '" .. tostring(tpl) .. "'. Templates: " .. table.concat(templates.names, ", ") }
        end
        if T.turtle and not turtle then return { error = "The " .. tpl .. " template needs a turtle." } end
        -- Params normally come in `params`, but accept them at the top level too.
        local ok, params = pcall(T.validate, type(input.params) == "table" and input.params or input)
        if not ok then return { error = "Bad params: " .. tostring(params), usage = T.help } end
        local owner = T.turtle and M.turtleOwner()
        if owner then return { error = ("The turtle is busy with job #%d. Cancel it first."):format(owner) } end
        if T.turtle and not navlib.hasInventory("back") then
            return { error = "Put a chest (or barrel) directly behind the turtle first: jobs unload into it.", usage = T.help }
        end
        j = { kind = "template", template = tpl, params = params, turtle = T.turtle,
              name = input.name or T.label(params) }
    else
        if type(code) ~= "string" or #code == 0 then return { error = "code must be a Lua program" } end
        if #code > MAX_CODE then return { error = "code is too long (max " .. MAX_CODE .. " bytes)" } end
        local fn, err = load(code, "=job", "t", {})
        if not fn then return { error = "Lua syntax error: " .. tostring(err) } end
        local summary = type(input.summary) == "string" and input.summary:gsub("%s+", " ") or ""
        if #summary == 0 then return { error = "summary is required for code jobs (shown to the player)" } end
        if coroutine.running() ~= mainCo then
            return { error = "Code jobs need the player's approval at this computer, so they can't be started from an incoming message. Templates can." }
        end
        local usesTurtle = turtle ~= nil and (code:find("turtle") or code:find("nav")) ~= nil
        local owner = usesTurtle and M.turtleOwner()
        if owner then return { error = ("The turtle is busy with job #%d. Cancel it first."):format(owner) } end

        announce("[job] Claude wants to start a background program:", "tool")
        announce("  " .. summary, "user")
        announce("  " .. riskSummary(code) .. ". It runs with this computer's full permissions.", "sep")
        local answer = ask("Start it? y=yes n=no v=view code", CONFIRM_SECS, nil, function()
            local n = 0
            for line in (code .. "\n"):gmatch("([^\n]*)\n") do
                n = n + 1
                pcall(hooks.add, ("%3d| %s"):format(n, line), "sep")
            end
            pcall(hooks.refresh, true)
        end)
        if answer == nil then
            announce("[job] not started (no answer)", "sep")
            return { error = "The player didn't answer within " .. CONFIRM_SECS .. "s, so the job was not started." }
        elseif not answer then
            announce("[job] declined", "sep")
            return { error = "The player declined to start this job.", declined = true }
        end
        j = { kind = "code", params = type(input.params) == "table" and input.params or {},
              turtle = usesTurtle, summary = summary,
              name = type(input.name) == "string" and input.name or summary:sub(1, 24) }
    end

    j.id = nextId()
    j.name = tostring(j.name):sub(1, 40)
    j.status, j.created = "running", now()
    j.progress, j.state, j.log = {}, {}, {}
    j.resume_on_boot = input.resume_on_boot == true
    if code then writeFile(DIR .. "/" .. j.id .. ".lua", code) end
    persist(j)
    jobs[j.id] = j
    local hookOk, hookErr = updateHook()
    spawn(j, false)
    announce(("[job #%d] started: %s"):format(j.id, j.name), "info")
    return {
        id = j.id, name = j.name, status = "running",
        resume_on_boot = j.resume_on_boot, warning = (not hookOk) and hookErr or nil,
        note = "Runs in the background. Check with job_status; you'll get a note in the conversation when it ends.",
    }
end

local function describe(j, full)
    local d = { id = j.id, name = j.name, status = j.status, pct = j.progress.pct, progress = j.progress.text }
    if not full then return d end
    d.kind, d.template, d.params = j.kind, j.template, j.params
    d.summary, d.result, d.error = j.summary, j.result, j.error
    d.resume_on_boot = j.resume_on_boot
    d.log = #j.log > 0 and { table.unpack(j.log, math.max(1, #j.log - 9)) } or nil
    if j.turtle and type(j.nav) == "table" and j.nav.x then
        d.position = { x = j.nav.x, y = j.nav.y, z = j.nav.z, facing = j.nav.f,
            frame = "relative to the job's start: +z = starting facing, +x = its right, +y = up" }
    end
    if j.turtle and turtle then d.fuel = turtle.getFuelLevel() end
    d.age_s = math.floor((now() - (j.created or now())) / 1000)
    return d
end

local function jobId(input)
    local id = tonumber(input and input.id)
    return id and math.floor(id) or nil
end

local TOOL_NAMES = { start_job = true, job_status = true, list_jobs = true, cancel_job = true }

function M.handles(name) return TOOL_NAMES[name] == true end

function M.exec(name, input)
    input = type(input) == "table" and input or {}
    if name == "start_job" then
        return startJob(input)
    elseif name == "job_status" then
        local j = jobs[jobId(input) or -1]
        if not j then return { error = "No job #" .. tostring(input.id) .. ". Use list_jobs." } end
        return describe(j, true)
    elseif name == "list_jobs" then
        local list, finished = {}, {}
        for _, id in ipairs(sortedIds(jobs)) do
            local j = jobs[id]
            if FINAL[j.status] then finished[#finished + 1] = j else list[#list + 1] = describe(j) end
        end
        for k = math.max(1, #finished - 4), #finished do list[#list + 1] = describe(finished[k]) end
        return { jobs = #list > 0 and list or textutils.empty_json_array, turtle_busy_with = M.turtleOwner() }
    elseif name == "cancel_job" then
        local id = jobId(input)
        if not id then return { error = "id is required" } end
        local status, err = M.cancel(id, input.return_home ~= false)
        if not status then return { error = err } end
        return { id = id, status = status }
    end
    return { error = "Unknown job tool: " .. tostring(name) }
end

function M.addDefs(d)
    local tpl = turtle and (" Templates (all need a chest directly behind the turtle for output; an optional fuel chest above it is used for refuelling; they track position relative to the start and go home to unload/refuel): "
        .. templates.quarry.help .. " " .. templates.tree_farm.help .. " " .. templates.crop_farm.help)
        or " (This computer isn't a turtle, so only code jobs are available.)"
    d[#d + 1] = { name = "start_job",
        description = "Start a background job that keeps running while the chat continues, checkpointed so it can be resumed after a reboot. Returns an id at once; a note is added to the conversation when it finishes or fails. Give EITHER template+params OR code." .. tpl
            .. " A code job is a Lua program you write; the player must approve it (y/n) and it runs with full computer permissions. It gets a `job` table: job.params; job.state (saved across reboots - keep your progress in it); job.resumed (true when restarted after a reboot: continue from job.state); job.save(); job.progress(pct, text); job.log(text); job.sleep(s); job.yield()."
            .. (turtle and " On turtles also job.nav (moves that track position relative to the start: forward/back/up/down(dig), turnLeft/turnRight/face(f), goTo(x,y,z[,order[,dig]]), goHome(), fields x y z f; +z = starting facing, +x = its right) and job.lib (unload(), ensureFuel(n), isFull())." or "")
            .. " print() goes to the job log. The program must yield often (turtle calls and job.sleep/job.yield do). Its return value is reported as the result.",
        input_schema = { type = "object", properties = {
            template = { type = "string", description = "Template name: " .. table.concat(templates.names, ", ") },
            params = { type = "object", description = "Template parameters, or values passed to a code job as job.params" },
            code = { type = "string", description = "Lua source for a custom job" },
            summary = { type = "string", description = "Required with code: one plain-language line telling the player what it does" },
            name = { type = "string", description = "Short label" },
            resume_on_boot = { type = "boolean", description = "Only if the player asked for it: resume automatically after a reboot or chunk reload (installs a startup hook)" },
        } } }
    d[#d + 1] = { name = "job_status", description = "Details of a background job: status, progress, recent log, position (turtle jobs), result or error.",
        input_schema = { type = "object", properties = { id = { type = "number" } }, required = { "id" } } }
    d[#d + 1] = { name = "list_jobs", description = "List background jobs (active, paused and recently finished).",
        input_schema = { type = "object", properties = {} } }
    d[#d + 1] = { name = "cancel_job", description = "Cancel a background job. Turtle jobs return home along their route unless return_home=false.",
        input_schema = { type = "object", properties = { id = { type = "number" }, return_home = { type = "boolean" } }, required = { "id" } } }
end

local READONLY_INV = { getItemDetail = true, getItemCount = true, getItemSpace = true,
    getFuelLevel = true, getFuelLimit = true, getSelectedSlot = true }
local TURTLE_PROGRAMS = { go = true, turn = true, excavate = true, tunnel = true, dance = true,
    refuel = true, equip = true, unequip = true, craft = true }

--- The turtle lock, checked by claude.lua before every chat tool call.
-- Returns an error result if `name` would interfere with a running turtle job.
function M.turtleBusy(name, input)
    if not turtle or type(name) ~= "string" then return nil end
    local owner = M.turtleOwner()
    if not owner then return nil end
    input = type(input) == "table" and input or {}
    local blocked = false
    if name == "turtle_inventory" then
        blocked = not READONLY_INV[input.action or ""]
    elseif name ~= "turtle_inspect" and (name:find("^turtle_") or name:find("^build_") or name == "scan_area") then
        blocked = true
    elseif name == "run_command" and type(input.command) == "string" then
        local prog = input.command:match("^%s*(%S+)")
        prog = prog and (fs.getName(prog):gsub("%.lua$", ""))
        blocked = prog ~= nil and TURTLE_PROGRAMS[prog] == true
    end
    if not blocked then return nil end
    return { error = ("The turtle is busy: background job #%d (%s) is using it. Read-only checks still work; use job_status to follow it or cancel_job to stop it.")
        :format(owner, jobs[owner].name) }
end

----------------------------------------------------------------------
-- Conversation and UI hooks for claude.lua
----------------------------------------------------------------------

--- Prefix the player's next message with notes about jobs that ended since
-- Claude last heard, so it learns about them on its next turn.
function M.attachNotes(text)
    local notes = {}
    for _, id in ipairs(sortedIds(jobs)) do
        local j = jobs[id]
        if FINAL[j.status] and j.reported == false then
            local n = ("- job #%d (%s) %s"):format(j.id, j.name, j.status)
            if j.result ~= nil then
                local ok, s = pcall(textutils.serialiseJSON, j.result)
                n = n .. ", result: " .. (ok and s or tostring(j.result))
            end
            if j.error then n = n .. ", error: " .. j.error end
            if j.status ~= "done" and #j.log > 0 then n = n .. ", last log: " .. j.log[#j.log] end
            notes[#notes + 1] = n
            j.reported = true
            persist(j)
        end
    end
    if #notes == 0 then return text end
    prune()
    return "[Automatic note - background jobs that ended since your last turn:\n"
        .. table.concat(notes, "\n") .. "]\n\n" .. text
end

--- One-line status for the separator line / monitor, or nil.
function M.status()
    local active, paused = {}, 0
    for id, j in pairs(jobs) do
        if rt[id] then active[#active + 1] = j elseif j.status == "paused" then paused = paused + 1 end
    end
    if #active == 0 then
        if paused > 0 then return ("%d job%s paused: /jobs"):format(paused, paused > 1 and "s" or "") end
        return nil
    end
    table.sort(active, function(a, b) return a.id < b.id end)
    local j = active[1]
    local s = ("#%d %s"):format(j.id, j.template or j.name:sub(1, 10))
    if j.progress.pct then s = s .. (" %d%%"):format(j.progress.pct) end
    if j.progress.text then s = s .. " " .. j.progress.text end
    if #active > 1 then s = s .. (" (+%d)"):format(#active - 1) end
    return s
end

function M.promptHint()
    return "\nFor long-running work (quarries, farms, anything that loops or takes minutes) use start_job: it runs in the background while you keep chatting"
        .. (turtle and "; prefer the quarry/tree_farm/crop_farm templates when they fit." or ".")
end

--- opts: add(text, kind), refresh(full), colors (claude.lua's C table).
-- Call from claude.lua's main coroutine.
function M.init(opts)
    opts = opts or {}
    hooks.add = opts.add or hooks.add
    hooks.refresh = opts.refresh or hooks.refresh
    C = opts.colors or C
    mainCo = coroutine.running()
    _G.__claudecraft_session = true -- tells the boot hook claude is already up
    if not loaded then
        loadAll()
        prune()
        loaded = true
    end
end

--- At chat start: offer to resume interrupted jobs. Jobs started with
-- resume_on_boot resume after a short countdown unless the player says no;
-- others are only listed.
function M.startup()
    for _, id in ipairs(sortedIds(jobs)) do
        local j = jobs[id]
        if j.status == "paused" then
            local where = j.progress.pct and (" at " .. j.progress.pct .. "%") or ""
            if j.resume_on_boot then
                announce(("[job #%d] %s was interrupted%s."):format(id, j.name, where), "info")
                if ask(("Resume job #%d now? y/n"):format(id), 10, true) then
                    local ok, err = M.resume(id)
                    if not ok then announce("[job] can't resume: " .. err, "err") end
                else
                    announce(("[job #%d] left paused: /jobs resume %d or /jobs cancel %d"):format(id, id, id), "sep")
                end
            else
                announce(("[job #%d] %s is paused%s: /jobs resume %d or /jobs cancel %d"):format(id, j.name, where, id, id), "info")
            end
        end
    end
    updateHook()
end

--- On exit: mark running jobs paused. Returns how many were paused.
function M.shutdown()
    local n = 0
    for _, id in ipairs(sortedIds(rt)) do
        local j, r = jobs[id], rt[id]
        rt[id] = nil
        if j and r.homing then
            j.status, j.error, j.reported = "cancelled", "exited before it got home", false
            persist(j)
        elseif j then
            j.status = "paused"
            addLog(j, "paused: claude exited")
            persist(j)
            n = n + 1
        end
    end
    updateHook()
    return n
end

--- /jobs [list|resume N|cancel N [stay]|log N]. Returns true if handled.
function M.command(inp)
    if inp ~= "/jobs" and not inp:match("^/jobs%s") then return false end
    local cmd, rest = inp:match("^/jobs%s*(%S*)%s*(.-)%s*$")
    local id = tonumber(rest:match("^(%d+)"))
    local function say(t, k) pcall(hooks.add, t, k or "ai") end
    if cmd == "" or cmd == "list" then
        local any = false
        for _, jid in ipairs(sortedIds(jobs)) do
            local j = jobs[jid]
            any = true
            local p = j.progress.pct and (" " .. j.progress.pct .. "%") or ""
            say(("#%d %s - %s%s %s"):format(jid, j.name, j.status, p,
                (j.progress.text and j.progress.text ~= j.status) and j.progress.text or ""),
                FINAL[j.status] and "sep" or "ai")
        end
        if not any then say("No background jobs. Ask Claude to start one.", "sep") end
        say("/jobs resume N | cancel N [stay] | log N", "sep")
    elseif (cmd == "resume" or cmd == "cancel" or cmd == "log") and not id then
        say("Usage: /jobs " .. cmd .. " <id>", "err")
    elseif cmd == "resume" then
        local ok, err = M.resume(id)
        if not ok then say("Can't resume: " .. err, "err") end
    elseif cmd == "cancel" then
        local status, err = M.cancel(id, not rest:find("stay"))
        if not status then say("Can't cancel: " .. err, "err") end
    elseif cmd == "log" then
        local j = jobs[id]
        if not j then say("No job #" .. id, "err")
        else
            say(("Job #%d %s (%s)"):format(id, j.name, j.status), "info")
            for _, l in ipairs(j.log) do say("  " .. l, "ai") end
            if j.error then say("  error: " .. j.error, "err") end
        end
    else
        say("Usage: /jobs [list|resume N|cancel N [stay]|log N]", "err")
    end
    pcall(hooks.add, "", "ai")
    pcall(hooks.refresh, true)
    return true
end

return M
