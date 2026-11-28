-- claudecraft/logistics.lua - item logistics tools for claude.lua
--
-- Tools: find_item, move_items, sort_storage, fluid_tanks, turtle_craft, turtle_equip.
-- Built only on vanilla CC:Tweaked: generic "inventory" / "fluid_storage" peripherals
-- (list, getItemDetail, size, pushItems, pullItems, tanks, pushFluid) and the turtle API.
--
-- Loaded by claude.lua with require("claudecraft.logistics"). Exposes:
--   M.getDefs()          -> tool schemas to append to tools.getDefs()
--   M.handlers[name](in) -> result table (plain data, safe for textutils.serialiseJSON)
--
-- This is a live scan of what is attached right now. It keeps no persistent index.

local M = {}
local H = {}
M.handlers = H

----------------------------------------------------------------------
-- LIMITS
----------------------------------------------------------------------
local MAX_ITEMS = 12          -- distinct items in a find_item result
local MAX_LOCS = 6            -- inventories listed per item
local MAX_SLOTS = 6           -- slot numbers listed per inventory
local MAX_DETAIL_LOOKUPS = 96 -- getItemDetail calls for tag / display-name matching
local MAX_FAILED = 10         -- failed inventory names reported
local BATCH = 32              -- peripheral calls run together in one parallel batch
local GRID = {1, 2, 3, 5, 6, 7, 9, 10, 11} -- turtle slots that form the 3x3 crafting grid
local TURTLE = "turtle"       -- pseudo-inventory name for this turtle's own 16 slots

local SIDES = {top = true, bottom = true, left = true, right = true, front = true, back = true}
local SUCK = {front = "suck", top = "suckUp", bottom = "suckDown"}
local DROP = {front = "drop", top = "dropUp", bottom = "dropDown"}

----------------------------------------------------------------------
-- SMALL HELPERS
----------------------------------------------------------------------
local yieldCount = 0
local function maybeYield(every)
    yieldCount = yieldCount + 1
    if yieldCount % (every or 200) == 0 then
        os.queueEvent("claudecraft_yield")
        os.pullEvent("claudecraft_yield")
    end
end

local function clampInt(v, lo, hi, default)
    v = tonumber(v)
    if not v then return default end
    v = math.floor(v)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function norm(s)
    s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return (s:gsub("%s+", "_"))
end

