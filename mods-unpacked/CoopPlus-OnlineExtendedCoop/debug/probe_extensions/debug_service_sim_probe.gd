extends "res://singletons/debug_service.gd"
# Local-sim breadcrumbs around DebugService.log_run_info (debug only).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func log_run_info(upgrades: Array = [[], [], [], []], consumables: Array = [[], [], [], []]) -> void:
	ProbeLog.event("local_sim.debug.log_run_info.before", {"upgrades": upgrades.size(), "players": RunData.get_player_count()})
	.log_run_info(upgrades, consumables)
	ProbeLog.event("local_sim.debug.log_run_info.after")
