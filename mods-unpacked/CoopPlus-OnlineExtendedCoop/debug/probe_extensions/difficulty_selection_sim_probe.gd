extends "res://ui/menus/run/difficulty_selection/difficulty_selection.gd"
# Local-sim breadcrumbs on difficulty selection (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _enter_tree() -> void:
	ProbeLog.event("local_sim.difficulty._enter_tree", {"count": RunData.get_player_count()})


func _ready() -> void:
	ProbeLog.event("local_sim.difficulty._ready", {"count": RunData.get_player_count()})
