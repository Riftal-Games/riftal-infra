#!/usr/bin/env bash
# Puts a `docker` shim first on PATH for the rest of the job. The shim stamps
# every container, network and `volume create` this job runs with a label
# naming the job run, so ci-container-sweep.sh can remove exactly those once the
# job ends, however it ends (riftal-infra#509). A volume that `run -v name:/path`
# creates on first use carries no label, so a self-test that needs a named
# volume creates it explicitly first (riftal-infra#685).
#
# A cancelled run kills a self-test before its EXIT trap fires, and its mysql
# or server container runs on for hours. Name prefixes alone cannot scope the
# sweep: the CI runners share one docker engine with each other and with every
# lane, so a riftal_smoke_ container may belong to a concurrent job. A label set
# from GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT cannot, and stamping it here covers
# every self-test without each script having to remember it.
set -euo pipefail

dir="${RUNNER_TEMP:?}/riftal-docker-label"

# A second run in the same job finds this shim first on PATH. Wrapping it would
# make the shim exec itself forever, so the search skips the shim's directory.
real=
IFS=: read -ra entries <<<"$PATH"
for entry in "${entries[@]}"; do
  entry="${entry:-.}"
  [ "$entry" = "$dir" ] && continue
  # container-limits: exempt tests a path and runs nothing
  if [ -f "$entry/docker" ] && [ -x "$entry/docker" ]; then
    # container-limits: exempt records the binary the shim wraps and runs nothing
    real="$entry/docker"
    break
  fi
done
if [ -z "$real" ]; then
  # container-limits: exempt prints an error and runs nothing
  printf '::error::no docker on PATH outside %s\n' "$dir" >&2
  exit 1
fi
mkdir -p "$dir"

# container-limits: exempt writes the shim, whose own runs keep the limits their callers pass
cat >"$dir/docker" <<EOF
#!/bin/sh
real='$real'
EOF
# container-limits: exempt writes the shim, whose own runs keep the limits their callers pass
cat >>"$dir/docker" <<'EOF'
if [ -z "${GITHUB_RUN_ID:-}" ] || [ -z "${GITHUB_RUN_ATTEMPT:-}" ]; then
  exec "$real" "$@"
fi
label="riftal.ci.job=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB:-job}"
case "$1 ${2:-}" in
  "container run"|"container create"|"network create"|"volume create")
    group="$1" verb="$2"
    shift 2
    exec "$real" "$group" "$verb" --label "$label" "$@"
    ;;
esac
case "$1" in
  run|create)
    verb="$1"
    shift
    exec "$real" "$verb" --label "$label" "$@"
    ;;
esac
exec "$real" "$@"
EOF
# container-limits: exempt makes the shim executable and runs nothing
chmod 0755 "$dir/docker"

printf '%s\n' "$dir" >>"${GITHUB_PATH:?}"
# container-limits: exempt prints the shim's path and runs nothing
printf 'docker shim at %s wraps %s\n' "$dir/docker" "$real"
