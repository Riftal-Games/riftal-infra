#!/usr/bin/env bash
# Self-test for how images/compose.yaml provisions the dump login before the
# `backup` service starts (riftal-infra#458). It reads the compose model, then
# brings up the real `mysql`, provisioning and `backup` services under a
# throwaway project whose volumes and network are riftal_smoke_ names, with
# no published port. At most two containers run at once, and the EXIT trap
# removes every one with its volumes.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/compose.yaml"
command -v jq >/dev/null || { printf '::error::jq is required\n'; exit 1; }

work="$(mktemp -d)"
id="riftal_smoke_dumplogin_$$_$RANDOM"
dc() { docker compose -p "$id" -f "$work/stack.json" "$@"; }
cleanup() {
  if [ -f "$work/stack.json" ]; then
    dc down -v --timeout 30 >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=9
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

root_pw="Root$(printf '%s' "$id" | tr -cd 'A-Za-z0-9')"
dump_pw="Dump$(printf '%s' "$id" | tr -cd 'A-Za-z0-9')Abcdefghij"
# $1 is the RIFTAL_DB_PASSWORD_BACKUP value to render the model with.
model() {
  printf 'MYSQL_ROOT_PASSWORD=%s\nRIFTAL_DB_PASSWORD_BACKUP=%s\nINSTANCE_ID=a\nINSTANCE_B_ID=b\n' \
    "$root_pw" "$1" > "$work/env"
  docker compose -f "$COMPOSE" --env-file "$work/env" config --format json
}

printf '\n== compose.yaml provisions the dump login ahead of `backup`\n'
real="$(model "$dump_pw")"
# Services other than `backup` that run the migration runner with the dump
# login's password, so provision it.
provisioner="$(jq -r '.services | to_entries[] | select(.key != "backup")
  | select((.value.command // [] | join(" ")) | test("run-migrations\\.sh"))
  | select(.value.environment.RIFTAL_DB_PASSWORD_BACKUP != null) | .key' <<<"$real")"
check "exactly one service runs the runner with RIFTAL_DB_PASSWORD_BACKUP" \
  '[ -n "$provisioner" ] && [ "$(wc -l <<<"$provisioner")" -eq 1 ]'
check "\`backup\` starts only once that service has completed successfully" \
  '[ -n "$provisioner" ] && [ "$(jq -r --arg p "$provisioner" ".services.backup.depends_on[\$p].condition // empty" <<<"$real")" = service_completed_successfully ]'
check "\`backup\` dumps as \`backup\` with the password that service provisions" \
  '[ -n "$provisioner" ] && jq -e --arg p "$provisioner" ".services.backup.environment.MYSQL_USER == \"backup\"
    and .services.backup.environment.MYSQL_PASSWORD == .services[\$p].environment.RIFTAL_DB_PASSWORD_BACKUP" <<<"$real" >/dev/null'
check "that service connects as the admin login, which can create logins" \
  '[ -n "$provisioner" ] && jq -e --arg p "$provisioner" ".services[\$p].environment.MYSQL_PASSWORD == .services.mysql.environment.MYSQL_ROOT_PASSWORD" <<<"$real" >/dev/null'

if [ -z "$provisioner" ]; then
  printf '\n%d passed, %d failed; no provisioning service, so nothing to bring up\n' "$PASSES" "$FAILURES"
  exit 1
fi

# The throwaway stack: only these three services, no host publish, every
# volume and the network renamed, resources capped, and the CI job's label on
# everything, since compose bypasses the docker shim that stamps it. mysql:8
# declares VOLUME /var/lib/mysql, which `backup` and the provisioning service
# leave unmounted, so each of their containers would get an anonymous volume
# for the run's leftovers. A tmpfs takes its place.
label="${GITHUB_RUN_ID:+riftal.ci.job=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}}"
stack() {
  jq --arg id "$id" --arg p "$provisioner" --arg label "$label" '
    ($label | if . == "" then {} else (split("=") | {(.[0]): (.[1:] | join("="))}) end) as $l
    | .services |= with_entries(select(.key == "mysql" or .key == "backup" or .key == $p)
        | .value |= (del(.ports) + {mem_limit: "1g", cpus: 1, labels: ((.labels // {}) + $l)})
        | if .key == "mysql" then . else .value.tmpfs = ["/var/lib/mysql"] end)
    | .volumes |= with_entries(.value.name = "\($id)_\(.key)" | .value.labels = $l)
    | .networks |= with_entries(.value.name = "\($id)_\(.key)" | .value.labels = $l)
  ' > "$work/stack.json"
}

printf '\n== on a running stack, `backup` dumps only after the provisioning\n'
model "$dump_pw" | stack
dc up -d --wait mysql > "$work/mysql.out" 2>&1 || { cat "$work/mysql.out"; exit 1; }
check "before the provisioning, a dump as \`backup\` fails to log in" \
  '! dc run --rm --no-deps -T backup bash /deploy/backup.sh > "$work/early.out" 2>&1 &&
    grep -q "Access denied for user .backup." "$work/early.out"'

model "" | stack
# Compose creates the dependent container before the gate decides, so
# "never starts" is a container that is still only created.
check "an empty RIFTAL_DB_PASSWORD_BACKUP fails the provisioning and \`backup\` never starts" \
  '! dc up -d backup > "$work/empty.out" 2>&1 && grep -q "$provisioner.*didn.t complete successfully" "$work/empty.out" &&
    [ -z "$(dc ps -a --format "{{.State}}" backup | grep -vx created)" ]'
check "the provisioning says which variable is empty" \
  'dc logs --no-log-prefix "$provisioner" 2>&1 | grep -q "RIFTAL_DB_PASSWORD_BACKUP is empty"'

model "$dump_pw" | stack
dc up -d backup > "$work/up.out" 2>&1 || cat "$work/up.out"
for _ in $(seq 1 60); do
  dc logs --no-log-prefix backup > "$work/run.out" 2>&1 || true
  grep -qE "applying retention|failed, exit" "$work/run.out" && break
  sleep 2
done
dc stop -t 5 backup >/dev/null 2>&1 || true
check "the provisioning creates the login with its role" \
  'dc logs --no-log-prefix "$provisioner" 2>&1 | grep -q "provisioned login backup with role riftal_role_backup"'
check "the first scheduled run completes a set as \`backup\`" \
  'grep -q "complete at /backups/" "$work/run.out" && ! grep -qE "failed|Access denied" "$work/run.out"'

if [ "$FAILURES" -ne 0 ] || [ "$PASSES" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '\n%d passed, %d failed, expected %d to pass\n' "$PASSES" "$FAILURES" "$EXPECTED_ASSERTIONS"
  for f in early empty up run; do
    [ -f "$work/$f.out" ] && { printf -- '--- %s\n' "$f"; cat "$work/$f.out"; }
  done
  exit 1
fi
printf '\nall %d checks passed\n' "$PASSES"
