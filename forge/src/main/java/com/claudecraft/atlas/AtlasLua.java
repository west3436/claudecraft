package com.claudecraft.atlas;

import dan200.computercraft.api.component.ComputerComponents;
import dan200.computercraft.api.lua.IArguments;
import dan200.computercraft.api.lua.IComputerSystem;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.peripheral.IComputerAccess;
import dan200.computercraft.api.turtle.ITurtleAccess;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;

import java.util.*;

/**
 * Lua-facing operations on the shared base atlas. Every method must run on the
 * server thread; {@link com.claudecraft.api.ClaudeAPI} exposes them as
 * {@code @LuaFunction(mainThread = true)}.
 *
 * Each public entry point resolves where the calling computer is, then hands off
 * to a package-private core that only needs the {@link AtlasData} and that
 * location. Results are plain Maps/Lists, which CC:Tweaked turns into Lua tables.
 */
public final class AtlasLua {
    private AtlasLua() {}

    private static final int MAX_NAME = 48;
    private static final int MAX_NOTE = 200;
    private static final int MAX_QUERY = 64;
    private static final int MAX_LIST = 100;
    private static final Set<String> SIDES = Set.of("front", "back", "left", "right", "top", "bottom");

    /**
     * Where the calling computer is. {@code facing} is null when unknown (pocket
     * computers); {@code now} is overworld game time, used for ages.
     */
    record Here(String dimension, BlockPos pos, Direction facing, long now) {}

    // ------------------------------------------------------------------
    // Lua entry points
    // ------------------------------------------------------------------

    /** claude.atlasSetWaypoint{name, x?, y?, z?, dimension?, note?, group?} */
    public static Map<String, Object> setWaypoint(IComputerAccess computer, IArguments args) throws LuaException {
        Map<?, ?> t = args.getTable(0);
        ServerLevel level = level(computer);
        return setWaypoint(AtlasData.get(level.getServer()), here(computer, level), computer.getID(), t);
    }

    /** claude.atlasListWaypoints{group?, filter?} -> {group, count, total, waypoints} sorted nearest first. */
    public static Map<String, Object> listWaypoints(IComputerAccess computer, IArguments args) throws LuaException {
        Map<?, ?> t = args.optTable(0).orElse(Map.of());
        ServerLevel level = level(computer);
        return listWaypoints(AtlasData.get(level.getServer()), here(computer, level), t);
    }

    /** claude.atlasRemoveWaypoint(name, group?) or claude.atlasRemoveWaypoint{name, group?} */
    public static Map<String, Object> removeWaypoint(IComputerAccess computer, IArguments args) throws LuaException {
        Map<?, ?> t = tableOrKey(args, "name");
        ServerLevel level = level(computer);
        return removeWaypoint(AtlasData.get(level.getServer()), here(computer, level), t);
    }

    /** claude.atlasRecordInventory{peripheral, items = {{name, count, displayName?}, ...}, size?, group?} */
    public static Map<String, Object> recordInventory(IComputerAccess computer, IArguments args) throws LuaException {
        Map<?, ?> t = args.getTable(0);
        ServerLevel level = level(computer);
        return recordInventory(AtlasData.get(level.getServer()), here(computer, level), computer.getID(), t);
    }

    /** claude.atlasSearch(query, group?) or claude.atlasSearch{query, group?, limit?} */
    public static Map<String, Object> search(IComputerAccess computer, IArguments args) throws LuaException {
        Map<?, ?> t = tableOrKey(args, "query");
        ServerLevel level = level(computer);
        return search(AtlasData.get(level.getServer()), here(computer, level), t);
    }

    // ------------------------------------------------------------------
    // Cores
    // ------------------------------------------------------------------

