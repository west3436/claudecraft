--[[
claudecraft.build: shape expansion, planning, dry run and execution for the
build_structure tool in claude.lua. Load it with require("claudecraft.build").

Coordinate frame: relative to the turtle when the tool is called.
  x = right, y = up, z = forward. (0,0,0) is the turtle's own cell, so y = 0
  is the turtle's level and y = -1 is the block it stands on. This is NOT the
  world/GPS frame that turtle_goto uses.

Every block is placed from directly above (placeDown), bottom layer first, so
the turtle always flies through the empty layer over the one it is building.
Cells it has placed, or found already correct, are "protected": no move may
dig them. That is how the trip home avoids tunnelling through the build.
]]

local M = {}

M.FRAME = "Relative to the turtle's start position and facing: x=right, y=up, z=forward; " ..
    "(0,0,0) is the turtle's own cell, so y=0 is its level and y=-1 the block under it. " ..
    "Not the world/GPS coordinates turtle_goto uses."

local MAX_COORD   = 256      -- |x|, |y|, |z| limit for any cell
local MAX_BLOCKS  = 32768    -- blocks after expansion
local MAX_SCAN    = 1000000  -- cells all shapes together may examine
local INV_CAP     = 15 * 64  -- items one restock trip is assumed to carry (estimate only)
local MAX_DIGS    = 64       -- digs per move (falling sand/gravel columns)
local MAX_WAITS   = 20       -- waits/attacks per move while an entity blocks it
local MAX_TRIPS   = 64       -- restock trips per build
local MAX_FAILS   = 24       -- consecutive unreachable cells before giving up
local LIST_CAP    = 20       -- cells listed per result category
local TEXT_CAP    = 6000     -- characters of text preview
local SECS_PER_OP = 0.45     -- rough turtle time per move or placement

local floor, ceil, abs, max, min = math.floor, math.ceil, math.abs, math.max, math.min
local HUGE = math.huge

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

-- One number per cell; coordinates must stay inside +/-512.
local function key(x, y, z) return (x + 512) * 1048576 + (y + 512) * 1024 + (z + 512) end
local function key2(x, z) return (x + 512) * 1024 + (z + 512) end

local function round(v) return floor(v + 0.5) end

local function manhattan(ax, ay, az, bx, by, bz)
    return abs(ax - bx) + abs(ay - by) + abs(az - bz)
end

local function normName(n)
    if type(n) ~= "string" then return nil end
    n = n:lower():match("^%s*(.-)%s*$")
    if n == "" then return nil end
    if not n:find(":", 1, true) then n = "minecraft:" .. n end
    return n
end
M.normName = normName

