-- claudecraft.jobs_templates - built-in turtle jobs: quarry, tree_farm, crop_farm.
--
-- Each template gets the job api `J` (J.turtle, J.nav, J.lib, J.state, ...)
-- and its validated params. All positions are relative to home (where the
-- turtle started, facing +z; +x is to its right). Every template expects an
-- output chest directly behind home and will use an optional fuel chest
-- directly above home. Template state lives in J.state and is checkpointed,
-- so run() is written to be restartable: on resume it works out where it is
-- and carries on.

local M = {}
M.names = { "quarry", "tree_farm", "crop_farm" }

local function now() return os.epoch("utc") end

local function int(v, name, lo, hi, default)
    if v == nil then
        if default ~= nil then return default end
        error(name .. " is required", 0)
    end
    local n = tonumber(v)
    if not n then error(name .. " must be a number", 0) end
    n = math.floor(n)
    if n < lo or n > hi then error(("%s must be %d-%d"):format(name, lo, hi), 0) end
    return n
end

local function optInt(v, name, lo, hi)
    if v == nil then return nil end
    return int(v, name, lo, hi)
end

-- Sleep until epoch-ms time `at` (survives reboots), showing a countdown.
local function waitUntil(J, at, what)
    while at and now() < at do
        local left = math.ceil((at - now()) / 1000)
        J.progress(nil, ("%s in %ds"):format(what, left))
        J.sleep(math.min(left, 10))
    end
end

local function goHomeOrFail(J)
    if J.nav.atHome() then return end
    local ok, e = J.nav.goHome()
    if not ok then error("can't get home: " .. tostring(e), 0) end
end

----------------------------------------------------------------------
-- QUARRY: dig width x length, from the turtle's level down `depth` layers
-- (or until bedrock). Like ROM `excavate`, but rectangular and resumable.
----------------------------------------------------------------------

-- Cell `i` (0-based) of `layer`: serpentine columns along z, stepping +x.
-- Odd layers run the same path backwards, so each layer starts directly
-- below where the previous one ended.
local function quarryCell(p, layer, i)
    local W, L = p.width, p.length
    if layer % 2 == 1 then i = W * L - 1 - i end
    local col = math.floor(i / L)
    local r = i % L
    local z = (col % 2 == 0) and r or (L - 1 - r)
    return col, -layer, z
end

M.quarry = {
    turtle = true,
    help = "quarry {width,length,depth?} (or {size}) digs width (to the right) x length (forward) "
        .. "starting at the turtle's own level, down `depth` layers, or to bedrock if depth is omitted.",
    validate = function(p)
        local size = optInt(p.size, "size", 1, 64)
        local depth = p.depth
        if depth == "bedrock" or depth == 0 then depth = nil end
        return {
            width = int(p.width or size, "width", 1, 64),
            length = int(p.length or size, "length", 1, 64),
            depth = optInt(depth, "depth", 1, 384),
        }
    end,
    label = function(p)
        return ("quarry %dx%dx%s"):format(p.width, p.length, p.depth and tostring(p.depth) or "bedrock")
    end,
    run = function(J, p)
        local nav, lib = J.nav, J.lib
        local s = J.state
        local N = p.width * p.length
        local total = p.depth and N * p.depth or nil
        local opts = { keepFuel = true, reserve = 20 }
        nav.setRoute("xzy", true, true) -- out: across the top, then down; home: up, then back
        if s.layer == nil then s.layer, s.i, s.cells = 0, 0, 1 end -- standing in cell 0

        local stopped = "reached depth"
        while true do
            local layer, i = s.layer, s.i + 1
            if i >= N then layer, i = layer + 1, 0 end
            if p.depth and layer >= p.depth then break end
            local x, y, z = quarryCell(p, layer, i)
            local travel = math.abs(x - nav.x) + math.abs(y - nav.y) + math.abs(z - nav.z)
            lib.service(travel + math.abs(x) + math.abs(y) + math.abs(z) + 2, opts)
            local ok, err, kind = nav.goTo(x, y, z)
            if not ok then
                if kind ~= "unbreakable" then error(err, 0) end
                stopped = err -- bedrock (or another undiggable block)
                J.log(("stopping at layer %d: %s"):format(layer + 1, err))
                break
            end
            s.layer, s.i, s.cells = layer, i, s.cells + 1
            J.progress(total and math.floor(s.cells * 100 / total) or nil,
                ("layer %d%s"):format(layer + 1, p.depth and ("/" .. p.depth) or ""))
        end

        J.progress(nil, "returning home")
        goHomeOrFail(J)
        lib.unload(opts)
        nav.face(0)
        return { cells_dug = s.cells, layers = s.layer + 1, stopped = stopped }
    end,
}

