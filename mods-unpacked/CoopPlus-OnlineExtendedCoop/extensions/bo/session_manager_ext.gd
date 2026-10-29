# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: capacity read from the runtime gate instead of MAX_LOBBY_MEMBERS; capacity refusals and stale LAN reconnects handled. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/session_manager.gd"
# Session capacity (AP-006; R01, R08; CAP-01..07, CAP-M01, CAP-M03). The
# parent's MAX_LOBBY_MEMBERS (4) cannot be redeclared and is inlined into its
# methods, so every method that reads it for admission or advertising is
# overridden here:
#   admission      _remote_connection_rejection_reason, _register_remote_connection
#   host join      _sync_host_local_join_listening_state
#   advertising    _publish_session_metadata, _setup_lobby_data,
#                  set_public_lobby_enabled, _prepare_friends_only_lobby_for_invite,
#                  get_lan_discovery_info
#   display        _get_lobby_status_text
#   LAN reconnect  _handle_transport_identity (stale peer of the same owner)
# Left alone on purpose: create_session (steam_transport_ext passes the
# capacity to createLobby, _setup_lobby_data fixes the native limit of the
# fallback createLobby), the transport_welcome member_limit (clients never
# read it), get_session_member_count (its meaning stays, CAP-14) and every
# protocol version constant (CAP-12).
# While RuntimeGate.is_extended() is false each override runs the parent
# method unchanged, so a vanilla gate keeps 1..4 player sessions identical (R08).
# Extended sessions still admit Brotato Online clients without the extension;
# refusing them above four players is the capability handshake (AP-009, CAP-13).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
# CAP-M03: _refresh_lobby_members re-evaluates every Steam member on each lobby
# update, so a refused member is announced at most once per interval.
const COOPPLUS_CAPACITY_NOTICE_INTERVAL_MSEC := 5000
# Wait between a notice and the check whether the member left the lobby. Longer
# than detach_kicked_peer's 1 s: the Steam session to a member that was never
# seated may still be connecting, and closing it drops the queued notice.
const COOPPLUS_CAPACITY_NOTICE_RETRY_SEC := 2.0
# Notices per refusal before the session is closed like the parent does.
const COOPPLUS_CAPACITY_NOTICE_ATTEMPTS := 3
# CAP-M01: one stale-peer replacement per LAN owner per interval.
const COOPPLUS_LAN_STALE_REPLACE_INTERVAL_MSEC := 15000
# CAP-M01: the old LAN connection counts as stale only after its owner missed
# two heartbeats on it (network_heartbeat.gd:3, HEARTBEAT_INTERVAL_MSEC 2000).
const COOPPLUS_LAN_STALE_SILENCE_MSEC := 4000
# Bound of the per-peer rate tables; a Steam lobby holds at most 8 members.
const COOPPLUS_MAX_TRACKED_PEERS := 64

var _coopplus_capacity_notice_msec := {}
var _coopplus_lan_replace_msec := {}


# Single source of the capacity for this script, so AP-009 can switch it to
# the negotiated session capacity in one place. Never below the vanilla 4.
func _coopplus_capacity() -> int:
	return int(clamp(RuntimeGate.capacity(), CapacityPolicy.VANILLA_MAX_PLAYERS, CapacityPolicy.MAX_SUPPORTED_PLAYERS))


func _coopplus_extended() -> bool:
	return RuntimeGate.is_extended()


# --- admission -------------------------------------------------------------

func _remote_connection_rejection_reason(peer_key: String, transport: Node, peer) -> String:
	if not _coopplus_extended():
		return ._remote_connection_rejection_reason(peer_key, transport, peer)
	return str(_coopplus_rejection(peer_key, transport, peer).reason)


