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

## 2026-09-28 `build_stairs`' rows sit at `base`'s own y, `HEADROOM` is 2; `build_platform`'s railing is a bottom slab ring; both register in `BUILDERS`

A stairs row is the tread a player's feet stand one cell above, the same
convention `road.py`'s rising tiles already use, so a row at `base.y + i`
needs only its own cell and the one above cleared for `Region.stand_mask` to
call it standable; that is `HEADROOM`, 2. The support fill under each row
closes the gap down to `base`'s height so a staircase over uneven or hollow
ground never opens over a void, mirroring the embankment `road.py` fills
under a rising tile. `build_platform`'s optional railing is a bottom-half
slab ring one block above the floor, low enough to read as an edge without
blocking the view or the headroom clearance above it. `StairsSpec` carries
no `name` and `build_stairs` marks nothing in the world index, because a
staircase is a passage between two named places, not a place of its own;
`build_platform` keeps `name` and tags its floor `walkway` like every other
builder's floor. Both are registered in
`designer.builders.BUILDERS` under `stairs` and `platform`: the CLI's `build`
command and the MCP `build` tool already dispatch on any name in that
registry, so leaving them out would make two working builders reachable only
from a test file.

## 2026-09-08 `MineSpec.geometry()` is the one source of a mine's bounds; `mine_valid` floods the interior as open and stops at the padding ring

The builder and the check read the same `MineGeometry`, so a wall the builder
places one block off is a named leak, not a disagreement between two copies of
the arithmetic. The flood starts from every interior cell, treated as passable
because a mine ships solid and is hollowed by players; a check on the built box
would otherwise prove nothing. It reaches the padding ring but never passes it,
so `leaks` names the cells beside each hole, which a builder teleports to, not
the whole ring. An even entrance width leans to the upper middle, as in
`Bounds.from_center`, so platform, opening and `resolve_pos` agree on the centre.

## 2026-09-28 `build_plot_grid` fills its whole footprint as road first and rings each plot in `plot_edge`; `build_signage` carries no top-level name

Issue #45's scope split with #93 (`build_perimeter`, `build_room`) to fit the
400-line lane; this closes the plot grid and the signage half only, per the
current issue body, not its unedited historical text that still names
perimeter and room. `checks.yaml` is untouched here for the same reason: the
`region_inside`/`no_holes` line in #45's body describes boundary and walkway
checks that belong with whichever issue actually ships `build_perimeter`.

A plot's interior is left as road, same as the gap around it, because the
plots layout waits for the M5 brainstorm; only the outline is the builder's
job today. Filling the whole grid footprint once and then ringing each plot
is simpler than computing the gap geometry directly, and a `buffer` of at
least one road block between plots keeps every ring off its neighbours', so
plots never touch. `SignageSpec` carries no name of its own, the same
reasoning `StairsSpec` already recorded: a sign is a named place, a batch of
them is not, and `build`'s report path already falls back to `kind` for
exactly this case.

## 2026-09-28 `isometric_png` projects on `half_w = 2*scale, half_h = scale`; canvas is `(nx+nz)*half_w` by `(nx+nz+span)*half_h`; a side face darkens by a fixed factor and is drawn only as deep as the neighbour falls short

