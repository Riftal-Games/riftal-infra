# Designer MCP tools

Rendered by `python -m designer.tools_doc`; edit the docstrings in designer/designer/mcp_server.py, not this file.
Every tool answers `{"ok": true, ...}` with the keys on its `Returns` line; a call that stops partway merges those
same keys with `{"ok": false, "error": ..., "code": ...}` rather than replacing them.

## analyze_terrain

Height stats, slope map and the flat and water fractions of ``target``, a region name or ``{"min", "max"}``.

```json
{"properties": {"flat_slope": {"default": 1, "title": "Flat Slope", "type": "integer"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target"], "title": "analyze_terrainArguments", "type": "object"}
```
Returns: world, bounds, columns, min, max, mean, water_fraction, flat_fraction.

## build

Build ``kind`` (a name in ``designer.builders.BUILDERS``) from ``spec``, a dict or a path under ``specs/``.

Checks every location and region it will register before the snapshot, the undo entry and the
first edit, then answers with the undo id like every mutating tool. Registers the builder's
locations and regions in the index unless ``register_index`` is false or ``dry_run``. Unless
``register_index`` is false, refuses a name that breaks the index's naming rules, names an
unlisted world or appears twice in the build, and a name already taken unless ``replace_index``,
a dry run included, so a dry run answers every refusal the build would; runs ``mine_valid`` when ``kind`` is
``mine`` unless ``verify`` is false, and refuses a build that fails it before the snapshot, a dry run
reporting the failure instead; writes the edit list's extras to ``reports/<kind>-<name>-extras.json`` unless ``dry_run``,
falling back to ``kind`` itself when the spec carries no ``name`` (``stairs`` and ``signage``, deliberately).

A build of floating text alone, ``signage``, touches no block, so it answers ``bounds`` and ``snapshot`` as null
and takes no snapshot, and is undoable all the same: its undo entry is pushed once the texts are set, and
``undo`` removes every text it set with ``remove_text``. An id that already carried text before the build is
removed too, not put back as it was.

