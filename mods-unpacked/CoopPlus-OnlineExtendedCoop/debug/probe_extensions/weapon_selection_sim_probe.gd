extends "res://ui/menus/run/weapon_selection.gd"
# Local-sim breadcrumbs on weapon selection (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _set_selected_element(p_player_index: int) -> void:
	ProbeLog.event("local_sim.weapons.selected.before", {"player": p_player_index, "picks": _player_weapons[p_player_index].size() if p_player_index < _player_weapons.size() else -1})
	._set_selected_element(p_player_index)
	ProbeLog.event("local_sim.weapons.selected.after", {"player": p_player_index})


func _on_selections_completed() -> void:
	ProbeLog.event("local_sim.weapons.completed.before", {"count": RunData.get_player_count(), "lists": _player_weapons.size()})
	._on_selections_completed()
	ProbeLog.event("local_sim.weapons.completed.after", {})