A 2:1 dimetric grid puts a column's screen position at
`(ox+(ix-iz)*half_w, oy+(ix+iz)*half_h-(h-lo)*half_h)`; canceling the height
term against the deepest possible drop (bounded by `span = hi-lo`, since no
neighbour falls below the heightmap's own low point) gives an exact bound on
how far any face can reach, which is the height formula above with `oy`
fixed at `half_h*(span+1)` so the highest, nearest column's top vertex lands
on pixel row zero. A missing or empty neighbour, including one past the
heightmap's edge, is scored at `lo`: a cliff into unmapped ground still shows
its full drop rather than vanishing at the boundary. The two faces darken by
different fixed factors, not a computed light angle, so a block reads as
three-dimensional from one flat top colour with no per-column shading pass
to keep in sync with `topdown_png`'s.

## 2026-09-28 The remaining bridge passthroughs skip the snapshot; `load_world`, `create_world`, `pregen` and `run_command` gate on `confirm=True`; entity calls always send `entity_id`

`spawn_npc`, `move_entity`, `remove_entity`, `set_spawn`, `set_text` and `remove_text`
go through `mutating`'s designer gate and read-only switch like every other write, but
call the bridge directly instead of `_apply`: none of them touches a block, so there is
nothing for a snapshot to cover and nothing for `undo` to reverse. The bridge names an
entity by `entity_id` or `npc_id` interchangeably; the toolkit always sends `entity_id`,
since a caller only ever has the `entity_id` `spawn_npc` handed back to give to
`move_entity` or `remove_entity`. `load_world` drops an unsaved change silently,
`create_world` leaves a stray world on disk on a name typo, `pregen` can run for minutes
and write real chunks, and `run_command` is scoped to nothing but itself; each refuses
without `confirm=True`, checked inside the tool after the designer gate rather than in a
second decorator, so `confirm` stays a plain parameter FastMCP can put in the schema.
`save_world` carries no such gate: it only writes back state a player or a prior tool
call already produced. The generated `TOOLS.md` header said a tool answers either the
`Returns` keys or the `ok: false` envelope; `_finish` and `undo` already merge both when
a run stops after the snapshot is pushed, so the header in `tools_doc.py` now says so.

## 2026-09-28 `build_perimeter` walks the rectangle's edge as one ordered path; `build_room` shells and hollows like `build_mine`

Tracing the wall once around the edge, corners visited exactly once, makes
post placement a plain index into that walk rather than four side loops each
skipping its own corners. Fixed `y` or a `Heightmap` is `build_road`'s choice
again; given neither, the builder refuses rather than guessing a height.
`RoomSpec` carries its own `RoomGeometry`, `MineSpec.geometry()`'s convention,
so the opening the builder cuts and the opening a test checks are one
calculation, and its door location sits one step outside the wall so a warp
there does not land a player wedged in the frame. `checks.yaml` is untouched
here for the reason the previous entry gives: `pvp_boundary` and room walkway
coverage waits for a follow-up, since #165 names only plot and sign regions.

## 2026-09-28 `metrics` refreshes `server_info`; `persist_mark`/`persist_verify` split a `persist_check` across a container replacement; `timelapse` frames on bounds, not label

`metrics` forces `refresh=True` rather than reading the cached `server_info`, since the whole
point is a TPS and tick-usage reading taken right before or right after a heavy operation, and
the 30 s TTL other tools rely on would otherwise answer with a stale sample. `persist_mark` and
`persist_verify` are two tools rather than one because the check spans a container being
replaced on the same volume: the MCP server that marks the block is not the one that verifies
it, so the marker (world, position, block) is written to `reports/persist-markers.json`, not
kept in memory, the same reasoning that put the undo manifest on disk. `persist_mark` goes
through `_apply` like `fill`, so the write it makes is snapshotted and undoable like any other.
`timelapse` finds its frames by bounds equality against the named region rather than by which
tool or label produced them, because a mutating tool's own before-mutation snapshot over that
same region is exactly as much a frame as an explicit `snapshot` call naming it; a snapshot
covering some other box, such as a builder's extras, is not. `topdown_png`'s pixel math is
split into `_topdown_image`, shared with `timelapse_png`, so the two renders can never drift out
of shading agreement with each other.

## 2026-09-28 `warp_safe` fails a `pos` outside the region instead of raising

`entity_clear` calls `Bounds.local` on the raw `pos` before any of `warp_safe`'s
own checks run, so a warp target outside the fetched region raised `ValueError`
out of the check rather than reporting it. `warp_safe` now tests
`region.bounds.contains` first and returns a failed `Check` naming the position
and the region it fell outside of, the same shape every other failure in this
module returns. The checks runner (#41) already fences its own call to
`ctx.around` before a check ever sees an unfetched position, so this guard is
for `warp_safe` called directly, from a test, a script or a future caller that
skips the runner.

## 2026-09-28 `slice_png` and `slice_ascii` colour a `Region` layer, not a `Heightmap`; `side_by_side` composites two finished PNGs, reshading neither

A slice needs the block classes at a fixed `y` and the layer beneath it, neither of which a
`Heightmap` carries, so both new renders take the `Region` a `get_region` job already returns
rather than adding a second fetch shape. An air cell shows the block one layer down scaled by
`SLICE_FLOOR_SHADE = 0.6`, so an open room still reads as a floor plan instead of a flat void;
a liquid cell, air's floor or not, gets the same `WATER_TINT` mix `topdown_png` uses on its top
block, so the two renders never disagree about what water looks like. `slice_png` duplicates
`topdown_png`'s grid, tick and legend drawing rather than sharing it, the same choice already
made between `topdown_png` and `isometric_png`: each PNG render owns its own draw loop, and the
duplication is smaller than the coupling a shared one would add. `slice_ascii` duplicates
`ascii_heightmap`'s marker, tick and gutter layout for the same reason, downsampling by stride
instead of `ascii_heightmap`'s pooled average, because a `BlockClass` is categorical and a mean
of enum values is not a class. `side_by_side` takes two already-rendered PNG paths rather than
two `Heightmap`s or `Region`s: it exists to compare a render someone already made against
another one, typically the same bounds before and after an edit, not to render anything itself.

## 2026-09-28 `designer build --apply` (CLI) writes `reports/<kind>-<name>-extras.json` on the same terms as the MCP `build` tool

`edits.extras["mine_reset"]` is the only place a mine's ore weights per layer, its interior
bounds, floor and reset percent exist; the region meta the index stores does not carry it. The
CLI's `_build` reached feature parity with `mcp_server.build` (#145) for the index and
`mine_valid`, but never wrote the extras report, so a mine built through the CLI, the reviewed,
human path acceptance criterion 3 exercises, had nowhere for `mines/` to read `mine_reset` from
at runtime. The write now happens whenever `--apply` sent blocks, keyed the same way the MCP
tool keys it, `<kind>-<name-or-kind>-extras.json`, and happens unconditionally once blocks are
sent, even when index registration then refuses an already-taken name, because the extras
describe what was just built, not whether the index accepted it. `mines/` is meant to read the
report at `reports/mine-<name>-extras.json` once, at world load, and treat it as the mine's
static reset config; it is not re-read per reset, since a changed report means a rebuild, not a
runtime event. `designer build`'s CLI has no `--replace-index` next to `--no-index`: the CLI is
the reviewed path where re-running under a new name is the expected flow, and the MCP tool's
`replace_index` exists for an agent iterating in one session without a human between attempts.

## 2026-09-28 `checks.yaml` covers plot and sign regions with `no_holes` and `entity_clear`, no new check kind

Issue #165, the plot/sign half of the follow-up #45's original text asked for; #169 carries the
pvp_boundary and room half. `no_holes` already checks a flush, walkable footprint over any
region and `entity_clear` already checks a location for an unobstructed hitbox with real support
underneath, the same kinds `mine_a`'s own entries use for its NPC location, so neither a plot's
ring nor a sign's marker needed a new `mine_valid`-style check kind or a change to `checks.py`.
A plot's floor is `no_holes`'s natural fit: `build_plot_grid` leaves the whole footprint solid at
its flush `y` with clear air above, exactly the shape `no_holes` was built to confirm. A sign
carries no block of its own, per `Text`'s own docstring, so the failure `entity_clear` catches is
a marker placed inside solid terrain, invisible and pointless; `warp_safe`'s stricter landing
rule does not apply, since nobody warps to a floating label.

Unlike `mine_a`'s entries, this pair does not read a committed `specs/*.json`: `plot_size:
[7, 7]` and `buffer: 3` are exactly the two values `tuning-numbers.md` lists as open pending
the M5 plots brainstorm (design plan §10), and neither is Nasir's or the brainstorm's to inherit
as already decided just because a checks-coverage PR needed some footprint to test against. The
fixture spec that exercises `no_holes` and `entity_clear` lives inline in
`tests/test_checks_plot_signage.py`, the same way `test_builders_plot_grid.py`'s own `_spec`
picks `[4, 4]`/`2`: arbitrary numbers sized only to give a check something to pass or fail, not a
proposal for what a plot is. Building the plots world stays out of scope until the M5 brainstorm
decides that, same as `build_plot_grid` and `build_signage` shipping in #164 without touching the
live map; `mine_a`'s own entries wait alongside these two for the session that actually builds
them, but only `mine_a`'s spec is real design data.

## 2026-09-28 `restore`'s run detection is vectorised in numpy; a run becomes a `Fill` only past `batch`; `prune` refuses a manifest path outside `SNAPSHOTS_DIR`

Building one `SetBlock` per changed cell in a Python loop before `coalesce` ever ran was
two million iterations for a fully changed 128^3 region. `_restore_ops` finds x-runs
in numpy instead: a sentinel marks the cells `mask` excludes, a boolean diff over the
reshaped array finds where each run starts, and the gaps between starts give every run's
length in one pass, so the Python loop that follows walks runs, not cells. A run becomes
a `Fill` only once its length exceeds `batch`, not at the fixed `COALESCE_RUN` the rest
of the toolkit uses for a typed edit list: a `Fill` always costs one request whatever its
length, while anything up to `batch` rides the same shared `set_blocks` request as every
other row's cells, for free. Under the default `batch` of 4096 and a row capped by
`MAX_EDGE` at 128, that is nearly every restore, which is the fix for QA's measured
16^3 case: 208 per-row fills for 3328 cells that fit one batched request. `prune`
resolves every path it is about to unlink against `SNAPSHOTS_DIR` and refuses the whole
batch, before any file is touched, if one lands outside it, because the manifest is
read back off disk and a hand edit or a bad write is exactly the kind of input `unlink`
must never trust blind.
