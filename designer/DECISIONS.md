# Designer toolkit decisions

Conventions every module follows. Each entry says what and why. The spec is
`docs/specs/001-designer-toolchain.md` in the `riftal-pm` workspace; this file
records the choices it makes so a reader of one module does not have to reopen
it.

## 2026-09-07 Arrays are `blocks[y][z][x]`, int16, one palette per region, air at index 0

The bridge streams a region as runs with x fastest, then z, then y. Indexing
the array `[y][z][x]` means a decoded run reshapes straight into place with no
transpose. int16 leaves room for palettes past 256 entries, which uint8 cannot
hold, while staying half the size of int32 for a 128^3 tile. Air at 0 makes
`numpy.zeros` an empty region and `array.any()` a content test. One palette per
region keeps an index meaning one block inside one array.

## 2026-09-07 Positions in every API are `(x, y, z)`

The game's order, so coordinates copied from a client, a command or the log
paste in unchanged. The array order above is an internal layout that callers
never spell.

## 2026-09-07 `Bounds` are inclusive; `.tiles(128)` splits bigger requests

Block coordinates name blocks, not edges, so both `min` and `max` are blocks
inside the region, as the bridge and the game report them. Tiling to 128 keeps
every request under the bridge's `max_region_edge`, and a failure part-way loses
one tile rather than the whole fetch.

## 2026-09-07 `RLE_ORDER` is one constant in `blocks.py`

The wire order appears in decode, encode and every test that touches a region.
A second spelling of it is a silent transpose that no check catches.

## 2026-09-07 Block classes `AIR SOLID LIQUID PASSABLE DANGER` come from a rule table keyed on base name; unknown is `SOLID`

Every verification check reads the class, not the block name. Defaulting an
unknown block to `SOLID` makes it block a path, so a missing rule shows up as a
failing check instead of a wall the checker walks through.

## 2026-09-07 Builders and `terraform` are pure and return an `EditList`

An `EditList` can be counted, diffed, dry-run and unit tested with no server.
`apply` is the only call that touches the bridge, so a bad spec costs nothing
until someone chooses to apply it.

## 2026-09-07 Every mutating MCP tool snapshots the affected bounds first and pushes a persisted undo entry

An agent-driven edit on a hand-built map must always be reversible. The undo
list is persisted because the MCP server restarts with every Claude Code
session, and an undo that lives only in memory is gone exactly when it is
needed.

## 2026-09-07 Mutating tools are refused unless `server_info.designer` is true; `DESIGNER_READ_ONLY=1` disables them all

The toolkit must never write to a world on any instance other than the design
one, even if a config points it there. The read-only switch is for sessions
that only need to look, so a wrong tool call cannot edit anything.

## 2026-09-07 Data describing the map is committed; `snapshots/` and `reports/` are not

`world_index.json`, `checks.yaml` and `specs/*.json` are the map's source and
are reviewed in pull requests. Snapshots are binary, large and reproducible
from the volume. Reports are per-run output.

## 2026-09-07 Stdio transport; `.mcp.json` carries no secrets

Stdio needs no port and no authentication of its own, so there is nothing to
expose. The token lives in the untracked `.env`, which is what lets `.mcp.json`
be committed in `riftal-pm`.

## 2026-09-07 `world_index.json` is validated on load; worlds are hand-edited in first; a region resolves to its centre; save is sorted

Worlds have no add API. They are written into the file by hand and must exist
before any location or region in them, since an entry in an unlisted world can
be neither fetched nor teleported to. Names match `^[a-z0-9_]+$` and are unique
across locations and regions, and `load` checks all of it because the file is
hand-edited and a hand edit is exactly what the `add_*` checks never see.
`resolve_pos` of a region is its centre block, the upper-middle on an even size
so `Bounds.from_center` round-trips, because `--at <region>` wants the middle
and the min corner may be inside solid ground. `save` sorts keys and lists by
name so a diff is one line per real change.

## 2026-09-07 Only `IDEMPOTENT_OPS` are resent; every attempt gets a fresh id; a timeout is never retried

