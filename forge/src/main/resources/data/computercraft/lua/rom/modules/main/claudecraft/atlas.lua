-- claudecraft/atlas.lua - shared, world-saved base atlas tools for claude.lua
--
-- The data lives on the server (NeoForge SavedData, see com.claudecraft.atlas),
-- so every computer and turtle in the world sees the same waypoints and chest
-- index. This module wraps the claude.atlas* Lua API as Claude tools and
-- indexes scan_inventory results automatically.
--
-- Groups: tools take an optional `group`. A computer's default group can be
-- set by writing a name to /.claude/atlas_group (scan_inventory results are
-- indexed into that group too). Without it, everything uses the shared
-- "default" group.

local M = {}

M.GROUP_FILE = "/.claude/atlas_group"

local function available()
    return type(claude) == "table" and claude.atlasSearch ~= nil
end

function M.defaultGroup()
    if not fs.exists(M.GROUP_FILE) then return nil end
    local f = fs.open(M.GROUP_FILE, "r"); if not f then return nil end
    local g = (f.readAll() or ""):match("^%s*(%S+)"); f.close()
    return g
end

local function groupOf(input)
    local g = input and input.group
    if type(g) == "string" and g:find("%S") then return g end
    return M.defaultGroup()
end

-- Calls an atlas API function, turning Lua errors into an error string.
local function call(fn, arg)
    local ok, r = pcall(fn, arg)
    if not ok then return nil, (tostring(r):gsub("^[^:]*:%d+: ", "")) end
    return r
end

local function dim(d) return (tostring(d or "?"):gsub("^minecraft:", "")) end

