#!/usr/bin/env bash
# Installs hadolint after checking HADOLINT_SHA256 against the exact file it
# then installs.
#
# The download lands in a fresh mktemp directory, never a fixed path, so another
# job on the same host cannot swap the file between the checksum and the
# install. HADOLINT_URL and HADOLINT_TARGET exist so selftest.sh can drive this
# with a local fixture and a scratch target, without the network or root.
set -euo pipefail

: "${HADOLINT_SHA256:?HADOLINT_SHA256 must be set}"
url="${HADOLINT_URL:-https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION:?HADOLINT_VERSION must be set}/hadolint-Linux-x86_64}"
target="${HADOLINT_TARGET:-/usr/local/bin/hadolint}"

dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/hadolint.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
curl -fsSL -o "$dir/hadolint" "$url"
printf '%s  %s\n' "$HADOLINT_SHA256" "$dir/hadolint" | sha256sum -c -

# /usr/local/bin is root-owned on the self-hosted runner, unlike the hosted
# image where the runner user already owns it.
if [ -w "$(dirname "$target")" ]; then
  install -m 0755 "$dir/hadolint" "$target"
else
  sudo install -m 0755 "$dir/hadolint" "$target"
fi
