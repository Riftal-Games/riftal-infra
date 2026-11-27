# Pit index and mine position sets

Written by `python -m designer.pit_index write`, compared by `check`. `pit_index.json` is in world coordinates,
`mine_sets/layer_NN.bin` hold one bit per cell of a layer's bed box where the hand-off has `packed_mud` (format `RPS1`,
spec 026), and `pit.sha256` is the `sha256sum` manifest of all 15. `images/plugins/deliver-pit-index.sh` refuses a
boot when a file differs, then copies `pit_index.json` into the data folders of `RiftalMines`, `RiftalRanks` and
`RiftalCells` and the 14 sets into `RiftalMines`' alone. `RiftalCustody` gets no file (spec 026, ADR 014 item 4). Bridge
strips carry end points, deck y and deck width only. Region bounds and the sell, rank-up and doorway positions are in `specs/pit_index.json`.
