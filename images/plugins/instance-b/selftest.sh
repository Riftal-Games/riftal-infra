#!/usr/bin/env bash
# Self-test for start.sh, instance-b's start script (riftal-infra#348, #345). Runs
# it with /plugins, /data and /opt/pocketmine moved under a scratch root and
# php stubbed to record its arguments and the roster it was handed, so
# nothing boots. Needs neither Docker nor a built phar.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY="$DIR/../instance-only"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

FAILURES=0
PASSES=0
EXPECTED_ASSERTIONS=8
pass() { printf '  ok    %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '::error::%s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# $1 the start script to run, $2 the phars built in instance-only, the rest
# environment assignments. The shared /plugins holds contracts.phar, as on the
# real stack, and instance-only every tracked config and start-instance.sh.
root="$work/boot"
# Every path under the shared /plugins and the content hash of each file, so
# an in-place overwrite shows as well as an added or removed name.
shared_state() { (cd "$root/plugins" && { find . ! -type f; find . -type f -exec sha256sum {} +; } | sort); }
boot() {
  local script="$1" phars="$2" phar
  shift 2
  rm -rf "$root"
  mkdir -p "$root/plugins/instance-only" "$root/data" "$root/pm" "$root/bin"
  : > "$root/plugins/contracts.phar"
  if [ -n "${source_folder:-}" ]; then
    mkdir -p "$root/plugins/$source_folder/src"
    : > "$root/plugins/$source_folder/plugin.yml"
  fi
  cp "$ONLY/RiftalRanks.config.yml" "$ONLY/RiftalEconomy.config.yml" \
    "$ONLY/render-config.sh" "$ONLY/RiftalMines.config.yml.template" "$root/plugins/instance-only/"
  for phar in $phars; do : > "$root/plugins/instance-only/$phar"; done
  local rewrite=(-e "s#/plugins#$root/plugins#g; s#/data#$root/data#g"
    -e "s#/opt/pocketmine#$root/pm#g; s#-user pocketmine#-user $(id -u)#g")
  sed "${rewrite[@]}" "$ONLY/start-instance.sh" > "$root/plugins/instance-only/start-instance.sh"
  sed "${rewrite[@]}" "$script" > "$root/start.sh"
  cat > "$root/bin/php" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$root/args"
for a; do case "\$a" in --plugins=*) ls "\${a#--plugins=}" > "$root/roster" ;; esac; done
EOF
  chmod +x "$root/bin/php"
  shared_state > "$root/before"
  env -i HOME="$work" PATH="$root/bin:$PATH" TMPDIR="$root" MYSQL_ROOT_PASSWORD=x "$@" \
    bash "$root/start.sh" > "$root/out" 2>&1 < /dev/null && [ -s "$root/args" ]
}
all="RiftalMines.phar RiftalRanks.phar RiftalEconomy.phar RiftalPlots.phar"
economy_on_volume="$root/data/plugin_data/RiftalEconomy/config.yml"
# The logins instance-b is given.
logins=(RIFTAL_DB_PASSWORD_ECONOMY=pw RIFTAL_DB_PASSWORD_PLOTS=pw)
# Holds when the last boot handed php contracts.phar, RiftalEconomy.phar and
# RiftalPlots.phar alone, with the tracked economy config on the volume and no
# other plugin's.
economy_and_plots_only() {
  [ "$(cat "$root/roster")" = "$(printf '%s\n' RiftalEconomy.phar RiftalPlots.phar contracts.phar)" ] &&
    cmp -s "$ONLY/RiftalEconomy.config.yml" "$economy_on_volume" &&
    [ "$(ls "$root/data/plugin_data")" = RiftalEconomy ]
}

printf '\n== instance-b loads RiftalEconomy and RiftalPlots beside the shared plugins and nothing else from instance-only\n'
check "with every instance-only phar built, the roster is the shared plugins, RiftalEconomy and RiftalPlots, the economy config on the volume" \
  'boot "$DIR/start.sh" "$all" "${logins[@]}" && economy_and_plots_only'
sed 's#cp "\$only/start-instance.sh" #cp "$only"/* #' "$DIR/start.sh" > "$work/leaky.sh"
check "a start script that stages all of instance-only is caught" \
  '! cmp -s "$DIR/start.sh" "$work/leaky.sh" &&
    boot "$work/leaky.sh" "$all" "${logins[@]}" RIFTAL_DB_PASSWORD_RANKS=pw RIFTAL_DB_PASSWORD_MINES=pw && ! economy_and_plots_only'
check "with RiftalEconomy.phar built, an unset RIFTAL_DB_PASSWORD_ECONOMY stops the boot before php, naming it" \
  '! boot "$DIR/start.sh" "$all" RIFTAL_DB_PASSWORD_PLOTS=pw && [ ! -e "$root/args" ] && grep -q "RIFTAL_DB_PASSWORD_ECONOMY is not set" "$root/out"'
check "with RiftalPlots.phar built, an unset RIFTAL_DB_PASSWORD_PLOTS stops the boot before php, naming it" \
  '! boot "$DIR/start.sh" "$all" RIFTAL_DB_PASSWORD_ECONOMY=pw && [ ! -e "$root/args" ] && grep -q "RIFTAL_DB_PASSWORD_PLOTS is not set" "$root/out"'
check "without RiftalEconomy.phar or RiftalPlots.phar, the roster is the shared plugins alone and no password is needed" \
  'boot "$DIR/start.sh" "RiftalMines.phar RiftalRanks.phar" && [ "$(cat "$root/roster")" = contracts.phar ] &&
    [ ! -e "$root/data/plugin_data" ]'
check "nothing is written into the shared /plugins" \
  'boot "$DIR/start.sh" "$all" "${logins[@]}" && shared_state | cmp -s - "$root/before"'
check "a source folder at the top of the shared /plugins joins the roster, instance-only does not" \
  'source_folder=Dev boot "$DIR/start.sh" "$all" "${logins[@]}" &&
    [ "$(cat "$root/roster")" = "$(printf "%s\n" Dev RiftalEconomy.phar RiftalPlots.phar contracts.phar)" ]'
check "the roster php gets is made outside /plugins" \
  'boot "$DIR/start.sh" "$all" "${logins[@]}" &&
    roster="$(sed -n "s/^--plugins=//p" "$root/args")" && [[ "$roster" == "$root"/* ]] &&
    [[ "$roster" != "$root/plugins"* ]]'

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
