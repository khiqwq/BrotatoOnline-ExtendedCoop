extends Reference
# Arena size for more than four players (D-013). The base game keeps the arena at the
# zone's size for 1..4 players and scales enemy count, HP, damage and
# materials linearly with the player count instead (coop_service.tscn,
# entity_spawner.gd, entity_service.gd); those continue on their own for
# more players. With more than four players each side grows by sqrt(n / 4), which
# keeps the four-player area per player. Every machine computes the same
# size from the same player count, so host and clients build the same map.
# Pure rules: no autoloads, no scene tree.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const VANILLA_PLAYERS := 4
const MAX_PLAYERS := CapacityPolicy.MAX_SUPPORTED_PLAYERS


static func side_factor(player_count: int) -> float:
	var n := int(clamp(player_count, 1, MAX_PLAYERS))
	if n <= VANILLA_PLAYERS:
		return 1.0
	return sqrt(float(n) / VANILLA_PLAYERS)


# Tiles per side after scaling; never smaller than given.
static func scaled_tiles(tiles: int, player_count: int) -> int:
	return int(max(tiles, round(tiles * side_factor(player_count))))