Reads are idempotent: `ping`, `server_info`, `list_worlds`, `list_entities`,
`tail_log`, `get_job`, `cancel_job`, `get_region`, `get_heightmap` and
`get_light` return the same answer however many times they run, and the region
reads also take one `max_pending_jobs` slot per attempt, which is why the
client backs off between reconnects instead of resending at once. Writes are
not: a `fill` that was sent and never answered may have run, and running it
twice is a second edit and a second undo entry, so the bridge raises
`BridgeConnectionError` with `detail="sent_unconfirmed"` and the caller
decides. Each attempt carries its own request id so a late reply to the first
send can never be taken as the answer to the second. A response timeout is not
retried even on an idempotent op: the server is still working on the request,
so a resend queues the same work behind it and turns one slow read into two.

## 2026-09-07 `call_job` polls `get_job` from 0.25 s growing 1.5x to a 1 s cap; a timeout cancels

A job that finishes in its first tick comes back `done` inline, so no poll is
spent on it. The interval starts short because most region reads settle in a
few ticks, and it caps at one second so a `pregen` running for minutes costs
one request a second rather than a busy loop. On the deadline the job is
cancelled before `JobTimeout` is raised, because a job the client has given up
on would otherwise keep its slot and its pinned chunks for the rest of its run.

## 2026-09-07 The ASCII map ticks on absolute multiples of 16; a downsampled cell is the block mean; `flat` is the share at the modal height

Ticks on chunk edges line up with what a player sees at a chunk border, which
a tick counted from the map's corner does not. A cell wider than a block is
the mean of its non-empty columns, and it is water when at least half of them
are, so a pond survives downsampling and a single wet column does not flood a
cell. `summary` calls a column flat when it sits at the most common height,
which is the number a builder wants: how much of the area is already the
platform it will stand on.

## 2026-09-08 `apply` batches 4096 blocks; `COALESCE_RUN` is 8; the first error stops it and nothing is resent; `Text` has no bounds

The bridge accepts 65536 blocks per `set_blocks` but writes `blocks_per_tick`
50000, so a batch at the cap spans ticks and every one of them needs a poll.
4096 is a twelfth of a tick: the batch settles inline in the tick that
received it, and a batch that goes `sent_unconfirmed` on a dropped
connection is 4096 blocks to inspect and resend by hand, which is cheap,
where a lost 65536 is a real question of what landed. Eight is the run
length at which a `fill` starts paying for itself: a `fill` is its own job
with its own chunk pinning and audit line, while eight `set_blocks` entries
ride in a batch that is being sent anyway, and a shorter run is more often
two neighbouring single blocks than a deliberate line. `apply` stops at the
first `BridgeError` and resends nothing because a write is not idempotent,
so a resend after an unclear failure is a possible second edit, and a later
op may depend on the one that failed; the result carries every job that ran
so the caller knows exactly how far it got, and the undo entry covers the
rest. `Text` changes no block, so it has no bounds, counts for nothing and
lies outside `before()`: the snapshot exists to reverse block changes, and a
text is reversed by `remove_text` with the id its own job returns.

## 2026-09-08 A snapshot is one self-describing `.npz` under `snapshots/<world>/<ts>-<label>.npz`; `diff` remaps by name; `restore` sends only what differs and snapshots first; the manifest is replaced whole; `prune` is never automatic

The file carries its own palette, bounds and a JSON `meta` naming the world,
the timestamp, the label, the toolkit version and `RLE_ORDER`, so a snapshot
found on disk months later still says what it is and `load` can refuse one
written in another axis order. `diff` maps the second region into the first
one's palette by name because an index means one block inside one region and
nothing across two. `restore` fetches the current state and sends only the
cells that differ, coalesced like any edit list, because a full rewrite of a
128^3 box is two million blocks of jobs to reverse a hundred, and it takes a
`restore` snapshot first through `before` so an undo is itself undoable. The
undo manifest is written to a temp file and moved over the old one, so a
crash mid-write leaves the previous manifest rather than half of a new one.
`prune` only runs when called and defaults to a dry run, because the undo
trail is the one thing that makes an agent edit on a hand-built map safe to
try, and deleting it is a choice someone makes on purpose.

