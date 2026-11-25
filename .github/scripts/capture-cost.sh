#!/usr/bin/env bash
# Sourced, not run, by deploy/bot-proofs.sh and capture-cost-selftest.sh. Reads the
# logs of ADR 015 proof 6 (listing entries across consecutive runs) and proof 8
# (what a hold costs) into the figures the harness reports and judges.

# $1 a backup.sh log, $2 a volume name. Prints "<changes> <entries> <outside> <empty>":
# the differing listings the log names, the entries those listings logged, the entries
# outside worlds/, .capture/ and server.lock, which are all a held volume lists, and the
# differing listings that logged no entry.
listing_audit() {
  awk -v v="$2" '
    function settle() { if (open) empty++; open = 0 }
    $0 ~ (": volume " v " changed during its tar$") { settle(); changes++; open = 1; next }
    $0 ~ (": volume " v " (before|after) its tar: ") {
      sub(/^.*its tar: /, "")
      entries++; open = 0
      if ($1 !~ /^(worlds|\.capture)(\/|$)/ && $1 != "server.lock") outside++
      next
    }
    { settle() }
    END { settle(); print changes + 0, entries + 0, outside + 0, empty + 0 }' "$1"
}

# $1 a backup.sh log of a held volume a. True when the run completed or failed on a
# differing listing twice, and every differing listing logged an entry, each of them
# one a held volume lists.
run_follows_listing_rule() {
  local changes entries outside empty
  read -r changes entries outside empty < <(listing_audit "$1" a)
  [ "$outside" = 0 ] && [ "$empty" = 0 ] &&
    { grep -q ': complete at ' "$1" || grep -qF 'changed during its tar twice' "$1"; }
}

# $1 a server log, $2 a request id, $3 a bot's name. True when the log shows the bot join,
# then the request held, then the bot leave, the join being the bot's last one before the
# held line and no leave coming between them.
held_inside_session() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | awk -v id="$2" -v bot="$3" '
    $0 ~ (" " bot " joined the game") && !held { joined = NR }
    $0 ~ (" " bot " left the game") && !held { joined = 0 }
    $0 ~ ("capture " id " held: ") { held = NR }
    $0 ~ (" " bot " left the game") && held && !left { left = NR }
    END { exit !(joined && held && left && joined < held) }'
}

# $1 1 when the run's bots passed, $2 the backup's exit status, $3 1 when its hold fell inside
# p3a's session, $4 1 when its log follows the listing rule, $5 the attempt, $6 the attempts
# allowed. True when the only thing wrong is a hold outside the session and an attempt
# remains, so the run is run again; a run that failed any other way is never run again.
p6_rerun() {
  [ "$1" = 1 ] && [ "$2" = 0 ] && [ "$3" = 0 ] && [ "$4" = 1 ] && [ "$5" -lt "$6" ]
}

# $1 a server log, $2 a request id. Prints "<files> <tick ms> <hold ms> <loaded chunks>
# <total MB>": the player files staged, the held tick's duration, the hold from the
# start of that tick to the release, and the last `status` sample between the held
# line and the release. A sample missing from that window prints as -.
cost_figures() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | awk -v id="$2" '
    function ms(stamp, p) { split(substr(stamp, 2, 12), p, /[:.]/); return ((p[1] * 60 + p[2]) * 60 + p[3]) * 1000 + p[4] }
    $0 ~ ("capture " id " held: ") {
      split($0, a, / held: | player files staged in |ms, lease/)
      files = a[2]; tick = a[3]; held = ms($1); chunks = ""; mem = ""
    }
    held != "" && /World "[^"]*": [0-9,]+ loaded chunks/ { c = $0; sub(/^.*World "[^"]*": /, "", c); sub(/ loaded chunks.*/, "", c); gsub(/,/, "", c); chunks = c }
    held != "" && /Total memory: [0-9,.]+ MB/ { m = $0; sub(/^.*Total memory: /, "", m); sub(/ MB.*/, "", m); gsub(/,/, "", m); mem = m }
    held != "" && $0 ~ ("capture " id " released") {
      printf "%s %s %.1f %s %s\n", files, tick, (ms($1) - held + 86400000) % 86400000 + tick, (chunks == "" ? "-" : chunks), (mem == "" ? "-" : mem)
      exit
    }'
}
