package com.claudecraft.atlas;

import net.minecraft.core.HolderLookup;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.ListTag;
import net.minecraft.nbt.Tag;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.saveddata.SavedData;

import java.util.*;

/**
 * World-saved shared "base atlas": named waypoints plus an index of scanned
 * inventories, split into groups so teams can keep separate atlases.
 *
 * Stored in the overworld's data storage (world/data/claudecraft_atlas.dat), so
 * there is one atlas per world covering every dimension. All access happens on
 * the server thread: the Lua entry points in {@link AtlasLua} are called from
 * {@code @LuaFunction(mainThread = true)} methods.
 */
public class AtlasData extends SavedData {
    public static final String FILE_ID = "claudecraft_atlas";
    public static final String DEFAULT_GROUP = "default";

    public static final int MAX_GROUPS = 64;
    public static final int MAX_WAYPOINTS = 512;
    public static final int MAX_INVENTORIES = 2048;
    public static final int MAX_ITEMS_PER_INVENTORY = 256;

    private static final int VERSION = 1;

    public static final class Waypoint {
        public String name = "";
        public String dimension = "minecraft:overworld";
        public int x, y, z;
        public String note = "";
        public int computerId;
        public long createdTick;
    }

    public static final class ItemSummary {
        public String id = "";
        /** Display name, if the scan was detailed. May be null. */
        public String display;
        public long count;
    }

    public static final class Inventory {
        /** Unique location key, see {@link AtlasLua#recordInventory}. */
        public String key = "";
        public String dimension = "minecraft:overworld";
        /** Peripheral name or side the inventory was scanned through. */
        public String peripheral = "";
        public int computerId;
        /** Block position if {@link #exact}, otherwise the scanning computer's position. */
        public int x, y, z;
        public boolean exact;
        public int size;
        public long updatedTick;
        /** Item id -> summary, most plentiful first. */
        public final LinkedHashMap<String, ItemSummary> items = new LinkedHashMap<>();
    }

    public static final class Group {
        /** Lower-case waypoint name -> waypoint. */
        public final LinkedHashMap<String, Waypoint> waypoints = new LinkedHashMap<>();
        /** Location key -> inventory. */
        public final LinkedHashMap<String, Inventory> inventories = new LinkedHashMap<>();
    }

    private final Map<String, Group> groups = new LinkedHashMap<>();

    public static AtlasData get(MinecraftServer server) {
        return server.overworld().getDataStorage().computeIfAbsent(
                new SavedData.Factory<>(AtlasData::new, AtlasData::load), FILE_ID);
    }

    // -- Access --

    /** Returns the group, or null if nothing has been stored in it yet. */
    public Group getGroup(String name) {
        return groups.get(name);
    }

    public boolean canCreateGroup(String name) {
        return groups.containsKey(name) || groups.size() < MAX_GROUPS;
    }

    private Group group(String name) {
        return groups.computeIfAbsent(name, k -> new Group());
    }

    // -- Mutation (each marks the data dirty so it is written on the next world save) --

    /** Adds or replaces a waypoint. Returns the replaced waypoint, or null. */
    public Waypoint putWaypoint(String groupName, Waypoint w) {
        Waypoint prev = group(groupName).waypoints.put(w.name.toLowerCase(Locale.ROOT), w);
        setDirty();
        return prev;
    }

    /** Removes a waypoint by (case-insensitive) name. Returns it, or null if absent. */
    public Waypoint removeWaypoint(String groupName, String name) {
        Group g = groups.get(groupName);
        if (g == null) return null;
        Waypoint removed = g.waypoints.remove(name.toLowerCase(Locale.ROOT));
        if (removed != null) setDirty();
        return removed;
    }

    /** Adds or replaces an inventory record, evicting the stalest records past the cap. */
    public void putInventory(String groupName, Inventory inv) {
        Group g = group(groupName);
        g.inventories.remove(inv.key); // re-insert so iteration order tracks recency
        g.inventories.put(inv.key, inv);
        while (g.inventories.size() > MAX_INVENTORIES) {
            Inventory oldest = null;
            for (Inventory i : g.inventories.values()) {
                if (oldest == null || i.updatedTick < oldest.updatedTick) oldest = i;
            }
            g.inventories.remove(oldest.key);
        }
        setDirty();
    }

