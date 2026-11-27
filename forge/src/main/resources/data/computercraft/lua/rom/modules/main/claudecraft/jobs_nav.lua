-- claudecraft.jobs_nav - position-tracked turtle movement for background jobs,
-- plus the refuel / unload / inventory helpers shared by the job templates.
--
-- Coordinates are relative to the job's home (where the turtle stood when the
-- job started): home is (0,0,0) facing f=0. +z is the starting facing, +x is
-- to its right, +y is up. f: 0=+z, 1=+x, 2=-z, 3=-x (turnRight adds 1).
--
-- Every move writes a "pending" marker (with the fuel level) to the job's
-- checkpoint before it starts and clears it once it's done, so after a reboot
-- reconcile() can tell from the fuel level whether the last move happened.

local M = {}

local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
M.DX, M.DZ = DX, DZ

local DIG = { forward = "dig", up = "digUp", down = "digDown" }
local DETECT = { forward = "detect", up = "detectUp", down = "detectDown" }
local ATTACK = { forward = "attack", up = "attackUp", down = "attackDown" }
local INSPECT = { forward = "inspect", up = "inspectUp", down = "inspectDown" }
local MOVES = { forward = true, back = true, up = true, down = true }

local function reverse(s)
    return (s or ""):reverse()
end

--- Create a navigator bound to job api `J` (uses J.turtle, J.save, J.sleep,
-- J.log) persisting into table `st` (the job record's `nav` field).
function M.new(J, st)
    local T = J.turtle
    st.x, st.y, st.z, st.f = st.x or 0, st.y or 0, st.z or 0, st.f or 0
    local nav = setmetatable({}, { __index = st })

    local function apply(op)
        if op == "forward" then st.x = st.x + DX[st.f]; st.z = st.z + DZ[st.f]
        elseif op == "back" then st.x = st.x - DX[st.f]; st.z = st.z - DZ[st.f]
        elseif op == "up" then st.y = st.y + 1
        elseif op == "down" then st.y = st.y - 1
        elseif op == "turnRight" then st.f = (st.f + 1) % 4
        elseif op == "turnLeft" then st.f = (st.f + 3) % 4
        end
    end

    -- One attempt at a single turtle movement, checkpointed before and after.
    local function raw(op)
        local fuel = T.getFuelLevel()
        st.pending = { op = op, fuel = type(fuel) == "number" and fuel or nil }
        J.save()
        local ok, err = T[op]()
        st.pending = nil
        if ok then apply(op); J.save() end
        return ok, err
    end

    -- Move with retries. dig=true digs blocks in the way (and attacks mobs
    -- unless the route says attack=false); dig=false only waits for mobs to
    -- wander off. Returns ok, err, kind where kind is "unbreakable",
    -- "obstructed", "fuel" or "blocked".
    local function move(op, dig)
        if op == "back" then
            local ok, err = raw("back")
            if ok then return true end
            if err and err:lower():find("fuel") then return false, err, "fuel" end
            -- Something behind us: turn round and go forward instead.
            nav.turnRight(); nav.turnRight()
            local ok2, err2, kind = move("forward", dig)
            nav.turnRight(); nav.turnRight()
            return ok2, err2, kind
        end
        local waits = 0
        for _ = 1, 400 do
            local ok, err = raw(op)
            if ok then return true end
            if err and err:lower():find("fuel") then return false, err, "fuel" end
            if T[DETECT[op]]() then
                if not dig then return false, "obstructed", "obstructed" end
                if not T[DIG[op]]() then
                    local _, info = T[INSPECT[op]]()
                    local what = type(info) == "table" and info.name or "block"
                    return false, "cannot dig " .. what, "unbreakable"
                end
            elseif not (dig and st.attack ~= false and T[ATTACK[op]]()) then
                -- A mob or player in the way (or a liquid we can't enter yet).
                waits = waits + 1
                if waits > 240 then return false, "blocked for 2 minutes", "blocked" end
                J.sleep(0.5)
            end
        end
        return false, "blocked", "blocked"
    end

    function nav.forward(dig) return move("forward", dig) end
    function nav.back(dig) return move("back", dig) end
    function nav.up(dig) return move("up", dig) end
    function nav.down(dig) return move("down", dig) end
    function nav.turnRight() return raw("turnRight") end
    function nav.turnLeft() return raw("turnLeft") end

    function nav.face(f)
        f = f % 4
        local diff = (f - st.f) % 4
        if diff == 1 then nav.turnRight()
        elseif diff == 2 then nav.turnRight(); nav.turnRight()
        elseif diff == 3 then nav.turnLeft()
        end
    end

    function nav.distHome()
        return math.abs(st.x) + math.abs(st.y) + math.abs(st.z)
    end

    function nav.atHome()
        return st.x == 0 and st.y == 0 and st.z == 0
    end

    --- At home the output chest is at (0,0,-1), so the side it shows up on
    -- gives the real facing. Fixes the facing if a reboot mid-turn left it
    -- wrong (turns, unlike moves, can't be verified from the fuel level).
    function nav.calibrate()
        if not nav.atHome() then return end
        local found
        for side, f in pairs({ back = 0, right = 1, front = 2, left = 3 }) do
            if M.hasInventory(side) then
                if found then return end -- several inventories: can't tell
                found = f
            end
        end
        if found and found ~= st.f then
            J.log(("facing corrected at home (%d -> %d)"):format(st.f, found))
            st.f = found
            J.save()
        end
    end

    --- Set the route used to leave home ("xzy" = along x, then z, then y),
    -- whether moves may dig, and whether digging moves may attack mobs in
    -- the way (default true). goHome() retraces the route in reverse order.
    function nav.setRoute(order, dig, attack)
        st.order, st.dig, st.attack = order, dig and true or false, attack ~= false
        J.save()
    end

    --- Travel to (x,y,z) one axis at a time in `order` (default: the route
    -- order). Returns ok, err, kind.
    function nav.goTo(x, y, z, order, dig)
        order = order or st.order or "xzy"
        if dig == nil then dig = st.dig end
        for axis in order:gmatch("[xyz]") do
            if axis == "y" then
                while st.y < y do local ok, e, k = move("up", dig); if not ok then return false, e, k end end
                while st.y > y do local ok, e, k = move("down", dig); if not ok then return false, e, k end end
            elseif axis == "x" and st.x ~= x then
                nav.face(st.x < x and 1 or 3)
                while st.x ~= x do local ok, e, k = move("forward", dig); if not ok then return false, e, k end end
            elseif axis == "z" and st.z ~= z then
                nav.face(st.z < z and 0 or 2)
                while st.z ~= z do local ok, e, k = move("forward", dig); if not ok then return false, e, k end end
            end
        end
        return true
    end

    function nav.goHome(dig)
        return nav.goTo(0, 0, 0, reverse(st.order or "xzy"), dig)
    end

    --- After a reboot: decide whether the move that was in flight completed.
    -- Moves cost 1 fuel, so a lower fuel level means it happened. Turns (and
    -- moves with unlimited fuel) can't be checked and are assumed not done.
    function nav.reconcile()
        local p = st.pending
        if not p then return end
        st.pending = nil
        local done = false
        if MOVES[p.op] and p.fuel then
            local now = T.getFuelLevel()
            done = type(now) == "number" and now < p.fuel
        end
        if done then apply(p.op) end
        J.log(("resume: interrupted %s %s"):format(p.op,
            done and "had completed" or ((MOVES[p.op] and p.fuel) and "had not happened" or "assumed not done")))
        J.save()
    end

    return nav
end

----------------------------------------------------------------------
-- Inventory / fuel helpers. `opts` (all optional):
--   keep(detail)    -> how many of this item type to keep in the turtle
--   product(detail) -> true for the job's output (burned only as last resort,
--                      never kept as the spare fuel stack)
--   keepFuel        -> keep one stack of fuel when unloading
--   reserve         -> extra fuel margin for round trips (default 20)
----------------------------------------------------------------------

function M.hasInventory(side)
    if not peripheral.isPresent(side) then return false end
    if peripheral.hasType then return peripheral.hasType(side, "inventory") == true end
    for _, t in ipairs({ peripheral.getType(side) }) do
        if t == "inventory" then return true end
    end
    return false
end

function M.bind(J)
    local T, nav = J.turtle, J.nav
    local L = {}

    function L.isFull()
        for s = 1, 16 do if T.getItemCount(s) == 0 then return false end end
        return true
    end

    function L.emptySlot()
        for s = 1, 16 do if T.getItemCount(s) == 0 then return s end end
        return nil
    end

    function L.findSlot(match)
        for s = 1, 16 do
            local d = T.getItemDetail(s)
            if d and match(d) then return s, d end
        end
        return nil
    end

    --- Burn fuel items from the inventory until the level reaches `target`.
    function L.refuel(target, opts)
        opts = opts or {}
        local lvl = T.getFuelLevel()
        if lvl == "unlimited" then return true end
        target = math.min(target, T.getFuelLimit())
        if lvl >= target then return true end
        for pass = 1, 2 do
            for s = 1, 16 do
                if T.getFuelLevel() >= target then break end
                local d = T.getItemDetail(s)
                local kept = d and opts.keep and (opts.keep(d) or 0) > 0
                local isProduct = d and opts.product and opts.product(d)
                if d and not kept and (pass == 2 or not isProduct) then
                    T.select(s)
                    if T.refuel(0) then
                        while T.getItemCount(s) > 0 and T.getFuelLevel() < target do
                            if not T.refuel(1) then break end
                        end
                    end
                end
            end
        end
        T.select(1)
        return T.getFuelLevel() >= target
    end

    --- Make sure there's at least `target` fuel: burn inventory fuel, pull
    -- from a fuel chest above home if there is one, otherwise wait (visibly)
    -- for the player to drop fuel into the turtle.
    function L.ensureFuel(target, opts)
        opts = opts or {}
        if T.getFuelLevel() == "unlimited" then return true end
        target = math.min(target, T.getFuelLimit())
        local warned = false
        while true do
            if L.refuel(target, opts) then return true end
            if nav.atHome() and M.hasInventory("top") then
                for _ = 1, 4 do
                    local slot = L.emptySlot()
                    if not slot then break end
                    T.select(slot)
                    if not T.suckUp() then break end
                    if L.refuel(target, opts) then break end
                end
                T.select(1)
                if T.getFuelLevel() >= target then return true end
            end
            if not warned then
                J.log(("needs fuel: have %d, need %d"):format(T.getFuelLevel(), target))
                warned = true
            end
            J.progress(nil, ("needs fuel %d/%d"):format(T.getFuelLevel(), target))
            J.waitFor("turtle_inventory", 15)
        end
    end

    --- At home: face the output chest behind home and drop everything except
    -- kept items. Waits (visibly) if the chest is missing or full.
    function L.unload(opts)
        opts = opts or {}
        nav.calibrate()
        nav.face(2)
        while not M.hasInventory("front") do
            J.progress(nil, "no chest behind home")
            J.waitFor("peripheral", 15)
        end
        local kept, fuelKept = {}, not opts.keepFuel
        for s = 1, 16 do
            local d = T.getItemDetail(s)
            if d then
                local keepN = 0
                local want = opts.keep and opts.keep(d) or 0
                if want > 0 then
                    local have = kept[d.name] or 0
                    keepN = math.min(d.count, math.max(0, want - have))
                    kept[d.name] = have + keepN
                end
                T.select(s)
                if keepN == 0 and not fuelKept and not (opts.product and opts.product(d)) and T.refuel(0) then
                    fuelKept, keepN = true, d.count
                end
                while T.getItemCount(s) > keepN do
                    if not T.drop(T.getItemCount(s) - keepN) then
                        J.progress(nil, "output chest full")
                        J.waitFor("turtle_inventory", 15)
                    end
                end
            end
        end
        T.select(1)
    end

    --- Call before each step of work. `need` = fuel to finish the step and
    -- get home from there. If fuel is short (after burning inventory fuel)
    -- or the inventory is full, go home, unload, refuel, and come back to
    -- exactly where we were.
    function L.service(need, opts)
        opts = opts or {}
        local lowFuel = false
        if T.getFuelLevel() ~= "unlimited" and T.getFuelLevel() < need then
            L.refuel(need + 40, opts) -- top up a little past what's needed
            lowFuel = T.getFuelLevel() < need
        end
        local full = L.isFull()
        if not lowFuel and not full then return end
        local x, y, z, f = nav.x, nav.y, nav.z, nav.f
        J.log(full and "inventory full: going home to unload" or "fuel low: going home")
        J.progress(nil, full and "unloading" or "refueling")
        local ok, e = nav.goHome()
        if not ok then error("can't get home: " .. tostring(e), 0) end
        L.unload(opts)
        L.ensureFuel(2 * (math.abs(x) + math.abs(y) + math.abs(z)) + (opts.reserve or 20), opts)
        J.progress(nil, "returning to work")
        ok, e = nav.goTo(x, y, z)
        if not ok then error("can't get back to work: " .. tostring(e), 0) end
        nav.face(f)
    end

    return L
end

return M
