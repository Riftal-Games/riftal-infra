#!/usr/bin/env bash
# Self-test for instance-levels-check.sh. Builds each case's instance
# definitions and build locks in a temp dir and starts no container. Every rule
# has a fixture it must refuse and the green cases pass, so a check that refuses
# everything fails here as surely as one that refuses nothing.
# INSTANCE_LEVELS_CHECK names another copy of the script to test, and JQ_BIN
# names the jq to give it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${INSTANCE_LEVELS_CHECK:-$SCRIPT_DIR/instance-levels-check.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
sha="$(printf 'a%.0s' {1..64})"

failures=0
ran=0
expected=44
cases=0

# fresh starts an empty case with an instances dir and a locks dir.
fresh() {
  cases=$((cases + 1))
  C="$DIR/c$cases"
  mkdir -p "$C/instances" "$C/locks"
  : >"$C/instances/.gitkeep"
}
# lock <zone> [<zone named in the lock>] [<content_sha256>] writes a build lock.
lock() {
  printf '{"zone": "%s", "content_sha256": "%s"}\n' "${2:-$1}" "${3:-$sha}" >"$C/locks/$1.lock.json"
}
# inst <id> <RIFTAL_LEVEL_ZONES value> <POCKETMINE_ARGS value> writes a definition.
inst() {
  mkdir -p "$C/instances/$1"
  printf '%s\n' 'img:v1' >"$C/instances/$1/image"
  printf 'RIFTAL_LEVEL_ZONES=%s\nPOCKETMINE_ARGS=%s\n' "$2" "$3" >"$C/instances/$1/instance.env"
}
# expect <exit> <regex some output line must match> <case>
expect() {
  local want="$1" match="$2" case="$3" out got
  ran=$((ran + 1))
  set +e
  out="$(INSTANCES_DIR="$C/instances" LEVEL_LOCKS_DIR="${LOCKS:-$C/locks}" bash "$CHECK" 2>&1)"
  got=$?
  set -e
  if [ "$got" -ne "$want" ] || ! grep -q -E -- "$match" <<<"$out" ||
    { [ "$want" -ne 1 ] && grep -q 'INSTANCE LEVELS REFUSED' <<<"$out"; } ||
    { [ -n "${ONLY:-}" ] && [ "$(grep -c 'INSTANCE LEVELS REFUSED' <<<"$out")" -ne 1 ]; } ||
    { [ "$want" -ne 0 ] && grep -q 'INSTANCE LEVELS OK' <<<"$out"; }; then
    printf 'FAIL %s: want exit %s matching /%s/, got exit %s:\n%s\n' "$case" "$want" "$match" "$got" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$case"
  fi
}
# refused <regex> <case> expects one refusal and no other finding.
refused() { ONLY=1 expect 1 "^INSTANCE LEVELS REFUSED: i: $1" "$2"; }

fresh
expect 0 'OK: 0 instance definition\(s\) read, 0 built zone\(s\): none$' 'an empty instances dir with .gitkeep passes'

fresh; lock lumber; lock mine_a; inst i 'lumber mine_a' '--level-name=lumber --auto-report.enabled=0'
expect 0 'OK: 1 instance definition\(s\) read, 2 built zone\(s\): lumber mine_a$' 'a default level and a second zone, both built, pass'

fresh; lock lumber; inst i '  lumber' '--x=1   --level-name=lumber'
expect 0 'OK: 1 instance definition' 'whitespace around tokens is not a finding'

fresh; lock lumber; lock mine_a; inst i lumber --level-name=lumber; inst j mine_a --level-name=mine_a
expect 0 'OK: 2 instance definition\(s\) read, 2 built zone\(s\)' 'two definitions with different zones pass'

fresh; lock lumber; inst i lumber --level-name=lumber; printf '# a comment\n\n' >>"$C/instances/i/instance.env"
expect 0 'OK: 1 instance definition' 'blank lines and # comments pass'

