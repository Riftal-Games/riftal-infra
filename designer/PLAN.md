# Designer toolkit: plan

The contract is `docs/specs/001-designer-toolchain.md` in the `riftal-pm` workspace root. This file is the working plan for the Python side and the stack, and the status table below is updated as issues close. Read `DECISIONS.md`, created by #31, before touching the code.

## What this is

Three layers, mirroring what a browser automation library gives a coding agent:

1. **DesignBridge** (`riftal-game/designbridge/`): a dev-only PocketMine plugin exposing a token-protected NDJSON socket API over the world. Reads and writes are jobs batched across ticks. Every mutation is logged with before and after hashes.
2. **This toolkit** (`designer/`): a `uv` project on Python 3.12 that wraps the bridge and adds the semantic map, rendering, snapshots, verification, terrain tools and procedural builders, exposed to Claude Code as MCP tools over stdio.
3. **The stack** (`stack/`): one core container from `local-pocketmine-mp` with the plugin mounted. No proxy, no MySQL. Ports published to `127.0.0.1` only.

## Architecture

| Module | Responsibility |
|---|---|
| `config.py` | token, host, port from the environment or an untracked `.env`; project paths |
| `bridge.py` | sync socket client, request ids, timeouts, reconnect with backoff, retries only for idempotent ops, `call_job` and `wait_job` |
| `blocks.py` | block name parsing, class table (`AIR SOLID LIQUID PASSABLE DANGER`, unknown is solid), `RLE_ORDER`, RLE decode and encode |
| `region.py` | `Bounds` inclusive, `Region` as `[y][z][x]` int16 with its own palette, tiling at 128, merge, fetch helpers, heightmaps |
| `world_index.py` | named locations, regions and worlds; every tool resolves names, never raw coordinates |
| `edits.py` | pure `EditList` of `SetBlock`, `Fill`, `Replace`, `Text`; `apply` snapshots first and batches |
| `snapshot.py` | `.npz` snapshots, diff, restore of changed cells, persisted undo manifest |
| `render.py` | ASCII heightmap, top-down PNG, isometric PNG, slice, side-by-side |
| `verify.py` | pure numpy checks: paths, travel time, hitbox and warp safety, containment, light, holes, `mine_valid` |
| `checks.py` | `checks.yaml` bound to named things, one fetch per world, markdown report |
| `terrain.py` | height and slope stats, flat-site search, terraform with feathering |
| `builders/` | mine, road, perimeter, platform, stairs, room, plot_grid, signage; JSON specs, palettes by role |
| `stack.py` | drives `wslc` or `docker` from `stack/compose.yaml`, since `wslc` has no compose verb |
| `cli.py` | `designer ping|info|heightmap|render|region|snapshot|checks|terrain|build|index|stack|tools-doc` |
| `mcp_server.py` | FastMCP tools, designer gate, auto-snapshot on mutation, `dry_run`, `confirm` on world-level ops |
| `tools_doc.py` | generates `TOOLS.md`; `--check` in CI |

## Bridge ops

`ping server_info list_worlds load_world create_world save_world set_spawn get_region get_heightmap get_light set_blocks fill replace pregen get_job cancel_job list_entities spawn_npc move_entity remove_entity set_text remove_text run_command tail_log`. Shapes, error codes and budgets are in the spec.

## `world_index.json`

```json
{"version":1,"updated":"...","default_world":"mine_a",
 "worlds":[{"name":"mine_a","generator":"normal","seed":20260907,"role":"ore_mine","rank":"A"}],
 "locations":[{"name":"mine_a_spawn","world":"mine_a","pos":[0,43,-14],"yaw":180,"pitch":0,"tags":["spawn"]}],
 "regions":[{"name":"mine_a","world":"mine_a","min":[-32,40,-32],"max":[31,63,31],
             "tags":["mine","safe_zone"],"meta":{"rank":"A","reset_percent":60}}]}
```

Names `^[a-z0-9_]+$`, unique across locations and regions. Worlds: `mine_a`, `mine_b`, `mine_c`, `lumber`, `quarry`, `farm`, `contested`, `plots`. Roles: `ore_mine lumber quarry farm contested plots`. Tags: `spawn npc sell rankup sign mine mine_interior safe_zone pvp_boundary walkway road plot plots_grid`.

