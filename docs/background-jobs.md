# Background jobs

A background job is long-running work that keeps going while you keep chatting
with Claude, and that can pick up where it left off after a reboot or chunk
reload. Claude starts jobs with tools; you watch and control them from the
status line and the `/jobs` command.

## Tools (Lua backend)

| Tool | Purpose |
|------|---------|
| `start_job` | Start a template job (`template` + `params`) or a custom Lua job (`code` + `summary`). |
| `job_status` | Progress, position, fuel, recent log lines, result or error of one job. |
| `list_jobs` | All known jobs with status and progress. |
| `cancel_job` | Stop a job. Turtle jobs drive home first unless `return_home=false`. |

Template jobs normally start right away. Custom code jobs print their code in
the chat (scroll up to read it), a one-line summary and the APIs the code
touches (`fs.delete`, `shell`, `http`, ...), then ask **Allow? y / n**. That's
the same prompt `/confirm` uses for risky tools, so it can also be answered by
tapping YES/NO on an advanced monitor. **N**, Ctrl+T, or no answer before the
confirm timeout (60s, or 45s in channel mode) declines the job.

## Confirm mode and the guard

A job runs unattended, so it never stops to ask. Instead, the player decides
once, when the job starts:

- **Code jobs** always ask, even with `/confirm off`. Code jobs can't be
  started by another computer's message, and are off on command computers
  while op commands are blocked.
- **Template jobs** ask only when another computer asked for them, or when
  `resume_on_boot` would install a startup file and confirm mode is on.

While a code job runs, the guard's hard limits apply to it without any
prompt. These are refused with an error inside the job:
- deleting `/`, `/rom` or a whole drive;
- starting `claude` (with `shell.run`, `shell.execute`, `shell.openTab` or `os.run`);
- calling command blocks;
- writing, moving or deleting startup files, anything under `/.claude`, or
  the `claude` program (`fs.open`/`io.open` for writing, `fs.delete`,
  `fs.move`, `fs.copy`).

Everything else the code does was approved at the start. These checks catch
mistakes. They are not a sandbox: the player approves the code itself.

Template jobs don't call any guarded tools. They only dig, place and move
items inside the area their parameters describe.

## Templates

All turtle templates measure positions from the turtle's start ("home"):
forward is +z, right is +x, up is +y. A **chest directly behind the turtle**
receives output; an optional **fuel chest on top** of the turtle at home is
used to refuel. The turtle goes home on its own to unload or refuel and then
returns to the exact spot it left.

- **quarry** `{width, length, depth?}` (or `{size}`): digs a `width` (to the
  right) x `length` (forward) hole that includes the turtle's own column,
  starting at its own level, down `depth` layers. Without `depth` it digs to
  bedrock and stops at the first block it can't break. Needs a mining turtle.
- **tree_farm** `{trees, spacing?=3, side?=right|left|both, interval?=120, cycles?}`:
  walks a straight path forward from home; tree *k* stands beside the path
  block `1+(k-1)*spacing` ahead. Chops 1x1 trees, replants saplings (keep some
  in the turtle), unloads logs, waits `interval` seconds and repeats.
- **crop_farm** `{width, length, crop?=wheat|carrots|potatoes|beetroots|nether_wart, interval?=300, cycles?}`:
  the turtle stands at crop level just outside a corner, facing along the
  field; the field is `width` blocks to the right (including the turtle's
  column) x `length` forward, starting one block ahead. It flies one block
  above the crops, harvests mature ones, replants and unloads.

## Custom code jobs

The code runs as a function with a `job` API in scope:

- `job.params`, `job.state` (a table saved with `job.save()`), `job.resumed`
- `job.log(...)`, `job.progress(pct, text)`
- `job.sleep(s)`, `job.yield()`, `job.waitFor(event, timeout)`
- turtle jobs also get `job.nav` (home-relative movement that survives
  reboots: `forward/back/up/down(dig)`, `turnLeft/turnRight`, `face`,
  `goTo(x,y,z)`, `goHome()`) and `job.lib` (`refuel`, `unload`, `service`,
  `isFull`, `findSlot`)

`print` goes to the job log. Long loops must call `job.yield()` or
`job.sleep()` now and then, or CC stops them with "Too long without yielding".

## Status and control

- The separator line above the input shows the running job, e.g.
  `-- #1 quarry 42% layer 3/5 --`. An attached monitor shows the same text on
  its bottom row.
- When a job finishes, fails or is cancelled, a line appears in the chat and a
  short note is attached to your next message so Claude knows about it.
- `/jobs` lists jobs; `/jobs log N` shows a job's log; `/jobs resume N`
  resumes a paused job; `/jobs cancel N [stay]` cancels one (`stay` skips the
  trip home).
- Only one turtle job runs at a time. While it runs, Claude's own turtle tools
  that move, dig, place, craft, equip or move items in or out of the turtle
  (`move_items` with `turtle`) are refused, so the two can't fight over the
  turtle. Read-only checks still work.

## Checkpoints and resuming

Jobs are saved to `/.claude/jobs/<id>.json` (custom code also to
`/.claude/jobs/<id>.lua`). Turtle jobs record each move or turn before making
it. After a restart, a move is checked against the fuel level. A turn can't
be checked that way. CC:Tweaked keeps running a turtle's queued commands
while its computer is off, and only a chunk unload or server stop drops
them. So the job assumes a turn finished if the computer was off for at most
10 seconds (a reboot, or `claude` exiting). After a longer gap it assumes the
turn didn't happen.

When `claude` exits or the computer reboots, running jobs become **paused**.
Next time `claude` starts it lists paused jobs; resume them with
`/jobs resume N`. If you ask Claude to start a job with `resume_on_boot`, a
startup file (`/startup/claudecraft_jobs.lua`) launches `claude` after a
reboot, and `claude` offers to resume the job with a 10 second countdown (press
**N** to keep it paused). The startup file is removed when no such job is
left.

## Known limits

- No chunk loading: jobs only run while the turtle's chunk is loaded. A
  chunk unload or server restart pauses the job like a reboot does.
- Channel mode does not offer the job tools yet; its tool list is defined
  separately from the Lua tool list.
- The turn rule above is a guess, and two cases defeat it:
  - a computer shut down and switched back on more than 10 seconds later
    while its chunk stayed loaded;
  - a chunk unloaded and reloaded within 10 seconds.

  A wrong guess leaves the facing off by 90°. It's corrected automatically
  only once the turtle is back home (from which side the chest is on), and a
  quarry may dig outside its area before then.
- On servers with unlimited turtle fuel, moves can't be checked by fuel
  either and use the same guess as turns.
- No GPS: if the turtle is moved by hand while a job is paused, its saved
  position is wrong.
- Tree farm handles 1x1 trees only and picks up only the saplings that land
  near the trunk. Crop farm does not till soil.
- Custom code that draws to the screen (`shell.run`, `paintutils`) can draw
  over the chat.
- The guard limits inside code jobs cover only the functions listed above.
  Code that reaches the real APIs through `_G` gets around them.
