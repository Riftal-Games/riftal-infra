#!/usr/bin/env bash
# Self-test for grants-revoke-check.sh. Uses a fake container runtime and
# fixture files and starts no container. Each rule of the reader has a file it
# must refuse as the new file and as an older tag's file, and a file it must
# pass, so a check that refuses everything fails here as surely as one that
# refuses nothing. GRANTS_REVOKE_CHECK names another copy of the script to test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${GRANTS_REVOKE_CHECK:-$SCRIPT_DIR/grants-revoke-check.sh}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
img='registry.example/riftal/pocketmine-mp'
mkdir -p "$DIR/instances" "$DIR/empty" "$DIR/bin"
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
# FAKE_FIND is `fail` for a scan that fails, else the one path the scan prints.
cat >"$DIR/bin/find" <<'EOF'
#!/usr/bin/env bash
[ "$FAKE_FIND" != fail ] || exit 1
echo "$FAKE_FIND"
EOF
chmod +x "$DIR/bin/find"
grants() { local name="$1"; shift; printf '%s\n' "$@" >"$DIR/$name"; }
revoke_a='REVOKE IF EXISTS UPDATE (balance_minor_units) ON balances FROM riftal_role_economy;'
revoke_b='REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;'
grant_a='GRANT SELECT ON accounts TO riftal_role_mines;'
grants none.sql '-- a comment naming REVOKE; and nothing else' "$grant_a"
grants only-comments.sql '-- nothing' '--' '-- REVOKE IF EXISTS x FROM y;'
grants a.sql "$revoke_a"
grants ab.sql "$revoke_a" "$revoke_b"
grants b.sql "$revoke_b"
grants spaced.sql '-- REVOKE in a comment;' 'REVOKE IF EXISTS' '   UPDATE (balance_minor_units)' '  ON balances  FROM riftal_role_economy; -- trailing'
grants multi.sql 'REVOKE IF EXISTS UPDATE (balance_minor_units) -- note' '  ON balances' '  FROM riftal_role_economy;'
sed 's/$/\r/' "$DIR/multi.sql" >"$DIR/multi-crlf.sql"
printf '%s --\r\n' "$revoke_b" >"$DIR/dash-cr.sql"
grants commented.sql "-- it's \"a\" \`b\` # c /* d */ \\ e" "$revoke_b"
grants lower.sql 'revoke if exists riftal_role_accounts from riftal_role_mines;'
grants word.sql 'GRANT SELECT ON revokes TO riftal_role_mines;'
grants real.sql 'CREATE ROLE IF NOT EXISTS riftal_role_economy;' 'GRANT SELECT, INSERT, UPDATE (id, username)' '  ON accounts TO riftal_role_accounts;' \
  'REVOKE IF EXISTS riftal_role_accounts FROM' '  riftal_role_mines, riftal_role_riots;' "$revoke_a"

