# Changes: lobbies of extended rooms (mod_version marker) count as compatible when this machine can join them. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/public_lobby_browser.gd"
# Public lobby browser and extended rooms (D-008, AP-009). An extended room
# advertises "<protocol>+coopplus" as mod_version (session_manager_ext.gd), so
# Brotato Online without the extension lists it as a version mismatch and
# cannot join it. This machine lists it as joinable when room_policy.gd says
# it can take part: extended mode verified for the room's capacity and the
# same capability version. Brotato Online creates the browser with
# load()+set_script() in its mod_main._ready (mod_main.gd:229-233), after this
# extension is installed from mod_main._init (ADR-001). Every other entry is
# the parent's.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const RoomPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/room_policy.gd")

const COOPPLUS_MARKER_SUFFIX := "+coopplus"


# Parent: public_lobby_browser.gd:1130.
func _read_lobby_entry(lobby_id: int) -> Dictionary:
	var entry: Dictionary = ._read_lobby_entry(lobby_id)
	if entry.empty() or _steam == null or not _steam_has_method("getLobbyData"):
		return entry
	if str(_steam.getLobbyData(lobby_id, "mod_version")) != _coopplus_marker():
		return entry
	var meta := {}
	for key in [RoomPolicy.META_TYPE, RoomPolicy.META_CAPACITY, RoomPolicy.META_CAPABILITY]:
		meta[key] = str(_steam.getLobbyData(lobby_id, key))
	var compatible := _coopplus_can_join(meta) and str(_steam.getLobbyData(lobby_id, "game_version")) == GAME_VERSION
	var state := str(entry.get("state", ""))
	var host_id := str(entry.get("host_id", ""))
	entry["compatible"] = compatible
	entry["joinable"] = compatible and (state == "character_selection" or state == "coop_resume") and not bool(entry.get("full", false)) and host_id != "" and host_id != "0"
	return entry


# Parent: public_lobby_browser.gd:1211. The marker is replaced by the
# protocol version before the parent's exact comparison when this machine can
# join the room.
func _on_lan_lobby_found(entry: Dictionary) -> void:
	if typeof(entry) == TYPE_DICTIONARY and str(entry.get("mod_version", "")) == _coopplus_marker() and _coopplus_can_join(entry):
		var patched := entry.duplicate(true)
		patched["mod_version"] = NETWORK_PROTOCOL_VERSION
		._on_lan_lobby_found(patched)
		return
	._on_lan_lobby_found(entry)


func _coopplus_marker() -> String:
	return NETWORK_PROTOCOL_VERSION + COOPPLUS_MARKER_SUFFIX


func _coopplus_can_join(meta: Dictionary) -> bool:
	return bool(RoomPolicy.join_room(meta, RuntimeGate.verified_capacity(), RuntimeGate.capability_version()).ok)
