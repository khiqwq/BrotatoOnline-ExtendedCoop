extends "res://mods-unpacked/six666-BrotatoOnline/scripts/menu_sync_manager.gd"
# AP-005: second BO manager, plus the menu layout clamp that AP-006 must replace.

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _ready() -> void:
	ProbeLog.event("menu_sync_probe._ready", {"path": str(get_path())})
	ProbeLog.count("menu_sync._ready")


func _get_online_coop_layout_player_count() -> int:
	ProbeLog.count("menu_sync._get_online_coop_layout_player_count")
	return ._get_online_coop_layout_player_count()