local function fmtAge(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 90 then return sec.."s ago" end
    local m = math.floor(sec / 60)
    if m < 90 then return m.."m ago" end
    local h = math.floor(m / 60)
    if h < 48 then return string.format("%dh %dm ago", h, m % 60) end
    return math.floor(h / 24).."d ago"
end

local function waypointLine(w)
    local s = string.format("%s: %d,%d,%d %s", w.name, w.x, w.y, w.z, dim(w.dimension))
    if w.distance then s = s..string.format(" (%d blocks away)", w.distance) end
    if w.note and w.note ~= "" then s = s.." - "..w.note end
    return s..string.format(" [by #%d]", w.computer or -1)
end

local function itemLine(m)
    local name = m.item
    if m.display and m.display ~= "" then name = name.." ("..m.display..")" end
    local where
    if m.exact then
        where = string.format("in chest at %d,%d,%d %s ('%s' of computer #%d)",
            m.x, m.y, m.z, dim(m.dimension), m.peripheral, m.computer)
    else
        where = string.format("in '%s' on the network of computer #%d at %d,%d,%d %s",
            m.peripheral, m.computer, m.x, m.y, m.z, dim(m.dimension))
    end
    if m.distance then where = where..string.format(", %d blocks away", m.distance) end
    return string.format("%dx %s %s, scanned %s", m.count, name, where, fmtAge(m.age_seconds))
end

local function groupProp()
    return {type="string", description="Optional atlas group, for teams that keep separate atlases. Omit to use this computer's default (normally the shared group)."}
end

function M.toolDefs()
    if not available() then return {} end
    return {
        {name="set_waypoint", description="Save a named location in the shared base atlas, which every computer and turtle in this world can read. Omit x/y/z to mark this computer's current position. Re-using a name moves that waypoint.", input_schema={type="object",properties={name={type="string",description="Waypoint name, e.g. 'home', 'iron farm'"},x={type="number"},y={type="number"},z={type="number"},dimension={type="string",description="overworld, the_nether, the_end or a full dimension id. Default: this computer's dimension"},note={type="string",description="Optional short note"},group=groupProp()},required={"name"}}},
        {name="list_waypoints", description="List waypoints in the shared base atlas, nearest first, with distance from this computer.", input_schema={type="object",properties={filter={type="string",description="Only waypoints whose name or note contains this text"},group=groupProp()}}},
        {name="remove_waypoint", description="Delete a waypoint from the shared base atlas by name.", input_schema={type="object",properties={name={type="string"},group=groupProp()},required={"name"}}},
        {name="atlas_search", description="Answer 'where is my X?' from the shared base atlas: stored chest contents (indexed automatically whenever any computer runs scan_inventory) plus waypoint names and notes. Stored data only, no live scan: each hit says how long ago it was scanned, and chests never scanned are not covered.", input_schema={type="object",properties={query={type="string",description="Item or place to look for, e.g. 'diamond', 'oak log', 'farm'"},limit={type="number",description="Max item hits (default 20, max 50)"},group=groupProp()},required={"query"}}},
    }
end

--- Runs an atlas tool. Returns nil if the tool is not an atlas tool.
function M.exec(name, input)
    if name ~= "set_waypoint" and name ~= "list_waypoints" and name ~= "remove_waypoint" and name ~= "atlas_search" then
        return nil
    end
    if not available() then return {error="Atlas API not available on this server"} end
    input = input or {}
    local group = groupOf(input)

    if name == "set_waypoint" then
        local r, err = call(claude.atlasSetWaypoint, {name=input.name, x=input.x, y=input.y, z=input.z,
            dimension=input.dimension, note=input.note, group=group})
        if not r then return {error=err} end
        return {success=true, waypoint=waypointLine(r.waypoint), replaced=r.replaced, group=r.group}

    elseif name == "list_waypoints" then
        local r, err = call(claude.atlasListWaypoints, {filter=input.filter, group=group})
        if not r then return {error=err} end
        local lines = {}
        for _, w in ipairs(r.waypoints or {}) do lines[#lines+1] = waypointLine(w) end
        local out = {group=r.group, matches=lines, count=#lines, total=r.total}
        if r.total == 0 then out.message = "No waypoints in group '"..r.group.."' yet. Use set_waypoint." end
        return out

    elseif name == "remove_waypoint" then
        local r, err = call(claude.atlasRemoveWaypoint, {name=input.name, group=group})
        if not r then return {error=err} end
        if not r.removed then
            return {error="No waypoint named '"..tostring(input.name).."' in group '"..r.group.."'"}
        end
        return {success=true, removed=waypointLine(r.waypoint), group=r.group}

    else -- atlas_search
        local r, err = call(claude.atlasSearch, {query=input.query, limit=input.limit, group=group})
        if not r then return {error=err} end
        local lines, wps = {}, {}
        for _, m in ipairs(r.matches or {}) do lines[#lines+1] = itemLine(m) end
        for _, w in ipairs(r.waypoints or {}) do wps[#wps+1] = waypointLine(w) end
        local out = {query=r.query, group=r.group, matches=lines, count=#lines,
            total_matches=r.total_matches, totals=r.totals, inventories_indexed=r.inventories_indexed,
            waypoints=wps}
        if r.oldest_age_seconds then
            out.staleness = string.format("Stored scans, newest %s, oldest %s (world time). Rescan with scan_inventory if exact counts matter.",
                fmtAge(r.newest_age_seconds), fmtAge(r.oldest_age_seconds))
        elseif (r.inventories_indexed or 0) == 0 then
            out.message = "No inventories indexed in group '"..r.group.."' yet. Run scan_inventory on chests to index them."
        else
            out.message = string.format("No indexed inventory holds '%s' (%d indexed). Chests never scanned are not covered.",
                r.query, r.inventories_indexed)
        end
        return out
    end
end

--- Post-tool hook: index scan_inventory results in the atlas. Never raises.
function M.observe(name, input, result)
    if name ~= "scan_inventory" or not available() then return end
    if type(result) ~= "table" or result.error or type(result.slots) ~= "table" then return end
    if type(input) ~= "table" or type(input.peripheral) ~= "string" then return end
    local items = {}
    for _, s in ipairs(result.slots) do
        if type(s) == "table" and s.name then
            items[#items+1] = {name=s.name, count=s.count, displayName=s.displayName}
        end
    end
    pcall(claude.atlasRecordInventory, {peripheral=input.peripheral, items=items,
        size=result.size, group=M.defaultGroup()})
end

return M