## 2026-09-08 `session` is a label; `undo` is global and newest-first; an undo pushes an `op="undo"` entry that `undo` skips unless asked; the manifest has one writer; `prune` keeps 14 days

`session` is written on every entry a stack pushes and is what
`entries(session=...)` filters on, nothing more. `undo` ignores it and walks
every session's entries newest first, because the MCP server restarts with
each Claude Code session and the edits most in need of reversing are the
ones a crashed session left behind, which only the next session can reach.
The `restore` snapshot an undo takes is pushed as an `op="undo"` entry so it
is listed, walkable and pruned like any other; plain `undo` skips those
entries, because two undos must reverse two edits rather than toggle the
newest one back and forth, so undoing an undo is `include_undo=True`, asked
for by name. Push is read-modify-write with ids from `max + 1`, so the
manifest assumes one writer at a time; two concurrent sessions would race,
and the current model runs one. `prune` keeps 14 days because a design
session's edits are reviewed within the week they land and a fortnight
covers a missed one, while snapshots of 128^3 tiles are large enough that an
unbounded default would fill the disk before anyone chose to.

## 2026-09-08 The MCP server caps `MAX_AREA` 256, `MAX_RADIUS` 8, `MAX_LOG_LINES` 200; the bridge and the index are created on first use under one lock; every tool answers an `ok` envelope and never raises

The caps bound what one tool call can put into a model's context. A 256
square is four 128 tiles of heightmap and the largest ASCII map that is still
legible when pasted; radius 8 is a 17^3 inspect, which is 17 slices of 17
rows, about what a reader can hold while comparing layers; 200 log lines is a
boot's worth of output, and anything longer is a file to open, not an answer
to read. The bridge and the index are built lazily so the server starts with
the design instance down and `server_status` can report that rather than the
process dying before the first call, and one lock covers both so two tools
racing at first use share one connection instead of opening two. Every tool
answers `{"ok": True, ...}` or `{"ok": False, "error", "code"}` because an
exception out of a tool reaches the client as a transport error with the
detail lost, and the `code` is what lets the caller tell `not_designer` from
a bad block name without parsing prose.

## 2026-09-08 `DESIGNER_READ_ONLY` is checked before the bridge; `set_blocks` takes 4096 entries per call; the snapshot and its undo entry are written inside `before`; `restore` takes a path or an undo id; the session label is the server's start time

The read-only switch is the one check that must hold with the bridge down, so
it answers first and costs no request; it covers the two lists as well
because a read-only session has no use for what feeds `restore` and `undo`.
4096 is `DEFAULT_BATCH`, so one call is one request and its progress is one
job's progress, and a bigger edit is a fill or a builder. The snapshot is
taken and pushed inside `apply`'s `before` hook so the manifest names the
entry before the first block is sent, and a run that stops at a `BridgeError`
still answers with the entry that covers what landed. An undo id spares the
caller a path it would otherwise copy out of `list_undo`. The session label
is the start time because the MCP server lives exactly one Claude Code
session, so the label groups the entries that session made.

## 2026-09-08 Every MCP tool docstring ends in a `RETURNS:` trailer, a missing one is an error, and `TOOLS.md` is rendered from the registered tools with `--check` run in CI

One description of the return shape, in the code beside the return it names.
A hand-kept copy drifts unseen, and a default for a missing trailer is that copy in disguise.

## 2026-09-08 `path_exists` charges the heuristic at the move rates; a view never caches its stand mask; the default corridor grows 8 in y