    static Map<String, Object> setWaypoint(AtlasData data, Here here, int computerId, Map<?, ?> t) throws LuaException {
        String name = str(t, "name", MAX_NAME);
        if (name == null) throw new LuaException("Waypoint name required");

        Integer x = num(t, "x"), y = num(t, "y"), z = num(t, "z");
        String dimension;
        if (x == null && y == null && z == null) {
            // No coordinates: mark where this computer (or turtle) is right now.
            x = here.pos().getX();
            y = here.pos().getY();
            z = here.pos().getZ();
            dimension = here.dimension();
        } else if (x == null || y == null || z == null) {
            throw new LuaException("Give all of x, y, z (or none, to use this computer's position)");
        } else {
            dimension = dimension(str(t, "dimension", 64), here.dimension());
        }
        checkCoords(x, y, z);

        String group = group(t.get("group"));
        AtlasData.Group g = data.getGroup(group);
        boolean exists = g != null && g.waypoints.containsKey(name.toLowerCase(Locale.ROOT));
        if (!exists) {
            if (!data.canCreateGroup(group)) throw new LuaException("Too many atlas groups (max " + AtlasData.MAX_GROUPS + ")");
            if (g != null && g.waypoints.size() >= AtlasData.MAX_WAYPOINTS) {
                throw new LuaException("Atlas group '" + group + "' is full (" + AtlasData.MAX_WAYPOINTS + " waypoints); remove some first");
            }
        }

        AtlasData.Waypoint w = new AtlasData.Waypoint();
        w.name = name;
        w.dimension = dimension;
        w.x = x;
        w.y = y;
        w.z = z;
        String note = str(t, "note", MAX_NOTE);
        w.note = note != null ? note : "";
        w.computerId = computerId;
        w.createdTick = here.now();
        AtlasData.Waypoint prev = data.putWaypoint(group, w);

        Map<String, Object> r = new HashMap<>();
        r.put("waypoint", waypointMap(w, here));
        r.put("replaced", prev != null);
        r.put("group", group);
        return r;
    }

    static Map<String, Object> listWaypoints(AtlasData data, Here here, Map<?, ?> t) throws LuaException {
        String group = group(t.get("group"));
        String filter = str(t, "filter", MAX_QUERY);
        String needle = filter != null ? filter.toLowerCase(Locale.ROOT) : null;

        AtlasData.Group g = data.getGroup(group);
        List<AtlasData.Waypoint> found = new ArrayList<>();
        int total = 0;
        if (g != null) {
            total = g.waypoints.size();
            for (AtlasData.Waypoint w : g.waypoints.values()) {
                if (needle == null || w.name.toLowerCase(Locale.ROOT).contains(needle)
                        || w.note.toLowerCase(Locale.ROOT).contains(needle)) {
                    found.add(w);
                }
            }
        }
        found.sort(nearestFirst(here));

        List<Object> list = new ArrayList<>();
        for (AtlasData.Waypoint w : found) {
            if (list.size() >= MAX_LIST) break;
            list.add(waypointMap(w, here));
        }
        Map<String, Object> r = new HashMap<>();
        r.put("group", group);
        r.put("total", total);
        r.put("count", found.size());
        r.put("waypoints", list);
        return r;
    }

    static Map<String, Object> removeWaypoint(AtlasData data, Here here, Map<?, ?> t) throws LuaException {
        String name = str(t, "name", MAX_NAME);
        if (name == null) throw new LuaException("Waypoint name required");
        String group = group(t.get("group"));
        AtlasData.Waypoint removed = data.removeWaypoint(group, name);

        Map<String, Object> r = new HashMap<>();
        r.put("group", group);
        r.put("removed", removed != null);
        if (removed != null) r.put("waypoint", waypointMap(removed, here));
        return r;
    }

