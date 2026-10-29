extends "res://ui/menus/ingame/upgrades_ui.gd"
# Local-sim breadcrumbs on the end-of-wave upgrade screen (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _show_next_player_options() -> bool:
	ProbeLog.event("local_sim.upgrades.show_next.before", {"coop": is_coop_ui})
	var r := ._show_next_player_options()
	ProbeLog.event("local_sim.upgrades.show_next.after", {"coop": is_coop_ui, "result": r})
	return r


func _update_player_stats(player_index: int) -> void:
	ProbeLog.event("local_sim.upgrades.update_stats", {"player_index": player_index})
	._update_player_stats(player_index)


func _on_choose_button_pressed(upgrade_data: UpgradeData, player_index: int) -> void:
	ProbeLog.event("local_sim.upgrades.choose.before", {"player_index": player_index})
	._on_choose_button_pressed(upgrade_data, player_index)
	ProbeLog.event("local_sim.upgrades.choose.after", {"player_index": player_index})
