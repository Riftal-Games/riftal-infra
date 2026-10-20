#!/usr/bin/env bash
# Self-test for grants-revoke-check.sh. Uses a fake container runtime and
# fixture files and starts no container. Every rule has a case that must refuse
# and one that must pass, so a check that refuses everything fails here as
# surely as one that refuses nothing. GRANTS_REVOKE_CHECK names another copy of
# the script to test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${GRANTS_REVOKE_CHECK:-$SCRIPT_DIR/grants-revoke-check.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

img='registry.example/riftal/pocketmine-mp'
mkdir -p "$DIR/instances" "$DIR/empty"

# FAKE_RUNNING and FAKE_ALL are the files `ps` and `ps -a` print.
cat >"$DIR/runtime" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_FAIL:-}" ] || exit 1
case "$*" in
  'ps --format'*) cat "$FAKE_RUNNING" ;;
  'ps -a --format'*) cat "$FAKE_ALL" ;;
  *) exit 3 ;;
esac
EOF

grants() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$DIR/$name"
}
revoke_a='REVOKE IF EXISTS UPDATE (balance_minor_units) ON balances FROM riftal_role_economy;'
revoke_b='REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;'
grants none.sql '-- a comment naming REVOKE; and nothing else' 'GRANT SELECT ON accounts TO riftal_role_mines;'
grants a.sql "$revoke_a"
grants ab.sql "$revoke_a" "$revoke_b"
grants b.sql "$revoke_b"
grants spaced.sql '-- REVOKE in a comment;' 'REVOKE IF EXISTS' '   UPDATE (balance_minor_units)' '  ON balances  FROM riftal_role_economy; -- trailing'
printf 'REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;\r\n' >"$DIR/crlf.sql"
grants block.sql "/* old note */ $revoke_a"
grants hash.sql '# old note' "$revoke_a"
grants inblock.sql "/* see riftal-game#123 -- old */ $revoke_b"
grants quoted.sql "SELECT '--'; $revoke_b"
grants dashes.sql "SELECT 1--1; $revoke_b"
printf -- '-- ok\n/* caf\351 */ %s\n' "$revoke_b" >"$DIR/latin1.sql"
printf 'GRANT SELECT ON t TO r;\n\0\n%s\n' "$revoke_b" >"$DIR/nul.sql"
grants lower.sql 'revoke if exists riftal_role_accounts from riftal_role_mines;'
grants word.sql 'GRANT SELECT ON revokes TO riftal_role_mines;'

# containers <file> <name> <image> ...
containers() {
  local file="$1"
  shift
  : >"$DIR/$file"
  while [ "$#" -gt 0 ]; do
    printf '%s\t%s\n' "$1" "$2" >>"$DIR/$file"
    shift 2
  done
}
containers none
containers one-old a-1 "$img:v1" other mysql:8
containers one-new a-1 "$img:v2" other mysql:8
containers byid a-1 0123456789ab
containers latest a-1 "$img:latest"
containers untagged a-1 "$img"
containers digest a-1 "$img@sha256:0123456789abcdef"

failures=0
ran=0
expected=32
# check <exit> <regex some output line must match> <case> <running> <all> <arg>...
check() {
  local want="$1" match="$2" case="$3" run="$4" all="$5" out got
  shift 5
  ran=$((ran + 1))
  set +e
  out="$(cd "$DIR" && INSTANCE_IMAGE="$img" CONTAINER_RUNTIME="bash $DIR/runtime" \
    INSTANCES_DIR="${INSTANCES_DIR:-$DIR/empty}" FAKE_RUNNING="$DIR/$run" FAKE_ALL="$DIR/$all" \
    bash "$CHECK" "$@" 2>&1)"
  got=$?
  set -e
  if [ "$got" -ne "$want" ] || ! grep -q -E -- "$match" <<<"$out" ||
    { [ "$want" -ne 1 ] && grep -q 'GRANTS REVOKE REFUSED' <<<"$out"; }; then
    printf 'FAIL %s: want exit %s matching /%s/, got exit %s:\n%s\n' "$case" "$want" "$match" "$got" "$out"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$case"
  fi
}

check 0 '^GRANTS REVOKE OK: 1 REVOKE statement\(s\) in b.sql, 0 older tag\(s\) checked, tags in use: v2, runtime: bash .*/runtime$' \
  'only the release tag in use passes' one-new one-new b.sql v2
check 0 '^GRANTS REVOKE OK: 1 REVOKE statement\(s\) in a.sql, 0 older tag' \
  'no container and no definition passes' none none a.sql v2
check 0 'in none.sql, 1 older tag\(s\) checked, tags in use: v1, runtime' 'a new grants.sql with no REVOKE passes against an older tag' \
  one-old one-old none.sql v2 v1=a.sql
check 0 'in ab.sql, 1 older tag' 'a REVOKE the older tag already carries passes' \
  one-old one-old ab.sql v2 v1=ab.sql
check 0 'in spaced.sql, 1 older tag' 'whitespace, comments and line breaks do not make a REVOKE new' \
  one-old one-old spaced.sql v2 v1=a.sql
check 0 'in crlf.sql, 1 older tag' 'CRLF line ends do not make a REVOKE new' \
  one-old one-old crlf.sql v2 v1=b.sql
