# Zone levels

A zone level is built, never committed (riftal-pm ADR 009). This directory holds, per
zone, the recipe that builds it and the lock that names what was built. Both are
read and written by `designer/level.py`.

## Recipe, `<zone>.json`

```json
{
  "generator": "normal",
  "seed": 23,
  "bounds": {"min": [-10, 38, -10], "max": [10, 52, 10]},
  "steps": [
    {"build": "mine", "spec": "specs/lumber.json", "palette": "mine_stone"},
    {"build": "stairs", "spec": "specs/lumber_access_south.json", "palette": "mine_stone"},
    {"build": "stairs", "spec": "specs/lumber_access_east.json", "palette": "mine_stone"}
  ]
}
```

- The file name is the zone. It matches `^[a-z0-9_]+$` and never contains `world`,
  `player` or `backup`, which are refused before any engine call.
- `generator` and `seed` are authoritative. `seed` must be a JSON integer: `7.0`,
  `"7"` and `true` are refused. The zone's `worlds` entry in `world_index.json` must
  exist and agree, or the build fails before any engine call.
- `bounds` is the box that must exist as chunks, and the box `content_sha256` covers.
  Terrain the generator populates (grass, ore pockets, dirt) differs between two builds
  of one seed, so `bounds` holds only cells a step overwrites. A step may write outside
  it, within the populated chunks `pregen` makes (`pregen_bounds`), and the lock's
  `inputs` hash names it.
- `steps` run in order. `build` is a builder in `designer.builders.BUILDERS`, `spec` a
  committed file relative to `designer/`, `palette` a name in `palettes.json`. Every
  step's spec must name the zone as its `world`. An unknown builder or palette, or a
  spec naming another world, refuses the build before any engine call.
- Each step's locations and regions are registered into the build's own copy of
  `world_index.json` before the checks run. The committed file is never written. A
  step may name a committed entry only by reproducing it exactly: a name whose kind,
  world, coordinates, tags or other fields differ refuses the build before that step
  writes anything, naming the entry and each field. Tag order does not count, a repeated
  tag does, and a tag that is not a string refuses. Two steps naming one entry refuse.
- A check belongs to a zone when its `checks.yaml` entry carries `zone: <zone>`. The
  build runs only those, and needs at least one. Each must resolve against the built
  index, read the zone's world and pass. A check with no `zone` never gates a build.
- `content_sha256` does not cover stairs written outside `bounds`, so lumber's
  `lumber_spawn_to_surface` (`path_exists`, `world: lumber`) walks the built terrain from
  the spawn to a cell on the exit's ground and fails the build when a leg ends short of it.
- A zone listed under `worlds:` in riftal-game `mines/resources/config.yml` is built
  only when `checks.yaml` has a `mine_valid` with its `zone` on a spec one of the
  recipe's `mine` steps builds (ADR 014 item 7). The file is read from
  `$RIFTAL_GAME_DIR`, else the `riftal-game` checkout beside this repository;
  `build_level(mines_config=...)` takes another path. With it absent or unreadable
  every zone is refused. Both refusals come before any engine call.
- After the checks, a chorus flower anywhere in `bounds` outside every `mine` step's
  interior refuses the build: a projectile breaks one with no cancellable event.

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

## Build, `designer level build <zone>`

Runs under `DESIGNER_RUNTIME` (`wslc` or `docker`). Two volumes, both caches:

- `riftal_smoke_levelbuild_<zone>` is the work volume. It holds the server's whole `/data`
  tree and is recreated by every build. One container of that name boots on it and
  publishes only the bridge, on `127.0.0.1:19144`; under the docker fallback, run it
  inside the distro.
- `riftal_smoke_level_<zone>` is the output volume. Its root is the level folder itself
  with `level-manifest.json` at that root, which is what an instance mounts read-only at
  `/etc/riftal/levels/<zone>`.

Either volume is refused, naming every container that mounts it, before anything is
removed. The output volume is checked before the server boots, so a mounted one costs no
build.

After the lock the build writes `worlds/<zone>/level-manifest.json` on the work volume:
the lock's `content_sha256` and a `tree_sha256` that is, in the level folder, the sha256 of
`find . -type f ! -path ./level-manifest.json -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum`.
It then creates the output volume fresh and copies the contents of the work volume's
`worlds/<zone>/` into its root, in the core image with plain named-volume mounts. The
copy runs as uid 1000, so every file is readable by it. Last it tars the output volume,
recomputes the tree hash and fails unless it equals the manifest's, so a stray file at the
root fails the build and not a later instance boot. An output volume without a manifest
was not fully built.
