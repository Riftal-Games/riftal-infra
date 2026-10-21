#!/bin/sh
# Runs first in every instance's command, then execs the rest of it. The
# instances restart on-failure with no cap (riftal-infra#355), and exit codes
# cannot tell a bad deploy from a crash: under tini both exit 137. Uptime can.
# Every boot failure exits within seconds, and core throttles a runtime crash
# until the server has been up 120 s. So three starts each under 120 s apart
# are a boot loop, and this parks the container Up instead of starting
# PocketMine again. Parked, it never exits, so on-failure never restarts it,
# and the healthcheck reads it as unhealthy.
#
# The start times live in the container's writable layer, never on /data or
# /plugins, so a new container starts with none. A manual restart comes long
# after the last start and boots normally. RIFTAL_BOOT_STARTS moves the file
# for selftest.sh only.
#
# POSIX sh, so the self-test can run it under a real restart policy in
# php:8.3-cli-alpine, which has no bash.
set -eu

starts="${RIFTAL_BOOT_STARTS:-/tmp/riftal-boot-starts}"
now="$(date +%s)"
{
	tail -n 2 "$starts" 2>/dev/null || true
	echo "$now"
} > "$starts.next"
mv "$starts.next" "$starts"

if [ "$(wc -l < "$starts")" -eq 3 ]; then
	first="$(sed -n 1p "$starts")"
	second="$(sed -n 2p "$starts")"
	if [ $((second - first)) -lt 120 ] && [ $((now - second)) -lt 120 ]; then
		echo "RIFTAL BOOT LOOP: 3 starts each under 120 s apart, PocketMine not started, container parked"
		exec sleep infinity
	fi
fi

exec "$@"
