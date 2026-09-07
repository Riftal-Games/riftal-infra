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
