<?php

declare(strict_types=1);

/*
 * Usage: php custody-page.php [--dry-run] park|check-error < check output
 *        php custody-page.php [--dry-run] --test
 *
 * Posts one Discord webhook message about a parked instance (riftal-pm ADR 055
 * item 5). stdin is the custody check's output: its `CUSTODY ALERT:` lines are
 * only counted by kind, and nothing from them is sent. The URL is read from
 * RIFTAL_CUSTODY_WEBHOOK_URL alone and never printed. stdout is `page sent`,
 * `page failed`, `no page sent` or, with --dry-run, the JSON payload. Exit 0
 * when sent or printed, 1 when not sent, 2 on usage.
 */

ini_set("display_errors", "0");
ini_set("log_errors", "0");

const URL_PATTERN = '#^https://(?:discord|discordapp)\.com/api/webhooks/\S+$#D';
const SEND_SECONDS = 10;
const CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
// Plain ASCII and at most 64 characters, so the page stays far under Discord's
// 2000 and the JSON never holds a split multibyte character.
const NAME_PATTERN = '/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/D';

function plainName(string|false $value, string $fallback) : string{
	return is_string($value) && preg_match(NAME_PATTERN, $value) === 1 ? $value : $fallback;
}

/** @return int[] instance-wide repeats, player repeats, unclassified lines */
function countFindings($stream) : array{
	$counts = [0, 0, 0];
	$atLineStart = true;
	while(($chunk = fgets($stream, 4096)) !== false){
		if($atLineStart && str_starts_with($chunk, "CUSTODY ALERT: ")){
			$index = match(true){
				str_starts_with($chunk, "CUSTODY ALERT: instance-wide custody stop") => 0,
				str_starts_with($chunk, "CUSTODY ALERT: player ") => 1,
				default => 2
			};
			$counts[$index]++;
		}
		$atLineStart = str_ends_with($chunk, "\n");
	}
	return $counts;
}

function send(string $url, string $payload) : bool{
	try{
		$curl = curl_init($url);
		$options = [
			CURLOPT_POST => true,
			CURLOPT_POSTFIELDS => $payload,
			CURLOPT_HTTPHEADER => ["Content-Type: application/json"],
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_FOLLOWLOCATION => false,
			CURLOPT_CONNECTTIMEOUT => SEND_SECONDS,
			CURLOPT_TIMEOUT => SEND_SECONDS
		];
		if(is_file(CA_BUNDLE)){
			$options[CURLOPT_CAINFO] = CA_BUNDLE;
		}
		curl_setopt_array($curl, $options);
		$result = curl_exec($curl);
		$status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
		return $result !== false && $status >= 200 && $status < 300;
	}catch(Throwable){
		return false;
	}
}

$args = array_values(array_diff(array_slice($argv, 1), ["--dry-run"]));
$dryRun = in_array("--dry-run", $argv, true);
if(count($args) !== 1 || !in_array($args[0], ["park", "check-error", "--test"], true)){
	fwrite(STDERR, "usage: custody-page.php [--dry-run] park|check-error|--test\n");
	exit(2);
}

if($args[0] === "--test"){
	$text = "RIFTAL CUSTODY TEST: this channel receives custody pages. Nothing is parked.";
}else{
	[$wide, $player, $other] = countFindings(STDIN);
	$what = $args[0] === "park"
		? "PARK: PocketMine not started, container parked"
		: "CHECK ERROR: the logs could not be checked, PocketMine not started, container parked";
	$text = "RIFTAL CUSTODY $what\n"
		. "Instance: " . plainName(getenv("INSTANCE_ID"), "unknown-instance") . "\n"
		. "Findings: instance-wide repeat $wide, player repeat $player, unclassified $other\n"
		. "Read the lines with: docker logs " . plainName(gethostname(), "container");
}
$payload = json_encode(
	["allowed_mentions" => ["parse" => []], "content" => $text],
	JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
);

if($dryRun){
	echo $payload . "\n";
	exit(0);
}
$url = getenv("RIFTAL_CUSTODY_WEBHOOK_URL");
if(!is_string($url) || preg_match(URL_PATTERN, $url) !== 1){
	echo "no page sent\n";
	exit(1);
}
$sent = send($url, $payload);
echo $sent ? "page sent\n" : "page failed\n";
exit($sent ? 0 : 1);