local AIR = { ["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }

-- Facing: 0 = +z (forward), 1 = +x (right), 2 = -z (back), 3 = -x (left)
local FACING = {
    forward = 0, front = 0, ["+z"] = 0,
    right = 1, ["+x"] = 1,
    back = 2, backward = 2, ["-z"] = 2,
    left = 3, ["-x"] = 3,
}
local FACING_NAME = { [0] = "forward", [1] = "right", [2] = "back", [3] = "left" }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local function parseFacing(v)
    if v == nil then return nil, true end
    if type(v) == "number" and v >= 0 and v <= 3 and v == floor(v) then return v, true end
    if type(v) == "string" then
        local f = FACING[v:lower()]
        if f then return f, true end
    end
    return nil, false
end

-- Blocks the turtle refuses to dig while travelling or replacing.
local NO_DIG = {
    "computercraft:", "chest", "barrel", "shulker_box", "hopper", "furnace", "smoker",
    "dispenser", "dropper", "spawner", "beacon", "brewing_stand", "lectern", "crafter",
}
local function isNoDig(name)
    if not name then return false end
    for _, p in ipairs(NO_DIG) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- Restock chest position (relative to the start cell) and its peripheral side.
local RESTOCK = {
    back  = { 0, 0, -1, "back" },
    front = { 0, 0, 1, "front" },
    left  = { -1, 0, 0, "left" },
    right = { 1, 0, 0, "right" },
    up    = { 0, 1, 0, "top" },
    down  = { 0, -1, 0, "bottom" },
}
RESTOCK.top, RESTOCK.bottom = RESTOCK.up, RESTOCK.down

local function addCapped(list, item)
    if #list < LIST_CAP then list[#list + 1] = item end
end

----------------------------------------------------------------------
-- Shape expansion
----------------------------------------------------------------------

local function coord(v)
    if type(v) ~= "number" or v ~= v or v == HUGE or v == -HUGE then return nil end
    return round(v)
end

local function readPoint(p)
    if type(p) ~= "table" then return nil end
    local x, y, z = coord(p.x or p[1]), coord(p.y or p[2]), coord(p.z or p[3])
    if x and y and z then return x, y, z end
    return nil
end

local function addErr(cv, msg)
    if #cv.errors < 8 then cv.errors[#cv.errors + 1] = msg end
end

-- Charge `n` examined cells to the shared budget; false (with an error) if over.
local function budget(cv, ctx, n)
    cv.scanned = cv.scanned + n
    if cv.scanned > MAX_SCAN then
        addErr(cv, ("%s is too large (%d cells; all shapes together may examine %d)"):format(ctx.where, n, MAX_SCAN))
        return false
    end
    return true
end

-- Set one cell. block == nil carves (air): removes whatever earlier shapes put there.
local function put(cv, x, y, z, block, facing)
    cv.ops = cv.ops + 1
    if cv.ops % 20000 == 0 then cv.yield() end
    if abs(x) > MAX_COORD or abs(y) > MAX_COORD or abs(z) > MAX_COORD then
        cv.outOfRange = cv.outOfRange + 1
        return
    end
    local k = key(x, y, z)
    local cur = cv.cells[k]
    if block == nil then
        if cur then
            cv.cells[k] = nil
            cv.n = cv.n - 1
            cv.carved = cv.carved + 1
        end
        return
    end
    if not cur then
        if cv.n >= MAX_BLOCKS * 2 then cv.overflow = true; return end -- bound memory; reported as an error
        cv.n = cv.n + 1
    end
    cv.cells[k] = { x = x, y = y, z = z, block = block, facing = facing }
end

local function boxRange(cv, s, ctx)
    local x1, y1, z1 = readPoint(s.from)
    local x2, y2, z2 = readPoint(s.to)
    if not (x1 and x2) then
        addErr(cv, ctx.where .. ": needs 'from' and 'to' as {x,y,z}")
        return nil
    end
    return min(x1, x2), min(y1, y2), min(z1, z2), max(x1, x2), max(y1, y2), max(z1, z2)
end

local SHAPES = {}

function SHAPES.box(cv, s, ctx)
    local x1, y1, z1, x2, y2, z2 = boxRange(cv, s, ctx)
    if not x1 or not budget(cv, ctx, (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)) then return end
    for y = y1, y2 do
        for z = z1, z2 do
            for x = x1, x2 do put(cv, x, y, z, ctx.block, ctx.facing) end
        end
    end
end

function SHAPES.hollow_box(cv, s, ctx)
    local x1, y1, z1, x2, y2, z2 = boxRange(cv, s, ctx)
    if not x1 or not budget(cv, ctx, (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)) then return end
    local open = {}
    local list = type(s.open) == "table" and s.open or { s.open }
    for _, f in ipairs(list) do
        if type(f) == "string" then open[f:lower()] = true end
    end
    local L, R = open.left or open["-x"], open.right or open["+x"]
    local B, F = open.back or open["-z"], open.front or open["+z"]
    local BOT, TOP = open.bottom or open["-y"], open.top or open["+y"]
    for y = y1, y2 do
        for z = z1, z2 do
            for x = x1, x2 do
                if (x == x1 and not L) or (x == x2 and not R) or (z == z1 and not B)
                    or (z == z2 and not F) or (y == y1 and not BOT) or (y == y2 and not TOP) then
                    put(cv, x, y, z, ctx.block, ctx.facing)
                end
            end
        end
    end
end

function SHAPES.floor(cv, s, ctx)
    local x1, _, z1, x2, _, z2 = boxRange(cv, s, ctx)
    if not x1 then return end
    local _, y = readPoint(s.from)
    if not budget(cv, ctx, (x2 - x1 + 1) * (z2 - z1 + 1)) then return end
    for z = z1, z2 do
        for x = x1, x2 do put(cv, x, y, z, ctx.block, ctx.facing) end
    end
end
SHAPES.plane = SHAPES.floor

-- A straight run of cells from `from` to `to` (3D for line, horizontal for wall).
local function lineCells(x1, y1, z1, x2, y2, z2)
    local n = max(abs(x2 - x1), abs(y2 - y1), abs(z2 - z1))
    local out = {}
    for i = 0, n do
        local t = (n == 0) and 0 or i / n
        out[#out + 1] = { round(x1 + (x2 - x1) * t), round(y1 + (y2 - y1) * t), round(z1 + (z2 - z1) * t) }
    end
    return out
end

function SHAPES.line(cv, s, ctx)
    local x1, y1, z1 = readPoint(s.from)
    local x2, y2, z2 = readPoint(s.to)
    if not (x1 and x2) then return addErr(cv, ctx.where .. ": needs 'from' and 'to' as {x,y,z}") end
    local n = max(abs(x2 - x1), abs(y2 - y1), abs(z2 - z1)) + 1
    if not budget(cv, ctx, n) then return end
    for _, p in ipairs(lineCells(x1, y1, z1, x2, y2, z2)) do put(cv, p[1], p[2], p[3], ctx.block, ctx.facing) end
end

-- Wall: a horizontal line from `from` to `to` (diagonals allowed), filled from
-- from.y up to to.y, or `height` blocks tall from from.y.
function SHAPES.wall(cv, s, ctx)
    local x1, y1, z1 = readPoint(s.from)
    local x2, y2, z2 = readPoint(s.to)
    if not (x1 and x2) then return addErr(cv, ctx.where .. ": needs 'from' and 'to' as {x,y,z}") end
    local ylo, yhi = min(y1, y2), max(y1, y2)
    if s.height ~= nil then
        local h = coord(s.height)
        if not h or h < 1 then return addErr(cv, ctx.where .. ": height must be >= 1") end
        ylo, yhi = y1, y1 + h - 1
    end
    local cells = lineCells(x1, 0, z1, x2, 0, z2)
    if not budget(cv, ctx, #cells * (yhi - ylo + 1)) then return end
    for y = ylo, yhi do
        for _, p in ipairs(cells) do put(cv, p[1], y, p[3], ctx.block, ctx.facing) end
    end
end

local function readRadius(cv, s, ctx)
    local cx, cy, cz = readPoint(s.center)
    local r = tonumber(s.radius)
    if not cx then addErr(cv, ctx.where .. ": needs 'center' as {x,y,z}"); return nil end
    if not r or r < 0 or r > MAX_COORD then addErr(cv, ctx.where .. ": needs 'radius' between 0 and " .. MAX_COORD); return nil end
    return cx, cy, cz, r
end

-- Vertical cylinder; center is the middle of the bottom layer.
function SHAPES.cylinder(cv, s, ctx)
    local cx, cy, cz, r = readRadius(cv, s, ctx)
    if not cx then return end
    local h = 1
    if s.height ~= nil then
        h = coord(s.height)
        if not h or h < 1 then return addErr(cv, ctx.where .. ": height must be >= 1") end
    end
    local R, lim = ceil(r), (r + 0.5) * (r + 0.5)
    if not budget(cv, ctx, (2 * R + 1) * (2 * R + 1) * h) then return end
    local function inside(dx, dz) return dx * dx + dz * dz < lim end
    local hollow = s.hollow == true
    for dz = -R, R do
        for dx = -R, R do
            if inside(dx, dz) and (not hollow or not (inside(dx + 1, dz) and inside(dx - 1, dz)
                and inside(dx, dz + 1) and inside(dx, dz - 1))) then
                for y = cy, cy + h - 1 do put(cv, cx + dx, y, cz + dz, ctx.block, ctx.facing) end
            end
        end
    end
end

local function sphere(cv, s, ctx, upperOnly, hollowDefault)
    local cx, cy, cz, r = readRadius(cv, s, ctx)
    if not cx then return end
    local R, lim = ceil(r), (r + 0.5) * (r + 0.5)
    if not budget(cv, ctx, (2 * R + 1) * (2 * R + 1) * (upperOnly and R + 1 or 2 * R + 1)) then return end
    local function inside(dx, dy, dz) return dx * dx + dy * dy + dz * dz < lim end
    local hollow = hollowDefault
    if s.hollow ~= nil then hollow = s.hollow == true end
    for dy = upperOnly and 0 or -R, R do
        for dz = -R, R do
            for dx = -R, R do
                if inside(dx, dy, dz) and (not hollow or not (
                    inside(dx + 1, dy, dz) and inside(dx - 1, dy, dz) and inside(dx, dy + 1, dz)
                    and inside(dx, dy - 1, dz) and inside(dx, dy, dz + 1) and inside(dx, dy, dz - 1))) then
                    put(cv, cx + dx, cy + dy, cz + dz, ctx.block, ctx.facing)
                end
            end
        end
    end
end

function SHAPES.sphere(cv, s, ctx) return sphere(cv, s, ctx, false, false) end
function SHAPES.dome(cv, s, ctx) return sphere(cv, s, ctx, true, true) end

-- Gable roof over the footprint from..to, starting at from.y. Each layer steps
-- in by one on both sloped sides until they meet at the ridge, which runs
-- along `axis` (default: the longer side). Stairs face up-slope automatically.
function SHAPES.roof(cv, s, ctx)
    local x1, _, z1, x2, _, z2 = boxRange(cv, s, ctx)
    if not x1 then return end
    local _, base = readPoint(s.from)
    local axis = type(s.axis) == "string" and s.axis:lower() or nil
    if axis ~= "x" and axis ~= "z" then axis = ((x2 - x1) >= (z2 - z1)) and "x" or "z" end
    -- a = along the ridge, p = across it (the sloped direction)
    local a1, a2, p1, p2, upF, downF
    if axis == "x" then
        a1, a2, p1, p2, upF, downF = x1, x2, z1, z2, 0, 2
    else
        a1, a2, p1, p2, upF, downF = z1, z2, x1, x2, 1, 3
    end
    local function at(a, y, p, block, facing)
        if axis == "x" then put(cv, a, y, p, block, facing) else put(cv, p, y, a, block, facing) end
    end
    local stairs = ctx.block and ctx.block:find("stairs", 1, true) ~= nil
    local fUp = ctx.facing or (stairs and upF or nil)
    local fDown = ctx.facing or (stairs and downF or nil)
    local gable = normName(s.gable_block)
    if gable and AIR[gable] then gable = nil end
    local layers = floor((p2 - p1) / 2) + 1
    if not budget(cv, ctx, layers * ((a2 - a1 + 1) * 2 + (p2 - p1 + 1) * 2)) then return end
    for k = 0, layers - 1 do
        local lo, hi, y = p1 + k, p2 - k, base + k
        for a = a1, a2 do
            at(a, y, lo, ctx.block, fUp)
            if hi ~= lo then at(a, y, hi, ctx.block, fDown) end
        end
        if gable then
            for p = lo + 1, hi - 1 do
                at(a1, y, p, gable)
                at(a2, y, p, gable)
            end
        end
    end
end

local SHAPE_NAMES = "box, hollow_box, wall, line, floor, plane, cylinder, sphere, dome, roof"

local function decodeList(v)
    if type(v) == "string" and textutils and textutils.unserialiseJSON then
        local ok, d = pcall(textutils.unserialiseJSON, v)
        if ok then v = d end
    end
    if type(v) ~= "table" then return nil end
    return v
end

--- Expand `shapes` (in order, later wins) and then `blocks` into a cell model.
-- @return model or nil, error
function M.expand(input, yieldFn)
    local cv = {
        cells = {}, n = 0, carved = 0, errors = {}, scanned = 0, ops = 0, outOfRange = 0,
        yield = yieldFn or function() end,
    }
    local shapes, blocks = decodeList(input.shapes), decodeList(input.blocks)
    if input.shapes ~= nil and not shapes then return nil, "'shapes' must be an array" end
    if input.blocks ~= nil and not blocks then return nil, "'blocks' must be an array" end
    if (not shapes or #shapes == 0) and (not blocks or #blocks == 0) then
        return nil, "Nothing to build: give 'shapes' and/or 'blocks'"
    end

    for i, s in ipairs(shapes or {}) do
        local where = ("shapes[%d]"):format(i)
        if type(s) ~= "table" then
            addErr(cv, where .. " must be an object")
        else
            local tname = type(s.type) == "string" and s.type:lower():gsub("[%s%-]", "_") or nil
            local fn = tname and SHAPES[tname]
            local block = normName(s.block)
            local facing, fok = parseFacing(s.facing)
            if not fn then
                addErr(cv, ("%s: unknown type '%s' (use %s)"):format(where, tostring(s.type), SHAPE_NAMES))
            elseif not block then
                addErr(cv, where .. ": 'block' is required (an item id, or 'air')")
            elseif not fok then
                addErr(cv, where .. ": facing must be forward, right, back or left")
            else
                fn(cv, s, {
                    where = where .. " (" .. tname .. ")",
                    block = (not AIR[block]) and block or nil,
                    facing = facing,
                })
            end
        end
        if cv.overflow or #cv.errors >= 8 then break end
    end

    for i, b in ipairs(blocks or {}) do
        local where = ("blocks[%d]"):format(i)
        if type(b) ~= "table" then
            addErr(cv, where .. " must be an object")
        else
            local x, y, z = coord(b.x), coord(b.y), coord(b.z)
            local block = normName(b.block)
            local facing, fok = parseFacing(b.facing)
            if not (x and y and z) then
                addErr(cv, where .. ": x, y and z must be numbers")
            elseif not block then
                addErr(cv, where .. ": 'block' is required")
            elseif not fok then
                addErr(cv, where .. ": facing must be forward, right, back or left")
            else
                put(cv, x, y, z, (not AIR[block]) and block or nil, facing)
            end
        end
        if #cv.errors >= 8 then break end
    end

    if cv.outOfRange > 0 then
        addErr(cv, ("%d cells lie outside the +/-%d range"):format(cv.outOfRange, MAX_COORD))
    end
    if cv.overflow or cv.n > MAX_BLOCKS then
        addErr(cv, ("blueprint has %s%d blocks; the limit is %d, so build it in sections")
            :format(cv.overflow and "over " or "", cv.n, MAX_BLOCKS))
    end
    if #cv.errors > 0 then return nil, "Invalid blueprint: " .. table.concat(cv.errors, "; ") end
    if cv.n == 0 then return nil, "Blueprint is empty (was everything carved away with air?)" end

    local list, counts, byLayer, layerYs = {}, {}, {}, {}
    local bb = { minx = HUGE, miny = HUGE, minz = HUGE, maxx = -HUGE, maxy = -HUGE, maxz = -HUGE }
    for _, c in pairs(cv.cells) do
        list[#list + 1] = c
        counts[c.block] = (counts[c.block] or 0) + 1
        local L = byLayer[c.y]
        if not L then L = {}; byLayer[c.y] = L; layerYs[#layerYs + 1] = c.y end
        L[#L + 1] = c
        if c.x < bb.minx then bb.minx = c.x end
        if c.x > bb.maxx then bb.maxx = c.x end
        if c.y < bb.miny then bb.miny = c.y end
        if c.y > bb.maxy then bb.maxy = c.y end
        if c.z < bb.minz then bb.minz = c.z end
        if c.z > bb.maxz then bb.maxz = c.z end
    end
    table.sort(layerYs)
    return {
        map = cv.cells, cells = list, n = cv.n, carved = cv.carved,
        counts = counts, byLayer = byLayer, layerYs = layerYs, bbox = bb,
    }
end

----------------------------------------------------------------------
-- Planning: bottom layer first; inside a layer, always go to the nearest
-- remaining cell, preferring the one straight ahead.
----------------------------------------------------------------------

function M.plan(model, yieldFn)
    yieldFn = yieldFn or function() end
    local order = {}
    local cx, cz, dx, dz = 0, 0, 0, 1
    local ops = 0
    for _, y in ipairs(model.layerYs) do
        local cells = model.byLayer[y]
        local set, left = {}, #cells
        local x1, x2, z1, z2 = HUGE, -HUGE, HUGE, -HUGE
        for _, c in ipairs(cells) do
            set[key2(c.x, c.z)] = c
            if c.x < x1 then x1 = c.x end
            if c.x > x2 then x2 = c.x end
            if c.z < z1 then z1 = c.z end
            if c.z > z2 then z2 = c.z end
        end
        while left > 0 do
            local pick = set[key2(cx, cz)]
            if not pick then
                local maxR = max(abs(cx - x1), abs(cx - x2)) + max(abs(cz - z1), abs(cz - z2))
                for r = 1, maxR do
                    pick = set[key2(cx + dx * r, cz + dz * r)]
                    if not pick then
                        -- the 4r cells at Manhattan distance r
                        for i = 0, r - 1 do
                            pick = set[key2(cx + r - i, cz + i)] or set[key2(cx - i, cz + r - i)]
                                or set[key2(cx - r + i, cz - i)] or set[key2(cx + i, cz - r + i)]
                            if pick then break end
                        end
                        ops = ops + r
                    end
                    if pick then break end
                end
            end
            assert(pick, "planner lost a cell")
            set[key2(pick.x, pick.z)] = nil
            left = left - 1
            order[#order + 1] = pick
            -- the turtle moves along x then z, so it ends up heading along z if z changed
            if pick.z ~= cz then
                dx, dz = 0, (pick.z > cz) and 1 or -1
            elseif pick.x ~= cx then
                dx, dz = (pick.x > cx) and 1 or -1, 0
            end
            cx, cz = pick.x, pick.z
            ops = ops + 1
            if ops > 20000 then ops = 0; yieldFn() end
        end
    end
    return order
end

----------------------------------------------------------------------
-- Estimates
----------------------------------------------------------------------

-- Moves to get from (x,y,z) back to the start, allowing a detour when the
-- start lies under the build's footprint.
local function homeEstimate(model, x, y, z)
    local b = model.bbox
    local d = manhattan(x, y, z, 0, 0, 0)
    if b.minx <= 0 and b.maxx >= 0 and b.minz <= 0 and b.maxz >= 0 then
        d = d + floor((b.maxx - b.minx + b.maxz - b.minz) / 2) + 2
    end
    return d
end

local function readInventory(t)
    local counts = {}
    if not t then return counts end
    for s = 1, 16 do
        local d = t.getItemDetail(s)
        if d then
            local n = normName(d.name)
            counts[n] = (counts[n] or 0) + d.count
        end
    end
    return counts
end

local function scanChest(env, side)
    local P = env.peripheral
    local info = RESTOCK[side]
    if not P or not info then return nil, "no peripheral API" end
    local ok, inv = pcall(P.wrap, info[4])
    if not ok or type(inv) ~= "table" or type(inv.list) ~= "function" then
        return nil, "no inventory seen on the turtle's " .. info[4] .. " side"
    end
    local ok2, list = pcall(inv.list)
    if not ok2 or type(list) ~= "table" then return nil, "could not read the chest" end
    local counts = {}
    for _, it in pairs(list) do
        local n = normName(it.name)
        if n then counts[n] = (counts[n] or 0) + (it.count or 0) end
    end
    return counts
end

-- Walk the plan with a simulated inventory to estimate moves (= fuel) and
-- restock trips. chest == nil with restock set means "assume it has enough";
-- have == nil means "assume the turtle carries everything".
local function simulate(model, order, have, chest, restock)
    local inv, stock, remaining, exhausted = {}, {}, {}, {}
    if have then
        for k, v in pairs(have) do inv[k] = v end
    else
        for k, v in pairs(model.counts) do inv[k] = v end
    end
    if chest then for k, v in pairs(chest) do stock[k] = v end end
    for k, v in pairs(model.counts) do remaining[k] = v end
    local cx, cy, cz = 0, 0, 0
    local moves, trips, placeable = 0, 0, 0
    for _, c in ipairs(order) do
        local m = c.block
        if (inv[m] or 0) <= 0 and restock and not exhausted[m] and trips < MAX_TRIPS then
            moves = moves + 2 * manhattan(cx, cy, cz, 0, 0, 0)
            trips = trips + 1
            local carried = 0
            for _, v in pairs(inv) do carried = carried + v end
            local room = max(0, INV_CAP - carried)
            local function take(mat)
                local want = (remaining[mat] or 0) - (inv[mat] or 0)
                if want <= 0 or room <= 0 then return end
                local avail = chest and (stock[mat] or 0) or want
                local got = min(want, avail, room)
                if got > 0 then
                    inv[mat] = (inv[mat] or 0) + got
                    room = room - got
                    if chest then stock[mat] = stock[mat] - got end
                end
            end
            take(m)
            for mat in pairs(remaining) do take(mat) end
            if (inv[m] or 0) <= 0 then exhausted[m] = true end
        end
        if (inv[m] or 0) > 0 then
            inv[m] = inv[m] - 1
            moves = moves + manhattan(cx, cy, cz, c.x, c.y + 1, c.z)
            cx, cy, cz = c.x, c.y + 1, c.z
            placeable = placeable + 1
        end
        remaining[m] = remaining[m] - 1
    end
    moves = moves + homeEstimate(model, cx, cy, cz)
    return { moves = moves, trips = trips, placeable = placeable }
end

local function materialRows(model, have, chest)
    local rows, short = {}, 0
    for name, need in pairs(model.counts) do
        local h = have[name] or 0
        local c = chest and (chest[name] or 0) or nil
        local s = max(0, need - h - (c or 0))
        rows[#rows + 1] = { block = name, need = need, have = h, chest = c, short = s }
        short = short + s
    end
    table.sort(rows, function(a, b)
        if a.need ~= b.need then return a.need > b.need end
        return a.block < b.block
    end)
    return rows, short
end

local function bboxOut(b)
    return {
        min = { x = b.minx, y = b.miny, z = b.minz },
        max = { x = b.maxx, y = b.maxy, z = b.maxz },
        size = { x = b.maxx - b.minx + 1, y = b.maxy - b.miny + 1, z = b.maxz - b.minz + 1 },
    }
end

local function fuelNumbers(t)
    if not t then return nil, nil, false end
    local f = t.getFuelLevel()
    if f == "unlimited" then return f, "unlimited", true end
    return f, t.getFuelLimit and t.getFuelLimit() or nil, false
end

----------------------------------------------------------------------
-- Previews
----------------------------------------------------------------------

local function makeLegend(model)
    local mats = {}
    for name in pairs(model.counts) do mats[#mats + 1] = name end
    table.sort(mats, function(a, b)
        local ca, cb = model.counts[a], model.counts[b]
        if ca ~= cb then return ca > cb end
        return a < b
    end)
    local used, charOf, legend = { ["."] = true }, {}, {}
    local pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#@%&*+=?"
    for _, name in ipairs(mats) do
        local base = name:match(":(.+)$") or name
        local ch
        for i = 1, #base do
            local c = base:sub(i, i)
            if c:match("%a") and not used[c] then ch = c; break end
        end
        if not ch then
            for i = 1, #pool do
                local c = pool:sub(i, i)
                if not used[c] then ch = c; break end
            end
        end
        ch = ch or "?"
        used[ch] = true
        charOf[name] = ch
        legend[ch] = name
    end
    return legend, charOf, mats
end

local function layerRows(model, y, charOf, x1, x2, zTop, zBottom)
    local rows = {}
    for z = zTop, zBottom, -1 do
        local row = {}
        for x = x1, x2 do
            local c = model.map[key(x, y, z)]
            row[#row + 1] = c and charOf[c.block] or "."
        end
        rows[#rows + 1] = table.concat(row)
    end
    return rows
end

function M.textPreview(model)
    local legend, charOf = makeLegend(model)
    local b = model.bbox
    local layers, used = {}, 0
    for _, y in ipairs(model.layerYs) do
        local cost = (b.maxz - b.minz + 1) * (b.maxx - b.minx + 2)
        if used + cost > TEXT_CAP then
            layers[#layers + 1] = { y = y, truncated = "text preview limit reached" }
            break
        end
        used = used + cost
        layers[#layers + 1] = { y = y, rows = layerRows(model, y, charOf, b.minx, b.maxx, b.maxz, b.minz) }
    end
    return {
        legend = legend,
        layout = ("each layer: top row is z=%d (forward is up), bottom row z=%d; columns run x=%d..%d left to right; '.' = empty")
            :format(b.maxz, b.minz, b.minx, b.maxx),
        layers = layers,
    }
end

local PALETTE = { "0", "1", "2", "3", "4", "5", "6", "9", "a", "b", "d", "e", "c", "8", "7" }

local function pickMonitor(env, wanted)
    local P = env.peripheral
    if not P then return nil end
    if wanted then
        if P.getType(wanted) == "monitor" then return wanted end
        return nil
    end
    local fallback
    for _, n in ipairs(P.getNames()) do
        if P.getType(n) == "monitor" then
            if n ~= env.chatMonitor then return n end
            fallback = n
        end
    end
    return fallback
end

-- Draw every layer as a small tile (forward is up) on a monitor.
function M.monitorPreview(model, env, wanted)
    local name = pickMonitor(env, wanted)
    if not name then return nil, wanted and ("no monitor named " .. wanted) or "no monitor attached" end
    local mon = env.peripheral.wrap(name)
    if not mon or not mon.getSize then return nil, "can't use monitor " .. name end
    pcall(mon.setTextScale, 0.5)
    local W, H = mon.getSize()
    local colour = mon.isColour and mon.isColour() or false
    local legend, charOf, mats = makeLegend(model)
    local colourOf = {}
    for i, m in ipairs(mats) do colourOf[m] = PALETTE[(i - 1) % #PALETTE + 1] end
    local b = model.bbox
    local sx, sz = b.maxx - b.minx + 1, b.maxz - b.minz + 1
    local legendRows = min(#mats, 4)
    local tw, th = min(sx, W), min(sz, max(1, H - 2 - legendRows))
    local cols = max(1, floor((W + 1) / (tw + 1)))
    local tileRows = max(1, floor((H - 1 - legendRows + 1) / (th + 2)))
    local nL = #model.layerYs
    local shown = min(nL, cols * tileRows)

    mon.setBackgroundColour(colors.black)
    mon.setTextColour(colors.white)
    mon.clear()
    mon.setCursorPos(1, 1)
    local title = ("Build %d blocks, %d layers (fwd ^)"):format(model.n, nL)
    if shown < nL then title = title .. (" %d/%d shown"):format(shown, nL) end
    mon.write(title:sub(1, W))

    for li = 1, shown do
        local y = model.layerYs[li]
        local col, row = (li - 1) % cols, floor((li - 1) / cols)
        local x0, y0 = 1 + col * (tw + 1), 2 + row * (th + 2)
        mon.setCursorPos(x0, y0)
        mon.write(("y=%d"):format(y):sub(1, tw))
        for r = 0, th - 1 do
            local z = b.maxz - r
            local text, fg, bg = {}, {}, {}
            for i = 0, tw - 1 do
                local c = model.map[key(b.minx + i, y, z)]
                if c then
                    text[#text + 1] = charOf[c.block]
                    fg[#fg + 1] = colour and "f" or "0"
                    bg[#bg + 1] = colour and colourOf[c.block] or "f"
                else
                    text[#text + 1], fg[#fg + 1], bg[#bg + 1] = ".", colour and "8" or "0", "f"
                end
            end
            mon.setCursorPos(x0, y0 + 1 + r)
            mon.blit(table.concat(text), table.concat(fg), table.concat(bg))
        end
    end

    for i = 1, legendRows do
        local m = mats[i]
        local ch = charOf[m]
        mon.setCursorPos(1, H - legendRows + i)
        mon.blit(ch, colour and "f" or "0", colour and colourOf[m] or "f")
        mon.setBackgroundColour(colors.black)
        local label = " " .. (m:match(":(.+)$") or m) .. " x" .. model.counts[m]
        if i == legendRows and #mats > legendRows then label = label .. (" (+%d more)"):format(#mats - legendRows) end
        mon.write(label:sub(1, W - 1))
    end
    return name, nil, shown
end

----------------------------------------------------------------------
-- Turtle state, movement and pathfinding
----------------------------------------------------------------------

local function newState(model, env, opts)
    local st = {
        env = env, t = env.turtle, model = model, opts = opts,
        px = 0, py = 0, pz = 0, face = 0,
        protected = {}, blocked = {}, visited = { [key(0, 0, 0)] = true },
        moves = 0, dugN = 0, dugNames = {},
    }
    local b = model.bbox
    local R = {
        minx = min(b.minx, 0), maxx = max(b.maxx, 0),
        miny = min(b.miny, 0), maxy = max(b.maxy + 2, 1),
        minz = min(b.minz, 0), maxz = max(b.maxz, 0),
    }
    if opts.restock then
        local r = RESTOCK[opts.restock]
        st.chest = { r[1], r[2], r[3] }
        st.protected[key(r[1], r[2], r[3])] = true
        R.minx, R.maxx = min(R.minx, r[1]), max(R.maxx, r[1])
        R.miny, R.maxy = min(R.miny, r[2]), max(R.maxy, r[2])
        R.minz, R.maxz = min(R.minz, r[3]), max(R.maxz, r[3])
    end
    -- one spare column on every side so the turtle can walk around the build
    R.minx, R.maxx, R.minz, R.maxz = R.minx - 1, R.maxx + 1, R.minz - 1, R.maxz + 1
    st.region = R
    return st
end

local function turnTo(st, d)
    d = d % 4
    local diff = (d - st.face) % 4
    local t = st.t
    if diff == 1 then
        t.turnRight()
    elseif diff == 2 then
        t.turnRight(); t.turnRight()
    elseif diff == 3 then
        t.turnLeft()
    end
    st.face = d
end

local MOVES = {
    forward = { "forward", "detect", "inspect", "dig", "attack", "front" },
    up      = { "up", "detectUp", "inspectUp", "digUp", "attackUp", "up" },
    down    = { "down", "detectDown", "inspectDown", "digDown", "attackDown", "down" },
}

-- Move one cell. Never enters (digs) a protected cell. Digs repeatedly for
-- falling sand/gravel; attacks mobs but only waits for players.
local function step(st, kind)
    local t, m = st.t, MOVES[kind]
    local tx, ty, tz = st.px, st.py, st.pz
    if kind == "up" then
        ty = ty + 1
    elseif kind == "down" then
        ty = ty - 1
    else
        tx, tz = tx + DX[st.face], tz + DZ[st.face]
    end
    local k = key(tx, ty, tz)
    if st.protected[k] then return false, "would break a placed block" end
    if st.blocked[k] then return false, "blocked" end
    local digs, waits = 0, 0
    while true do
        local ok, err = t[m[1]]()
        if ok then
            st.px, st.py, st.pz = tx, ty, tz
            st.visited[k] = true
            st.moves = st.moves + 1
            return true
        end
        err = tostring(err or "")
        if err:find("[Ff]uel") then return false, "out of fuel" end
        if err:find("Too high") or err:find("Too low") or err:find("leave") then
            st.blocked[k] = true
            return false, err
        end
        if t[m[2]]() then
            local has, info = t[m[3]]()
            local name = (has and type(info) == "table" and normName(info.name)) or "unknown block"
            if isNoDig(name) then
                st.blocked[k] = true
                return false, "won't dig " .. name
            end
            if digs >= MAX_DIGS then
                st.blocked[k] = true
                return false, ("still blocked after %d digs (%s)"):format(digs, name)
            end
            local dug, derr = t[m[4]]()
            if not dug then
                st.blocked[k] = true
                return false, "can't dig " .. name .. (derr and (" (" .. tostring(derr) .. ")") or "")
            end
            digs = digs + 1
            st.dugN = st.dugN + 1
            st.dugNames[name] = (st.dugNames[name] or 0) + 1
        else
            -- Nothing solid there, so an entity is in the way.
            if waits >= MAX_WAITS then return false, "blocked by an entity" end
            waits = waits + 1
            local player = st.env.isPlayer(m[6]) -- true, false, or nil (unknown)
            if not (player == false and t[m[5]]()) then
                st.env.sleep(player == false and 0.25 or 0.5)
            end
        end
    end
end

local function routeClear(st, order, tx, ty, tz)
    local x, y, z = st.px, st.py, st.pz
    local P, B = st.protected, st.blocked
    for _, ax in ipairs(order) do
        if ax == "x" then
            local s = tx > x and 1 or -1
            while x ~= tx do
                x = x + s
                local k = key(x, y, z)
                if P[k] or B[k] then return false end
            end
        elseif ax == "y" then
            local s = ty > y and 1 or -1
            while y ~= ty do
                y = y + s
                local k = key(x, y, z)
                if P[k] or B[k] then return false end
            end
        else
            local s = tz > z and 1 or -1
            while z ~= tz do
                z = z + s
                local k = key(x, y, z)
                if P[k] or B[k] then return false end
            end
        end
    end
    return true
end

local function followOrder(st, order, tx, ty, tz)
    for _, ax in ipairs(order) do
        if ax == "y" then
            while st.py ~= ty do
                local ok, e = step(st, st.py < ty and "up" or "down")
                if not ok then return false, e end
            end
        elseif ax == "x" then
            if st.px ~= tx then turnTo(st, st.px < tx and 1 or 3) end
            while st.px ~= tx do
                local ok, e = step(st, "forward")
                if not ok then return false, e end
            end
        else
            if st.pz ~= tz then turnTo(st, st.pz < tz and 0 or 2) end
            while st.pz ~= tz do
                local ok, e = step(st, "forward")
                if not ok then return false, e end
            end
        end
    end
    return true
end

local NEI = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }

-- Cheapest route through non-protected cells inside the build's region
-- (bounding box plus a spare ring). Cells the turtle has already been in cost
-- 1, unknown cells 3 (they may need digging). With `goals`, stops at the first
-- goal reached; with `near`, returns the reachable cell closest to it.
local function findPath(st, goals, near)
    local R, sx, sy, sz = st.region, st.px, st.py, st.pz
    local minx, maxx = min(R.minx, sx), max(R.maxx, sx)
    local miny, maxy = min(R.miny, sy), max(R.maxy, sy)
    local minz, maxz = min(R.minz, sz), max(R.maxz, sz)
    for _, g in ipairs(goals or {}) do
        minx, maxx = min(minx, g[1]), max(maxx, g[1])
        miny, maxy = min(miny, g[2]), max(maxy, g[2])
        minz, maxz = min(minz, g[3]), max(maxz, g[3])
    end
    local SX, SZ = maxx - minx + 1, maxz - minz + 1
    local function enc(x, y, z) return ((y - miny) * SZ + (z - minz)) * SX + (x - minx) end
    local function dec(i)
        local x = i % SX
        local r = (i - x) / SX
        local z = r % SZ
        return x + minx, (r - z) / SZ + miny, z + minz
    end
    local goalSet = {}
    for _, g in ipairs(goals or {}) do goalSet[enc(g[1], g[2], g[3])] = true end

    local P, B, V = st.protected, st.blocked, st.visited
    local dist, parent, pdir, buckets = {}, {}, {}, {}
    local s = enc(sx, sy, sz)
    dist[s], buckets[0] = 0, { s }
    local cur, top, ops = 0, 0, 0
    local best, bestScore, bestCost = nil, HUGE, HUGE
    while cur <= top do
        local bucket = buckets[cur]
        if bucket then
            buckets[cur] = nil
            for bi = 1, #bucket do
                local u = bucket[bi]
                if dist[u] == cur then
                    local ux, uy, uz = dec(u)
                    if goals then
                        if goalSet[u] then best = u; break end
                    else
                        local sc = manhattan(ux, uy, uz, near[1], near[2], near[3]) * 4
                            + ((uy < near[2]) and 2 or ((uy > near[2]) and 1 or 0))
                        if sc < bestScore or (sc == bestScore and cur < bestCost) then
                            best, bestScore, bestCost = u, sc, cur
                        end
                    end
                    for d = 1, 6 do
                        local n = NEI[d]
                        local vx, vy, vz = ux + n[1], uy + n[2], uz + n[3]
                        if vx >= minx and vx <= maxx and vy >= miny and vy <= maxy and vz >= minz and vz <= maxz then
                            local wk = key(vx, vy, vz)
                            if not P[wk] and not B[wk] then
                                local v = enc(vx, vy, vz)
                                local nd = cur + (V[wk] and 1 or 3)
                                local dv = dist[v]
                                if dv == nil or nd < dv then
                                    dist[v], parent[v], pdir[v] = nd, u, d
                                    local nb = buckets[nd]
                                    if not nb then nb = {}; buckets[nd] = nb end
                                    nb[#nb + 1] = v
                                    if nd > top then top = nd end
                                elseif nd == dv and pdir[u] == d and pdir[v] ~= d then
                                    parent[v], pdir[v] = u, d -- same cost, fewer turns
                                end
                            end
                        end
                    end
                    ops = ops + 1
                    if ops % 5000 == 0 then st.env.yield() end
                end
            end
            if goals and best then break end
        end
        cur = cur + 1
    end
    if not best then return nil end
    local path, v = {}, best
    while v ~= s do
        local x, y, z = dec(v)
        path[#path + 1] = { x, y, z }
        v = parent[v]
    end
    for i = 1, floor(#path / 2) do path[i], path[#path - i + 1] = path[#path - i + 1], path[i] end
    return path
end

local function followPath(st, path)
    for _, p in ipairs(path) do
        local ok, e
        if p[2] > st.py then
            ok, e = step(st, "up")
        elseif p[2] < st.py then
            ok, e = step(st, "down")
        else
            local dx, dz = p[1] - st.px, p[3] - st.pz
            turnTo(st, (dz == 1 and 0) or (dx == 1 and 1) or (dz == -1 and 2) or 3)
            ok, e = step(st, "forward")
        end
        if not ok then return false, e end
    end
    return true
end

local ORDERS_UP = { { "y", "x", "z" }, { "y", "z", "x" }, { "x", "y", "z" }, { "z", "y", "x" }, { "x", "z", "y" }, { "z", "x", "y" } }
local ORDERS_DOWN = { { "x", "z", "y" }, { "z", "x", "y" }, { "x", "y", "z" }, { "z", "y", "x" }, { "y", "x", "z" }, { "y", "z", "x" } }

-- Go to (tx,ty,tz) without entering protected cells: a straight axis-by-axis
-- route if one is clear, otherwise a planned path (re-planned after blockages).
local function travel(st, tx, ty, tz)
    if st.px == tx and st.py == ty and st.pz == tz then return true end
    for _, o in ipairs(ty >= st.py and ORDERS_UP or ORDERS_DOWN) do
        if routeClear(st, o, tx, ty, tz) then
            local ok, e = followOrder(st, o, tx, ty, tz)
            if ok then return true end
            if e == "out of fuel" then return false, e end
            break
        end
    end
    local lastErr = "no route that avoids the build"
    for _ = 1, 5 do
        if st.px == tx and st.py == ty and st.pz == tz then return true end
        local path = findPath(st, { { tx, ty, tz } })
        if not path then return false, lastErr end
        local ok, e = followPath(st, path)
        if ok then return true end
        lastErr = e
        if e == "out of fuel" then return false, e end
        if e == "blocked by an entity" then st.env.sleep(1) end
    end
    return false, lastErr
end

-- Return to the start cell, or park as close to it as the build allows.
local function goHome(st)
    local ok, why = false, "the start cell is part of the build"
    if not st.protected[key(0, 0, 0)] then ok, why = travel(st, 0, 0, 0) end
    if not ok then
        local path = findPath(st, nil, { 0, 0, 0 })
        if path then followPath(st, path) end
    end
    local home = st.px == 0 and st.py == 0 and st.pz == 0
    if home then turnTo(st, 0) end
    return home, why
end

----------------------------------------------------------------------
-- Inventory, placing and restocking
----------------------------------------------------------------------

local function findSlot(st, name)
    local t, cache = st.t, st.slotCache
    local s = cache[name]
    if s then
        local d = t.getItemDetail(s)
        if d and normName(d.name) == name and d.count > 0 then return s end
    end
    for s2 = 1, 16 do
        local d = t.getItemDetail(s2)
        if d and normName(d.name) == name and d.count > 0 then
            cache[name] = s2
            return s2
        end
    end
    cache[name] = nil
    return nil
end

-- The turtle is directly above cell c. Returns "placed", "present",
-- "occupied" (existing block left alone), "replaced" or "failed", detail.
local function placeAt(st, c, slot)
    local t, k = st.t, key(c.x, c.y, c.z)
    if c.facing then turnTo(st, c.facing) end
    t.select(slot)
    local replaced
    if t.detectDown() then
        local has, info = t.inspectDown()
        local existing = (has and type(info) == "table" and normName(info.name)) or "unknown block"
        if existing == c.block then
            st.protected[k] = true
            return "present"
        end
        -- Replaceable blocks (grass, snow layers) take the new block directly.
        if t.placeDown() then
            st.protected[k] = true
            return "placed"
        end
        if not st.opts.replace or isNoDig(existing) then
            st.protected[k] = true -- leave it, and never dig it on the way past either
            return "occupied", existing
        end
        local tries = 0
        while t.detectDown() and tries < 8 do
            local d, e = t.digDown()
            if not d then
                st.protected[k] = true
                return "occupied", existing .. " (can't dig" .. (e and (": " .. tostring(e)) or "") .. ")"
            end
            tries = tries + 1
        end
        replaced = existing
    end
    local lastErr = "place failed"
    for _ = 1, 6 do
        local ok, err = t.placeDown()
        if ok then
            st.protected[k] = true
            if replaced then return "replaced", replaced end
            return "placed"
        end
        lastErr = tostring(err or lastErr)
        if t.detectDown() then break end
        -- Probably an entity in the cell: hit mobs, wait for players.
        local player = st.env.isPlayer("down")
        if not (player == false and t.attackDown()) then st.env.sleep(0.5) end
    end
    return "failed", lastErr
end

-- Go to the restock chest, take what it gives, put back anything the rest of
-- the build doesn't need, and come back. `needed` = set of item ids.
local function restock(st, needed)
    local t, cx, cy, cz = st.t, st.chest[1], st.chest[2], st.chest[3]
    local rx, ry, rz = st.px, st.py, st.pz
    local ok, e = false, nil
    if not st.protected[key(0, 0, 0)] then ok, e = travel(st, 0, 0, 0) end
    if not ok then
        local goals = {}
        for _, n in ipairs(NEI) do
            local gx, gy, gz = cx + n[1], cy + n[2], cz + n[3]
            if not st.protected[key(gx, gy, gz)] then goals[#goals + 1] = { gx, gy, gz } end
        end
        local path = findPath(st, goals)
        if not path then return false, "no route to the restock chest" end
        ok, e = followPath(st, path)
        if not ok then return false, "couldn't reach the restock chest: " .. tostring(e) end
    end
    local suck, drop
    if st.px == cx and st.pz == cz and st.py == cy + 1 then
        suck, drop = t.suckDown, t.dropDown
    elseif st.px == cx and st.pz == cz and st.py == cy - 1 then
        suck, drop = t.suckUp, t.dropUp
    else
        local dx, dz = cx - st.px, cz - st.pz
        turnTo(st, (dz == 1 and 0) or (dx == 1 and 1) or (dz == -1 and 2) or 3)
        suck, drop = t.suck, t.drop
    end
    local before = {}
    for s = 1, 16 do
        local d = t.getItemDetail(s)
        before[s] = d and { name = normName(d.name), count = d.count } or false
    end
    local pulls = 0
    for _ = 1, 16 do
        if not suck() then break end
        pulls = pulls + 1
    end
    local returned = 0
    for s = 1, 16 do
        local d = t.getItemDetail(s)
        if d then
            local n, b = normName(d.name), before[s]
            local extra = d.count - ((b and b.name == n) and b.count or 0)
            if extra > 0 and not needed[n] then
                t.select(s)
                if drop(extra) then returned = returned + extra end
            end
        end
    end
    st.slotCache = {}
    local back, be = travel(st, rx, ry, rz)
    if not back then return false, "couldn't get back to the build: " .. tostring(be) end
    return true, { pulled_stacks = pulls, returned = returned }
end

----------------------------------------------------------------------
-- Dry run and build
----------------------------------------------------------------------

function M.dryRun(model, order, env, opts)
    local t = env.turtle
    local have = readInventory(t)
    local chest, chestErr
    if opts.restock then chest, chestErr = scanChest(env, opts.restock) end
    local rows, short = materialRows(model, have, chest)
    local sim = simulate(model, order, have, chest, opts.restock)
    -- Fuel for the whole build: exact plan if everything is on hand (incl.
    -- restock trips); otherwise as if the missing materials were supplied.
    local needed, nowMoves = sim.moves, nil
    if sim.placeable < model.n then
        needed = max(sim.moves, simulate(model, order, nil, nil, nil).moves)
        nowMoves = sim.moves
    end
    local level, limit, unlimited = fuelNumbers(t)
    local fuelOk = unlimited or (type(level) == "number" and level >= needed)
    local layers = {}
    for _, y in ipairs(model.layerYs) do layers[#layers + 1] = { y = y, blocks = #model.byLayer[y] } end
    local warnings = {}
    if model.map[key(0, 0, 0)] then
        warnings[#warnings + 1] = "The start cell (0,0,0) is part of the build, so the turtle will park beside it instead of returning home."
    end
    if short > 0 then
        warnings[#warnings + 1] = ("Short %d blocks; cells without material are skipped and listed as missing."):format(short)
    end
    if not fuelOk and type(level) == "number" then
        warnings[#warnings + 1] = ("Not enough fuel: the full build needs about %d, the turtle has %d."):format(needed, level)
    end
    if opts.restock and not chest then
        warnings[#warnings + 1] = "Restock chest not readable (" .. tostring(chestErr) .. "); estimates assume it has enough."
    end
    return {
        dry_run = true,
        frame = M.FRAME,
        total_blocks = model.n,
        carved = model.carved > 0 and model.carved or nil,
        bbox = bboxOut(model.bbox),
        layers = layers,
        materials = rows,
        shortfall = short,
        fuel = {
            needed = needed,
            needed_with_current_materials = nowMoves,
            recommended = ceil(needed * 1.1) + 10,
            level = level, limit = limit, ok = fuelOk,
        },
        restock = opts.restock and {
            side = opts.restock, chest_read = chest ~= nil, est_trips = sim.trips,
        } or nil,
        est_minutes = floor((needed + model.n) * SECS_PER_OP / 6 + 0.5) / 10,
        warnings = #warnings > 0 and warnings or nil,
    }
end

function M.run(model, order, env, opts)
    local t, log = env.turtle, env.log
    local fuel0, _, unlimited = fuelNumbers(t)
    local have = readInventory(t)
    local chest = opts.restock and scanChest(env, opts.restock) or nil
    local sim = simulate(model, order, have, chest, opts.restock)
    if not unlimited and fuel0 < sim.moves then
        return {
            error = ("Not enough fuel: this build needs about %d moves (recommended %d fuel) and the turtle has %d. "
                .. "Refuel with turtle_inventory action=refuel, or build it in sections."):format(
                sim.moves, ceil(sim.moves * 1.1) + 10, fuel0),
            fuel_needed = sim.moves, fuel_level = fuel0, total_blocks = model.n,
        }
    end

    local st = newState(model, env, opts)
    st.slotCache = {}
    local remaining = {}
    for k, v in pairs(model.counts) do remaining[k] = v end

    local placed, present, replacedN, skippedN, failedN = 0, 0, 0, 0, 0
    local skipped, failed, replaced, missing = {}, {}, {}, {}
    local exhausted, trips, fails = {}, 0, 0
    local stopped, notAttempted
    local layerIdx, lastY = 0, nil

    log(("Build: %d blocks, %d layers, fuel ~%d"):format(model.n, #model.layerYs, sim.moves))

    for i, c in ipairs(order) do
        if c.y ~= lastY then
            lastY, layerIdx = c.y, layerIdx + 1
            log(("layer %d/%d (y=%d)"):format(layerIdx, #model.layerYs, c.y))
        end

        local slot = findSlot(st, c.block)
        if not slot and opts.restock and not exhausted[c.block] and trips < MAX_TRIPS then
            if not unlimited then
                local need = manhattan(st.px, st.py, st.pz, 0, 0, 0) * 2 + homeEstimate(model, st.px, st.py, st.pz) + 2
                if t.getFuelLevel() < need then
                    stopped = "low fuel (not enough for a restock trip)"
                    notAttempted = #order - i + 1
                    break
                end
            end
            local needed = {}
            for m, n in pairs(remaining) do if n > 0 then needed[m] = true end end
            trips = trips + 1
            log(("restock trip %d (%s)"):format(trips, c.block:match(":(.+)$") or c.block))
            local ok, info = restock(st, needed)
            if not ok then
                log("restock failed: " .. tostring(info))
                for m in pairs(needed) do exhausted[m] = true end
                if tostring(info):find("fuel") then
                    stopped = "out of fuel during restock"
                    notAttempted = #order - i + 1
                    break
                end
            end
            slot = findSlot(st, c.block)
            if not slot then exhausted[c.block] = true end
        end

        if not slot then
            missing[c.block] = (missing[c.block] or 0) + 1
        else
            local ax, ay, az = c.x, c.y + 1, c.z
            if not unlimited then
                local need = manhattan(st.px, st.py, st.pz, ax, ay, az) + homeEstimate(model, ax, ay, az) + 2
                local fuel = t.getFuelLevel()
                if fuel < need then
                    stopped = ("low fuel (%d left, about %d needed to place the next block and get home)"):format(fuel, need)
                    notAttempted = #order - i + 1
                    break
                end
            end
            local ok, why = travel(st, ax, ay, az)
            if not ok then
                failedN, fails = failedN + 1, fails + 1
                addCapped(failed, { x = c.x, y = c.y, z = c.z, block = c.block, reason = "can't reach: " .. tostring(why) })
                if why == "out of fuel" then
                    stopped = "out of fuel"
                    notAttempted = #order - i
                    break
                end
                if fails >= MAX_FAILS then
                    stopped = ("gave up after %d unreachable cells in a row"):format(fails)
                    notAttempted = #order - i
                    break
                end
            else
                fails = 0
                local res, detail = placeAt(st, c, slot)
                if res == "placed" then
                    placed = placed + 1
                elseif res == "present" then
                    present = present + 1
                elseif res == "replaced" then
                    placed, replacedN = placed + 1, replacedN + 1
                    addCapped(replaced, { x = c.x, y = c.y, z = c.z, was = detail })
                elseif res == "occupied" then
                    skippedN = skippedN + 1
                    addCapped(skipped, { x = c.x, y = c.y, z = c.z, existing = detail })
                else
                    failedN = failedN + 1
                    addCapped(failed, { x = c.x, y = c.y, z = c.z, block = c.block, reason = detail })
                end
            end
        end
        remaining[c.block] = remaining[c.block] - 1
    end

    local home, homeWhy = goHome(st)
    local fuel1 = t.getFuelLevel()
    local result = {
        complete = (placed + present) == model.n,
        total = model.n,
        placed = placed,
        already_present = present > 0 and present or nil,
        skipped_occupied = skippedN > 0 and {
            count = skippedN, cells = skipped,
            hint = "Existing blocks were left in place. Use replace=true to dig and replace them.",
        } or nil,
        replaced = replacedN > 0 and { count = replacedN, cells = replaced } or nil,
        missing = next(missing) and missing or nil,
        failed = failedN > 0 and { count = failedN, cells = failed } or nil,
        dug_while_moving = st.dugN > 0 and { count = st.dugN, blocks = st.dugNames } or nil,
        restock_trips = opts.restock and trips or nil,
        stopped = stopped,
        not_attempted = notAttempted,
        position = { x = st.px, y = st.py, z = st.pz },
        facing = FACING_NAME[st.face],
        home = home,
        note = (not home) and ("Not back at the start (" .. tostring(homeWhy) .. "); parked at position, "
            .. "which is relative to the start: x=right, y=up, z=forward.") or nil,
        fuel = unlimited and "unlimited" or { start = fuel0, used = fuel0 - fuel1, remaining = fuel1 },
        frame = M.FRAME,
    }
    log(("done: %d/%d placed%s, %s"):format(placed + present, model.n,
        stopped and (" (stopped: " .. stopped .. ")") or "",
        home and "home" or ("parked at " .. st.px .. "," .. st.py .. "," .. st.pz)))
    return result
end

----------------------------------------------------------------------
-- Entry point for the build_structure tool
----------------------------------------------------------------------

local function defaultIsPlayer(dir)
    if claude and claude.isPlayerBlocking then
        local ok, r = pcall(claude.isPlayerBlocking, dir)
        if ok then return r == true end
    end
    return nil -- unknown: callers then wait instead of attacking
end

local function makeEnv(e)
    e = e or {}
    return {
        turtle = e.turtle or turtle,
        peripheral = e.peripheral or peripheral,
        log = e.log or function() end,
        sleep = e.sleep or (os and os.sleep) or sleep,
        yield = e.yield or function()
            os.queueEvent("claudecraft_build_yield")
            os.pullEvent("claudecraft_build_yield")
        end,
        isPlayer = e.isPlayer or defaultIsPlayer,
        chatMonitor = e.chatMonitor,
        onPreview = e.onPreview or function() end,
    }
end

--- Run the build_structure tool. `envIn` may supply turtle, peripheral, log,
-- sleep, yield, isPlayer, chatMonitor (name of the chat mirror monitor) and
-- onPreview(monitorName).
function M.handle(input, envIn)
    local env = makeEnv(envIn)
    input = type(input) == "table" and input or {}
    local opts = {
        dry = input.dry_run == true or input.dry_run == "true",
        replace = input.replace == true or input.replace == "true",
    }
    local rc = input.restock_chest
    if rc ~= nil and rc ~= false and rc ~= "" then
        local side = tostring(rc):lower()
        if not RESTOCK[side] then return { error = "restock_chest must be one of back, down, up, left, right, front" } end
        opts.restock = side
    end
    local preview = input.preview
    if preview == true then preview = "monitor" end
    if preview ~= nil and preview ~= false and preview ~= "monitor" and preview ~= "text" and preview ~= "both" then
        return { error = "preview must be 'monitor', 'text' or 'both'" }
    end
    if not env.turtle and not opts.dry then return { error = "Not a turtle" } end

    local model, err = M.expand(input, env.yield)
    if not model then return { error = err } end
    if opts.restock then
        local r = RESTOCK[opts.restock]
        if model.map[key(r[1], r[2], r[3])] then
            return { error = ("The restock chest's cell (%d,%d,%d) is inside the blueprint."):format(r[1], r[2], r[3]) }
        end
    end
    local order = M.plan(model, env.yield)

    local previewOut
    if preview and preview ~= false then
        previewOut = {}
        if preview == "text" or preview == "both" then previewOut.text = M.textPreview(model) end
        if preview == "monitor" or preview == "both" then
            local name, perr = M.monitorPreview(model, env, input.preview_monitor)
            if name then
                previewOut.monitor = name
                env.onPreview(name)
            else
                previewOut.monitor_error = perr
            end
        end
    end

    local res
    if opts.dry then
        res = M.dryRun(model, order, env, opts)
    else
        res = M.run(model, order, env, opts)
    end
    if previewOut then res.preview = previewOut end
    return res
end

-- Exposed for offline tests only.
M._internal = { key = key, simulate = simulate, newState = newState, findPath = findPath }

return M