    /**
     * Records what an inventory held when it was scanned. Location key:
     *  - side name ("left", "front", ...) on a computer/turtle with a known facing:
     *    the exact adjacent block position;
     *  - any other name ("minecraft:chest_3"): wired-network names are unique per
     *    world, so the name itself, with the scanning computer's position as "near";
     *  - side name with unknown facing (pocket computer): computer id + side.
     */
    static Map<String, Object> recordInventory(AtlasData data, Here here, int computerId, Map<?, ?> t) throws LuaException {
        String peripheral = str(t, "peripheral", 64);
        if (peripheral == null) throw new LuaException("peripheral name required");
        String group = group(t.get("group"));
        if (!data.canCreateGroup(group)) throw new LuaException("Too many atlas groups (max " + AtlasData.MAX_GROUPS + ")");

        AtlasData.Inventory inv = new AtlasData.Inventory();
        inv.dimension = here.dimension();
        inv.peripheral = peripheral;
        inv.computerId = computerId;
        inv.updatedTick = here.now();
        Integer size = num(t, "size");
        inv.size = size != null ? Math.max(0, size) : 0;

        String side = peripheral.toLowerCase(Locale.ROOT);
        Direction dir = SIDES.contains(side) ? worldDirection(side, here.facing()) : null;
        BlockPos pos = dir != null ? here.pos().relative(dir) : here.pos();
        inv.x = pos.getX();
        inv.y = pos.getY();
        inv.z = pos.getZ();
        inv.exact = dir != null;
        if (dir != null) {
            inv.key = here.dimension() + "@" + pos.getX() + "," + pos.getY() + "," + pos.getZ();
        } else if (SIDES.contains(side)) {
            inv.key = here.dimension() + "@computer" + computerId + ":" + side;
        } else {
            inv.key = here.dimension() + "#" + peripheral;
        }

        // Aggregate slots into per-item totals, keeping the most plentiful items.
        Map<String, AtlasData.ItemSummary> byId = new HashMap<>();
        Object rawItems = t.get("items");
        if (rawItems instanceof Map<?, ?> items) {
            for (Object v : items.values()) {
                if (!(v instanceof Map<?, ?> slot)) continue;
                String id = str(slot, "name", 128);
                Integer count = num(slot, "count");
                if (id == null || count == null || count <= 0) continue;
                AtlasData.ItemSummary s = byId.computeIfAbsent(id, k -> {
                    AtlasData.ItemSummary n = new AtlasData.ItemSummary();
                    n.id = k;
                    return n;
                });
                s.count += count;
                if (s.display == null) s.display = str(slot, "displayName", 64);
            }
        }
        List<AtlasData.ItemSummary> sorted = new ArrayList<>(byId.values());
        sorted.sort((a, b) -> Long.compare(b.count, a.count));
        for (AtlasData.ItemSummary s : sorted) {
            if (inv.items.size() >= AtlasData.MAX_ITEMS_PER_INVENTORY) break;
            inv.items.put(s.id, s);
        }

        data.putInventory(group, inv);

        Map<String, Object> r = new HashMap<>();
        r.put("group", group);
        r.put("key", inv.key);
        r.put("exact", inv.exact);
        r.put("x", inv.x);
        r.put("y", inv.y);
        r.put("z", inv.z);
        r.put("dimension", inv.dimension);
        r.put("items", inv.items.size());
        r.put("truncated", sorted.size() > inv.items.size());
        return r;
    }

    /**
     * Searches stored data only: item ids / display names in the inventory index,
     * and waypoint names / notes. Each item match carries age_seconds (world time
     * since that inventory was last scanned).
     */
    static Map<String, Object> search(AtlasData data, Here here, Map<?, ?> t) throws LuaException {
        String query = str(t, "query", MAX_QUERY);
        if (query == null || query.length() < 2) throw new LuaException("query must be at least 2 characters");
        String group = group(t.get("group"));
        Integer limitArg = num(t, "limit");
        int limit = limitArg == null ? 20 : Math.max(1, Math.min(50, limitArg));

        List<String> needles = needles(query);
        long now = here.now();
        AtlasData.Group g = data.getGroup(group);

        record Hit(AtlasData.Inventory inv, AtlasData.ItemSummary item, boolean exactName) {}
        List<Hit> hits = new ArrayList<>();
        Map<String, Long> totals = new TreeMap<>();
        List<Object> waypoints = new ArrayList<>();
        int indexed = 0;
        long oldest = -1, newest = -1;

        if (g != null) {
            indexed = g.inventories.size();
            for (AtlasData.Inventory inv : g.inventories.values()) {
                for (AtlasData.ItemSummary item : inv.items.values()) {
                    String id = item.id.toLowerCase(Locale.ROOT);
                    String path = id.contains(":") ? id.substring(id.indexOf(':') + 1) : id;
                    String display = item.display != null ? item.display.toLowerCase(Locale.ROOT) : "";
                    boolean match = false, exactName = false;
                    for (String n : needles) {
                        String spaced = n.replace('_', ' ');
                        if (id.contains(n) || display.contains(spaced)) match = true;
                        if (path.equals(n) || display.equals(spaced)) exactName = true;
                    }
                    if (!match) continue;
                    hits.add(new Hit(inv, item, exactName));
                    totals.merge(item.id, item.count, Long::sum);
                    long age = Math.max(0, now - inv.updatedTick) / 20;
                    if (oldest < 0 || age > oldest) oldest = age;
                    if (newest < 0 || age < newest) newest = age;
                }
            }

            List<AtlasData.Waypoint> wps = new ArrayList<>();
            for (AtlasData.Waypoint w : g.waypoints.values()) {
                String name = w.name.toLowerCase(Locale.ROOT), note = w.note.toLowerCase(Locale.ROOT);
                for (String n : needles) {
                    String spaced = n.replace('_', ' ');
                    if (name.contains(n) || name.contains(spaced) || note.contains(n) || note.contains(spaced)) {
                        wps.add(w);
                        break;
                    }
                }
            }
            wps.sort(nearestFirst(here));
            for (AtlasData.Waypoint w : wps) {
                if (waypoints.size() >= 10) break;
                waypoints.add(waypointMap(w, here));
            }
        }

        // Exact item-name matches first, then the biggest stacks.
        hits.sort((a, b) -> {
            if (a.exactName() != b.exactName()) return a.exactName() ? -1 : 1;
            return Long.compare(b.item().count, a.item().count);
        });

        List<Object> matches = new ArrayList<>();
        for (Hit h : hits) {
            if (matches.size() >= limit) break;
            AtlasData.Inventory inv = h.inv();
            AtlasData.ItemSummary item = h.item();
            Map<String, Object> m = new HashMap<>();
            m.put("item", item.id);
            if (item.display != null) m.put("display", item.display);
            m.put("count", item.count);
            m.put("peripheral", inv.peripheral);
            m.put("computer", inv.computerId);
            m.put("dimension", inv.dimension);
            m.put("x", inv.x);
            m.put("y", inv.y);
            m.put("z", inv.z);
            m.put("exact", inv.exact);
            m.put("age_seconds", Math.max(0, now - inv.updatedTick) / 20);
            putDistance(m, here, inv.dimension, inv.x, inv.y, inv.z);
            matches.add(m);
        }

        Map<String, Object> r = new HashMap<>();
        r.put("query", query);
        r.put("group", group);
        r.put("matches", matches);
        r.put("total_matches", hits.size());
        r.put("totals", totals);
        r.put("inventories_indexed", indexed);
        if (oldest >= 0) {
            r.put("oldest_age_seconds", oldest);
            r.put("newest_age_seconds", newest);
        }
        r.put("waypoints", waypoints);
        return r;
    }

