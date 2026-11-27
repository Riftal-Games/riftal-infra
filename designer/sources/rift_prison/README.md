# rift_prison sources

The studio's hand-off for the pit, pinned by sha256 in `pins.json`. Every file
here is a byte copy and is excluded from line-ending rewrites in `.gitattributes`,
since the pins are of those exact bytes.

| File | From the hand-off |
|---|---|
| `cells.json`, `routes.json`, `markers.json` | the top level of `builds/rift_prison/`. `export/markers.json` holds the same markers wrapped with `anchor`, `size` and `min_corner`. |
| `rift_prison_bedrock.mcstructure.gz` | `export/rift_prison_bedrock.mcstructure`, 373,116,853 bytes, gzipped. |
| `pins.json` | the sha256 of each file above, and `structure_sha256`, the sha256 of the structure's uncompressed bytes. That one names the content, since two gzips of the same bytes differ. |
| `census.json` | every block state and block-entity type with its count, and `resolution`, the pinned core image's verdict on each. |

`python -m designer.pit_census check` is what CI runs: the pins, then the census
rebuilt from the gzip. `designer/sources/resolve.sh check` runs `resolve_states.php`
in the core image `images/core-image.sha` names and compares its verdict with
`resolution`. A new pin or a new structure is refreshed with
`python -m designer.pit_census write`, then `designer/sources/resolve.sh write`.

A block state the core does not read is listed under `resolution.unresolved` and is
never replaced with `info_update`. The substitute for each is decided on
riftal-infra#1504.

`cells_without_state.layer_0` counts the cells whose index is -1: the structure
writes nothing there.
