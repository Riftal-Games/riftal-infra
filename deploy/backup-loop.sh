#!/usr/bin/env bash
# Scheduling wrapper around backup.sh: run once, then every
# BACKUP_INTERVAL_SECONDS, forever. A loop inside the container rather than
# host cron, because CLAUDE.md's containers-everywhere rule leaves no host to
# put a crontab on.
#
# A failed run is logged and the loop keeps going rather than exiting, so one
# bad run does not turn into no backups at all until someone notices the
# container died.
set -euo pipefail

INTERVAL="${BACKUP_INTERVAL_SECONDS:-21600}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while true; do
  if ! bash "$SCRIPT_DIR/backup.sh"; then
    echo "backup-loop: run at $(date -u +%Y-%m-%dT%H:%M:%SZ) failed, see the error above" >&2
  fi
  sleep "$INTERVAL"
done
