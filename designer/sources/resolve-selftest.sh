#!/usr/bin/env bash
# Proves resolve.sh can fail: a census with a block the core knows, a block it
# does not and a block-entity type it does not must come back as exactly the two
# unknown ones, and a committed verdict that differs must fail `check`.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/census.json" <<'JSON'
{
 "states": [
  {"key": "minecraft:stone", "name": "minecraft:stone", "states": {}, "version": 18496512, "count": 1},
  {"key": "minecraft:no_such_block", "name": "minecraft:no_such_block", "states": {}, "version": 18496512, "count": 2}
 ],
 "block_entities": {"Chest": 1, "NoSuchTile": 1}
}
JSON
chmod 755 "$work"
chmod 644 "$work/census.json"

verdict="$(bash "$DIR/resolve.sh" run "$work/census.json")"
printf '%s\n' "$verdict" | uv run --frozen --project "$DIR/../../designer" python -I -c '
import json, sys
v = json.load(sys.stdin)
assert [u["key"] for u in v["unresolved"]] == ["minecraft:no_such_block"], v["unresolved"]
assert v["unresolved"][0]["count"] == 2, v["unresolved"]
assert v["block_entities_unknown"] == ["NoSuchTile"], v["block_entities_unknown"]
assert v["states_checked"] == 2 and v["block_entity_types_checked"] == 2, v
print("ok    the core reports the unknown block and the unknown block entity, and only them")
'


if bash "$DIR/resolve.sh" check "$work/census.json" >/dev/null 2>&1; then
  printf '::error::a census with no recorded verdict passed check\n'
  exit 1
fi
printf 'ok    check refuses a census whose recorded verdict differs from the core\n'

bash "$DIR/resolve.sh" write "$work/census.json"
bash "$DIR/resolve.sh" check "$work/census.json"
printf 'ok    a verdict written by the core passes check\n'
