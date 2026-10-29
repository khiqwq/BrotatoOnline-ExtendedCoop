# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: ENet server peer limit taken from the runtime gate plus a reconnect/refusal margin instead of MAX_CLIENTS. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/lan_transport.gd"
# LAN transport capacity (AP-006; R01; CAP-05, NET-02). create_server takes
# its peer limit only when the server is made, and the parent passes
# MAX_CLIENTS (3), so start_host is replaced as a whole in extended mode.
# Untouched on purpose: set_channel_count(4) and clamp(channel + 1, 1, 3) in
# send_packet are ENet channel numbers, not player counts.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
# Transport peers beyond the remote seats: one for a client that reconnects
# before the host noticed its old peer drop (session_manager_ext releases the
# stale one, CAP-M01), one for a newcomer to a full room, so the session gate
# answers with its explicit room_full welcome (R01) instead of ENet refusing
# the connection without a reason. Seats are still counted only by the session
# gate (_remote_connection_rejection_reason), never here.
const COOPPLUS_EXTRA_TRANSPORT_PEERS := 2


# Body of lan_transport.gd:39-52 with the create_server limit replaced.
func start_host(port: int = DEFAULT_PORT) -> int:
	if not RuntimeGate.is_extended():
		return .start_host(port)
	var max_clients: int = RuntimeGate.max_remote_players() + COOPPLUS_EXTRA_TRANSPORT_PEERS
	stop()
	_peer = NetworkedMultiplayerENet.new()
	_peer.set_channel_count(4)
	var err = _peer.create_server(port, max_clients)
	if err != OK:
		_peer = null
		return err
	_is_host = true
	_active = true
	_reset_runtime_diagnostics()
	_bind_peer_signals()
	_diag_log("host_started", "port=" + str(port))
	ModLoaderLog.info("LAN host accepts %d transport peers for %d remote seats" % [max_clients, RuntimeGate.max_remote_players()], COOPPLUS_MOD_ID)
	return OK