    // ------------------------------------------------------------------
    // Location of the calling computer
    // ------------------------------------------------------------------

    private static IComputerSystem system(IComputerAccess computer) throws LuaException {
        if (computer instanceof IComputerSystem sys) return sys;
        throw new LuaException("Atlas is unavailable on this computer");
    }

    private static ServerLevel level(IComputerAccess computer) throws LuaException {
        ServerLevel level = system(computer).getLevel();
        if (level == null) throw new LuaException("Computer is not in a world");
        return level;
    }

    private static Here here(IComputerAccess computer, ServerLevel level) throws LuaException {
        IComputerSystem sys = system(computer);
        BlockPos pos = sys.getPosition();
        if (pos == null) throw new LuaException("Computer is not in a world");

        Direction facing = null;
        ITurtleAccess turtle = sys.getComponent(ComputerComponents.TURTLE);
        if (turtle != null) {
            facing = turtle.getDirection();
        } else if (sys.getComponent(ComputerComponents.POCKET) == null) {
            BlockState state = level.getBlockState(pos);
            if (state.hasProperty(BlockStateProperties.HORIZONTAL_FACING)) {
                facing = state.getValue(BlockStateProperties.HORIZONTAL_FACING);
            }
        }
        long now = level.getServer().overworld().getGameTime();
        return new Here(level.dimension().location().toString(), pos, facing, now);
    }

    /** Same mapping as CC:Tweaked's DirectionUtil.toLocal, inverted. */
    static Direction worldDirection(String side, Direction facing) {
        switch (side) {
            case "top": return Direction.UP;
            case "bottom": return Direction.DOWN;
        }
        if (facing == null || facing.getAxis() == Direction.Axis.Y) return null;
        return switch (side) {
            case "front" -> facing;
            case "back" -> facing.getOpposite();
            case "left" -> facing.getCounterClockWise();
            case "right" -> facing.getClockWise();
            default -> null;
        };
    }

    // ------------------------------------------------------------------
    // Formatting
    // ------------------------------------------------------------------

    private static Map<String, Object> waypointMap(AtlasData.Waypoint w, Here here) {
        Map<String, Object> m = new HashMap<>();
        m.put("name", w.name);
        m.put("dimension", w.dimension);
        m.put("x", w.x);
        m.put("y", w.y);
        m.put("z", w.z);
        m.put("note", w.note);
        m.put("computer", w.computerId);
        m.put("age_seconds", Math.max(0, here.now() - w.createdTick) / 20);
        putDistance(m, here, w.dimension, w.x, w.y, w.z);
        return m;
    }

    private static void putDistance(Map<String, Object> m, Here here, String dim, int x, int y, int z) {
        if (dim.equals(here.dimension())) m.put("distance", Math.round(distance(here, x, y, z)));
    }

