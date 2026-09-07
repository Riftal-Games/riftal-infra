# Designer MCP tools

Rendered by `python -m designer.tools_doc` from the tools `designer.mcp_server` registers; write in the docstrings.
Every tool answers `{"ok": true, ...}` with the keys on its `Returns` line, or `{"ok": false, "error": ..., "code": ...}`.

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
Returns: default_world, then a list per kind asked for: worlds, locations, regions.

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

## render

Write a PNG under ``reports/`` and return its path with a summary; ``kind`` is ``topdown``.

```json
{"properties": {"at": {"title": "At", "type": "string"}, "kind": {"default": "topdown", "title": "Kind", "type": "string"}, "size": {"default": 64, "title": "Size", "type": "integer"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["at"], "title": "renderArguments", "type": "object"}
```
Returns: see the ok envelope

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

## server_status

Whether the bridge answers, its round trip, ``server_info``, the designer flag and the worlds on disk.

```json
{"properties": {}, "title": "server_statusArguments", "type": "object"}
```
Returns: connected, rtt_ms, server_info, designer, worlds; or connected false with error.

## set_blocks

Set up to 4096 ``[x, y, z, block]`` entries; runs of eight or more along x go as fills. Snapshots the bounding box first.

```json
{"properties": {"blocks": {"items": {"items": {}, "type": "array"}, "title": "Blocks", "type": "array"}, "dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["blocks"], "title": "set_blocksArguments", "type": "object"}
```
Returns: world, bounds, dry_run, blocks, requests, snapshot, undo_id, jobs.

## snapshot

Save ``target`` to disk as ``label`` without an undo entry; ``restore`` takes the path back.

```json
{"properties": {"label": {"title": "Label", "type": "string"}, "target": {"anyOf": [{"type": "string"}, {"additionalProperties": true, "type": "object"}], "title": "Target"}, "world": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "World"}}, "required": ["target", "label"], "title": "snapshotArguments", "type": "object"}
```
Returns: world, bounds, label, timestamp, path.

## tail_log

The last ``lines`` (at most 200) of the server log, colour codes stripped.

```json
{"properties": {"lines": {"default": 50, "title": "Lines", "type": "integer"}}, "title": "tail_logArguments", "type": "object"}
```
Returns: lines, as the bridge answers.

## undo

Reverse the ``n`` newest edits not yet undone, from any session; each pushes an ``undo`` entry that plain ``undo`` skips.

```json
{"properties": {"dry_run": {"default": false, "title": "Dry Run", "type": "boolean"}, "n": {"default": 1, "title": "N", "type": "integer"}}, "title": "undoArguments", "type": "object"}
```
Returns: dry_run, count, undone, blocks, snapshot, undo_id.
