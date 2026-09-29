#!/usr/bin/env bash
# Self-test for RiftalCapture.php's request parsing, lease and staged copy
# (riftal-infra#534, ADR 015 items 1, 2 and 8).
#
# CaptureRequest, Lease and Stage use no PocketMine type, so this loads the
# real, shipped plugin file, catches the expected "PluginBase not found" Error
# once execution reaches Main, and drives the three classes directly inside
# php:8.3-cli-alpine, the image the "Lint PHP plugins" CI step uses. Each case
# prints one "ok <what>" or "FAIL <what>" line; the count below catches a case
# that never ran.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SCRIPT_DIR/RiftalCapture.php"
EXPECTED_ASSERTIONS=13

output="$(docker run --rm -i -v "$PLUGIN:/plugin.php:ro" php:8.3-cli-alpine php <<'PHP' 2>&1
<?php
try{
	require "/plugin.php";
}catch(\Error $e){
}
use riftal\capture\CaptureRequest;
use riftal\capture\Lease;
use riftal\capture\Stage;

function check(bool $ok, string $what) : void{
	echo ($ok ? "ok " : "FAIL ") . $what . "\n";
}

$r = CaptureRequest::parse("20260929T0600-1 1700000900\n");
check($r !== null && $r->id === "20260929T0600-1" && $r->deadline === 1700000900, "a well-formed request parses to its id and deadline");

$bad = ["../x 1", ".. 1", ". 1", "a/b 1", "x", "x 1 2", "", "x -1", " x 1", "x 1\n\n"];
$parsed = array_filter($bad, fn(string $s) => CaptureRequest::parse($s) !== null);
check($parsed === [], "no request naming a path outside .capture, or malformed, parses: " . implode("|", $parsed));

$a = new CaptureRequest("a", 100);
$lease = new Lease();
check($lease->mayCapture($a, 50) && !$lease->mustRelease($a, 50), "a new live request is captured, and nothing is released");
$lease->hold($a);
check(!$lease->mayCapture($a, 60) && !$lease->mustRelease($a, 60), "a held request before its deadline is neither captured again nor released");
check($lease->mustRelease(new CaptureRequest("a", 900), 100), "rewriting the held id with a later deadline does not extend the lease");
check($lease->mustRelease(null, 60), "the request going away releases");
check($lease->mustRelease(new CaptureRequest("b", 900), 60), "a request naming another id releases");
check($lease->release() === "a" && $lease->release() === null, "release names the held id once");
check(!$lease->mayCapture(new CaptureRequest("a", 900), 101), "an id already captured is never captured again");
check($lease->mayCapture(new CaptureRequest("b", 900), 101) && !$lease->mayCapture(new CaptureRequest("c", 101), 101), "another id is captured, one past its deadline is not");

$root = sys_get_temp_dir() . "/cap-" . getmypid();
mkdir("$root/players/sub", 0755, true);
mkdir("$root/.capture/old/players", 0755, true);
file_put_contents("$root/.capture/old/ack", "old\n");
Stage::clear("$root/.capture");
check(is_dir("$root/.capture") && scandir("$root/.capture") === [".", ".."], "leftovers of an earlier run are cleared, the root stays");

file_put_contents("$root/players/alice.dat", random_bytes(4096));
file_put_contents("$root/players/bob.dat", "");
file_put_contents("$root/players/sub/x", "not a player file");
$count = Stage::write("$root/players", "$root/.capture", "r1");
$staged = "$root/.capture/r1";
check($count === 2
	&& file_get_contents("$staged/players/alice.dat") === file_get_contents("$root/players/alice.dat")
	&& file_get_contents("$staged/players/bob.dat") === ""
	&& !file_exists("$staged/players/sub")
	&& file_get_contents("$staged/ack") === "r1\n"
	&& !file_exists("$staged/ack.tmp"), "every player file is staged byte for byte, then the ack holds the id");

try{
	Stage::write("$root/missing", "$root/.capture", "r2");
	$threw = false;
}catch(\RuntimeException $e){
	$threw = true;
}
check($threw && !file_exists("$root/.capture/r2/ack"), "an unreadable players directory throws and writes no ack");
PHP
)" || true

printf '%s\n' "$output"
passes="$(grep -c '^ok ' <<<"$output" || true)"
failures="$(grep -c '^FAIL ' <<<"$output" || true)"
ran=$((passes + failures))
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf '::error::%s of %s assertions ran, so one did not run and cannot have passed\n' \
    "$ran" "$EXPECTED_ASSERTIONS"
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  printf '::error::%s self-test assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all %s assertions passed: requests parse safely, a lease is taken once and never extended, and the ack follows a whole staged copy.\n' "$passes"
