#!/usr/bin/env bash
# Proves wslc-drift.sh can fail: the real doc must pass, scratch copies of it
# with one flag drifted, or of compose with its healthcheck changed, must each
# fail naming the differing line, and a doc that only writes a health duration
# in another form must still pass.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$DIR/../../docs/dev-stack-two-instance.md"
CHECK="$DIR/wslc-drift.sh"
ROOT_COMPOSE="$DIR/../../images/compose.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=21
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# $1 sed script applied to a scratch copy of the doc, $2 a line the check's
# output must hold. Passes when the check fails and prints that line.
caught() {
  sed "$1" "$DOC" > "$work/doc.md"
  if cmp -s "$DOC" "$work/doc.md"; then
    printf '  the sed script %s changed nothing\n' "$1"
    return 1
  fi
  ! bash "$CHECK" "$work/doc.md" > "$work/out" 2>&1 && grep -qxF -- "$2" "$work/out"
}

check "the doc as committed matches compose" 'bash "$CHECK" "$DOC" > "$work/out" 2>&1'
check "a drifted POCKETMINE_ARGS is caught" \
  'caught "s/--motd=riftal-dev-b /--motd=riftal-dev /" "< -e POCKETMINE_ARGS=--level-name=plots_b --level-type=flat --xbox-auth=false --motd=riftal-dev --riftal-dev-bots=on --auto-report.enabled=0"'
check "an -e compose does not set is caught" \
  'caught "s/-e \"RIFTAL_DEV_ENV=1\"/-e \"RIFTAL_DEV_ENV=0\"/" "< -e RIFTAL_DEV_ENV=0"'
check "a missing -e is caught" \
  'caught "/RIFTAL_DB_PASSWORD_ACCOUNTS=/d" "> -e RIFTAL_DB_PASSWORD_ACCOUNTS=\${RIFTAL_DB_PASSWORD_ACCOUNTS}"'
check "a -v on the wrong volume is caught" \
  'caught "s/-v riftal-world-b:/-v riftal-world:/" "< -v riftal-world:/data"'
check "a -v that lost :ro is caught" \
  'caught "s#/etc/riftal/world_index.json:ro#/etc/riftal/world_index.json#" "< -v \$INFRA/designer/world_index.json:/etc/riftal/world_index.json"'
check "a -p on the wrong host port is caught" \
  'caught "s/:19133:19132/:19132:19132/" "< -p \${INSTANCE_B_BIND:-127.0.0.1}:19132:19132/udp"'
check "a -p published as TCP is caught" \
  'caught "s#:19132/udp#:19132#" "< -p \${INSTANCE_B_BIND:-127.0.0.1}:19133:19132/tcp"'
check "a drifted --memory is caught" 'caught "s/--memory 2G/--memory 4G/" "< --memory 4G"'
check "a dropped -i, without which stop on stdin cannot reach the server, is caught" \
  'caught "s/wslc run -d -i /wslc run -d /" "> -i"'
check "a command chain missing a step is caught" \
  'caught "s#bash /plugins/require-custody.sh ##" "< command [\"bash\",\"/plugins/restart/boot-gate.sh\",\"bash\",\"/plugins/deliver-world-index.sh\",\"bash\",\"/plugins/require-accounts.sh\",\"bash\",\"/plugins/instance-b/start.sh\"]"'
check "a flag the check does not know is caught" \
  'caught "s/--network riftal-dev/--network riftal-dev --privileged/" "< unknown --privileged"'
check "a doc that drops the healthcheck is caught" \
  'caught "/--health-/d" "> --health-cmd php /plugins/restart/raknet-ping.php"'
check "a drifted --health-retries is caught" \
  'caught "s/--health-retries 3/--health-retries 5/" "< --health-retries 5"'
check "a drifted --health-interval is caught" \
  'caught "s/--health-interval 30s/--health-interval 20s/" "< --health-interval 20s"'
check "a drifted --health-timeout is caught" \
  'caught "s/--health-timeout 10s/--health-timeout 5s/" "< --health-timeout 5s"'
check "a drifted --health-start-period is caught" \
  'caught "s/--health-start-period 180s/--health-start-period 120s/" "< --health-start-period 120s"'
check "a duration in a form neither side prints still matches" \
  'sed "s/--health-start-period 180s/--health-start-period 2m60s/" "$DOC" > "$work/doc.md" &&
    ! cmp -s "$DOC" "$work/doc.md" && bash "$CHECK" "$work/doc.md" > "$work/out" 2>&1'
check "a healthcheck the compose service lacks is caught" \
  'sed "/healthcheck: \*raknet-health/d" "$ROOT_COMPOSE" > "$work/compose.yaml" &&
    ! WSLC_DRIFT_COMPOSE="$work/compose.yaml" WSLC_DRIFT_PROJECT_DIR="$(dirname "$ROOT_COMPOSE")" \
      bash "$CHECK" "$DOC" > "$work/out" 2>&1 &&
    grep -qxF -- "< --health-cmd php /plugins/restart/raknet-ping.php" "$work/out"'
check "a compose start_period that differs is caught after normalising" \
  'sed "s/start_period: 180s/start_period: 2m/" "$ROOT_COMPOSE" > "$work/compose.yaml" &&
    ! WSLC_DRIFT_COMPOSE="$work/compose.yaml" WSLC_DRIFT_PROJECT_DIR="$(dirname "$ROOT_COMPOSE")" \
      bash "$CHECK" "$DOC" > "$work/out" 2>&1 &&
    grep -qxF -- "> --health-start-period 120s" "$work/out"'
check "a doc with no wslc run is caught" \
  'printf "nothing here\n" > "$work/none.md" && ! bash "$CHECK" "$work/none.md" > "$work/out" 2>&1 &&
    grep -q "no wslc run command found" "$work/out"'

printf '\n'
ran=$((PASSES + FAILURES))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '%s of %s assertions ran, so one did not run and cannot have passed\n' "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  printf '%s self-test assertion(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all %s assertions passed\n' "$PASSES"