# Branch order of session_manager.gd:778-793, capacity compared with the gate.
# "capacity" is true only for the member-count refusal, the one CAP-M03
# announces (a frozen run already says so through joinable = false).
func _coopplus_rejection(peer_key: String, transport: Node, peer) -> Dictionary:
	if _kicked_departing_peer_keys.has(peer_key):
		return {"reason": "room_full", "capacity": false}
	if peer_key == "" or peer_key == _self_steam_id:
		return {"reason": "duplicate_identity", "capacity": false}
	if _connection_by_peer_key.has(peer_key):
		var existing = _connection_by_peer_key[peer_key]
		if existing.get("transport", null) != transport or existing.get("peer", null) != peer:
			return {"reason": "duplicate_identity", "capacity": false}
		return {"reason": "", "capacity": false}
	var identity = _get_identity_manager()
	if identity != null and not identity.can_admit_peer(peer_key):
		return {"reason": "resume_reassignment_required", "capacity": false}
	if not _session_remote_peer_keys.has(peer_key):
		if _should_freeze_online_run_slots():
			return {"reason": "room_full", "capacity": false}
		if get_session_member_count() >= _coopplus_capacity():
			return {"reason": "room_full", "capacity": true}
	return {"reason": "", "capacity": false}


# CAP-M03: the parent refuses a Steam member of a full room silently and closes
# its Steam session at once (session_manager.gd:798-804); the member stays in
# the Steam lobby and keeps a native slot. Here it is told with player_kicked
# first, the notice is repeated while the member is still in the lobby, and its
# session is closed afterwards. LAN refusals already carry their reason in
# transport_welcome, so LAN and every other refusal go to the parent unchanged.
func _register_remote_connection(peer_key: String, transport: Node, peer) -> bool:
	if not _coopplus_extended() or transport == null or transport != _steam_transport:
		return ._register_remote_connection(peer_key, transport, peer)
	if not bool(_coopplus_rejection(peer_key, transport, peer).capacity):
		return ._register_remote_connection(peer_key, transport, peer)
	_rejected_peer_keys[peer_key] = true
	_coopplus_announce_capacity_refusal(peer_key, transport, peer)
	return false


func _coopplus_announce_capacity_refusal(peer_key: String, transport: Node, peer) -> void:
	var now := OS.get_ticks_msec()
	var key := _coopplus_session_key(peer_key)
	if _coopplus_capacity_notice_msec.has(key) and now - int(_coopplus_capacity_notice_msec[key]) < COOPPLUS_CAPACITY_NOTICE_INTERVAL_MSEC:
		return
	_coopplus_remember(_coopplus_capacity_notice_msec, key, now, COOPPLUS_CAPACITY_NOTICE_INTERVAL_MSEC)
	ModLoaderLog.info("session full (%d/%d): notifying a refused Steam member" % [get_session_member_count(), _coopplus_capacity()], COOPPLUS_MOD_ID)
	_coopplus_send_capacity_notice(peer_key, transport, peer, 1, _online_session_generation)


# Every Brotato Online client handles player_kicked before its roster revision
# filter (player_removal_manager.gd:356-371; repeats are ignored at 365) and
# leaves the Steam lobby, which frees the native slot. Not detach_kicked_peer:
# the member was never seated (session_manager.gd:9648).
func _coopplus_send_capacity_notice(peer_key: String, transport: Node, peer, attempt: int, generation: int) -> void:
	var _sent = _send_p2p_json(peer_key, {"msg_type": "player_kicked"}, true)
	var tree = get_tree()
	if tree == null:
		if transport.has_method("close_peer"):
			transport.close_peer(peer)
		return
	var _connected = tree.create_timer(COOPPLUS_CAPACITY_NOTICE_RETRY_SEC).connect("timeout", self, "_coopplus_after_capacity_notice", [peer_key, transport, peer, attempt, generation], CONNECT_ONESHOT)


# transport is untyped: the bound node may have been freed by the time the
# timer fires.
func _coopplus_after_capacity_notice(peer_key: String, transport, peer, attempt: int, generation: int) -> void:
	if generation != _online_session_generation or not _rejected_peer_keys.has(peer_key):
		return
	# Seated meanwhile because someone left: never close a live connection.
	if _connection_by_peer_key.has(peer_key):
		return
	if transport == null or not is_instance_valid(transport):
		return
	# Still in the lobby: the notice was lost or is not handled yet. Repeat it;
	# the refreshed rate entry keeps lobby updates from starting a second chain.
	if attempt < COOPPLUS_CAPACITY_NOTICE_ATTEMPTS and _member_list_has_steam_id(peer_key):
		_coopplus_remember(_coopplus_capacity_notice_msec, _coopplus_session_key(peer_key), OS.get_ticks_msec(), COOPPLUS_CAPACITY_NOTICE_INTERVAL_MSEC)
		_coopplus_send_capacity_notice(peer_key, transport, peer, attempt + 1, generation)
		return
	if transport.has_method("close_peer"):
		transport.close_peer(peer)