    private static double distance(Here here, int x, int y, int z) {
        double dx = x - here.pos().getX(), dy = y - here.pos().getY(), dz = z - here.pos().getZ();
        return Math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    /** Same-dimension waypoints by distance, then everything else by name. */
    private static Comparator<AtlasData.Waypoint> nearestFirst(Here here) {
        return (a, b) -> {
            boolean ha = a.dimension.equals(here.dimension()), hb = b.dimension.equals(here.dimension());
            if (ha != hb) return ha ? -1 : 1;
            if (ha) {
                int c = Double.compare(distance(here, a.x, a.y, a.z), distance(here, b.x, b.y, b.z));
                if (c != 0) return c;
            }
            return a.name.compareToIgnoreCase(b.name);
        };
    }

    // ------------------------------------------------------------------
    // Argument helpers
    // ------------------------------------------------------------------

    /** Accepts f(key, group?) as well as f{key=..., group=...}. */
    private static Map<?, ?> tableOrKey(IArguments args, String key) throws LuaException {
        Object first = args.get(0);
        if (first instanceof Map<?, ?> m) return m;
        if (first instanceof String s) {
            Map<String, Object> m = new HashMap<>();
            m.put(key, s);
            Object g = args.get(1);
            if (g instanceof String) m.put("group", g);
            return m;
        }
        throw new LuaException("bad argument #1 (string or table expected)");
    }

    private static String str(Map<?, ?> t, String key, int max) throws LuaException {
        Object v = t.get(key);
        if (v == null) return null;
        if (!(v instanceof String s)) throw new LuaException("bad field '" + key + "' (string expected)");
        s = s.strip().replaceAll("[\\r\\n\\t]+", " ");
        if (s.isEmpty()) return null;
        return s.length() > max ? s.substring(0, max) : s;
    }

    private static Integer num(Map<?, ?> t, String key) throws LuaException {
        Object v = t.get(key);
        if (v == null) return null;
        double d;
        if (v instanceof Number n) {
            d = n.doubleValue();
        } else if (v instanceof String s && !s.isBlank()) {
            try {
                d = Double.parseDouble(s.strip());
            } catch (NumberFormatException e) {
                throw new LuaException("bad field '" + key + "' (number expected)");
            }
        } else {
            throw new LuaException("bad field '" + key + "' (number expected)");
        }
        if (!Double.isFinite(d) || Math.abs(d) > Integer.MAX_VALUE) throw new LuaException("bad field '" + key + "' (out of range)");
        return (int) Math.floor(d);
    }

    private static void checkCoords(int x, int y, int z) throws LuaException {
        if (Math.abs(x) > 30_000_000 || Math.abs(z) > 30_000_000 || Math.abs(y) > 4096) {
            throw new LuaException("Coordinates out of range");
        }
    }

    /** Lower-case [a-z0-9_-], max 32 chars; anything else means the shared default group. */
    static String group(Object raw) {
        if (!(raw instanceof String s)) return AtlasData.DEFAULT_GROUP;
        StringBuilder b = new StringBuilder();
        for (char c : s.strip().toLowerCase(Locale.ROOT).toCharArray()) {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') b.append(c);
            else if (c == ' ') b.append('_');
            if (b.length() >= 32) break;
        }
        return b.length() == 0 ? AtlasData.DEFAULT_GROUP : b.toString();
    }

    private static String dimension(String raw, String fallback) throws LuaException {
        if (raw == null) return fallback;
        String d = raw.toLowerCase(Locale.ROOT).replace(' ', '_');
        switch (d) {
            case "overworld": return "minecraft:overworld";
            case "nether": case "the_nether": return "minecraft:the_nether";
            case "end": case "the_end": return "minecraft:the_end";
        }
        if (!d.contains(":")) d = "minecraft:" + d;
        if (ResourceLocation.tryParse(d) == null) throw new LuaException("bad dimension '" + raw + "'");
        return d;
    }

    /** "Diamonds" -> [diamonds, diamond]; "iron ingot" -> [iron_ingot]; "torches" -> [torches, torche, torch]. */
    static List<String> needles(String query) {
        String q = query.toLowerCase(Locale.ROOT).strip().replaceAll("\\s+", "_");
        LinkedHashSet<String> out = new LinkedHashSet<>();
        out.add(q);
        if (q.length() > 3 && q.endsWith("s")) out.add(q.substring(0, q.length() - 1));
        if (q.length() > 4 && q.endsWith("es")) out.add(q.substring(0, q.length() - 2));
        return new ArrayList<>(out);
    }
}
