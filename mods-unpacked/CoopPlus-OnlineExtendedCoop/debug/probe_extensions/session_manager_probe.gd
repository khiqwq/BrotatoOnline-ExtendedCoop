extends "res://mods-unpacked/six666-BrotatoOnline/scripts/session_manager.gd"
# AP-005: proves an extension of a Brotato Online manager script reaches the
# instance BO creates in its mod_main._ready (load() + set_script()). Godot 3
# calls _init/_ready on every level of the script chain, so the overrides below
# must not call the parent versions again.

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _init() -> void:
	ProbeLog.event("session_manager_probe._init")
	ProbeLog.count("session_manager._init")


func _ready() -> void:
	ProbeLog.event("session_manager_probe._ready", {"path": str(get_path())})
	ProbeLog.count("session_manager._ready")


func _bind_transports() -> void:
	ProbeLog.count("session_manager._bind_transports")
	._bind_transports()


func get_session_member_count() -> int:
	ProbeLog.count("session_manager.get_session_member_count")
	return .get_session_member_count()
