extends "res://global/entity_spawner.gd"
# Local-sim breadcrumbs around EntitySpawner.init (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func init(zone_min_pos: Vector2, zone_max_pos: Vector2, current_wave_data: WaveData, wave_timer: Timer) -> void:
	ProbeLog.event("local_sim.spawner.init.before", {"run_players": RunData.get_player_count()})
	.init(zone_min_pos, zone_max_pos, current_wave_data, wave_timer)
	ProbeLog.event("local_sim.spawner.init.after")
