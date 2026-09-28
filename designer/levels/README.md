# Zone levels

A zone level is built, never committed (riftal-pm ADR 009). This directory holds, per
zone, the recipe that builds it and the lock that names what was built. Both are
read and written by `designer/level.py`.

## Recipe, `<zone>.json`

```json
{
  "generator": "normal",
  "seed": 20260907,
  "bounds": {"min": [-10, 38, -10], "max": [10, 52, 10]},
  "steps": [{"build": "mine", "spec": "specs/lumber.json", "palette": "mine_stone"}]
}
```

- The file name is the zone. It matches `^[a-z0-9_]+$` and never contains `world`,
  `player` or `backup`, which are refused before any engine call.
- `generator` and `seed` are authoritative. The zone's `worlds` entry in
  `world_index.json` must exist and agree, or the build fails before any engine call.
- `bounds` is the box that must exist as chunks, and the box `content_sha256` covers.
- `steps` run in order. `build` is a builder in `designer.builders.BUILDERS`, `spec` a
  committed file relative to `designer/`, `palette` a name in `palettes.json`. Every
  step must write the zone's world.
- `checks.yaml` must hold at least one check on the zone, and every one must pass.

## Lock, `<zone>.lock.json`

| Key | Meaning |
|---|---|
| `zone`, `generator`, `seed`, `bounds` | Copied from the recipe |
| `core_image` | Image id of the `local-pocketmine-mp` the build ran on |
| `designbridge_commit`, `toolkit_commit` | Commits of the DesignBridge source and this toolkit |
| `inputs` | sha256 of the recipe, each step's spec, and each palette as `palette:<name>` |
| `chunks` | Chunks `scan_items` walked: every chunk the saved level holds |
| `size_bytes` | Uncompressed size of the saved level folder |
| `content_sha256` | Block states in `bounds`, then `design_npcs.json` and `design_texts.json` when present |

`chunks` and `size_bytes` count more than the recipe bounds. They include the boot
spawn area around (256, 256), the one-chunk margin `pregen` populates around the
bounds, and the ring two chunks out: populating a margin chunk writes into its
neighbours, so that ring is generated and saved but never populated. `content_sha256`
covers only `bounds`, so neither the spawn area nor the margin changes it.

A lock is written only when every stage passed. A scan finding, a failed check or a
failed step leaves the previous lock untouched.
