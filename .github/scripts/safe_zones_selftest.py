#!/usr/bin/env python3
"""Proves safe_zones.py can fail. Each case edits a passing index and must be
refused for its own reason, or accepted where want starts with =. Reads files
only. Standard library only.
"""

import importlib.util
import json
import pathlib
import sys
import tempfile

sys.dont_write_bytecode = True
here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("safe_zones", here / "safe_zones.py")
safe_zones = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe_zones)

GOOD = {
    "regions": [
        {"name": "a_zone", "world": "mine_a", "tags": ["mine", "safe_zone"]},
        {"name": "b_zone", "world": "mine_b", "tags": ["mine", "safe_zone"]},
        {"name": "c_outer", "world": "contested", "tags": ["mine"]},
    ],
    "worlds": [
        {"name": "contested", "role": "contested"},
        {"name": "lumber", "role": "lumber"},
        {"name": "mine_a", "rank": "A", "role": "ore_mine"},
        {"name": "mine_b", "rank": "B", "role": "ore_mine"},
    ],
}


def edit(change):
    def apply(data):
        change(data)
        return data
    return apply


cases = [
    ("ranked-mine-without-region", edit(lambda d: d["regions"].pop(1)), "ranked world mine_b has no region tagged safe_zone"),
    ("ranked-mine-region-untagged", edit(lambda d: d["regions"][0].update(tags=["mine"])), "ranked world mine_a has no region tagged safe_zone"),
    ("ranked-mine-region-in-other-world", edit(lambda d: d["regions"][0].update(world="lumber")), "ranked world mine_a has no region tagged safe_zone"),
    ("contested-with-region", edit(lambda d: d["regions"][2].update(tags=["mine", "safe_zone"])), "contested world contested has a region tagged safe_zone"),
    ("no-ranked-world", edit(lambda d: [w.pop("rank", None) for w in d["worlds"]]), "no world carries a rank"),
    ("no-worlds-key", edit(lambda d: d.pop("worlds")), "cannot read"),
    ("unzoned-unranked-world", edit(lambda d: d["worlds"].append({"name": "farm", "role": "farm"})), "=all have a safe_zone region"),
    ("good-fixture", None, "=all have a safe_zone region; 1 contested world(s) have none"),
]

failures = 0
for name, change, want in cases:
    data = json.loads(json.dumps(GOOD))
    if change:
        data = change(data)
    with tempfile.TemporaryDirectory() as tmp:
        file = pathlib.Path(tmp, "world_index.json")
        file.write_text(json.dumps(data), encoding="utf-8")
        errors, summary = safe_zones.check(str(file))
    accepts = want.startswith("=")
    got = summary if accepts else "\n".join(errors)
    ok = bool(errors) != accepts and want.lstrip("=") in got
    print(f"  ok    {name}" if ok else f"::error::{name}: wanted '{want}', got: {got}")
    failures += not ok

errors, _ = safe_zones.check(str(here / "absent.json"))
failures += not any("cannot read" in error for error in errors)
if failures:
    sys.exit(1)
print("safe_zones.py refuses every mutant for its own reason")
