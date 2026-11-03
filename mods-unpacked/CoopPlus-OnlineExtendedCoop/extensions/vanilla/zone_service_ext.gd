extends "res://singletons/zone_service.gd"
# Bigger arenas for 5..8 players (D-013; scripts/core/map_scale.gd). Each
# wave main.gd takes a copy of the zone data, applies the players' map size
# effects and passes it here (main.gd:162-169); the tile map, its limits, the
# camera bounds and the enemy spawner all read that same copy afterwards.
# The copy grows here before the parent stores it. The shared zone resource
# itself is never changed, so nothing adds up from wave to wave.
# Only while the gate is extended and the run has more than four players
# (R08).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const MapScale = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/map_scale.gd")


# Parent: zone_service.gd:38.
func set_current_zone(p_current_zone: ZoneData) -> void:
	if RuntimeGate.is_extended() and p_current_zone != null and _coopplus_is_wave_copy(p_current_zone):
		var count: int = RunData.get_player_count()
		p_current_zone.width = MapScale.scaled_tiles(p_current_zone.width, count)
		p_current_zone.height = MapScale.scaled_tiles(p_current_zone.height, count)
	.set_current_zone(p_current_zone)


func _coopplus_is_wave_copy(zone: ZoneData) -> bool:
	for shared in zones:
		if shared == zone:
			return false
	return true
