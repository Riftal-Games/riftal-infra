# Pit index and mine position sets

Written by `python -m designer.pit_index write`, compared by `check`. `pit_index.json` is in world coordinates,
`mine_sets/layer_01.bin` to `layer_13.bin` hold each deck bed's `packed_mud`, `layer_14.bin` the floor ring's and
`contested.bin` the contested cylinder's terracotta, one bit per cell of the mine's box (format `RPS1`, spec 026), and
`pit.sha256` is the `sha256sum` manifest of all 16. `images/plugins/deliver-pit-index.sh` refuses a boot when a file
differs, then copies `pit_index.json` into the data folders of `RiftalMines`, `RiftalRanks` and `RiftalCells` and the 15
sets into `RiftalMines`' alone. `RiftalCustody` gets no file (spec 026, ADR 014 item 4). A transit flight or balcony is a
band box plus `r`, an inclusive range of the pit radius; no transit region holds a bridge strip. Region bounds and the
sell, rank-up and doorway positions are in `specs/pit_index.json`.