fresh; lock mine_a; inst i 'lumber mine_a' '--level-name=lumber'
refused "zone lumber has no build: .*lumber.lock.json is not a regular file" 'a default level listed with no lock refuses'
fresh; lock lumber; inst i 'lumber mine_a' '--level-name=lumber'
refused "zone mine_a has no build: .*mine_a.lock.json is not a regular file" 'another listed zone with no lock refuses'
fresh; lock lumber; lock mine_a; inst i 'mine_a' '--level-name=lumber'
refused "--level-name zone 'lumber' is not in RIFTAL_LEVEL_ZONES" 'a default level outside the list refuses'
fresh; lock lumber; inst i lumber '--auto-report.enabled=0'
refused 'POCKETMINE_ARGS holds no --level-name' 'no --level-name refuses'
fresh; lock lumber; lock mine_a; inst i 'lumber mine_a' '--level-name=lumber --level-name=mine_a'
refused 'POCKETMINE_ARGS holds 2 --level-name tokens' 'two --level-name tokens refuse'
fresh; lock lumber; inst i lumber '--level-name'
refused "POCKETMINE_ARGS token '--level-name' is not --level-name=<zone>" 'a bare --level-name refuses'
fresh; lock lumber; inst i lumber '--xbox-auth false --level-name=lumber'
refused "POCKETMINE_ARGS token 'false' is not a single long option" 'a value token before --level-name refuses, since getopt stops there'
fresh; lock lumber; inst i lumber '--level-name lumber'
expect 1 "POCKETMINE_ARGS token 'lumber' is not a single long option" 'a --level-name given its value as a separate token refuses'
fresh; lock lumber; inst i lumber '--auto-report.enabled=0 -- --level-name=lumber'
refused "POCKETMINE_ARGS token '--' is not a single long option" 'a -- token before --level-name refuses'
fresh; lock lumber; inst i lumber '- --level-name=lumber'
refused "POCKETMINE_ARGS token '-' is not a single long option" 'a lone - token before --level-name refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber --level-name='
refused "POCKETMINE_ARGS token '--level-name=' is not --level-name=<zone>" 'an empty --level-name value refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber --worlds=x'
refused "POCKETMINE_ARGS token '--worlds=x' would generate" 'a --worlds token refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber'; sed -i '/^RIFTAL_LEVEL_ZONES/d' "$C/instances/i/instance.env"
refused 'instance.env sets no RIFTAL_LEVEL_ZONES' 'a missing RIFTAL_LEVEL_ZONES refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber'; sed -i '/^POCKETMINE_ARGS/d' "$C/instances/i/instance.env"
refused 'instance.env sets no POCKETMINE_ARGS' 'a missing POCKETMINE_ARGS refuses'
fresh; lock lumber; inst i ' ' '--level-name=lumber'
expect 1 '^INSTANCE LEVELS REFUSED: i: RIFTAL_LEVEL_ZONES lists no zone' 'a RIFTAL_LEVEL_ZONES of only spaces refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber'; printf 'RIFTAL_LEVEL_ZONES=\n' >>"$C/instances/i/instance.env"
refused 'instance.env:3 repeats RIFTAL_LEVEL_ZONES' 'a repeated key refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber'; printf 'EMPTY=\n' >>"$C/instances/i/instance.env"
refused 'instance.env:3 gives EMPTY an empty value' 'an empty value refuses'
fresh; lock lumber; inst i '"lumber"' '--level-name=lumber'
expect 1 '^INSTANCE LEVELS REFUSED: i: instance.env:1 gives RIFTAL_LEVEL_ZONES a character outside' 'a quoted value refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber $HOME'
expect 1 '^INSTANCE LEVELS REFUSED: i: instance.env:2 gives POCKETMINE_ARGS a character outside' 'a $ in a value refuses'
fresh; lock lumber; inst i lumber '--level-name=lumber'; printf 'not a line\n' >>"$C/instances/i/instance.env"
refused 'instance.env:3 is not blank, a # comment or KEY=VALUE' 'a line that is not KEY=VALUE refuses'
fresh; lock lumber; inst i 'lumber ../x' '--level-name=lumber'; : >"$C/x.lock.json"
refused "RIFTAL_LEVEL_ZONES zone '../x' is not a name" 'a zone name with a path refuses and reads no lock'
fresh; lock lumber; inst i 'lumber Lumber' '--level-name=lumber'
refused "RIFTAL_LEVEL_ZONES zone 'Lumber' is not a name" 'an uppercase zone name refuses'
fresh; lock lumber; inst i 'lumber lumber' '--level-name=lumber'
refused 'RIFTAL_LEVEL_ZONES lists zone lumber more than once' 'a zone repeated in one list refuses'
fresh; lock lumber; inst a lumber --level-name=lumber; inst b lumber --level-name=lumber
expect 1 '^INSTANCE LEVELS REFUSED: b: zone lumber is also listed by a' 'one zone in two definitions refuses'
fresh; lock lumber; inst i lumber --level-name=lumber; : >"$C/instances/i/server.properties"
refused 'holds server.properties, and a definition holds only' 'an extra server.properties refuses'
fresh; lock lumber; inst i lumber --level-name=lumber; rm "$C/instances/i/instance.env"
refused 'has no instance.env' 'a definition with no instance.env refuses'
fresh; lock lumber; inst i lumber --level-name=lumber; rm "$C/instances/i/image"
refused 'has no image file' 'a definition with no image file refuses'
fresh; lock lumber; inst i lumber --level-name=lumber; rm "$C/instances/i/image"; mkdir "$C/instances/i/image"
refused 'image is not a regular file' 'an image that is a directory refuses'
fresh; inst i lumber --level-name=lumber; printf 'not json\n' >"$C/locks/lumber.lock.json"
refused 'zone lumber has no build: .* is not one JSON object' 'a lock that is not JSON refuses'
fresh; inst i lumber --level-name=lumber; lock lumber mine_a
refused "zone lumber has no build: .* names zone 'mine_a'" 'a lock naming another zone refuses'
fresh; inst i lumber --level-name=lumber; lock lumber lumber "${sha:1}"
refused 'zone lumber has no build: .* no 64-digit lowercase hex content_sha256' 'a short content_sha256 refuses'
fresh; inst i lumber --level-name=lumber; lock lumber lumber "$(printf 'A%.0s' {1..64})"
refused 'zone lumber has no build: .* no 64-digit lowercase hex content_sha256' 'an uppercase content_sha256 refuses'
fresh; inst i lumber --level-name=lumber; printf '{"zone": "lumber"}\n' >"$C/locks/lumber.lock.json"
refused 'zone lumber has no build: .* no 64-digit lowercase hex content_sha256' 'a lock with no content_sha256 refuses'
fresh; inst i lumber --level-name=lumber; printf '[{"zone": "lumber", "content_sha256": "%s"}]\n' "$sha" >"$C/locks/lumber.lock.json"
refused 'zone lumber has no build: .* is not one JSON object' 'a lock that is a JSON array refuses'
fresh; inst i lumber --level-name=lumber; mkdir "$C/locks/lumber.lock.json"
refused 'zone lumber has no build: .* is not a regular file' 'a lock that is a directory refuses'
fresh; printf 'x\n' >"$C/instances/stray"
expect 1 '^INSTANCE LEVELS REFUSED: stray: is not a directory' 'a top-level file in instances refuses'

fresh; LOCKS="$C/no-such-dir" expect 2 'is not a directory, so no zone' 'a locks dir that is not a directory is an error, not a pass'
unset LOCKS

fresh; JQ_BIN="$DIR/no-jq" expect 2 'is not an executable jq' 'a missing jq is an error, not a pass'

fresh; inst i lumber --level-name=lumber; chmod 000 "$C/instances/i/instance.env"
if [ -r "$C/instances/i/instance.env" ]; then
  ran=$((ran + 1))
  echo 'skip an unreadable instance.env: this user reads mode 000 files'
else
  expect 2 'cannot read .*instance.env' 'an unreadable instance.env is an error, not a pass'
fi
chmod 600 "$C/instances/i/instance.env"

if [ "$ran" -ne "$expected" ]; then
  echo "FAIL ran $ran cases, expected $expected" >&2
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  echo "$failures of $ran cases failed" >&2
  exit 1
fi
echo "instance levels check self-test: $ran cases ok"
