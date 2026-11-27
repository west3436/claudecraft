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

Template jobs start right away. Custom code jobs show a one-line summary, the
APIs the code touches (`fs.delete`, `shell`, `http`, ...) and wait for the
player to press **Y** (or **V** to view the code). **N**, Ctrl+T, or no
answer within 45 seconds declines the job.

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
  that move, dig or place are refused, so the two can't fight over the turtle.

## Checkpoints and resuming

Jobs are saved to `/.claude/jobs/<id>.json` (custom code also to
`/.claude/jobs/<id>.lua`). Turtle jobs record each move before making it and
check the fuel level afterwards to tell whether the move actually happened.

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
- A turn interrupted by a reboot in the few milliseconds before it is
  confirmed can't be verified. Facing is corrected automatically only when
  the turtle is back home (from which side the chest is on).
- On servers with unlimited turtle fuel, moves can't be verified by fuel, so
  a move cut off by a reboot may leave the saved position one block off.
- No GPS: if the turtle is moved by hand while a job is paused, its saved
  position is wrong.
- Tree farm handles 1x1 trees only and picks up only the saplings that land
  near the trunk. Crop farm does not till soil.
- Custom code that draws to the screen (`shell.run`, `paintutils`) can draw
  over the chat.
