#!/usr/bin/env bash
# Proves pull-mysql.sh can fail. Its only real input is a compose file that
# passes and a pull that succeeds, so without these cases a script that never
# pulled, or ignored a failed pull, would look the same. A stub docker stands in
# for the engine, so this pulls nothing and starts no container.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
ran=0
expected=7

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  pull) [ "${STUB_PULL:-ok}" = ok ] || { printf 'pull refused\n' >&2; exit 1; } ;;
  image) printf 'mysql@sha256:stub\n' ;;
esac
EOF
chmod 0755 "$work/bin/docker"

compose() {
  local i=0 name
  printf 'services:\n'
  for name in "$@"; do
    i=$((i + 1))
    printf '  s%d:\n    image: %s\n' "$i" "$name"
  done
}

# Each case names the error it must print and whether a pull must be attempted,
# so a refusal for the wrong reason, or a pass that never pulled, does not count.
expect() {
  local label="$1" status="$2" pull="$3" want="$4" file="$5" out rc
  ran=$((ran + 1))
  : >"$work/log"
  out="$(PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_PULL="$pull" \
    bash "$dir/pull-mysql.sh" "$file" 2>&1)"
  rc=$?
  if [[ "$out" == *"$want"* ]] &&
    { { [ "$status" = pass ] && [ "$rc" -eq 0 ] && grep -qx 'pull mysql:8' "$work/log"; } ||
      { [ "$status" = fail ] && [ "$rc" -ne 0 ]; }; }; then
    printf '  ok    %s, %s\n' "$label" "$status"
  else
    printf "::error::%s: want %s with '%s', got exit %s with '%s'\n" "$label" "$status" "$want" "$rc" "$out"
    failures=$((failures + 1))
  fi
}

compose mysql:8 local-pocketmine-mp mysql:8 >"$work/good.yaml"
expect "every mysql service runs mysql:8" pass ok 'mysql@sha256:stub' "$work/good.yaml"
expect "the pull fails" fail refuse 'docker pull mysql:8 failed' "$work/good.yaml"

compose mysql:8 mysql:8.4 >"$work/drift.yaml"
expect "one service drifts to mysql:8.4" fail ok 'runs mysql:8.4 but the self-tests run mysql:8' "$work/drift.yaml"

printf 'services:\n  db:\n    image: "mysql@sha256:abc"\n' >"$work/digest.yaml"
expect "a digest pin is not mysql:8" fail ok 'runs mysql@sha256:abc but' "$work/digest.yaml"

compose local-pocketmine-mp >"$work/none.yaml"
expect "no mysql service" fail ok 'names no mysql image' "$work/none.yaml"

expect "missing compose file" fail ok 'not found' "$work/absent.yaml"

expect "the real compose file" pass ok 'mysql@sha256:stub' "$dir/../../images/compose.yaml"

if [ "$ran" -ne "$expected" ]; then
  printf '::error::ran %d of %d cases\n' "$ran" "$expected"
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  printf '::error::%d of %d cases failed\n' "$failures" "$ran"
  exit 1
fi
printf 'all %d cases behaved\n' "$ran"
