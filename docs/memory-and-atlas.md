# Memory and the Base Atlas

ClaudeCraft gives each computer a private memory, and gives the whole world a
shared "base atlas" of waypoints and chest contents.

## Per-computer memory

- Notes are stored in `/.claude/memory.md` on the computer, one per line:
  `- [3] The iron farm is at 120,64,-40`.
- The file is added to Claude's system prompt at the start of every user turn.
  It survives restarts and `/clear`.
- Claude manages it with two tools:
  - `remember {note}` adds a note (one line, max 300 chars). It refuses once the
    file would pass 4 KB, so Claude has to `forget` something first.
  - `forget {id}` or `forget {match}` removes notes by id, or every note that
    contains the text.
- You can edit the file by hand (`edit /.claude/memory.md`). Lines in any other
  format are kept and shown to Claude as written. If a hand-edited file goes over
  4 KB, Claude sees the first 4 KB plus a note that it was truncated.
- `/memory` shows the notes. `/memory clear` deletes them.

## Base atlas

The atlas is stored with the world (`world/data/claudecraft_atlas.dat`, NeoForge
`SavedData`). Every computer and turtle in the world reads and writes the same
data.

- **Waypoints**: a name, dimension, x/y/z, a note, and the id of the computer
  that saved it. If `set_waypoint` is called without coordinates, it uses the
  calling computer's current position. Saving a name that already exists
  (case-insensitive) moves that waypoint. `list_waypoints` puts waypoints in the
  current dimension first, sorted by distance.
- **Chest index**: every successful `scan_inventory` updates the index
  automatically, storing per-item totals and the world time of the scan.
  - **Side names** (`left`, `front`, ...) on a computer or turtle are stored at
    the exact block position of the chest.
  - **Wired-modem names** (`minecraft:chest_3`) are unique within a world. They
    are stored by name, with the scanning computer's position as an
    approximate location.
- **`atlas_search {query}`** looks in the stored chest index and in waypoint
  names and notes. It reports how long ago each chest was scanned, measured in
  world time. It never scans live, so chests that were never scanned are not
  included.

### Groups

Every atlas tool accepts an optional `group`, so teams can keep separate atlases.
Without one, a computer uses the shared `default` group. To give a computer a
different default, write a group name to `/.claude/atlas_group`. That computer's
`scan_inventory` results are then indexed into that group too.

### Lua API

These functions run on the server thread and return tables:

```lua
claude.atlasSetWaypoint{name="home", note="main base"}      -- uses this computer's position
claude.atlasSetWaypoint{name="fortress", x=10, y=70, z=10, dimension="nether"}
claude.atlasListWaypoints{filter="farm", group="team_red"}
claude.atlasRemoveWaypoint("home")
claude.atlasSearch("diamond")                               -- or {query=, group=, limit=}
claude.atlasRecordInventory{peripheral="left", items=chest.list(), size=chest.size()}
```

### Limits

- **No privacy between players.** Any computer can read or change any group if
  it knows the group's name. Groups keep data apart, but they are not access
  control.
- Each group holds up to 512 waypoints and 2048 indexed inventories; the
  oldest-scanned inventories are dropped first. Each inventory stores up to 256
  distinct items. A world can have up to 64 groups.
- A chest that is scanned both by side name and by network name is indexed
  twice.