----------------------------------------------------------------------
-- TREE FARM: a straight path runs forward from home; trees stand beside it
-- (right, left or both sides) every `spacing` blocks, the first one level
-- with the block in front of home. Chops 1x1 trees (birch never branches;
-- spruce works too) and replants saplings.
----------------------------------------------------------------------

local function isLog(d)
    if d.tags and d.tags["minecraft:logs"] then return true end
    return d.name:find("_log$") ~= nil or d.name:find("_stem$") ~= nil
end

local function isLeaves(d)
    if d.tags and d.tags["minecraft:leaves"] then return true end
    return d.name:find("leaves") ~= nil
end

local function isSaplingItem(d) return d.name:find("sapling") ~= nil end

local function isLogItem(d)
    return d.name:find("_log$") ~= nil or d.name:find("_stem$") ~= nil or d.name:find("_wood$") ~= nil
end

M.tree_farm = {
    turtle = true,
    help = "tree_farm {trees, spacing?=3, side?=right|left|both, interval?=120s, cycles?} chops and replants "
        .. "a row of 1x1 trees beside a straight path running forward from the turtle; tree k is beside "
        .. "the path block 1+(k-1)*spacing ahead. Keep saplings in the turtle.",
    validate = function(p)
        local side = p.side or "right"
        if side ~= "right" and side ~= "left" and side ~= "both" then
            error("side must be right, left or both", 0)
        end
        return {
            trees = int(p.trees, "trees", 1, 32),
            spacing = int(p.spacing, "spacing", 2, 8, 3),
            side = side,
            interval = int(p.interval, "interval", 10, 3600, 120),
            cycles = optInt(p.cycles, "cycles", 1, 100000),
        }
    end,
    label = function(p) return ("tree farm x%d"):format(p.trees) end,
    run = function(J, p)
        local nav, lib, T = J.nav, J.lib, J.turtle
        local s = J.state
        s.cycle, s.chopped = s.cycle or 0, s.chopped or 0
        nav.setRoute("zxy", true, false) -- along the path, into a trunk, up it; never attack
        local sides = p.side == "both" and { 1, 3 } or (p.side == "left" and { 3 } or { 1 })
        local pathLen = 1 + (p.trees - 1) * p.spacing
        local opts = {
            keep = function(d) return isSaplingItem(d) and 64 or 0 end,
            product = isLogItem, -- logs are only burned if there's nothing else
            reserve = 40,
        }

        local function plant()
            local slot = lib.findSlot(isSaplingItem)
            if not slot then
                if not s.noSaplings then J.log("out of saplings"); s.noSaplings = true end
                return false
            end
            s.noSaplings = nil
            T.select(slot)
            local ok = T.place()
            T.select(1)
            return ok
        end

        -- Standing in a trunk column (x ~= 0): climb while there are logs
        -- above, come back down, and step back onto the path facing the spot.
        local function chopColumn()
            local spot = nav.x > 0 and 1 or 3
            while true do
                local ok, d = T.inspectUp()
                if not (ok and isLog(d)) then break end
                local fuel = T.getFuelLevel()
                if fuel ~= "unlimited" and fuel <= nav.distHome() + 2 then break end
                if not nav.up(true) then break end
            end
            local ok, e = nav.goTo(nav.x, 0, nav.z, "y", true)
            if not ok then error("can't climb down the trunk: " .. tostring(e), 0) end
            nav.face(spot)
            ok, e = nav.back(true)
            if not ok then error("can't step out of the trunk: " .. tostring(e), 0) end
            s.chopped = s.chopped + 1
        end

        local function tendSpot(f)
            nav.face(f)
            local ok, d = T.inspect()
            if ok and isLog(d) then
                local mok, e = nav.forward(true) -- digs the bottom log and steps in
                if not mok then J.log("can't reach tree: " .. tostring(e)); return end
                chopColumn()
            elseif ok and isLeaves(d) then
                T.dig()
            elseif ok then
                return -- a sapling (still growing) or something we leave alone
            end
            T.suck() -- dropped saplings lying on the spot
            plant()
        end

        -- s.k = next tree of the current pass (nil between passes), so a
        -- resumed job carries on from the tree it was at.
        if nav.x ~= 0 then chopColumn(); plant() end -- resumed mid-chop
        while not p.cycles or s.cycle < p.cycles do
            if s.k == nil then
                goHomeOrFail(J)
                waitUntil(J, s.nextAt, "next pass")
                local need = 2 * pathLen + #sides * p.trees * 4 + 20
                lib.refuel(need, opts) -- may burn a few of our own logs before they're unloaded
                lib.unload(opts)
                lib.ensureFuel(need, opts)
                s.k = 1
                J.save()
            end
            while s.k <= p.trees do
                local k = s.k
                local z = 1 + (k - 1) * p.spacing
                lib.service(math.abs(z - nav.z) + 40 + z, opts)
                if nav.z > z then
                    local ok, e = nav.goTo(0, 0, z)
                    if not ok then error("can't get back along the path: " .. tostring(e), 0) end
                end
                while nav.z < z do
                    nav.face(0)
                    T.suck() -- sweep up dropped saplings along the path
                    local ok, e = nav.forward(true)
                    if not ok then error(("path blocked %d ahead of home: %s"):format(nav.z + 1, tostring(e)), 0) end
                end
                for _, f in ipairs(sides) do tendSpot(f) end
                s.k = k + 1
                J.progress(math.floor(k * 100 / p.trees), ("cycle %d: tree %d/%d"):format(s.cycle + 1, k, p.trees))
            end
            goHomeOrFail(J)
            s.cycle, s.k = s.cycle + 1, nil
            s.nextAt = now() + p.interval * 1000
            J.save()
        end
        lib.unload(opts)
        nav.face(0)
        return { cycles = s.cycle, trees_chopped = s.chopped }
    end,
}

