extends "res://ui/menus/run/coop_end_run.gd"
# Local-sim breadcrumbs on the co-op end-of-run screen (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _enter_tree() -> void:
	ProbeLog.event("local_sim.end_run._enter_tree", {"count": RunData.get_player_count(), "data": RunData.players_data.size(), "children": get_child_count()})


func _ready() -> void:
	ProbeLog.event("local_sim.end_run._ready", {"count": RunData.get_player_count(), "containers": player_containers.size()})
