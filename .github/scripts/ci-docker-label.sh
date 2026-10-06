#!/usr/bin/env bash
# Puts a `docker` shim first on PATH for the rest of the job. The shim stamps
# every container and network this job creates with a label naming the job run,
# so ci-container-sweep.sh can remove exactly those once the job ends, however
# it ends (riftal-infra#509).
#
# A cancelled run kills a self-test before its EXIT trap fires, and its mysql
# or server container runs on for hours. Name prefixes alone cannot scope the
# sweep: the CI runners share one docker engine with each other and with every
# lane, so a riftal_smoke_ container may belong to a concurrent job. A label set
# from GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT cannot, and stamping it here covers
# every self-test without each script having to remember it.
set -euo pipefail

real="$(command -v docker)"
dir="${RUNNER_TEMP:?}/riftal-docker-label"
mkdir -p "$dir"

cat >"$dir/docker" <<EOF
#!/bin/sh
real='$real'
EOF
cat >>"$dir/docker" <<'EOF'
if [ -z "${GITHUB_RUN_ID:-}" ] || [ -z "${GITHUB_RUN_ATTEMPT:-}" ]; then
  exec "$real" "$@"
fi
label="riftal.ci.job=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB:-job}"
case "$1 ${2:-}" in
  "container run"|"container create"|"network create")
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
chmod 0755 "$dir/docker"

printf '%s\n' "$dir" >>"${GITHUB_PATH:?}"
printf 'docker shim at %s wraps %s\n' "$dir/docker" "$real"