----------------------------------------------------------------------
-- CROP FARM: the turtle stands at crop level just outside one corner of the
-- field, facing along it. The field is `width` blocks to the right
-- (including the turtle's own column) by `length` blocks forward, starting
-- one block ahead. The turtle flies one block above the crops, harvests the
-- mature ones and replants. Never digs or attacks anything else.
----------------------------------------------------------------------

local CROPS = {
    ["minecraft:wheat"] = { age = 7, seed = "minecraft:wheat_seeds" },
    ["minecraft:carrots"] = { age = 7, seed = "minecraft:carrot" },
    ["minecraft:potatoes"] = { age = 7, seed = "minecraft:potato" },
    ["minecraft:beetroots"] = { age = 3, seed = "minecraft:beetroot_seeds" },
    ["minecraft:nether_wart"] = { age = 3, seed = "minecraft:nether_wart" },
}
local SEEDS = {}
for _, c in pairs(CROPS) do SEEDS[c.seed] = true end
local CROP_ALIAS = {
    wheat = "minecraft:wheat", carrot = "minecraft:carrots", carrots = "minecraft:carrots",
    potato = "minecraft:potatoes", potatoes = "minecraft:potatoes",
    beetroot = "minecraft:beetroots", beetroots = "minecraft:beetroots",
    nether_wart = "minecraft:nether_wart",
}

M.crop_farm = {
    turtle = true,
    help = "crop_farm {width, length, crop?=wheat|carrots|potatoes|beetroots|nether_wart, interval?=300s, cycles?} "
        .. "harvests and replants a field. Turtle stands at crop level just outside a corner, facing along "
        .. "the field; the field is width blocks to the right (incl. the turtle's column) x length forward, "
        .. "starting 1 block ahead. Keep seeds in the turtle.",
    validate = function(p)
        local crop = nil
        if p.crop ~= nil then
            local key = tostring(p.crop):lower():gsub("^minecraft:", "")
            crop = CROP_ALIAS[key]
            if not crop then error("unknown crop: " .. tostring(p.crop), 0) end
        end
        return {
            width = int(p.width, "width", 1, 32),
            length = int(p.length, "length", 1, 32),
            crop = crop,
            interval = int(p.interval, "interval", 30, 7200, 300),
            cycles = optInt(p.cycles, "cycles", 1, 100000),
        }
    end,
    label = function(p) return ("crop farm %dx%d"):format(p.width, p.length) end,
    run = function(J, p)
        local nav, lib, T = J.nav, J.lib, J.turtle
        local s = J.state
        s.cycle, s.harvested = s.cycle or 0, s.harvested or 0
        local W, L = p.width, p.length
        local seed = p.crop and CROPS[p.crop].seed or nil
        nav.setRoute("yzx", false, false) -- out: up, along the near column, across
        local opts = { keep = function(d) return SEEDS[d.name] and 64 or 0 end, reserve = 10 }

        local function plant(item)
            local slot = lib.findSlot(function(d)
                if item then return d.name == item end
                return SEEDS[d.name] == true
            end)
            if not slot then return false end
            T.select(slot)
            local ok = T.placeDown()
            T.select(1)
            return ok
        end

        local function tend()
            local ok, d = T.inspectDown()
            if not ok then plant(seed); return end -- empty farmland (planting fails harmlessly elsewhere)
            local c = CROPS[d.name]
            local maxAge = c and c.age or ((d.tags and d.tags["minecraft:crops"]) and 7 or nil)
            local age = d.state and tonumber(d.state.age)
            if maxAge and age and age >= maxAge and T.digDown() then
                s.harvested = s.harvested + 1
                local again = c and c.seed or seed
                if again then plant(again) end
            end
        end

        -- s.i = next cell of the current pass (nil between passes), so a
        -- resumed job carries on from where it was. Re-tending a cell is
        -- harmless: a freshly planted crop isn't ripe.
        while not p.cycles or s.cycle < p.cycles do
            if s.i == nil then
                goHomeOrFail(J)
                waitUntil(J, s.nextAt, "next pass")
                lib.unload(opts)
                lib.ensureFuel(W * L + 2 * (W + L) + 10, opts)
                s.i = 0
                J.save()
            end
            while s.i < W * L do
                local i = s.i
                local col, r = math.floor(i / L), i % L
                local x, z = col, (col % 2 == 0) and (r + 1) or (L - r)
                local travel = math.abs(x - nav.x) + math.abs(1 - nav.y) + math.abs(z - nav.z)
                lib.service(travel + x + 1 + z + 2, opts)
                local ok, e = nav.goTo(x, 1, z)
                if not ok then error(("can't reach field cell %d,%d: %s"):format(x, z, tostring(e)), 0) end
                tend()
                s.i = i + 1
                if r == L - 1 then
                    J.progress(math.floor((i + 1) * 100 / (W * L)), ("cycle %d: row %d/%d"):format(s.cycle + 1, col + 1, W))
                end
            end
            goHomeOrFail(J)
            s.cycle, s.i = s.cycle + 1, nil
            s.nextAt = now() + p.interval * 1000
            J.save()
        end
        lib.unload(opts)
        nav.face(0)
        return { cycles = s.cycle, harvested = s.harvested }
    end,
}

return M