# --- host local join -------------------------------------------------------

# session_manager.gd:491-499. CoopService._can_add_new_device still decides
# whether a local device may join (CAP-07); this only stops the listening
# from ending at four.
func _sync_host_local_join_listening_state() -> void:
	if not _coopplus_extended():
		._sync_host_local_join_listening_state()
		return
	if not _session_active or not _is_game_host() or _should_freeze_online_run_slots():
		return
	if not _is_host_at_character_selection_for_lobby():
		return
	CoopService.listening_for_inputs = get_session_member_count() < _coopplus_capacity()


# --- advertising -----------------------------------------------------------

# Full replacement without the parent call: the parent's _process runs this
# every 125 ms, and parent-then-fix would write member_limit and joinable twice
# per poll (CAP-04). Body of session_manager.gd:1146-1159.
func _publish_session_metadata() -> void:
	if not _coopplus_extended():
		._publish_session_metadata()
		return
	if not _is_game_host() or _steam == null or _lobby_id == 0:
		return
	var capacity := _coopplus_capacity()
	var count = get_session_member_count()
	var state = get_lobby_state()
	var joinable = count < capacity and (state == "character_selection")
	_set_lobby_metadata_if_changed("session_id", _get_wire_session_id())
	_set_lobby_metadata_if_changed("room_name", _get_room_name_for_lobby())
	_set_lobby_metadata_if_changed("member_count", str(count))
	_set_lobby_metadata_if_changed("member_limit", str(capacity))
	_set_lobby_metadata_if_changed("state", state)
	_set_lobby_metadata_if_changed("resume_assignment_pending", "1" if _is_in_official_coop_resume_scene() else "0")
	_set_lobby_metadata_if_changed("joinable", "1" if joinable else "0")
	_set_lobby_joinable_if_changed(joinable)


# One-off setup at lobby creation (session_manager.gd:1984) and when the host
# joins its own lobby (2073). The parent writes joinable and member_limit for
# four (2230, 2247); the metadata cache keeps the corrected values, so the
# next publish writes nothing.
func _setup_lobby_data() -> void:
	._setup_lobby_data()
	if not _coopplus_extended() or _steam == null or _lobby_id == 0 or not _is_game_host():
		return
	var capacity := _coopplus_capacity()
	_set_lobby_joinable_if_changed(get_session_member_count() < capacity)
	if _steam_has_method("setLobbyData"):
		_set_lobby_metadata_if_changed("member_limit", str(capacity))
	_coopplus_apply_native_member_limit(capacity)


# CAP-03 fallback. steam_transport_ext already creates the lobby with the
# capacity; the parent's own createLobby (session_manager.gd:1349, used when
# the Steam transport is unavailable) still asks for four. Steam counts lobby
# members, i.e. the host plus Steam peers; LAN peers never take a native slot.
func _coopplus_apply_native_member_limit(capacity: int) -> void:
	if not _steam_has_method("setLobbyMemberLimit"):
		return
	if _steam_has_method("getLobbyMemberLimit") and int(_steam.getLobbyMemberLimit(_lobby_id)) == capacity:
		return
	var _ok = _steam.setLobbyMemberLimit(_lobby_id, capacity)


func set_public_lobby_enabled(enabled: bool) -> void:
	.set_public_lobby_enabled(enabled)
	if enabled and _coopplus_extended():
		_coopplus_refresh_lobby_joinable()


func _prepare_friends_only_lobby_for_invite() -> void:
	._prepare_friends_only_lobby_for_invite()
	if _coopplus_extended():
		_coopplus_refresh_lobby_joinable()