# Each file below must exit 2 as the new file and as an older tag's file.
grants hash.sql '# GRANT SELECT ON accounts TO riftal_role_mines; REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines;' "$grant_a"
grants oneblock.sql '/* hold until riftal-game#N; REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines; */' "$grant_a"
grants midblock.sql 'REVOKE /* ; */ riftal_role_accounts FROM riftal_role_mines;'
grants multiblock.sql '/* old note' '-- still a note */' "$revoke_b"
grants quit.sql "$grant_a" 'quit;' "$revoke_b"
grants unterminated.sql "$grant_a" 'quit'
grants drop.sql 'DROP ROLE IF EXISTS riftal_role_economy;' 'SET DEFAULT ROLE NONE TO riftal_economy;'
grants select.sql "$grant_a" 'SELECT 1;' "$revoke_b"
grants revokes.sql 'REVOKES IF EXISTS x FROM y;'
grants squote.sql "SELECT '--'; $revoke_b"
grants dquote.sql "SELECT \"-- x\"; $revoke_b"
grants backtick.sql "SELECT \`-- x\`; $revoke_b"
grants dashes.sql "GRANT SELECT ON t TO r --1; $revoke_b"
grants backslash.sql "$grant_a" "$revoke_b \\g"
printf -- '-- ok\n%s\n-- caf\351\n' "$revoke_b" >"$DIR/latin1.sql"
printf -- '-- caf\303\251\n%s\n' "$revoke_b" >"$DIR/utf8.sql"
printf '%s\n\0\n' "$grant_a" >"$DIR/nul.sql"
printf '%s\f\n%s\n' "$grant_a" "$revoke_b" >"$DIR/formfeed.sql"
printf '%s\177\n%s\n' "$grant_a" "$revoke_b" >"$DIR/del.sql"
rejects=(
  'hash.sql:1: a character outside'
  'oneblock.sql:1: a character outside'
  'midblock.sql:1: a character outside'
  'multiblock.sql:1: a character outside'
  'quit.sql:2: a statement that does not begin with CREATE ROLE, GRANT or REVOKE'
  'unterminated.sql:2: a statement that does not begin'
  'drop.sql:1: a statement that does not begin'
  'select.sql:2: a statement that does not begin'
  'revokes.sql:1: a statement that does not begin'
  'squote.sql:1: a character outside'
  'dquote.sql:1: a character outside'
  'backtick.sql:1: a character outside'
  'dashes.sql:1: a -- not followed by whitespace'
  'backslash.sql:2: a character outside'
  'latin1.sql:3: a byte other than printable ASCII'
  'utf8.sql:1: a byte other than printable ASCII'
  'nul.sql:2: a byte other than printable ASCII'
  'formfeed.sql:1: a byte other than printable ASCII'
  'del.sql:1: a byte other than printable ASCII'
)

# containers <file> <name> <image> ...
containers() { local file="$1"; shift; printf '%s\t%s\n' "$@" >"$DIR/$file"; }
: >"$DIR/none"
containers one-old a-1 "$img:v1" other mysql:8
containers one-new a-1 "$img:v2" other mysql:8
containers byid a-1 0123456789ab
containers latest a-1 "$img:latest"
containers untagged a-1 "$img"
containers digest a-1 "$img@sha256:0123456789abcdef"

