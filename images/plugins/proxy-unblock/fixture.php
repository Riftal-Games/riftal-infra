<?php

/**
 * RakNet client for selftest.sh. Completes the RakNet handshake with the
 * server, sends an 0xfe payload core cannot decode, then sends unconnected
 * pings from the same socket until a pong comes back, and prints how long
 * after the bad payload that was. Runs inside the server's own container, so
 * its source address is 127.0.0.1.
 *
 * Usage: php fixture.php <host> <port>
 * Prints "handshake ok", then "pong <ms>" or "no pong".
 */

declare(strict_types=1);

const MAGIC = "\x00\xff\xff\x00\xfe\xfe\xfe\xfe\xfd\xfd\xfd\xfd\x12\x34\x56\x78";
const RAKNET_PROTOCOL = 11;
const OFFLINE_MTU = 1200;
const CLIENT_GUID = 0x1470147014701470;

// The block lasts 5 s. Pings start after the block has been raised and any
// unblock has had several ticks to run, and stop after it has expired.
const FIRST_PING_MS = 1000;
const PING_EVERY_MS = 250;
const GIVE_UP_MS = 9000;

function address(string $ip, int $port) : string{
	$out = "\x04";
	foreach(explode(".", $ip) as $octet){
		$out .= chr(~(int) $octet & 0xff);
	}
	return $out . pack("n", $port);
}

function triad(int $n) : string{
	return substr(pack("V", $n), 0, 3);
}

function frame(int $sequence, int $reliability, int $messageIndex, int $orderIndex, string $payload) : string{
	$header = chr($reliability << 5) . pack("n", strlen($payload) * 8) . triad($messageIndex);
	if($reliability === 3){
		$header .= triad($orderIndex) . "\x00";
	}
	return "\x84" . triad($sequence) . $header . $payload;
}

function receive($socket, int $waitMs) : ?string{
	$read = [$socket];
	$write = $except = null;
	if(socket_select($read, $write, $except, intdiv($waitMs, 1000), ($waitMs % 1000) * 1000) < 1){
		return null;
	}
	return socket_read($socket, 2048) ?: null;
}

function expect($socket, string $id, string $what) : string{
	$deadline = microtime(true) + 3;
	while(microtime(true) < $deadline){
		$data = receive($socket, 200);
		if($data !== null && $data[0] === $id){
			return $data;
		}
	}
	fwrite(STDERR, "no $what from the server\n");
	exit(2);
}

[, $host, $port] = $argv + [null, "127.0.0.1", "19132"];
$socket = socket_create(AF_INET, SOCK_DGRAM, SOL_UDP);
socket_connect($socket, $host, (int) $port);

$serverAddress = address($host, (int) $port);
socket_write($socket, "\x05" . MAGIC . chr(RAKNET_PROTOCOL) . str_repeat("\x00", OFFLINE_MTU - 18));
expect($socket, "\x06", "open connection reply 1");
socket_write($socket, "\x07" . MAGIC . $serverAddress . pack("n", OFFLINE_MTU) . pack("J", CLIENT_GUID));
expect($socket, "\x08", "open connection reply 2");

$now = (int) (microtime(true) * 1000);
socket_write($socket, frame(0, 2, 0, 0, "\x09" . pack("J", CLIENT_GUID) . pack("J", $now) . "\x00"));
$deadline = microtime(true) + 3;
$accepted = false;
while(!$accepted && microtime(true) < $deadline){
	$data = receive($socket, 200);
	$accepted = $data !== null && (ord($data[0]) & 0x80) !== 0 && strlen($data) > 7 && $data[7] === "\x10";
}
if(!$accepted){
	fwrite(STDERR, "no connection request accepted from the server\n");
	exit(2);
}
socket_write($socket, frame(1, 2, 1, 0, "\x13" . $serverAddress . pack("J", $now) . pack("J", $now)));
echo "handshake ok\n";
usleep(300000);

$sentBad = microtime(true);
socket_write($socket, frame(2, 3, 2, 0, "\xfe" . str_repeat("\xff", 24)));

$ping = "\x01" . pack("J", 1) . MAGIC . pack("J", CLIENT_GUID);
$next = FIRST_PING_MS;
while(true){
	$elapsed = (int) ((microtime(true) - $sentBad) * 1000);
	if($elapsed >= GIVE_UP_MS){
		echo "no pong\n";
		exit(0);
	}
	if($elapsed >= $next){
		socket_write($socket, $ping);
		$next += PING_EVERY_MS;
	}
	$data = receive($socket, 50);
	if($data !== null && $data[0] === "\x1c"){
		echo "pong ", (int) ((microtime(true) - $sentBad) * 1000), "\n";
		exit(0);
	}
}