# Both parents end with joinable = count < MAX_LOBBY_MEMBERS and (character
# selection or coop resume) (session_manager.gd:1748, 1758). Recomputed with
# the capacity under the guard the parents return on; below four players the
# value is the parent's own and the joinable cache skips the Steam call.
func _coopplus_refresh_lobby_joinable() -> void:
	if _steam == null or _lobby_id == 0 or not _is_game_host():
		return
	var joinable = get_session_member_count() < _coopplus_capacity() and (_is_host_at_character_selection_for_lobby() or _is_in_official_coop_resume_scene())
	_set_lobby_joinable_if_changed(joinable)


# CAP-06: LAN browsers judge "full" from member_limit/joinable. Discovery
# protocol and mod_version stay as the parent wrote them.
func get_lan_discovery_info() -> Dictionary:
	var info = .get_lan_discovery_info()
	if info.empty() or not _coopplus_extended():
		return info
	var capacity := _coopplus_capacity()
	info["member_limit"] = capacity
	info["joinable"] = get_session_member_count() < capacity and (_is_host_at_character_selection_for_lobby() or _is_in_official_coop_resume_scene())
	return info


# --- display ---------------------------------------------------------------

# Body of session_manager.gd:8556-8580 with the member limit of the room.
func _get_lobby_status_text() -> String:
	if not _coopplus_extended():
		return ._get_lobby_status_text()
	var creating = _lobby_toggle_pending_create and not _lobby_toggle_close_after_create
	if creating and not _session_active:
		return _ui_text("status_creating_steam")

	if _main_menu_online_start_pending and not _session_active:
		return _ui_text("status_preparing")

	if _lobby_toggle_pending_create and _lobby_toggle_close_after_create:
		return _ui_text("status_close_after_creation")

	if _session_active:
		var count = get_session_member_count()
		var text = _ui_text("status_open") % [count, _coopplus_status_member_limit(count)]
		return text

	if _last_lobby_create_failed_result != 0:
		if _last_lobby_create_failed_result == -1:
			return _ui_text("status_failed_steam_not_ready")
		if _last_lobby_create_failed_result == -2:
			return _ui_text("status_failed_api_unavailable")
		return _ui_text("status_failed_code") % _last_lobby_create_failed_result

	return _ui_text("status_closed")


# The host shows its own capacity. A client shows what its host advertises,
# so an extended client in a plain four-player room still reads x/4; a LAN
# client has no advertised value yet and keeps the parent's four (AP-009
# brings the negotiated capacity), unless more than four players already
# prove an extended room, so it never reads 5/4.
func _coopplus_status_member_limit(count: int) -> int:
	if _is_game_host():
		return _coopplus_capacity()
	if _steam != null and _lobby_id != 0 and _steam_has_method("getLobbyData"):
		var advertised = int(str(_steam.getLobbyData(_lobby_id, "member_limit")))
		if advertised >= 1 and advertised <= CapacityPolicy.MAX_SUPPORTED_PLAYERS:
			return advertised
	if count > MAX_LOBBY_MEMBERS:
		return _coopplus_capacity()
	return MAX_LOBBY_MEMBERS


# --- LAN reconnect ---------------------------------------------------------

func _handle_transport_identity(transport: Node, peer, message: Dictionary) -> void:
	if _coopplus_extended():
		_coopplus_release_stale_lan_peer(transport, peer, message)
	._handle_transport_identity(transport, peer, message)


