#!/usr/bin/env bash
# Installs hadolint after checking HADOLINT_SHA256 against the exact file it
# then installs, and points this job's later steps at that file.
#
# Everything lands under RUNNER_TEMP, a directory no other job writes in normal
# operation. The download goes to a fresh mktemp directory and the binary to
# RUNNER_TEMP/bin, never a host-wide path like /usr/local/bin, where a
# concurrent job's install on the same self-hosted host could replace the
# checked binary before the scans run it. Every runner on that host is the same
# `runner` user, so this keeps jobs from clashing by accident; it does not stop
# a hostile job.
# The scans find it through HADOLINT in GITHUB_ENV, not a PATH lookup that a
# shared directory could win. HADOLINT_URL exists so selftest.sh can drive this
# with a local fixture, without the network.
set -euo pipefail

: "${HADOLINT_SHA256:?HADOLINT_SHA256 must be set}"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set, hadolint installs only into this job}"
: "${GITHUB_ENV:?GITHUB_ENV must be set, or the scans cannot find this install}"
url="${HADOLINT_URL:-https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION:?HADOLINT_VERSION must be set}/hadolint-Linux-x86_64}"
target="$RUNNER_TEMP/bin/hadolint"

dir="$(mktemp -d "$RUNNER_TEMP/hadolint.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
curl -fsSL -o "$dir/hadolint" "$url"
printf '%s  %s\n' "$HADOLINT_SHA256" "$dir/hadolint" | sha256sum -c -

mkdir -p "$RUNNER_TEMP/bin"
install -m 0755 "$dir/hadolint" "$target"
"$target" --version
printf 'HADOLINT=%s\n' "$target" >> "$GITHUB_ENV"