failures=0
ran=0
expected=71
# check <exit> <regex some output line must match> <case> <running> <all> <arg>...
check() {
  local want="$1" match="$2" case="$3" run="$4" all="$5" out got
  shift 5
  ran=$((ran + 1))
  set +e
  out="$(cd "$DIR" && LC_ALL=C.UTF-8 INSTANCE_IMAGE="$img" CONTAINER_RUNTIME="bash $DIR/runtime" \
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

# old <exit> <regex> <case> <new file> [<older tag's file>]: one container on tag v1.
old() { check "$1" "$2" "$3" one-old one-old "$4" v2 ${5:+"v1=$5"}; }

check 0 '^GRANTS REVOKE OK: 1 REVOKE statement\(s\) in b.sql, 0 older tag\(s\) checked, tags in use: v2, runtime: bash .*/runtime$' 'only the release tag passes' one-new one-new b.sql v2
check 0 '^GRANTS REVOKE OK: 1 REVOKE statement\(s\) in a.sql, 0 older tag' 'no container and no definition passes' none none a.sql v2
old 0 'in none.sql, 1 older tag\(s\) checked, tags in use: v1, runtime' 'a new grants.sql with no REVOKE passes against an older tag' none.sql a.sql
old 0 'in ab.sql, 1 older tag' 'a REVOKE the older tag already carries passes' ab.sql ab.sql
old 0 'in spaced.sql, 1 older tag' 'whitespace, comments and line breaks do not make a REVOKE new' spaced.sql a.sql
old 0 'in multi-crlf.sql, 1 older tag' 'a multi-line REVOKE in CRLF equals the same in LF' multi-crlf.sql multi.sql
old 0 'in multi.sql, 1 older tag' 'a multi-line REVOKE in LF equals the same in CRLF' multi.sql multi-crlf.sql
old 0 'in dash-cr.sql, 1 older tag' 'a -- followed by CR ends the statement text' dash-cr.sql b.sql
old 0 'in commented.sql, 1 older tag' 'a -- comment may hold quotes, #, /* and a backslash' commented.sql b.sql
old 0 'in a.sql, 1 older tag' 'a REVOKE the new file dropped is not a hazard' a.sql ab.sql
old 0 'OK: 0 REVOKE statement\(s\) in word.sql' 'a word merely containing revoke is not a REVOKE' word.sql none.sql
old 0 'OK: 2 REVOKE statement\(s\) in real.sql, 1 older tag' 'a file in the real dialect against itself passes' real.sql real.sql
old 1 'REFUSED: "REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines, riftal_role_riots" is new' 'the real dialect against only comments refuses REVOKE one' real.sql only-comments.sql
old 1 'REFUSED: "REVOKE IF EXISTS UPDATE \(balance_minor_units\) ON balances FROM riftal_role_economy" is new' 'the real dialect against only comments refuses REVOKE two' real.sql only-comments.sql
old 1 'REFUSED: "REVOKE IF EXISTS riftal_role_accounts FROM riftal_role_mines" is new against tag v1 \(running container a-1\)$' 'a REVOKE new against a running container refuses' ab.sql a.sql
check 1 'is new against tag v1 \(stopped container a-1\)$' 'a REVOKE new against a stopped container refuses' none one-old ab.sql v2 v1=a.sql
old 1 'REFUSED: "REVOKE IF EXISTS UPDATE \(balance_minor_units\) ON balances FROM riftal_role_economy" is new' 'a multi-line REVOKE is one statement and refuses' spaced.sql none.sql
old 1 '^GRANTS REVOKE REFUSED: "revoke if exists riftal_role_accounts' 'a lowercase revoke is seen and refuses' lower.sql none.sql

for r in "${rejects[@]}"; do
  f="${r%%:*}"
  old 2 "$r" "$f as the new file is an error, not a pass" "$f" none.sql
  old 2 "$r" "$f as an older tag's file is an error, not a pass" b.sql "$f"
done
# def <image reference> <exit> <regex> <case> <new file> [<older tag's file>]: no container, one definition.
def() {
  printf '%s\n' "image: $1" >"$DIR/instances/a.yaml"
  INSTANCES_DIR="$DIR/instances" check "$2" "$3" "$4" none none "$5" v2 ${6:+"v1=$6"}
}
def "$img:v1" 1 'is new against tag v1 \(instance definition .*/instances/a.yaml:1\)$' 'a REVOKE new against an instance definition refuses' ab.sql a.sql
def "$img:v1" 0 'in ab.sql, 1 older tag' 'a definition naming an older tag with the same REVOKEs passes' ab.sql ab.sql
def "$img:v1" 2 'no <tag>=<grants.sql>' 'a definition naming an older tag with no grants.sql is an error, not a pass' ab.sql
def "$img:v2" 0 'in ab.sql, 0 older tag' 'a definition naming only the release tag passes' ab.sql
def "$img" 2 'names .* with no tag' 'a definition naming the image with no tag is an error' ab.sql
rm "$DIR/instances/a.yaml"
PATH="$DIR/bin:$PATH" FAKE_FIND="$DIR/instances/gone.yaml" check 2 'cannot read instance definition .*/gone.yaml' 'an unreadable instance definition is an error, not a pass' none none ab.sql v2
PATH="$DIR/bin:$PATH" FAKE_FIND=fail check 2 'cannot scan instance definitions' 'a failed definition scan is an error, not a pass' none none ab.sql v2
old 2 'tag v1 \(running container a-1\) has no <tag>=<grants.sql>' 'an older tag with no grants.sql is an error, not a pass' ab.sql
old 2 'cannot read missing.sql for tag v1' 'an unreadable grants.sql for an older tag is an error' ab.sql missing.sql
old 2 'cannot read missing.sql' 'an unreadable new grants.sql is an error' missing.sql ab.sql
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