check 0 'in a.sql, 1 older tag' 'a REVOKE the new file dropped is not a hazard' \
  one-old one-old a.sql v2 v1=ab.sql
check 1 '^GRANTS REVOKE REFUSED: "REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines" is new against tag v1 \(running container a-1\)$' \
  'a REVOKE new against a running container refuses' one-old one-old ab.sql v2 v1=a.sql
check 1 'is new against tag v1 \(stopped container a-1\)$' \
  'a REVOKE new against a stopped container refuses' none one-old ab.sql v2 v1=a.sql
check 1 '^GRANTS REVOKE REFUSED: "REVOKE IF EXISTS UPDATE \(balance_minor_units\) ON balances FROM riftal_role_economy" is new against tag v1 ' \
  'a multi-line REVOKE is read as one statement and refuses' one-old one-old spaced.sql v2 v1=none.sql
check 1 '^GRANTS REVOKE REFUSED: "/\* old note \*/ REVOKE IF EXISTS UPDATE' \
  'a REVOKE after a block comment is seen and refuses' one-old one-old block.sql v2 v1=none.sql
check 1 '^GRANTS REVOKE REFUSED: "# old note REVOKE IF EXISTS UPDATE' \
  'a REVOKE after a # comment is seen and refuses' one-old one-old hash.sql v2 v1=none.sql
check 1 '^GRANTS REVOKE REFUSED: "revoke if exists riftal_role_accounts' \
  'a lowercase revoke is seen and refuses' one-old one-old lower.sql v2 v1=none.sql
check 2 'inblock.sql:1: a /\* \*/ comment that spans lines or shares a line with --' \
  'a -- inside a block comment does not hide a REVOKE' one-old one-old inblock.sql v2 v1=none.sql
check 2 'quoted.sql:1: a quote or backtick' \
  'a -- inside a quoted string does not hide a REVOKE' one-old one-old quoted.sql v2 v1=none.sql
check 2 'dashes.sql:1: a -- not followed by whitespace' \
  'a -- with no whitespace after it does not hide a REVOKE' one-old one-old dashes.sql v2 v1=none.sql
LC_ALL=C.UTF-8 check 2 'latin1.sql has a byte other than printable ASCII' \
  'a non-UTF-8 byte does not hide a REVOKE' one-old one-old latin1.sql v2 v1=none.sql
check 2 'nul.sql has a byte other than printable ASCII' \
  'a NUL does not hide a REVOKE' one-old one-old nul.sql v2 v1=none.sql
check 2 'inblock.sql:1: a /\* \*/ comment' \
  'a reader failure on an older tag file is an error, not a pass' one-old one-old b.sql v2 v1=inblock.sql
check 0 'OK: 0 REVOKE statement\(s\) in word.sql' \
  'a word merely containing revoke is not a REVOKE' one-old one-old word.sql v2 v1=none.sql

printf '%s\n' "image: $img:v1" >"$DIR/instances/a.yaml"
INSTANCES_DIR="$DIR/instances" check 1 'is new against tag v1 \(instance definition .*/instances/a.yaml:1\)$' \
  'a REVOKE new against an instance definition refuses' none none ab.sql v2 v1=a.sql
INSTANCES_DIR="$DIR/instances" check 0 'in ab.sql, 1 older tag' \
  'a definition naming an older tag with the same REVOKEs passes' none none ab.sql v2 v1=ab.sql
INSTANCES_DIR="$DIR/instances" check 2 'no <tag>=<grants.sql>' \
  'a definition naming an older tag with no grants.sql is an error, not a pass' none none ab.sql v2
printf '%s\n' "image: $img:v2" >"$DIR/instances/a.yaml"
INSTANCES_DIR="$DIR/instances" check 0 'in ab.sql, 0 older tag' \
  'a definition naming only the release tag passes' none none ab.sql v2
printf '%s\n' "image: $img" >"$DIR/instances/a.yaml"
INSTANCES_DIR="$DIR/instances" check 2 'names .* with no tag' \
  'a definition naming the image with no tag is an error' none none ab.sql v2
rm "$DIR/instances/a.yaml"

check 2 'tag v1 \(running container a-1\) has no <tag>=<grants.sql>' \
  'an older tag with no grants.sql is an error, not a pass' one-old one-old ab.sql v2
check 2 'cannot read missing.sql for tag v1' 'an unreadable grants.sql for an older tag is an error' \
  one-old one-old ab.sql v2 v1=missing.sql
check 2 'image known only by id' 'an image known only by id is an error' byid byid ab.sql v2
check 2 'not an immutable tag' 'a latest tag is an error' latest latest ab.sql v2
check 2 'with no tag' 'an image with no tag is an error' untagged untagged ab.sql v2
check 2 'with no tag|not an immutable tag' 'an image by digest is an error' digest digest ab.sql v2
FAKE_FAIL=1 check 2 'failed' 'a runtime that fails is an error, not a pass' none none ab.sql v2

if [ "$failures" -ne 0 ] || [ "$ran" -ne "$expected" ]; then
  printf '%s case(s) failed, %s of %s expected case(s) ran\n' "$failures" "$ran" "$expected"
  exit 1
fi
echo 'grants-revoke-check self-test passed'
