extends "res://mods-unpacked/six666-BrotatoOnline/scripts/online_player_slot_manager.gd"
# AP-005/006: checks the INP-M02 risk - this parent declares a const derived from
# the CoopService autoload, and installing the extension in _init compiles it
# while autoloads are still being created.

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _ready() -> void:
	ProbeLog.event("slot_manager_probe._ready", {
		"placeholder_type": REMOTE_PLACEHOLDER_PLAYER_TYPE,
		"gamepad_xbox": CoopService.PlayerType.GAMEPAD_XBOX,
		"can_instance": get_script().can_instance(),
	})
	ProbeLog.count("slot_manager._ready")