-- Run functions concurrently, BATCH at a time. Main-thread peripheral calls started
-- together finish in the same server tick, so this is much faster than a plain loop.
-- Every function must catch its own errors.
local function runParallel(fns)
    local i = 1
    while i <= #fns do
        local last = math.min(#fns, i + BATCH - 1)
        if last == i then
            fns[i]()
        else
            local batch = {}
            for j = i, last do batch[#batch + 1] = fns[j] end
            parallel.waitForAll(table.unpack(batch))
        end
        i = last + 1
    end
end

local function hasType(name, t)
    if peripheral.hasType then
        local ok, r = pcall(peripheral.hasType, name, t)
        if ok then return r == true end
    end
    return peripheral.getType(name) == t
end

local function isInventory(name)
    if hasType(name, "inventory") then return true end
    local methods = peripheral.getMethods(name)
    if not methods then return false end
    local has = {}
    for _, m in ipairs(methods) do has[m] = true end
    return (has.list and has.pushItems and has.size) and true or false
end

local function listOf(inv)
    local ok, l = pcall(peripheral.call, inv, "list")
    return (ok and type(l) == "table") and l or {}
end

--- Every inventory peripheral this computer can see (sides and wired network), sorted.
function M.inventories()
    local out = {}
    for _, n in ipairs(peripheral.getNames()) do
        if isInventory(n) then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

-- list() every inventory in parallel. Returns name -> (slot -> {name, count, nbt}), failed names.
local function scan(names)
    local lists, failed, fns = {}, {}, {}
    for _, n in ipairs(names) do
        fns[#fns + 1] = function()
            local ok, items = pcall(peripheral.call, n, "list")
            if ok and type(items) == "table" then lists[n] = items else failed[#failed + 1] = n end
        end
    end
    runParallel(fns)
    table.sort(failed)
    return lists, failed
end

local function turtleList()
    local items = {}
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d then items[s] = {name = d.name, count = d.count} end
    end
    return items
end

local function availability(lists)
    local av = {}
    for _, items in pairs(lists) do
        for _, it in pairs(items) do av[it.name] = (av[it.name] or 0) + it.count end
    end
    return av
end

-- All stacks of one item across `lists`, largest first.
local function stacksOf(lists, name)
    local out = {}
    for inv, items in pairs(lists) do
        for slot, it in pairs(items) do
            if it.name == name and it.count > 0 then out[#out + 1] = {inv = inv, slot = slot, item = it} end
        end
        maybeYield(500)
    end
    table.sort(out, function(a, b) return a.item.count > b.item.count end)
    return out
end

----------------------------------------------------------------------
-- ITEM MATCHING
-- "minecraft:iron_ingot" = exact id, "#c:ingots" = item tag,
-- "iron" / "iron ingot" = id contains it (find_item falls back to display names),
-- nil / "" / "*" = anything.
----------------------------------------------------------------------
local function matcher(query)
    local q = norm(query)
    if q == "" or q == "*" then return {any = true, label = "*"} end
    if q:sub(1, 1) == "#" then return {tag = q:sub(2), label = q} end
    if q:find(":", 1, true) then return {exact = q, label = q} end
    return {sub = q, label = q}
end

-- true/false from the id alone, or nil when item details are needed (tags).
local function matchName(m, name)
    if m.any then return true end
    if m.exact then return name == m.exact end
    if m.sub then return name:find(m.sub, 1, true) ~= nil end
    return nil
end

local function matchDetail(m, d)
    if not d then return false end
    if m.tag then return type(d.tags) == "table" and d.tags[m.tag] == true end
    if m.sub and d.displayName then return norm(d.displayName):find(m.sub, 1, true) ~= nil end
    return false
end

local function matches(m, name, details, useDisplay)
    local ok = matchName(m, name)
    if ok == nil then return matchDetail(m, details and details[name]) end
    if not ok and useDisplay and details then return matchDetail(m, details[name]) end
    return ok
end

-- getItemDetail once per distinct item name (tags and display names are per item id).
local function fetchDetails(lists)
    local seen, fns, details, n = {}, {}, {}, 0
    for inv, items in pairs(lists) do
        for slot, it in pairs(items) do
            if not seen[it.name] and n < MAX_DETAIL_LOOKUPS then
                seen[it.name] = true
                n = n + 1
                local name = it.name
                fns[#fns + 1] = function()
                    local ok, d
                    if inv == TURTLE then ok, d = pcall(turtle.getItemDetail, slot, true)
                    else ok, d = pcall(peripheral.call, inv, "getItemDetail", slot) end
                    if ok and type(d) == "table" then details[name] = d end
                end
            end
        end
    end
    runParallel(fns)
    return details, n >= MAX_DETAIL_LOOKUPS
end

local function collect(lists, m, details, useDisplay)
    local hits = {}
    for inv, items in pairs(lists) do
        for slot, it in pairs(items) do
            if matches(m, it.name, details, useDisplay) then
                hits[#hits + 1] = {inv = inv, slot = slot, name = it.name, count = it.count}
            end
        end
        maybeYield(200)
    end
    return hits
end

----------------------------------------------------------------------
-- TURTLE TRANSPORT
-- Moves items between the turtle's own slots and an inventory, two ways:
--   network:  a wired modem block next to the turtle, right-clicked so the turtle is
--             on the network. Its name (getNameLocal) is a valid pushItems/pullItems
--             target, so items go straight into a chosen turtle slot.
--   adjacent: a chest in front of, above or below the turtle. turtle.suck takes from
--             the chest's first slot, so the wanted stack is moved to slot 1 first.
----------------------------------------------------------------------
local T = {}
local MAXSTACK = {}

function T.init()
    T.net, T.lastError = nil, nil
    if not turtle then return end
    for _, side in ipairs({"front", "back", "top", "bottom", "left", "right"}) do
        if hasType(side, "modem") then
            local okW, wireless = pcall(peripheral.call, side, "isWireless")
            if okW and wireless == false then
                local ok, nm = pcall(peripheral.call, side, "getNameLocal")
                if ok and type(nm) == "string" then T.net = nm; return end
            end
        end
    end
end

function T.reachable(inv)
    if inv == TURTLE then return false end
    if SUCK[inv] then return true end
    return T.net ~= nil and not SIDES[inv]
end

local function reachHint(inv)
    if inv and SIDES[inv] then
        return "The turtle can only exchange items with a chest in front of, above or below it ('" .. inv ..
            "' is beside or behind it). Move the chest, or use a wired modem network."
    end
    return "The turtle is not on the wired network. Place a wired modem block next to the turtle and " ..
        "right-click it, or put a chest in front of, above or below the turtle."
end

local function adjacentToTurtle(inv, slot, n, tslot)
    local list = peripheral.call(inv, "list")
    local target = list[slot]
    if not target then return 0 end
    if slot ~= 1 then
        local first = list[1]
        if first and (first.name ~= target.name or first.nbt ~= target.nbt) then
            local size = peripheral.call(inv, "size")
            local empty
            for s = 2, size do
                if not list[s] then empty = s; break end
            end
            if not empty then error("the chest needs one free slot so the turtle can pick items from it", 0) end
            peripheral.call(inv, "pushItems", inv, 1, first.count, empty)
        end
        peripheral.call(inv, "pushItems", inv, slot, n, 1)
    end
    local top = peripheral.call(inv, "getItemDetail", 1)
    if not top or top.name ~= target.name then return 0 end
    if top.maxCount then MAXSTACK[top.name] = top.maxCount end
    local room = (top.maxCount or 64) - turtle.getItemCount(tslot)
    local want = math.min(n, top.count, room)
    if want <= 0 then return 0 end
    local before = turtle.getItemCount(tslot)
    local prev = turtle.getSelectedSlot()
    turtle.select(tslot)
    turtle[SUCK[inv]](want)
    turtle.select(prev)
    return turtle.getItemCount(tslot) - before
end

-- Inventory slot -> turtle slot. Returns moved, relayout (true when the source inventory's
-- slots were rearranged, so any cached list() of it is stale).
function T.toTurtle(inv, slot, n, tslot)
    if n <= 0 then return 0, false end
    if T.net and not SIDES[inv] then
        local ok, moved = pcall(peripheral.call, inv, "pushItems", T.net, slot, n, tslot)
        return (ok and type(moved) == "number") and moved or 0, false
    end
    if not SUCK[inv] then return 0, false end
    local ok, moved = pcall(adjacentToTurtle, inv, slot, n, tslot)
    if not ok then T.lastError = tostring(moved); return 0, true end
    return moved, true
end

-- Turtle slot -> inventory (any free slot). Returns moved.
function T.fromTurtle(tslot, n, inv)
    local count = turtle.getItemCount(tslot)
    n = math.min(n or count, count)
    if n <= 0 then return 0 end
    if T.net and not SIDES[inv] then
        local ok, moved = pcall(peripheral.call, inv, "pullItems", T.net, tslot, n)
        return (ok and type(moved) == "number") and moved or 0
    end
    local drop = DROP[inv]
    if not drop then return 0 end
    local prev = turtle.getSelectedSlot()
    turtle.select(tslot)
    turtle[drop](n)
    turtle.select(prev)
    return count - turtle.getItemCount(tslot)
end

-- A turtle slot that can take `name`: one holding it with room, else an empty one.
local function turtleSlotFor(name, avoid)
    for s = 1, 16 do
        if not (avoid and avoid[s]) then
            local d = turtle.getItemDetail(s)
            if d and d.name == name and turtle.getItemSpace(s) > 0 then return s end
        end
    end
    for s = 1, 16 do
        if not (avoid and avoid[s]) and turtle.getItemCount(s) == 0 then return s end
    end
end

-- Pull up to n of `name` from `lists` into the turtle. Keeps `lists` roughly current.
local function fetchToTurtle(lists, name, n, tslot)
    local got, zeros, guard = 0, 0, 0
    while got < n and zeros < 3 and guard < 200 do
        guard = guard + 1
        local stacks = stacksOf(lists, name)
        if #stacks == 0 then break end
        local slot = tslot or turtleSlotFor(name)
        if not slot then break end
        local st = stacks[1]
        local moved, relayout = T.toTurtle(st.inv, st.slot, n - got, slot)
        if relayout then
            lists[st.inv] = listOf(st.inv)
        else
            st.item.count = st.item.count - moved
            if st.item.count <= 0 or moved == 0 then lists[st.inv][st.slot] = nil end
        end
        if moved > 0 then zeros = 0 else zeros = zeros + 1 end
        got = got + moved
        if tslot and turtle.getItemSpace(tslot) == 0 then break end
    end
    return got
end

-- Empty every turtle slot into `invs`. Adds what moved to `record` (name -> count).
-- Returns the slots that could not be emptied.
local function stashAll(invs, record)
    local stuck = {}
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d then
            for _, inv in ipairs(invs) do
                T.fromTurtle(s, d.count, inv)
                if turtle.getItemCount(s) == 0 then break end
            end
            local left = turtle.getItemCount(s)
            if record and d.count > left then record[d.name] = (record[d.name] or 0) + d.count - left end
            if left > 0 then stuck[#stuck + 1] = s end
        end
    end
    return stuck
end

local function reachableInventories()
    local invs, unreachable = {}, {}
    for _, n in ipairs(M.inventories()) do
        if T.reachable(n) then invs[#invs + 1] = n else unreachable[#unreachable + 1] = n end
    end
    -- Network storage first; adjacent chests (slot juggling) last.
    table.sort(invs, function(a, b)
        local sa, sb = SIDES[a] and 1 or 0, SIDES[b] and 1 or 0
        if sa ~= sb then return sa < sb end
        return a < b
    end)
    return invs, unreachable
end

----------------------------------------------------------------------
-- find_item
----------------------------------------------------------------------
local function summarise(hits, maxItems)
    local byName, order, total = {}, {}, 0
    for _, h in ipairs(hits) do
        local e = byName[h.name]
        if not e then
            e = {name = h.name, total = 0, locs = {}, locOrder = {}}
            byName[h.name] = e
            order[#order + 1] = e
        end
        e.total = e.total + h.count
        total = total + h.count
        local l = e.locs[h.inv]
        if not l then
            l = {inventory = h.inv, count = 0, slots = {}}
            e.locs[h.inv] = l
            e.locOrder[#e.locOrder + 1] = l
        end
        l.count = l.count + h.count
        l.slots[#l.slots + 1] = h.slot
        maybeYield(500)
    end
    table.sort(order, function(a, b) return a.total > b.total end)
    local items = {}
    for i = 1, math.min(#order, maxItems) do
        local e = order[i]
        table.sort(e.locOrder, function(a, b) return a.count > b.count end)
        local locs = {}
        for j = 1, math.min(#e.locOrder, MAX_LOCS) do
            local l = e.locOrder[j]
            table.sort(l.slots)
            local slots = {}
            for k = 1, math.min(#l.slots, MAX_SLOTS) do slots[k] = l.slots[k] end
            local entry = {inventory = l.inventory, count = l.count, slots = slots}
            if #l.slots > MAX_SLOTS then entry.more_slots = #l.slots - MAX_SLOTS end
            locs[#locs + 1] = entry
        end
        local item = {name = e.name, total = e.total, locations = locs}
        if #e.locOrder > MAX_LOCS then item.more_locations = #e.locOrder - MAX_LOCS end
        items[#items + 1] = item
    end
    return items, total, math.max(0, #order - maxItems)
end

function H.find_item(input)
    local m = matcher(input.query or input.item)
    local maxItems = clampInt(input.limit, 1, 30, MAX_ITEMS)
    local names = M.inventories()
    if #names == 0 and not turtle then
        return {error = "No inventories found. Attach chests directly or through wired modems."}
    end
    local lists, failed = scan(names)
    if turtle then lists[TURTLE] = turtleList() end

    local details, capped
    if m.tag then details, capped = fetchDetails(lists) end
    local hits = collect(lists, m, details, false)
    local byDisplay = false
    if #hits == 0 and m.sub then
        details, capped = fetchDetails(lists)
        hits = collect(lists, m, details, true)
        byDisplay = #hits > 0
    end

    local items, total, more = summarise(hits, maxItems)
    local r = {query = m.label, inventories_scanned = #names, total = total, items = items}
    if turtle then r.note = "'turtle' is this turtle's own inventory" end
    if more > 0 then r.more_items = more end
    if byDisplay then r.matched_by = "display name" end
    if capped then r.detail_lookups_capped = true end
    if #failed > 0 then
        r.failed = {}
        for i = 1, math.min(#failed, MAX_FAILED) do r.failed[i] = failed[i] end
    end
    if m.any then
        -- Storage overview: slot usage across every inventory.
        local sizes, fns = {}, {}
        for _, n in ipairs(names) do
            fns[#fns + 1] = function()
                local ok, s = pcall(peripheral.call, n, "size")
                if ok and type(s) == "number" then sizes[n] = s end
            end
        end
        runParallel(fns)
        local slots, used = 0, 0
        for n, s in pairs(sizes) do
            slots = slots + s
            for _ in pairs(lists[n] or {}) do used = used + 1 end
        end
        r.slots_total, r.slots_used, r.slots_free = slots, used, slots - used
    end
    if #hits == 0 then
        r.hint = "Nothing matched. Try a shorter partial name, a full id (minecraft:oak_log) or a tag (#minecraft:logs)."
    end
    return r
end

----------------------------------------------------------------------
-- move_items
----------------------------------------------------------------------
local function isSelf(n) return n == TURTLE or n == "self" end

function H.move_items(input)
    local from, to = input.from, input.to
    if type(from) ~= "string" or type(to) ~= "string" then return {error = "from and to are required"} end
    if from == to or (isSelf(from) and isSelf(to)) then return {error = "from and to must be different"} end
    local m = matcher(input.item)
    local want = input.count ~= nil and clampInt(input.count, 0, 1000000, 0) or math.huge
    if want == 0 then return {moved = 0} end
    local toSlot = input.to_slot ~= nil and clampInt(input.to_slot, 1, 1000000, 1) or nil
    T.lastError = nil

    local function check(n)
        if isSelf(n) then return (not turtle) and "This computer is not a turtle" or nil end
        if not peripheral.isPresent(n) then return "No peripheral named '" .. n .. "'" end
        if not isInventory(n) then return "'" .. n .. "' is not an inventory" end
    end
    local e = check(from) or check(to)
    if e then return {error = e} end
    if isSelf(from) or isSelf(to) then
        T.init()
        local other = isSelf(from) and to or from
        if not T.reachable(other) then return {error = reachHint(other)} end
    end

    local srcName = isSelf(from) and TURTLE or from
    local lists = {[srcName] = isSelf(from) and turtleList() or listOf(from)}
    local details = m.tag and fetchDetails(lists) or nil

    local function nextStack(skip)
        local best
        for slot, it in pairs(lists[srcName]) do
            if not skip[slot] and it.count > 0 and matches(m, it.name, details, false) then
                if not best or slot < best.slot then best = {slot = slot, item = it} end
            end
        end
        return best
    end

    local moved, err, zeros, skip = 0, nil, 0, {}
    while moved < want and zeros < 3 do
        local st = nextStack(skip)
        if not st then break end
        local n = math.min(st.item.count, want - moved)
        local got, relayout = 0, false
        if isSelf(from) then
            got = T.fromTurtle(st.slot, n, to)
        elseif isSelf(to) then
            local tslot = toSlot or turtleSlotFor(st.item.name)
            if not tslot then err = "The turtle inventory is full"; break end
            got, relayout = T.toTurtle(from, st.slot, n, tslot)
        else
            local ok, r = pcall(peripheral.call, from, "pushItems", to, st.slot, n, toSlot)
            if not ok then err = tostring(r); break end
            got = type(r) == "number" and r or 0
        end
        if relayout then
            lists[srcName] = listOf(from)
            skip = {}
        else
            st.item.count = st.item.count - got
            if got == 0 then skip[st.slot] = true end
        end
        if got > 0 then zeros = 0 else zeros = zeros + 1 end
        moved = moved + got
    end

    local left = 0
    for _, it in pairs(isSelf(from) and turtleList() or listOf(from)) do
        if matches(m, it.name, details, false) then left = left + it.count end
    end
    local r = {moved = moved, from = from, to = to, item = m.label, left_in_source = left}
    if err then r.error = err
    elseif T.lastError then r.error = T.lastError; T.lastError = nil
    elseif moved == 0 and left == 0 then r.error = "No matching items in " .. from
    elseif moved < want and want ~= math.huge then r.note = "Destination full or not enough items"
    elseif moved == 0 then r.note = "Nothing moved: destination full?" end
    return r
end

----------------------------------------------------------------------
-- sort_storage
----------------------------------------------------------------------
function H.sort_storage(input)
    local all = M.inventories()
    local scope = all
    if type(input.inventories) == "table" and #input.inventories > 0 then
        local wanted = {}
        for _, n in ipairs(input.inventories) do wanted[n] = true end
        scope = {}
        for _, n in ipairs(all) do if wanted[n] then scope[#scope + 1] = n end end
    end
    if #scope == 0 then return {error = "No inventories to sort"} end
    local maxMoves = clampInt(input.max_moves, 1, 2000, 300)
    local moves = 0
    local lists = scan(scope)
    local report = {inventories = #scope}

    -- 1. Route items by rule: {match = "iron" | "minecraft:cobblestone" | "#c:ores", to = "minecraft:chest_3"}
    local rules = type(input.rules) == "table" and input.rules or {}
    if #rules > 0 then
        local details
        local routed = {}
        for i = 1, math.min(#rules, 20) do
            local rule = rules[i]
            local m = matcher(rule.match)
            local dest = rule.to
            local entry = {match = m.label, to = tostring(dest), moved = 0}
            if m.any then
                entry.error = "match is required"
            elseif type(dest) ~= "string" or not peripheral.isPresent(dest) or not isInventory(dest) then
                entry.error = "destination is not an inventory"
            else
                if m.tag and not details then details = fetchDetails(lists) end
                local tasks = {}
                for _, inv in ipairs(scope) do
                    if inv ~= dest and lists[inv] then
                        for slot, it in pairs(lists[inv]) do
                            if matches(m, it.name, details, false) then tasks[#tasks + 1] = {inv = inv, slot = slot} end
                        end
                    end
                end
                local full, k = false, 1
                while k <= #tasks and not full and moves < maxMoves do
                    local stop = math.min(#tasks, k + BATCH - 1, k + (maxMoves - moves) - 1)
                    local fns = {}
                    for t = k, stop do
                        local task = tasks[t]
                        fns[#fns + 1] = function()
                            local ok, n = pcall(peripheral.call, task.inv, "pushItems", dest, task.slot)
                            if ok and type(n) == "number" then
                                entry.moved = entry.moved + n
                                if n == 0 then full = true end
                            else
                                entry.error = tostring(n)
                                full = true
                            end
                        end
                    end
                    runParallel(fns)
                    moves = moves + #fns
                    k = stop + 1
                end
                if full and not entry.error then entry.note = "destination full" end
                if k <= #tasks then entry.stacks_left = #tasks - k + 1 end
            end
            routed[#routed + 1] = entry
        end
        report.routed = routed
        lists = scan(scope)
    end

    -- 2. Merge partial stacks of the same item inside each inventory.
    if input.consolidate ~= false then
        local merged, fns = 0, {}
        for inv, items in pairs(lists) do
            fns[#fns + 1] = function()
                local groups = {}
                for slot, it in pairs(items) do
                    local key = it.name .. "|" .. tostring(it.nbt or "")
                    groups[key] = groups[key] or {}
                    table.insert(groups[key], {slot = slot, count = it.count})
                end
                for _, g in pairs(groups) do
                    -- Guess the stack size from the biggest stack: 64/16/1 means those are full.
                    local biggest = 0
                    for _, s in ipairs(g) do if s.count > biggest then biggest = s.count end end
                    local cap = (biggest == 64 or biggest == 16 or biggest == 1) and biggest or 64
                    local partial = {}
                    for _, s in ipairs(g) do if s.count < cap then partial[#partial + 1] = s end end
                    if #partial > 1 then
                        table.sort(partial, function(a, b) return a.slot < b.slot end)
                        local i, j = 1, #partial
                        while i < j and moves < maxMoves do
                            local src, dst = partial[j], partial[i]
                            local ok, n = pcall(peripheral.call, inv, "pushItems", inv, src.slot, src.count, dst.slot)
                            moves = moves + 1
                            n = (ok and type(n) == "number") and n or 0
                            src.count = src.count - n
                            dst.count = dst.count + n
                            if src.count <= 0 then j = j - 1; merged = merged + 1 end
                            if n == 0 or src.count > 0 then i = i + 1 end
                        end
                    end
                end
            end
        end
        runParallel(fns)
        report.stacks_merged = merged
    end

    report.moves = moves
    if moves >= maxMoves then report.truncated = "Hit max_moves; run again to continue" end
    return report
end

----------------------------------------------------------------------
-- fluid_tanks
----------------------------------------------------------------------
function H.fluid_tanks(input)
    local action = input.action or ((input.from or input.to) and "move") or "list"
    if action == "move" then
        if type(input.from) ~= "string" or type(input.to) ~= "string" then
            return {error = "from and to are required"}
        end
        local fluid = input.fluid and norm(input.fluid) or nil
        if fluid == "" then fluid = nil end
        if fluid and not fluid:find(":", 1, true) then fluid = "minecraft:" .. fluid end
        local amount = input.amount ~= nil and clampInt(input.amount, 1, 2 ^ 31 - 1, 1000) or nil
        local ok, moved = pcall(peripheral.call, input.from, "pushFluid", input.to, amount, fluid)
        if not ok then return {error = tostring(moved)} end
        return {success = (moved or 0) > 0, moved_mb = moved or 0, from = input.from, to = input.to, fluid = fluid}
    elseif action ~= "list" then
        return {error = "action must be list or move"}
    end

    local names = {}
    for _, n in ipairs(peripheral.getNames()) do
        if hasType(n, "fluid_storage") then names[#names + 1] = n end
    end
    table.sort(names)
    if #names == 0 then return {error = "No fluid storage found (tanks, cauldrons and the like on a modem or side)"} end
    local q = input.fluid and norm(input.fluid) or nil
    if q == "" then q = nil end
    local results, fns = {}, {}
    for i, n in ipairs(names) do
        fns[#fns + 1] = function()
            local ok, t = pcall(peripheral.call, n, "tanks")
            results[i] = (ok and type(t) == "table") and t or false
        end
    end
    runParallel(fns)

    local out, totals = {}, {}
    for i, n in ipairs(names) do
        local tanks = results[i]
        if tanks then
            local fl = {}
            for _, tank in pairs(tanks) do
                if type(tank) == "table" and tank.name and (not q or tank.name:find(q, 1, true)) then
                    fl[#fl + 1] = {fluid = tank.name, mb = tank.amount}
                    totals[tank.name] = (totals[tank.name] or 0) + (tank.amount or 0)
                end
            end
            if (#fl > 0 or not q) and #out < 20 then out[#out + 1] = {name = n, fluids = fl} end
        end
    end
    local tl = {}
    for k, v in pairs(totals) do tl[#tl + 1] = {fluid = k, mb = v} end
    table.sort(tl, function(a, b) return a.mb > b.mb end)
    return {tanks = out, totals = tl, fluid_peripherals = #names}
end

----------------------------------------------------------------------
-- turtle_craft
----------------------------------------------------------------------
local function craftFunction()
    if turtle.craft then return turtle.craft end
    for _, side in ipairs({"left", "right"}) do
        if peripheral.getType(side) == "workbench" then
            return function(n) return peripheral.call(side, "craft", n) end
        end
    end
end

local function loadCraftingRecipes(item)
    local ok, json = pcall(claude.getRecipes, item, "crafting", 50, 0)
    if not ok then return nil, tostring(json) end
    local ok2, data = pcall(textutils.unserialiseJSON, json)
    if not ok2 or type(data) ~= "table" then return nil, "Could not parse recipe data" end
    if data.error then return nil, data.error end
    return data.recipes or {}
end

-- Turtle slots for a recipe, plus ingredient groups (identical ingredient sets).
local function planFor(r)
    local slots = {}
    local ings = r.ingredients or {}
    if r.width then
        if type(r.grid) ~= "table" or r.width > 3 or (r.height or 0) > 3 then return nil end
        for idx, k in ipairs(r.grid) do
            if k > 0 and ings[k] then
                local row, col = math.floor((idx - 1) / r.width), (idx - 1) % r.width
                slots[#slots + 1] = {slot = row * 4 + col + 1, alts = ings[k]}
            end
        end
    else
        if #ings > 9 then return nil end
        for i, alts in ipairs(ings) do slots[#slots + 1] = {slot = GRID[i], alts = alts} end
    end
    if #slots == 0 then return nil end
    local groups, byKey = {}, {}
    for _, s in ipairs(slots) do
        local key = table.concat(s.alts, ",")
        local g = byKey[key]
        if not g then
            g = {alts = s.alts, n = 0}
            byKey[key] = g
            groups[#groups + 1] = g
        end
        g.n = g.n + 1
        s.group = g
    end
    -- Most specific ingredients claim their items first.
    table.sort(groups, function(a, b) return #a.alts < #b.alts end)
    return slots, groups
end

-- What is short for `crafts` crafts, reserving items from a copy of `avail`.
local function shortfalls(groups, avail, crafts)
    local pool = {}
    for k, v in pairs(avail) do pool[k] = v end
    local missing = {}
    for _, g in ipairs(groups) do
        local need = g.n * crafts
        local have = 0
        for _, a in ipairs(g.alts) do have = have + (pool[a] or 0) end
        if have < need then
            local m = {item = g.alts[1], need = need, have = have}
            if #g.alts > 1 then m.or_alternatives = #g.alts - 1 end
            missing[#missing + 1] = m
        end
        local order = {table.unpack(g.alts)}
        table.sort(order, function(a, b) return (pool[a] or 0) > (pool[b] or 0) end)
        local rem = need
        for _, a in ipairs(order) do
            if rem <= 0 then break end
            local take = math.min(rem, pool[a] or 0)
            pool[a] = (pool[a] or 0) - take
            rem = rem - take
        end
    end
    return missing
end

local function maxCrafts(groups, avail, upTo)
    local lo, hi = 0, upTo
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if #shortfalls(groups, avail, mid) == 0 then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- Put n items for grid slot s into the turtle. One item type per slot. Returns count placed.
local function fillSlot(lists, s, n)
    local g = s.group
    local av = availability(lists)
    local order = {}
    for _, a in ipairs(g.alts) do
        if (av[a] or 0) > 0 then order[#order + 1] = a end
    end
    -- Prefer an item that can fill the whole slot (the one used last time first), then the most plentiful.
    local function score(a) return (av[a] >= n and 2 or 0) + (a == g.chosen and 1 or 0) end
    table.sort(order, function(a, b)
        local sa, sb = score(a), score(b)
        if sa ~= sb then return sa > sb end
        if av[a] ~= av[b] then return av[a] > av[b] end
        return a < b
    end)
    for _, name in ipairs(order) do
        local have = fetchToTurtle(lists, name, n, s.slot)
        if have > 0 then
            g.chosen = name
            return have
        end
    end
    return 0
end

local function mapToList(t)
    local out = {}
    for k, v in pairs(t) do out[#out + 1] = {item = k, count = v} end
    table.sort(out, function(a, b) return a.item < b.item end)
    return out
end

local function runCraft(plan, target, invs, craft, keep)
    local stashed = {}
    local stuck = stashAll(invs, stashed)
    if #stuck > 0 then
        return {success = false, error = "Storage is full: could not clear turtle slots " .. table.concat(stuck, ","),
            stashed = mapToList(stashed)}
    end
    local lists = scan(invs)

    -- Crafts per batch: 64 per grid slot, and the results must fit in the non-grid slots.
    local free = 16 - #plan.slots
    local perBatch = math.max(1, math.min(64, math.floor(free * (plan.r.result_max_stack or 64) / plan.rc)))

    local remaining, crafted, batches, problem = plan.crafts, 0, 0, nil
    while remaining > 0 do
        local placed = math.min(remaining, perBatch)
        for _, s in ipairs(plan.slots) do
            local got = fillSlot(lists, s, placed)
            if got < placed then placed = got end
            if placed == 0 then break end
        end
        if placed == 0 then
            problem = T.lastError or "Could not move ingredients into the turtle"
            T.lastError = nil
            break
        end
        turtle.select(16) -- never a grid slot
        local ok, err = craft(placed)
        if not ok then problem = "turtle.craft failed: " .. tostring(err); break end
        batches = batches + 1
        remaining = remaining - placed
        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d and d.name == target then crafted = crafted + d.count end
        end
        local stuck2 = stashAll(invs)
        if #stuck2 > 0 then problem = "Storage full: items left in turtle slots " .. table.concat(stuck2, ","); break end
        if remaining > 0 then lists = scan(invs) end
    end
    if problem then stashAll(invs) end

    -- Give back what the turtle was holding, and the results if asked to keep them.
    local restored, kept = {}, nil
    if next(stashed) or (keep and crafted > 0) then
        lists = scan(invs)
        for name, n in pairs(stashed) do
            local got = fetchToTurtle(lists, name, n)
            local e = {item = name, count = got}
            if got < n then e.left_in_storage = n - got end
            restored[#restored + 1] = e
        end
        if keep and crafted > 0 then kept = fetchToTurtle(lists, target, crafted) end
    end

    local res = {success = crafted > 0 and not problem, item = target, crafted = crafted, batches = batches,
        recipe = plan.r.id}
    if problem then res.error = problem end
    if keep then res.kept_in_turtle = kept or 0 elseif crafted > 0 then res.stored_in = "storage" end
    if #restored > 0 then res.restored_to_turtle = restored end
    return res
end

function H.turtle_craft(input)
    if not turtle then return {error = "Not a turtle"} end
    local craft = craftFunction()
    if not craft then
        return {error = "No crafting table equipped. Run turtle_equip with action=equip, item=minecraft:crafting_table first."}
    end
    local item = norm(input.item)
    if item == "" then return {error = "item is required"} end
    local want = clampInt(input.count, 1, 1024, 1)

    local recipes, err = loadCraftingRecipes(item)
    if not recipes then return {error = err} end
    local candidates, results = {}, {}
    for _, r in ipairs(recipes) do
        if r.type == "minecraft:crafting" and (r.result == item or r.result:match(":(.+)$") == item) then
            candidates[#candidates + 1] = r
            results[r.result] = true
        end
    end
    if #candidates == 0 then
        local similar, seen = {}, {}
        for _, r in ipairs(recipes) do
            if not seen[r.result] and #similar < 8 then seen[r.result] = true; similar[#similar + 1] = r.result end
        end
        return {error = "No crafting-table recipe makes " .. item, similar = #similar > 0 and similar or nil}
    end
    local distinct = {}
    for k in pairs(results) do distinct[#distinct + 1] = k end
    if #distinct > 1 then
        table.sort(distinct)
        return {error = "Several items match '" .. item .. "'. Use the full id.", candidates = distinct}
    end
    local target = distinct[1]

    T.init()
    local invs, unreachable = reachableInventories()
    if #invs == 0 then
        local hint = reachHint(unreachable[1])
        return {error = "turtle_craft needs storage the turtle can move items with. " .. hint}
    end
    local avail = availability(scan(invs))
    for _, it in pairs(turtleList()) do avail[it.name] = (avail[it.name] or 0) + it.count end

    local chosen, best
    for _, r in ipairs(candidates) do
        local slots, groups = planFor(r)
        if slots then
            local rc = math.max(1, r.result_count or 1)
            local crafts = math.ceil(want / rc)
            local missing = shortfalls(groups, avail, crafts)
            if #missing == 0 then
                chosen = {r = r, slots = slots, groups = groups, crafts = crafts, rc = rc}
                break
            end
            local mx = maxCrafts(groups, avail, crafts)
            if not best or mx > best.max then best = {r = r, missing = missing, max = mx, rc = rc} end
        end
    end
    if not chosen then
        if not best then return {error = "No recipe for " .. target .. " fits a turtle's 3x3 grid"} end
        local res = {success = false, error = "Missing ingredients for " .. want .. " x " .. target,
            recipe = best.r.id, missing = best.missing, inventories_searched = #invs}
        if best.max > 0 then
            res.can_make = best.max * best.rc
            res.hint = "Enough for " .. res.can_make .. ". Retry with that count, or get the missing items first."
        else
            res.hint = "Use get_recipes on a missing item to see if it can be crafted first."
        end
        if #unreachable > 0 then res.unreachable_inventories = #unreachable end
        return res
    end

    if input.check_only then
        local uses = {}
        for _, g in ipairs(chosen.groups) do
            local u = {item = g.alts[1], count = g.n * chosen.crafts}
            if #g.alts > 1 then u.or_alternatives = #g.alts - 1 end
            uses[#uses + 1] = u
        end
        return {success = true, check_only = true, item = target, recipe = chosen.r.id, crafts = chosen.crafts,
            will_make = chosen.crafts * chosen.rc, uses = uses}
    end

    local prevSel = turtle.getSelectedSlot()
    local ok, res = pcall(runCraft, chosen, target, invs, craft, input.keep == true)
    turtle.select(prevSel)
    if not ok then return {error = "Crafting stopped: " .. tostring(res)} end
    return res
end

----------------------------------------------------------------------
-- turtle_equip
----------------------------------------------------------------------
-- What is on a side. turtle.getEquippedLeft/Right exist from CC:Tweaked 1.116.0 and see
-- every upgrade. Older versions only reveal peripheral upgrades (modem, workbench, ...).
local function equippedName(side)
    local fn = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if fn then
        local ok, d = pcall(fn)
        if ok then return type(d) == "table" and d.name or nil end
    end
    local t = peripheral.getType(side)
    return t and ("peripheral:" .. t) or nil
end

function H.turtle_equip(input)
    if not turtle then return {error = "Not a turtle"} end
    local action = input.action or (input.item and "equip") or "status"
    if action == "status" then
        local r = {left = equippedName("left") or "empty", right = equippedName("right") or "empty",
            can_craft = craftFunction() ~= nil}
        if not turtle.getEquippedLeft then r.note = "Old CC:Tweaked: only peripheral upgrades are visible" end
        return r
    end
    local side = input.side
    if side ~= "left" and side ~= "right" then return {error = "side must be 'left' or 'right'"} end
    local equip = side == "left" and turtle.equipLeft or turtle.equipRight
    local prev = turtle.getSelectedSlot()

    if action == "unequip" then
        local before = equippedName(side)
        if not before then return {error = "Nothing equipped on the " .. side} end
        local slot
        for s = 1, 16 do
            if turtle.getItemCount(s) == 0 then slot = s; break end
        end
        if not slot then return {error = "No empty turtle slot to unequip into"} end
        turtle.select(slot)
        local ok, err = equip()
        turtle.select(prev)
        local d = turtle.getItemDetail(slot)
        local r = {success = ok and d ~= nil, side = side, removed = d and d.name or before, slot = d and slot or nil}
        if not ok then r.error = err end
        if ok and d and input.store then
            T.init()
            for _, inv in ipairs((reachableInventories())) do
                T.fromTurtle(slot, d.count, inv)
                if turtle.getItemCount(slot) == 0 then r.stored_in = inv; r.slot = nil; break end
            end
        end
        return r
    elseif action ~= "equip" then
        return {error = "action must be status, equip or unequip"}
    end

    local m = matcher(input.item)
    if m.any or m.tag then return {error = "item must be an item id or name, e.g. minecraft:diamond_pickaxe"} end
    local slot, fetched
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and matchName(m, d.name) then slot = s; break end
    end
    if not slot then
        T.init()
        local invs = reachableInventories()
        local lists = scan(invs)
        local hits = collect(lists, m, nil, false)
        if #hits > 0 then
            local tslot = turtleSlotFor(hits[1].name)
            if tslot and fetchToTurtle(lists, hits[1].name, 1, tslot) > 0 then
                slot, fetched = tslot, hits[1].inv
            end
        end
    end
    if not slot then return {error = "No " .. m.label .. " in the turtle or in storage it can reach"} end

    local before = equippedName(side)
    turtle.select(slot)
    local ok, err = equip()
    turtle.select(prev)
    local r = {success = ok, side = side, equipped = equippedName(side), fetched_from = fetched}
    if not ok then r.error = err end
    if ok and before then r.previous = before .. " (now in the turtle inventory)" end
    return r
end

----------------------------------------------------------------------
-- TOOL SCHEMAS
----------------------------------------------------------------------
local ITEM_HELP = "full id 'minecraft:iron_ingot' (exact), partial name 'iron' (id contains it), or tag '#minecraft:logs'"

function M.getDefs()
    local d = {
        {name = "find_item",
            description = "Live search of every inventory on the wired network or next to this computer (and the turtle's own slots) for an item. Returns totals and where it is (inventory name + slots), capped. query '*' gives a storage overview with free slots.",
            input_schema = {type = "object", properties = {
                query = {type = "string", description = ITEM_HELP .. ", or '*'"},
                limit = {type = "number", description = "Max distinct items (default 12, max 30)"},
            }, required = {"query"}}},
        {name = "move_items",
            description = "Move items between two inventories by peripheral name (from find_item). Use 'turtle' for this turtle's own inventory. Returns how many actually moved.",
            input_schema = {type = "object", properties = {
                from = {type = "string", description = "Source inventory name, or 'turtle'"},
                to = {type = "string", description = "Destination inventory name, or 'turtle'"},
                item = {type = "string", description = "Filter: " .. ITEM_HELP .. ". Omit to move everything."},
                count = {type = "number", description = "Max items to move. Omit for all matching."},
                to_slot = {type = "number", description = "Optional destination slot"},
            }, required = {"from", "to"}}},
        {name = "sort_storage",
            description = "Tidy storage: route items to chosen inventories by rules, then merge partial stacks inside each inventory.",
            input_schema = {type = "object", properties = {
                rules = {type = "array", description = "Routing rules, applied in order",
                    items = {type = "object", properties = {
                        match = {type = "string", description = ITEM_HELP},
                        to = {type = "string", description = "Destination inventory name"},
                    }, required = {"match", "to"}}},
                inventories = {type = "array", description = "Only touch these inventories (default: all)", items = {type = "string"}},
                consolidate = {type = "boolean", description = "Merge partial stacks (default true)"},
                max_moves = {type = "number", description = "Transfer budget (default 300)"},
            }}},
        {name = "fluid_tanks",
            description = "List fluids in tanks on the network/sides (action=list), or pump fluid between two of them (action=move).",
            input_schema = {type = "object", properties = {
                action = {type = "string", description = "list (default) or move"},
                fluid = {type = "string", description = "Fluid filter for list, or the fluid to move, e.g. minecraft:water"},
                from = {type = "string"}, to = {type = "string"},
                amount = {type = "number", description = "mB to move (default: as much as fits)"},
            }}},
    }
    if turtle then
        d[#d + 1] = {name = "turtle_craft",
            description = "Craft on a crafty turtle (crafting table equipped). Looks up the recipe, pulls ingredients from reachable storage into the grid, crafts, and puts results back in storage. Reports missing ingredients without crafting anything. Storage must be a chest in front/above/below, or the wired network via a connected modem next to the turtle. Anything already in the turtle is moved out first and given back afterwards.",
            input_schema = {type = "object", properties = {
                item = {type = "string", description = "Item to craft, e.g. 'minecraft:chest' or 'torch'"},
                count = {type = "number", description = "How many items you want (default 1)"},
                keep = {type = "boolean", description = "Leave the results in the turtle instead of storage"},
                check_only = {type = "boolean", description = "Only check ingredients, craft nothing"},
            }, required = {"item"}}}
        d[#d + 1] = {name = "turtle_equip",
            description = "Show, equip or unequip turtle upgrades (pickaxe, crafting table, modem...). equip takes the item from the turtle inventory, or fetches it from reachable storage.",
            input_schema = {type = "object", properties = {
                action = {type = "string", description = "status (default), equip, or unequip"},
                side = {type = "string", description = "left or right"},
                item = {type = "string", description = "Item to equip, e.g. minecraft:crafting_table"},
                store = {type = "boolean", description = "unequip: put the removed upgrade into storage"},
            }}}
    end
    return d
end

return M
