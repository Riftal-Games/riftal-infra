<?php

declare(strict_types=1);

// Resolves every block state and block-entity type of a census against the
// core image this runs in, through the handlers the core loads a level with.
//
// php resolve_states.php <census.json> <core image sha>
//
// Prints one JSON object. A state is unresolved when the upgrader or the
// deserializer refuses it, and altered when the core's own state for it is not
// the one the structure holds. Neither is ever replaced by info_update here.

require 'phar:///opt/pocketmine/PocketMine-MP.phar/vendor/autoload.php';

use pocketmine\data\bedrock\block\BlockStateData;
use pocketmine\nbt\tag\ByteTag;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\nbt\tag\IntTag;
use pocketmine\nbt\tag\StringTag;
use pocketmine\nbt\tag\Tag;
use pocketmine\world\format\io\GlobalBlockStateHandlers;
use pocketmine\block\tile\TileFactory;

function tagText(Tag $tag) : string{
	return $tag instanceof ByteTag ? ($tag->getValue() === 1 ? "true" : "false") : (string) $tag->getValue();
}

function canonical(BlockStateData $data) : string{
	$parts = [];
	foreach($data->getStates() as $key => $tag){
		$parts[$key] = $key . "=" . tagText($tag);
	}
	ksort($parts);
	return $data->getName() . ($parts === [] ? "" : "[" . implode(",", $parts) . "]");
}

/** @param array<string,bool|int|string> $states */
function stateNbt(string $name, array $states, int $version) : CompoundTag{
	$tags = CompoundTag::create();
	foreach($states as $key => $value){
		$tags->setTag($key, match(true){
			is_bool($value) => new ByteTag($value ? 1 : 0),
			is_int($value) => new IntTag($value),
			default => new StringTag($value),
		});
	}
	return CompoundTag::create()
		->setString("name", $name)
		->setTag("states", $tags)
		->setInt("version", $version);
}

if($argc !== 3){
	fwrite(STDERR, "usage: resolve_states.php <census.json> <core image sha>\n");
	exit(2);
}
$census = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);

$upgrader = GlobalBlockStateHandlers::getUpgrader();
$deserializer = GlobalBlockStateHandlers::getDeserializer();
$serializer = GlobalBlockStateHandlers::getSerializer();

$unresolved = [];
$altered = [];
foreach($census["states"] as $row){
	try{
		$loaded = $upgrader->upgradeBlockStateNbt(stateNbt($row["name"], $row["states"], $row["version"]));
		$id = $deserializer->deserialize($loaded);
		$held = canonical($serializer->serialize($id));
		if($held !== canonical($loaded)){
			$altered[] = ["key" => $row["key"], "core" => $held];
		}
	}catch(\Exception $e){
		$unresolved[] = ["key" => $row["key"], "count" => $row["count"], "error" => $e->getMessage()];
	}
}

// TileFactory publishes no list of the save ids it reads, only the private map.
$known = array_keys((new ReflectionProperty(TileFactory::class, "knownTiles"))->getValue(TileFactory::getInstance()));
$tilesUnknown = array_values(array_diff(array_keys($census["block_entities"]), $known));
sort($tilesUnknown);

echo json_encode([
	"core_image" => $argv[2],
	"states_checked" => count($census["states"]),
	"block_entity_types_checked" => count($census["block_entities"]),
	"unresolved" => $unresolved,
	"altered" => $altered,
	"block_entities_unknown" => $tilesUnknown,
], JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
