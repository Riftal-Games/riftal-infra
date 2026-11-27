"""The two fill steps of a level recipe: ``fill_box`` and ``fill_sets``.

``fill_box`` writes one block over a committed box, before the zone's checks. ``fill_sets``
runs after them, because the checks read the placeholder of every mine, and replaces that
placeholder with a stone block in the mines whose layers the spec names (spec 026, Q8).
Each mine is a position set committed in ``designer/pit/``, read only when the manifest
vouches for its bytes.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import numpy as np

from designer.blocks import parse_name
from designer.edits import EditList, Fill, Replace
from designer.pit_index import PitIndexError, decode_set, set_name
from designer.region import Bounds, Region


class FillError(ValueError):
    """A fill spec, a set or the level it would write to is not what the step needs."""


def box_edits(spec: dict[str, Any]) -> EditList:
    """One ``Fill`` of ``spec["block"]`` over ``spec["bounds"]``."""
    try:
        return EditList(str(spec["world"]), [Fill(Bounds.from_json(spec["bounds"]), str(spec["block"]))])
    except (KeyError, TypeError, ValueError) as exc:
        raise FillError(f"a fill_box spec needs world, bounds and block: {exc!r}") from exc


def manifest(directory: Path, name: str) -> dict[str, str]:
    """File name to sha256 from a ``sha256sum`` listing."""
    path = directory / name
    if not path.is_file():
        raise FillError(f"{path} does not exist")
    named: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, separator, file = line.partition("  ")
        if not separator:
            raise FillError(f"{path}: malformed line {line!r}")
        named[file] = digest
    return named


def read_sets(directory: Path, manifest_name: str, layers: list[int]) -> dict[int, tuple[Bounds, np.ndarray]]:
    """Each layer's box and positions, from a set file whose sha256 the manifest names."""
    named, out = manifest(directory, manifest_name), {}
    for layer in layers:
        name = set_name(layer)
        data = (directory / name).read_bytes() if (directory / name).is_file() else None
        if data is None:
            raise FillError(f"{directory / name} does not exist")
        if hashlib.sha256(data).hexdigest() != named.get(name):
            raise FillError(f"{name} differs from the sha256 {manifest_name} names")
        try:
            origin, size, points = decode_set(data)
        except PitIndexError as exc:
            raise FillError(f"{name}: {exc}") from exc
        out[layer] = (Bounds.from_size(origin, size), points)
    return out


def set_edits(spec: dict[str, Any], directory: Path, region: Region) -> EditList:
    """One ``Replace`` of the placeholder per layer, over the layer's set box.

    A box replace writes exactly the set only if every position holds the placeholder and the
    box holds it nowhere else, so ``region`` is read for both first.
    """
    try:
        world, layers = str(spec["world"]), [int(n) for n in spec["layers"]]
        placeholder, block = str(spec["from"]), str(spec["block"])
        sets = read_sets(directory / str(spec["sets"]), str(spec["manifest"]), layers)
    except (KeyError, TypeError, ValueError) as exc:
        if isinstance(exc, FillError):
            raise
        raise FillError(f"a fill_sets spec needs world, sets, manifest, layers, from and block: {exc!r}") from exc
    if region.world != world:
        raise FillError(f"the level read is world {region.world!r}, the spec names {world!r}")
    base = parse_name(placeholder)[0]
    held = [i for i, name in enumerate(region.palette) if parse_name(name)[0] == base]
    ops: list[Replace] = []
    for layer, (box, points) in sets.items():
        if region.bounds.intersect(box) != box:
            raise FillError(f"layer {layer}'s set box {box.min}..{box.max} is not inside the level read {region.bounds.min}..{region.bounds.max}")
        view = region.sub(box)
        local = points - np.array(box.min)
        absent = ~np.isin(view.blocks[local[:, 1], local[:, 2], local[:, 0]], held)
        if absent.any():
            first = tuple(int(v) for v in points[int(absent.argmax())])
            raise FillError(f"layer {layer}: {int(absent.sum())} set positions do not hold {base}, first at {first}")
        found = int(np.isin(view.blocks, held).sum())
        if found != len(points):
            raise FillError(f"layer {layer}: its box holds {found} {base}, its set has {len(points)} positions")
        ops.append(Replace(box, (placeholder,), block))
    return EditList(world, list(ops))
