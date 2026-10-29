extends "res://global/entity_spawner.gd"
# AP-005: stacks on top of Brotato Online's entity_spawner_online_player_count_guard.gd;
# the recorded script chain shows whether our extension sits above BO's.

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _ready() -> void:
	ProbeLog.event("entity_spawner_probe._ready", {"chain": ProbeLog.script_chain(self)})
	ProbeLog.count("entity_spawner._ready")


func _brotato_online_get_authoritative_online_player_count() -> int:
	ProbeLog.count("entity_spawner._brotato_online_get_authoritative_online_player_count")
	return ._brotato_online_get_authoritative_online_player_count()
