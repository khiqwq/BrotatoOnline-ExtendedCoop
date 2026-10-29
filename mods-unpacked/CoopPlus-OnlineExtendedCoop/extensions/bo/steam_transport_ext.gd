extends "res://mods-unpacked/six666-BrotatoOnline/scripts/steam_transport.gd"
# Native Steam lobby limit (AP-006; R01; CAP-03). createLobby fixes the member
# limit when the lobby is made; the only caller, create_session
# (session_manager.gd:1346), passes MAX_LOBBY_MEMBERS (4). With extended mode
# the lobby is created for the session capacity instead, so the session gate
# (session_manager_ext) is the only place that counts seats. Steam counts
# lobby members: the host plus its Steam peers, never LAN peers.
# The parent declares both "var _ready" and "func _ready"; this script
# declares neither (ADR-001 rule 2).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


func start_host(lobby_type: int, member_limit: int) -> int:
	if not RuntimeGate.is_extended():
		return .start_host(lobby_type, member_limit)
	return .start_host(lobby_type, RuntimeGate.capacity())
