<?php

declare(strict_types=1);

/*
 * Usage: php write-latency-probe.php <data dir> <writes per kind>
 *
 * Run in the core image by write-latency-probe.sh. Times the two durable writes
 * behind K and W as riftal-game's lib makes them, one "player <ms>" or
 * "chunk <ms>" line per write. player is DatFilePlayerSave: gzip, core's
 * safeFilePutContents() temporary file and rename, read-back, fsync of the file
 * then of `players/`. chunk is DurableChunkSave: core's unsynced saveChunk()
 * batch, the synced rewrite of every key under the chunk's index, then an
 * fsync of the LevelDB directory, opened with core's options.
 */

// Standard output carries only timing lines, which the check parses.
ini_set("display_errors", "stderr");
set_error_handler(static function(int $severity, string $message) : bool{
	throw new ErrorException($message, 0, $severity);
});

// A player file with a full inventory, and a chunk of a built-up area. Random
// bytes do not compress, so neither write is flattered by zlib.
const PLAYER_PAYLOAD_BYTES = 8192;
const SUBCHUNKS = 16;
const SUBCHUNK_BYTES = 4096;

// Core's ChunkDataKey::NEW_VERSION and ::SUBCHUNK.
const KEY_VERSION = "\x2c";
const KEY_SUBCHUNK = "\x2f";

[, $dataDir, $writes] = $argv + [null, null, null];
if(!is_string($dataDir) || !is_dir($dataDir) || !is_string($writes) || !ctype_digit($writes) || (int) $writes < 1){
	fwrite(STDERR, "usage: write-latency-probe.php <data dir> <writes per kind>\n");
	exit(2);
}

function fsyncPath(string $path) : void{
	$handle = fopen($path, "rb");
	try{
		if(!fsync($handle)){
			throw new RuntimeException("fsync failed on $path");
		}
	}finally{
		fclose($handle);
	}
}

function milliseconds(int $start) : string{
	return sprintf("%.3f", (hrtime(true) - $start) / 1e6);
}

$players = "$dataDir/players";
if(!is_dir($players)){
	mkdir($players);
}
$file = "$players/probe.dat";
for($i = 0; $i < (int) $writes; $i++){
	$payload = random_bytes(PLAYER_PAYLOAD_BYTES);
	$start = hrtime(true);
	$bytes = zlib_encode($payload, ZLIB_ENCODING_GZIP);
	file_put_contents("$file.0.tmp", $bytes);
	rename("$file.0.tmp", $file);
	if(zlib_decode(file_get_contents($file)) !== $payload){
		throw new RuntimeException("$file did not read back as written");
	}
	fsyncPath($file);
	fsyncPath($players);
	echo "player ", milliseconds($start), "\n";
}

$levelDir = "$dataDir/worlds/probe/db";
mkdir($levelDir, 0777, true);
$db = new LevelDB($levelDir, ["compression" => LEVELDB_ZLIB_RAW_COMPRESSION, "block_size" => 64 * 1024]);
$index = pack("VV", 0, 0);
for($i = 0; $i < (int) $writes; $i++){
	$saveChunk = new LevelDBWriteBatch();
	$saveChunk->put($index . KEY_VERSION, chr(40));
	for($y = 0; $y < SUBCHUNKS; $y++){
		$saveChunk->put($index . KEY_SUBCHUNK . chr($y), random_bytes(SUBCHUNK_BYTES));
	}
	$start = hrtime(true);
	$db->write($saveChunk);
	$rewrite = new LevelDBWriteBatch();
	for($byte = 0; $byte < 256; $byte++){
		$rewrite->delete($index . chr($byte));
		$rewrite->delete($index . KEY_SUBCHUNK . chr($byte));
	}
	$iterator = $db->getIterator();
	for($iterator->seek($index); $iterator->valid() && str_starts_with($iterator->key(), $index); $iterator->next()){
		$rewrite->put($iterator->key(), $iterator->current());
	}
	unset($iterator);
	$db->write($rewrite, ["sync" => true]);
	fsyncPath($levelDir);
	echo "chunk ", milliseconds($start), "\n";
}
unset($db);
