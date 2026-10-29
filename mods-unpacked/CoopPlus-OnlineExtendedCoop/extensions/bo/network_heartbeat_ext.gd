# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: client keeps up to capacity - 1 host-reported disconnected peers instead of 3. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/network_heartbeat.gd"
# Heartbeat disconnect list (AP-006; CAP-16, NET-03). The host already
# repeats every disconnected peer in each heartbeat; a client kept only the
# first three, so with five or more players some disconnects never showed.
# One player per machine: the host has at most capacity - 1 remote peers.
# Timeouts and intervals stay the parent's values (requirements section 5).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


# Body of network_heartbeat.gd:152-166 with the row limit from the gate.
func _receive_host_disconnect_status(message: Dictionary) -> void:
	if not RuntimeGate.is_extended():
		._receive_host_disconnect_status(message)
		return
	var limit: int = RuntimeGate.max_remote_players()
	var rows = message.get("disconnected_peers", [])
	if typeof(rows) != TYPE_ARRAY:
		return
	var reported = {}
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var peer_key = str(row.get("peer_key", ""))
		var display_name = _sanitize_name(str(row.get("name", "")))
		if peer_key != "" and display_name != "":
			reported[peer_key] = display_name
		if reported.size() >= limit:
			break
	_host_reported_disconnected = reported
