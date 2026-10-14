<?php

declare(strict_types=1);

// The instances' healthcheck, run inside the container with the image's own
// php. It sends one RakNet unconnected ping to the server's UDP port and exits
// 0 only on an unconnected pong carrying the offline magic and an MCPE status
// string. A container parked by boot-gate.sh, or a server with no listener yet,
// answers nothing and so reads as unhealthy. Streams rather than the
// sockets extension, which php:8.3-cli-alpine, the image the self-test runs
// this in, does not ship. It lives in a subdirectory because PocketMine loads
// every top-level /plugins/*.php as a script plugin.

const MAGIC = "\x00\xff\xff\x00\xfe\xfe\xfe\xfe\xfd\xfd\xfd\xfd\x12\x34\x56\x78";

$target = sprintf('udp://%s:%d', $argv[1] ?? '127.0.0.1', (int) ($argv[2] ?? 19132));
$socket = @stream_socket_client($target);
if ($socket === false) {
	fwrite(STDERR, "cannot open $target\n");
	exit(1);
}
stream_set_timeout($socket, 3);

fwrite($socket, "\x01" . pack('J', (int) (microtime(true) * 1000)) . MAGIC . pack('J', random_int(0, PHP_INT_MAX)));
$pong = (string) @fread($socket, 2048);

// 0x1c, send time (8), server GUID (8), magic (16), string length (2), string.
if (strlen($pong) < 40 || $pong[0] !== "\x1c" || substr($pong, 17, 16) !== MAGIC
	|| !str_starts_with(substr($pong, 35), 'MCPE;')) {
	fwrite(STDERR, "no RakNet pong from $target\n");
	exit(1);
}
echo substr($pong, 35), "\n";