# CAP-M01: a LAN client that reconnects before the host noticed its old ENet
# peer drop is refused as duplicate_identity (session_manager.gd:785) and
# leaves. lan_transport_ext keeps ENet slots free for exactly that overlap,
# so the stale peer of the same, freshly proven owner is released first, with
# the cleanup _on_transport_peer_disconnected does (session_manager.gd:556-565);
# the parent then seats the new peer like any reconnect after a detected
# disconnect. Only when that seating is certain, when the old connection is
# silent (a live one is never evicted: right after a run rotation cleared the
# LAN hashes, player_identity_manager.gd:323 and 171, accept_lan_identity
# accepts the first claim without proof; two instances sharing one identity,
# CAP-M02, both prove it), and once per owner per
# COOPPLUS_LAN_STALE_REPLACE_INTERVAL_MSEC. Otherwise the new peer gets the
# parent's duplicate_identity refusal.
func _coopplus_release_stale_lan_peer(transport: Node, peer, message: Dictionary) -> void:
	if transport == null or transport != _lan_transport or not _is_game_host() or not _session_active:
		return
	if str(message.get("msg_type", "")) != "transport_identity":
		return
	# Same order as the parent: an unchallenged or late reply is ignored before
	# any other field is read.
	var challenge = _lan_identity_challenges.get(_connection_lookup_key(transport, peer), null)
	if typeof(challenge) != TYPE_DICTIONARY or str(message.get("run_id", "")) != str(challenge.get("run_id", "")):
		return
	var version = message.get("protocol_version", 0)
	if not (typeof(version) == TYPE_INT or typeof(version) == TYPE_REAL) or int(version) != LAN_PROTOCOL_VERSION:
		return
	var installation_id = str(message.get("installation_id", ""))
	var peer_key = "lan:" + installation_id
	var existing = _connection_by_peer_key.get(peer_key, {})
	if typeof(existing) != TYPE_DICTIONARY or existing.empty():
		return
	if existing.get("transport", null) != transport or existing.get("peer", null) == peer:
		return
	if _kicked_departing_peer_keys.has(peer_key) or not _session_remote_peer_keys.has(peer_key):
		return
	var identity = _get_identity_manager()
	if identity == null or not identity.can_admit_peer(peer_key):
		return
	var now := OS.get_ticks_msec()
	var key := _coopplus_session_key(peer_key)
	if _coopplus_lan_replace_msec.has(key) and now - int(_coopplus_lan_replace_msec[key]) < COOPPLUS_LAN_STALE_REPLACE_INTERVAL_MSEC:
		return
	if not _coopplus_lan_owner_silent(peer_key, now):
		return
	# Proof of ownership, the same call the parent repeats next. Last check:
	# for an owner without a known hash it registers this claim.
	if not identity.accept_lan_identity(installation_id, str(message.get("resume_token", "")), false):
		return
	_coopplus_remember(_coopplus_lan_replace_msec, key, now, COOPPLUS_LAN_STALE_REPLACE_INTERVAL_MSEC)
	var old_peer = existing.get("peer", null)
	var old_lookup = _connection_lookup_key(transport, old_peer)
	_lan_identity_challenges.erase(old_lookup)
	_peer_key_by_connection.erase(old_lookup)
	_connection_by_peer_key.erase(peer_key)
	_remove_player_connection(peer_key)
	_drop_pending_p2p_sends_for_target(peer_key)
	# Its disconnect callback now finds no lookup and changes nothing.
	transport.close_peer(old_peer)
	ModLoaderLog.info("LAN reconnect replaced a stale transport peer of the same owner", COOPPLUS_MOD_ID)


# The heartbeat monitor stamps every seated peer key when it appears and on
# each heartbeat (network_heartbeat.gd:106, 127); only the old connection can
# deliver them, the new one is not mapped yet. No monitor or no stamp means
# unknown, which is treated as live.
func _coopplus_lan_owner_silent(peer_key: String, now: int) -> bool:
	var parent = get_parent()
	var heartbeat = parent.get_node_or_null("BrotatoOnlineNetworkHeartbeat") if parent != null else null
	if heartbeat == null:
		return false
	var last_by_peer = heartbeat.get("_last_heartbeat_by_peer")
	if typeof(last_by_peer) != TYPE_DICTIONARY or not last_by_peer.has(peer_key):
		return false
	return now - int(last_by_peer[peer_key]) >= COOPPLUS_LAN_STALE_SILENCE_MSEC


# --- helpers ---------------------------------------------------------------

# Keys never outlive their session: a new session bumps the generation.
func _coopplus_session_key(peer_key: String) -> String:
	return str(_online_session_generation) + "|" + peer_key


func _coopplus_remember(table: Dictionary, key: String, now: int, max_age_msec: int) -> void:
	for old_key in table.keys():
		if now - int(table[old_key]) >= max_age_msec:
			table.erase(old_key)
	if table.size() >= COOPPLUS_MAX_TRACKED_PEERS:
		table.clear()
	table[key] = now
