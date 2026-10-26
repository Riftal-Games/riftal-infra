#!/usr/bin/env python3
"""Fails unless every world in designer/world_index.json that carries a rank has
a region tagged safe_zone, and the world with role contested has none. Riots
makes a world safe once any region in it carries the tag, so a ranked mine
without one is open PvP, and a contested world with one is no longer contested.
Reads the file only. Standard library only.
"""

import json
import pathlib
import sys

DEFAULT = pathlib.Path(__file__).resolve().parents[2] / "designer" / "world_index.json"


def check(path):
    try:
        data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        worlds = data["worlds"]
        regions = data["regions"]
        zoned = {r["world"] for r in regions if "safe_zone" in r["tags"]}
        ranked = sorted(w["name"] for w in worlds if "rank" in w)
        contested = sorted(w["name"] for w in worlds if w.get("role") == "contested")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [f"cannot read {path} as a world index: {exc}"], ""
    errors = [f"ranked world {n} has no region tagged safe_zone" for n in ranked if n not in zoned]
    errors += [f"contested world {n} has a region tagged safe_zone" for n in contested if n in zoned]
    if not ranked:
        errors.append("no world carries a rank, so the check has nothing to judge")
    summary = f"{len(ranked)} ranked world(s) all have a safe_zone region; {len(contested)} contested world(s) have none"
    return errors, summary


if __name__ == "__main__":
    problems, ok = check(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    for problem in problems:
        print(f"::error::{problem}")
    if not problems:
        print(ok)
    sys.exit(1 if problems else 0)