## Palettes

`palettes.json` holds render colours and named palettes keyed by role: `wall wall_trim floor ceiling road road_edge stairs slab light boundary boundary_accent plot_edge plot_floor sign`. Builders use roles only. First palette `mine_stone`; each rank tier gets its own so a mine's tier is readable from its walls.

## Checks

`checks.yaml` binds `path_exists`, `travel_time`, `warp_safe`, `entity_clear`, `region_inside`, `light_ok`, `no_holes` and `mine_valid` to names. Two standing assertions for every mine, both from the spec's Phase 3 acceptance: `travel_time` from `<name>_spawn` to `<name>_exit` under 10 seconds on foot, and from `<name>_exit` to `sell_npc_<suffix>` under 10 seconds on foot. `travel_time` is the check that yields seconds; `path_exists` alone only proves reachability. The second is the brief's map principle that the walk from mine exit to sell point stays short.

## Map principles

- Every location answers what the player does here and where they go next.
- The new-player path reads without text: sightlines and roads lead from arrival to Mine A to the sell marker to the rank-up marker.
- Mines are enclosed and obvious, one exit facing the sell point.
- PvP boundaries are visibly marked.
- Modest and coherent over ornate. Palettes over improvisation.

## Working rules

- Only ever against the designer stack. The MCP server refuses to mutate a server whose `server_info` lacks `designer: true`.
- Snapshot before any mutation, restore on failure, never leave the world half-edited.
- Small verifiable increments. A mine that passes checks beats three that do not.
- Measure TPS around heavy ops and tune `blocks_per_tick`.
- Keep `TOOLS.md` and `DECISIONS.md` current.

## Status

| Issue | Unit | Phase exit | State |
|---|---|---|---|
| riftal-game#2 | CI for riftal-game | | open |
| riftal-game#3 | DesignBridge scaffold, Bounds, CellIterator | | open |
| riftal-game#4 | RleCodec, BlockStateParser, CommandDenylist, RegionHash | | open |
| riftal-game#5 | transport, ping, server_info, list_worlds | | open |
| riftal-game#6 | jobs and reads | | open |
| riftal-game#7 | writes and audit log | | open |
| riftal-game#8 | worlds, commands, tail_log, pregen | | open |
| riftal-game#9 | NPC and text registries | | open |
| riftal-game#10 | smoke test | | open |
| riftal-infra#30 | stack, local image build, DevTools.phar, first boot | | open |
| riftal-infra#31 | toolkit scaffold and CI steps | | open |
| riftal-infra#32 | bridge client, fake bridge, stack command | | open |
| riftal-infra#33 | block model and regions | | open |
| riftal-infra#34 | fetch helpers and world index | | open |
| riftal-infra#35 | ASCII heightmap and CLI | Phase 1 | open |
| riftal-infra#36 | PNG renders and palettes | | open |
| riftal-infra#37 | edits, snapshots, undo | | open |
| riftal-infra#38 | MCP server and TOOLS.md | | open |
| riftal-pm#8 | `.mcp.json` | Phase 2 | open |
| riftal-infra#39 | verify part 1 | | open |
| riftal-infra#40 | verify part 2 | | open |
| riftal-infra#41 | checks | | open |
| riftal-infra#42 | terrain | | open |
| riftal-infra#43 | builders base and build_mine | Phase 3 | open |
| riftal-infra#44 | road, stairs, platform | | open |
| riftal-infra#45 | perimeter, room, plot_grid, signage | | open |
| riftal-infra#46 | isometric render, remaining tools | | open |

Phase 4, the map itself, is driven through the MCP tools once Phase 3 closes: `mine_a`, `mine_b`, `mine_c` and `lumber`, each sited, terraformed, built, checked and rendered before and after. That is the M1 scope on the roadmap. The `quarry`, `farm`, `contested` and `plots` worlds are created and pregenerated only; their builds belong to the milestones that need them.

## Open questions

None. The four design-intent questions were answered on 2026-09-07 and are in the root decision log.