```json
{"properties": {"dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "kind": {"title": "Kind", "type": "string"}, "palette": {"default": "mine_stone", "title": "Palette", "type": "string"}, "register_index": {"default": true, "title": "Register Index", "type": "boolean"}, "replace_index": {"default": false, "title": "Replace Index", "type": "boolean"}, "spec": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "string"}], "title": "Spec"}, "verify": {"default": true, "title": "Verify", "type": "boolean"}}, "required": ["kind", "spec"], "title": "buildArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs, locations, regions, mine_valid, extras_report.

## check_entity_clear

Whether the 1x2 hitbox at ``at`` is free.

```json
{"properties": {"at": {"title": "At", "type": "string"}}, "required": ["at"], "title": "check_entity_clearArguments", "type": "object"}
```
Returns: passed, detail, coords, seconds.

## check_mine

Whether the named ``region`` matches the mine ``spec`` (a path under ``specs/``): enclosure, entrances, ore mix, floor.

```json
{"properties": {"region": {"title": "Region", "type": "string"}, "spec": {"title": "Spec", "type": "string"}}, "required": ["region", "spec"], "title": "check_mineArguments", "type": "object"}
```
Returns: passed, detail, coords, seconds.

## check_path

Whether a walkable path from ``start`` to ``end`` exists and its travel time is under ``max_seconds``.

``start`` and ``end`` are ``from``/``to`` in ``checks.yaml``, renamed here since ``from`` is a Python keyword.

```json
{"properties": {"end": {"title": "End", "type": "string"}, "max_seconds": {"default": 10, "title": "Max Seconds", "type": "integer"}, "start": {"title": "Start", "type": "string"}}, "required": ["start", "end"], "title": "check_pathArguments", "type": "object"}
```
Returns: passed, detail, coords, seconds.

## check_warp_safe

Whether a warp landing at ``at`` is clear, grounded, free of liquid or danger, with no deep hole underfoot.

```json
{"properties": {"at": {"title": "At", "type": "string"}}, "required": ["at"], "title": "check_warp_safeArguments", "type": "object"}
```
Returns: passed, detail, coords, seconds.

## create_world

Create world ``name`` with ``generator`` (``flat``, ``normal`` or ``hell``) and ``seed``; spawn chunks generate in the background.

Refused unless ``confirm=True``: a name typo would otherwise leave a stray world on disk.

```json
{"properties": {"confirm": {"default": false, "title": "Confirm", "type": "boolean"}, "generator": {"title": "Generator", "type": "string"}, "name": {"title": "Name", "type": "string"}, "seed": {"title": "Seed", "type": "integer"}}, "required": ["name", "generator", "seed"], "title": "create_worldArguments", "type": "object"}
```
Returns: world, generator, seed.

## define_location

Add a named location to the index and save it; ``pos`` is the feet block.

```json
{"properties": {"name": {"title": "Name", "type": "string"}, "pitch": {"default": 0, "title": "Pitch", "type": "number"}, "pos": {"items": {"type": "integer"}, "title": "Pos", "type": "array"}, "tags": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "title": "Tags"}, "world": {"title": "World", "type": "string"}, "yaw": {"default": 0, "title": "Yaw", "type": "number"}}, "required": ["name", "pos", "world"], "title": "define_locationArguments", "type": "object"}
```
Returns: entry, the location as saved.

## define_region

Add a named region to the index and save it; the name must be new and match ``[a-z0-9_]+``.

```json
{"properties": {"max": {"items": {"type": "integer"}, "title": "Max", "type": "array"}, "meta": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "title": "Meta"}, "min": {"items": {"type": "integer"}, "title": "Min", "type": "array"}, "name": {"title": "Name", "type": "string"}, "tags": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "title": "Tags"}, "world": {"title": "World", "type": "string"}}, "required": ["name", "min", "max", "world"], "title": "define_regionArguments", "type": "object"}
```
Returns: entry, the region as saved.

## fill

Fill ``target``, a region name or ``{"min", "max"}``, with ``block``; snapshots first and answers with the undo id.

```json
{"properties": {"block": {"title": "Block", "type": "string"}, "dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "block"], "title": "fillArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## find_flat_site

The best ``size``-square sites in ``target`` by slope, height range and water, ranked by distance to ``near`` when given.

```json
{"properties": {"limit": {"default": 5, "title": "Limit", "type": "integer"}, "max_range": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": null, "title": "Max Range"}, "max_slope": {"default": 1, "title": "Max Slope", "type": "integer"}, "max_water": {"default": 0.0, "title": "Max Water", "type": "number"}, "near": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Near"}, "size": {"title": "Size", "type": "integer"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "size"], "title": "find_flat_siteArguments", "type": "object"}
```
Returns: world, bounds, sites as [{bounds, x, z, height, range, slope_max, water_fraction, score}].

## heightmap_ascii

An ASCII heightmap of a ``size`` square (at most 256) around ``at``: a name, ``x,z`` or ``x,y,z``.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "size": {"default": 64, "title": "Size", "type": "integer"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["at"], "title": "heightmap_asciiArguments", "type": "object"}
```
Returns: text, summary.

## index_list

Entries of ``world_index.json``: ``kind`` is worlds, locations or regions; ``tag`` filters locations and regions.

```json
{"properties": {"kind": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Kind"}, "tag": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Tag"}}, "title": "index_listArguments", "type": "object"}
```
Returns: default_world, then a list per kind asked for: worlds, locations, regions; a tag drops worlds.

## index_remove

Remove a location or region from the index and save it.

```json
{"properties": {"name": {"title": "Name", "type": "string"}}, "required": ["name"], "title": "index_removeArguments", "type": "object"}
```
Returns: entry, the one removed.

## index_resolve

The location or region called ``name`` and the position it stands for; a region resolves to its centre.

```json
{"properties": {"name": {"title": "Name", "type": "string"}}, "required": ["name"], "title": "index_resolveArguments", "type": "object"}
```
Returns: kind, entry, pos.

## inspect

Block counts and one ASCII slice per y around ``at``, ``radius`` at most 8; glyphs ``. # ~ , !`` by class.

The box stops at the build range, y -64..319, so ``bounds`` is shorter than ``2*radius+1`` near either end;
an ``at`` outside that range is refused.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "radius": {"default": 3, "title": "Radius", "type": "integer"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["at"], "title": "inspectArguments", "type": "object"}
```
Returns: world, center, bounds, counts, slices as [{y, rows}] from the lowest y up.

## list_entities

Entities in ``world`` as the bridge reports them, players excluded.

```json
{"properties": {"world": {"title": "World", "type": "string"}}, "required": ["world"], "title": "list_entitiesArguments", "type": "object"}
```
Returns: world, count, entities.

## list_snapshots

Snapshot files on disk, newest first, with the undo id of any that the manifest knows.

```json
{"properties": {"limit": {"default": 20, "title": "Limit", "type": "integer"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "title": "list_snapshotsArguments", "type": "object"}
```
Returns: snapshots as [{path, world, timestamp, label, bytes, undo_id}].

## list_undo

Undo manifest entries newest first: id, session, op, world, bounds, label, timestamp, path, restored.

```json
{"properties": {"limit": {"default": 20, "title": "Limit", "type": "integer"}}, "title": "list_undoArguments", "type": "object"}
```
Returns: manifest, total, entries.

## load_world

Load world ``name`` from the worlds folder, discarding any unsaved change already loaded under that name.

Refused unless ``confirm=True``: a load nobody meant is state silently gone.

```json
{"properties": {"confirm": {"default": false, "title": "Confirm", "type": "boolean"}, "name": {"title": "Name", "type": "string"}}, "required": ["name"], "title": "load_worldArguments", "type": "object"}
```
Returns: world, spawn, seed, generator.

## metrics

``server_info``'s TPS, tick usage and memory, refreshed so a caller can sample it before and after a heavy operation.

```json
{"properties": {}, "title": "metricsArguments", "type": "object"}
```
Returns: tps, tps_avg, tick_usage, tick_usage_avg, memory_bytes.

## move_entity

Move entity or NPC ``id`` to ``at`` (a name, ``x,z`` or ``x,y,z``).

```json
{"properties": {"at": {"title": "At", "type": "string"}, "id": {"title": "Id", "type": "string"}}, "required": ["id", "at"], "title": "move_entityArguments", "type": "object"}
```
Returns: id, world, pos.

## persist_mark

Place ``block`` at ``at`` and record it as ``marker``, so ``persist_verify`` can prove it survived the container underneath being replaced.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "block": {"default": "minecraft:diamond_block", "title": "Block", "type": "string"}, "dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "marker": {"title": "Marker", "type": "string"}}, "required": ["marker", "at"], "title": "persist_markArguments", "type": "object"}
```
Returns: marker, pos, block, world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## persist_verify

Whether the block ``persist_mark`` placed as ``marker`` is still there, fetched straight from the world.

```json
{"properties": {"marker": {"title": "Marker", "type": "string"}}, "required": ["marker"], "title": "persist_verifyArguments", "type": "object"}
```
Returns: marker, world, pos, expected, found, passed.

## pregen

Generate every chunk in the ``x,z`` box ``min``..``max`` of ``world`` ahead of a build that needs it loaded.

A wide box can run for minutes and cost real disk, so it is refused unless ``confirm=True``.

```json
{"properties": {"confirm": {"default": false, "title": "Confirm", "type": "boolean"}, "max": {"items": {"type": "integer"}, "title": "Max", "type": "array"}, "min": {"items": {"type": "integer"}, "title": "Min", "type": "array"}, "world": {"title": "World", "type": "string"}}, "required": ["world", "min", "max"], "title": "pregenArguments", "type": "object"}
```
Returns: world, bounds, job, result.

## remove_entity

Remove entity or NPC ``id``.

```json
{"properties": {"id": {"title": "Id", "type": "string"}}, "required": ["id"], "title": "remove_entityArguments", "type": "object"}
```
Returns: id.

## remove_text

Remove the floating text ``id``.

```json
{"properties": {"id": {"title": "Id", "type": "string"}}, "required": ["id"], "title": "remove_textArguments", "type": "object"}
```
Returns: id.

## render

Write a PNG under ``reports/`` and return its path with a summary; ``kind`` is ``topdown`` or ``isometric``.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "kind": {"default": "topdown", "title": "Kind", "type": "string"}, "size": {"default": 64, "title": "Size", "type": "integer"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["at"], "title": "renderArguments", "type": "object"}
```
Returns: path, summary.

## replace

Turn every ``from_block`` inside ``target`` into ``to_block``; snapshots first and answers with the undo id.

```json
{"properties": {"dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "from_block": {"anyOf": [{"type": "string"}, {"items": {"type": "string"}, "type": "array"}], "title": "From Block"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "to_block": {"title": "To Block", "type": "string"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "from_block", "to_block"], "title": "replaceArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## restore

Put a snapshot back by path or undo id, sending only the cells that differ; what it overwrites is pushed as a ``restore`` entry.

```json
{"properties": {"dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "snapshot": {"anyOf": [{"type": "string"}, {"type": "integer"}], "title": "Snapshot"}}, "required": ["snapshot"], "title": "restoreArguments", "type": "object"}
```
Returns: world, bounds, restored, dry_run, blocks, snapshot, undo_id, jobs.

## run_checks

Run every check in ``checks.yaml``, or only the ids in ``only``, and write the markdown report.

```json
{"properties": {"only": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "title": "Only"}}, "title": "run_checksArguments", "type": "object"}
```
Returns: report, passed, failed, total, table (at most sixty rows) of id, check, ok, seconds, detail.

## run_command

Run ``command`` as the console; the plugin's own denylist still applies underneath.

Refused unless ``confirm=True``: a command is the one tool here scoped to nothing but itself.

```json
{"properties": {"command": {"title": "Command", "type": "string"}, "confirm": {"default": false, "title": "Confirm", "type": "boolean"}}, "required": ["command"], "title": "run_commandArguments", "type": "object"}
```
Returns: command, success, output.

## save_world

Flush ``world`` to disk along with its NPC and text registries.

```json
{"properties": {"world": {"title": "World", "type": "string"}}, "required": ["world"], "title": "save_worldArguments", "type": "object"}
```
Returns: world.

## server_status

Whether the bridge answers, its round trip, ``server_info``, the designer flag and the worlds on disk.

```json
{"properties": {}, "title": "server_statusArguments", "type": "object"}
```
Returns: connected, rtt_ms, server_info, designer, worlds; or connected false, designer false and error.

## set_blocks

Set up to 4096 ``[x, y, z, block]`` entries; runs of eight or more along x go as fills. Snapshots the bounding box first.

```json
{"properties": {"blocks": {"items": {"items": {}, "type": "array"}, "title": "Blocks", "type": "array"}, "dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["blocks"], "title": "set_blocksArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## set_spawn

Set ``world``'s spawn to ``at`` (a name, ``x,z`` or ``x,y,z``).

```json
{"properties": {"at": {"title": "At", "type": "string"}, "world": {"title": "World", "type": "string"}}, "required": ["world", "at"], "title": "set_spawnArguments", "type": "object"}
```
Returns: world, pos.

## set_text

Place floating text ``text`` at ``at`` (a name, ``x,z`` or ``x,y,z``); passing a prior ``id`` updates it in place.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Id"}, "text": {"title": "Text", "type": "string"}}, "required": ["at", "text"], "title": "set_textArguments", "type": "object"}
```
Returns: world, pos, text, id.

## snapshot

Save ``target`` to disk as ``label`` without an undo entry; ``restore`` takes the path back.

```json
{"properties": {"label": {"title": "Label", "type": "string"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "label"], "title": "snapshotArguments", "type": "object"}
```
Returns: world, bounds, label, timestamp, path.

## spawn_npc

Spawn an NPC called ``name`` at ``at`` (a name, ``x,z`` or ``x,y,z``); ``kind`` defaults to ``human``.

Registers no location: a caller that wants ``at`` to persist calls ``define_location`` itself.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "kind": {"default": "human", "title": "Kind", "type": "string"}, "meta": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "title": "Meta"}, "name": {"title": "Name", "type": "string"}, "yaw": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": null, "title": "Yaw"}}, "required": ["name", "at"], "title": "spawn_npcArguments", "type": "object"}
```
Returns: world, pos, npc_id, entity_id.

## tail_log

The last ``lines`` (at most 200) of the server log, colour codes stripped.

```json
{"properties": {"lines": {"default": 50, "title": "Lines", "type": "integer"}}, "title": "tail_logArguments", "type": "object"}
```
Returns: lines, as the bridge answers.

## terraform

Flatten, raise, lower or smooth every column of ``target`` toward ``level``; snapshots first, answers with the undo id.

```json
{"properties": {"block": {"default": "minecraft:stone", "title": "Block", "type": "string"}, "dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "feather": {"default": 0, "title": "Feather", "type": "integer"}, "level": {"default": 0, "title": "Level", "type": "integer"}, "mode": {"title": "Mode", "type": "string"}, "smooth_radius": {"default": 2, "title": "Smooth Radius", "type": "integer"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "mode"], "title": "terraformArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## timelapse

A top-down PNG strip, one frame per snapshot on disk whose bounds exactly match ``region``, oldest first.

A frame is either an explicit ``snapshot`` call naming ``region`` or the automatic
before-mutation snapshot a mutating tool takes when its own ``target`` was ``region``;
a snapshot over any other box, such as a builder's own extras, is not one of its frames.

```json
{"properties": {"out": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Out"}, "region": {"title": "Region", "type": "string"}}, "required": ["region"], "title": "timelapseArguments", "type": "object"}
```
Returns: region, world, frames, path.

## undo

Reverse the ``n`` newest edits not yet undone, from any session; each pushes an ``undo`` entry that plain ``undo`` skips.

Stops at the first failure with ``ok`` false, and ``undone``, ``snapshot`` and ``undo_id`` still name what was
reversed and pushed before it.

```json
{"properties": {"dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "n": {"default": 1, "title": "N", "type": "integer"}}, "title": "undoArguments", "type": "object"}
```
Returns: dry_run, count, undone, blocks, snapshot, undo_id, jobs.