A drop costs 0.25 a block and a climb 0.5, so a heuristic that charged 0.5
for every block of height would overestimate a descent and A* could return a
dearer path than exists; the heuristic charges 0.5 when the goal is above and
0.25 when it is below, which is exactly what the cheapest move sequence pays.
`stand_mask` does not depend on the drop limit, so `Region.stand_mask` caches
one array on the root region and `_invalidate` clears it with the classes,
but a `sub` view computes fresh every call: an edit through the parent never
reaches the view's cache, and a stale mask is a path through a block placed a
moment ago. The cache lives in `Region` so its contract is read in one file
beside the classes cache it mirrors. A drop reads
the head cell of the neighbour column before the feet leave the ledge, the
same cell a step up the other way reads, so the graph is symmetric on the
same geometry. The default corridor grows the endpoints' box by `margin` in x
and z but only 8 in y, since two points a check names together rarely sit
more than a few storeys apart and every extra layer is another full plane of
nodes.

## 2026-09-08 `entity_clear` judges the support a player would rest on and passes over a void; `warp_safe` demands solid within `LANDING` 3 below and no ring hole deeper than that; `region_inside` names the corner

`entity_clear` looks past air and passable blocks to the first block that
would hold the player, and fails only when that block is liquid or danger,
because a hitbox over a drop is free and a hitbox over lava is a death. A
column with no support is not an obstruction, so it passes, and `warp_safe`
is the check that refuses it: a warp puts a player at the position with no
control over the fall, so there must be solid ground within three blocks of
the feet, which is at most a two-block fall. The floor ring may be one
deeper, solid within four, which is the three-block fall Bedrock takes
without damage, since a player who steps off the warp onto a hole is
choosing to. The hazard scan covers the floor plane of the ring as well as
feet and head, because a first step onto a lava floor is the same death as
a step into a lava wall, and it runs before the ring rule so lava at floor
level is named as lava whether air or stone lies under it. The rules run
hitbox, landing, hazards, ring so that `detail` always names the first
thing a builder must fix. Cells outside the region are unknown, so
they never offend and never count as solid: a check at the edge of a fetch
fails toward caution on the landing and stays silent on what it cannot see.
`region_inside` reports each corner of the inner box that lies outside the
outer one, because a corner is a coordinate a builder can paste into a
teleport, where "not inside" is not.

## 2026-09-08 `LightRegion` splits the packed palette into two uint8 arrays; `light_ok` checks every cell unless masked and names the darkest twenty; `no_holes` names `HOLES_REPORTED` 50 and accepts only a solid floor

The wire packs `sky << 4 | block` into one integer palette entry so a light
payload rides the same run expansion as a region, and `decode_light` splits it
once on arrival because every check reads one kind of light at a time.
`merge` unions the stale chunk lists into a sorted set, since a chunk on a
tile edge is reported by both tiles and a builder wants to know it once. A
light region carries no block classes, so `light_ok` has no way to tell air
from stone and checks every cell by default; a caller with a region passes
its `passable()` as the mask. The worst cells are sorted by level and then
by position so two runs over the same map name the same cells in the same
order. `no_holes` names up to `HOLES_REPORTED` 50 cells, more than the light
cap because holes come in array order rather than worst first, and a missing
strip shows only when its whole run is listed. It accepts only a solid block as floor, so lava or water under
a walkway is a hole like a missing block is: walkable floor in this codebase
means `SOLID`, which is what `stand_mask` requires, and `warp_safe` is a point
check within a block of a warp, so nothing else scans a whole walkway for a
lava tile. At walkway level anything a player cannot pass through is an
obstruction, liquid and danger included.

## 2026-09-08 `MineSpec.geometry()` is the one source of a mine's bounds; `mine_valid` floods the interior as open and stops at the padding ring

The builder and the check read the same `MineGeometry`, so a wall the builder
places one block off is a named leak, not a disagreement between two copies of
the arithmetic. The flood starts from every interior cell, treated as passable
because a mine ships solid and is hollowed by players; a check on the built box
would otherwise prove nothing. It reaches the padding ring but never passes it,
so `leaks` names the cells beside each hole, which a builder teleports to, not
the whole ring. An even entrance width leans to the upper middle, as in
`Bounds.from_center`, so platform, opening and `resolve_pos` agree on the centre.