    // -- NBT --

    @Override
    public CompoundTag save(CompoundTag tag, HolderLookup.Provider registries) {
        tag.putInt("version", VERSION);
        CompoundTag groupsTag = new CompoundTag();
        for (Map.Entry<String, Group> e : groups.entrySet()) {
            Group g = e.getValue();
            CompoundTag gt = new CompoundTag();

            ListTag wps = new ListTag();
            for (Waypoint w : g.waypoints.values()) {
                CompoundTag t = new CompoundTag();
                t.putString("name", w.name);
                t.putString("dim", w.dimension);
                t.putInt("x", w.x);
                t.putInt("y", w.y);
                t.putInt("z", w.z);
                t.putString("note", w.note);
                t.putInt("by", w.computerId);
                t.putLong("created", w.createdTick);
                wps.add(t);
            }
            gt.put("waypoints", wps);

            ListTag invs = new ListTag();
            for (Inventory inv : g.inventories.values()) {
                CompoundTag t = new CompoundTag();
                t.putString("key", inv.key);
                t.putString("dim", inv.dimension);
                t.putString("peripheral", inv.peripheral);
                t.putInt("by", inv.computerId);
                t.putInt("x", inv.x);
                t.putInt("y", inv.y);
                t.putInt("z", inv.z);
                t.putBoolean("exact", inv.exact);
                t.putInt("size", inv.size);
                t.putLong("updated", inv.updatedTick);
                ListTag items = new ListTag();
                for (ItemSummary s : inv.items.values()) {
                    CompoundTag it = new CompoundTag();
                    it.putString("id", s.id);
                    if (s.display != null) it.putString("name", s.display);
                    it.putLong("count", s.count);
                    items.add(it);
                }
                t.put("items", items);
                invs.add(t);
            }
            gt.put("inventories", invs);

            groupsTag.put(e.getKey(), gt);
        }
        tag.put("groups", groupsTag);
        return tag;
    }

    public static AtlasData load(CompoundTag tag, HolderLookup.Provider registries) {
        AtlasData data = new AtlasData();
        CompoundTag groupsTag = tag.getCompound("groups");
        for (String groupName : groupsTag.getAllKeys()) {
            CompoundTag gt = groupsTag.getCompound(groupName);
            Group g = new Group();

            ListTag wps = gt.getList("waypoints", Tag.TAG_COMPOUND);
            for (int i = 0; i < wps.size(); i++) {
                CompoundTag t = wps.getCompound(i);
                Waypoint w = new Waypoint();
                w.name = t.getString("name");
                w.dimension = t.getString("dim");
                w.x = t.getInt("x");
                w.y = t.getInt("y");
                w.z = t.getInt("z");
                w.note = t.getString("note");
                w.computerId = t.getInt("by");
                w.createdTick = t.getLong("created");
                if (!w.name.isEmpty()) g.waypoints.put(w.name.toLowerCase(Locale.ROOT), w);
            }

            ListTag invs = gt.getList("inventories", Tag.TAG_COMPOUND);
            for (int i = 0; i < invs.size(); i++) {
                CompoundTag t = invs.getCompound(i);
                Inventory inv = new Inventory();
                inv.key = t.getString("key");
                inv.dimension = t.getString("dim");
                inv.peripheral = t.getString("peripheral");
                inv.computerId = t.getInt("by");
                inv.x = t.getInt("x");
                inv.y = t.getInt("y");
                inv.z = t.getInt("z");
                inv.exact = t.getBoolean("exact");
                inv.size = t.getInt("size");
                inv.updatedTick = t.getLong("updated");
                ListTag items = t.getList("items", Tag.TAG_COMPOUND);
                for (int j = 0; j < items.size(); j++) {
                    CompoundTag it = items.getCompound(j);
                    ItemSummary s = new ItemSummary();
                    s.id = it.getString("id");
                    s.display = it.contains("name") ? it.getString("name") : null;
                    s.count = it.getLong("count");
                    if (!s.id.isEmpty()) inv.items.put(s.id, s);
                }
                if (!inv.key.isEmpty()) g.inventories.put(inv.key, inv);
            }

            data.groups.put(groupName, g);
        }
        return data;
    }
}
