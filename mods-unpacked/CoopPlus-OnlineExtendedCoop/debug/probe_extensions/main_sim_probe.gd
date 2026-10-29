extends "res://main.gd"
# Local-sim breadcrumbs around battle scene setup (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _enter_tree() -> void:
	ProbeLog.event("local_sim.main._enter_tree")


func on_lock_coop_camera_changed(value: int) -> void:
	ProbeLog.event("local_sim.main.camera")
	.on_lock_coop_camera_changed(value)


func _on_EntitySpawner_players_spawned(players: Array) -> void:
	var lookups := {}
	for i in range(4, players.size()):
		var n := str(i + 1)
		for path in ["%PlayerLifeBarContainerP" + n, "%PlayerLifeBarContainerP" + n + "/PlayerLifeBarP" + n, "%LifeContainerP" + n,
				"%UILifeBarP" + n, "%UILifeBarP" + n + "/MarginContainer/LifeLabel", "%LifeContainerP" + n + "/UIHitProtection",
				"%UIXPBarP" + n, "%UIXPBarP" + n + "/MarginContainer/LevelLabel", "%UIGoldP" + n, "%UIThingsToProcessPlayerContainer" + n]:
			lookups[path] = get_node_or_null(path) != null
	ProbeLog.event("local_sim.main.players_spawned.before", {"players": players.size(), "things": _things_to_process_player_containers.size(), "lookups": lookups})
	._on_EntitySpawner_players_spawned(players)
	ProbeLog.event("local_sim.main.players_spawned.after", {"players": _players.size(), "hud": _players_ui.size()})


func connect_visual_effects(unit: Unit) -> void:
	ProbeLog.event("local_sim.main.connect_visual_effects", {"player_index": unit.get("player_index")})
	.connect_visual_effects(unit)


func check_half_health_stats(player_index: int) -> void:
	ProbeLog.event("local_sim.main.check_half_health_stats", {"player_index": player_index})
	.check_half_health_stats(player_index)


func _on_player_health_updated(player: Player, current_val: int, max_val: int) -> void:
	ProbeLog.event("local_sim.main.player_health_updated", {"player_index": player.player_index})
	._on_player_health_updated(player, current_val, max_val)


func _on_WaveTimer_timeout() -> void:
	ProbeLog.event("local_sim.main.wave_timer_timeout.before")
	._on_WaveTimer_timeout()
	ProbeLog.event("local_sim.main.wave_timer_timeout.after")


func clean_up_room() -> void:
	ProbeLog.event("local_sim.main.clean_up_room.before")
	.clean_up_room()
	ProbeLog.event("local_sim.main.clean_up_room.after")


func _on_EndWaveTimer_timeout() -> void:
	ProbeLog.event("local_sim.main.end_wave_timer.before")
	._on_EndWaveTimer_timeout()
	ProbeLog.event("local_sim.main.end_wave_timer.after")


func on_upgrade_selected(upgrade_data: UpgradeData, upgrade: UpgradesUI.UpgradeToProcess) -> void:
	ProbeLog.event("local_sim.main.upgrade_selected", {"player_index": upgrade.player_index})
	.on_upgrade_selected(upgrade_data, upgrade)
