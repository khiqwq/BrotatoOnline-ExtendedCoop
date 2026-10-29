extends "res://singletons/coop_service.gd"
# AP-005: vanilla autoload created after ModLoader (scene res://singletons/coop_service.tscn).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")


func _init() -> void:
	ProbeLog.event("coop_service_probe._init")
	ProbeLog.count("coop_service._init")


func _ready() -> void:
	ProbeLog.event("coop_service_probe._ready")
	ProbeLog.count("coop_service._ready")


func get_max_players():
	ProbeLog.count("coop_service.get_max_players")
	return .get_max_players()
