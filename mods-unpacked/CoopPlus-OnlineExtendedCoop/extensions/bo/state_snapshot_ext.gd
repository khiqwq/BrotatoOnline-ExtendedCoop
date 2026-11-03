extends "res://mods-unpacked/six666-BrotatoOnline/scripts/state_snapshot.gd"
# A remote player whose game is gone no longer leaves an invincible character
# (AP-017; reported from online 5-player play, 2026-11-02: P5 quit on the
# retry prompt, the other four retried, P5's character could not die).
# Each client owns its character's HP and death. On the host every remote
# character is a proxy whose damage is undone and whose death is blocked
# until its client reports it (state_snapshot.gd:1777-1806,
# player_safe_room_cleanup.gd:215-246). An owner who disconnected never
# reports again, so a character spawned for them (a retried wave, or a wave
# started while they were gone) stood untouchable, and with it alive the
# wave could not be lost. Brotato Online keeps the slot reserved so the
# player can come back; that stays.
# In extended rooms, on the host, a remote character whose owner has had no
# connection for ABSENT_GRACE_MSEC gets the death Brotato Online applies when
# a client reports dying (_apply_client_authoritative_remote_player_life_state).
# Host snapshots then carry that death to every client; no message changes.
# Not while the host's first-snapshot gate of a new battle is closed: that
# gate waits for every player to be alive (session_manager.gd:5160-5179).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const ABSENT_GRACE_MSEC := 3000
const ABSENT_DEATH_META := "coopplus_absent_owner_death"
const MAIN_SCENE := "res://main.tscn"

# peer key -> first tick (msec) its owner was seen without a connection
var _coopplus_absent_since := {}


# Parent: state_snapshot.gd:1788 (runs every 250 ms on the host in battle).
func _prepare_host_remote_player_damage_proxies(force: bool) -> void:
	._prepare_host_remote_player_damage_proxies(force)
	if RuntimeGate.is_extended() and _is_game_host():
		_coopplus_settle_absent_owners()


func _coopplus_settle_absent_owners() -> void:
	var scene = get_tree().current_scene
	var session = _get_session_manager()
	var slots = _get_player_slot_manager()
	var locator = _get_runtime_locator()
	if scene == null or str(scene.filename) != MAIN_SCENE or session == null or slots == null or locator == null:
		return
	if bool(scene.get("_cleaning_up")) or bool(scene.get("_is_wave_failed")):
		return
	if session.has_method("_host_retry_first_snapshot_needs_gate") and session._host_retry_first_snapshot_needs_gate():
		return
	var pending = session.get("_pending_host_game_start")
	if typeof(pending) == TYPE_DICTIONARY and not pending.empty():
		return
	var connections = session.get("_connection_by_peer_key")
	if typeof(connections) != TYPE_DICTIONARY:
		return
	var players = locator.get_players()
	if typeof(players) != TYPE_ARRAY:
		return
	var now := OS.get_ticks_msec()
	var seen := {}
	for i in range(players.size()):
		var player = players[i]
		if not _is_valid_node(player):
			continue
		var player_index := _get_player_index_from_node(player, i)
		if not _is_host_remote_player_index(player_index):
			continue
		var peer := str(slots.get_remote_steam_id(player_index))
		if peer == "" or connections.has(peer):
			continue
		seen[peer] = true
		if not _coopplus_absent_since.has(peer):
			_coopplus_absent_since[peer] = now
		if now - int(_coopplus_absent_since[peer]) < ABSENT_GRACE_MSEC:
			continue
		if bool(player.get("dead")) or _has_meta_true(player, ABSENT_DEATH_META):
			continue
		player.set_meta(ABSENT_DEATH_META, true)
		_apply_client_authoritative_remote_player_life_state(player, player_index, 0, true)
		ModLoaderLog.info("battle: P%d's game is not connected; their character dies (slot kept for a reconnect)" % (player_index + 1), COOPPLUS_MOD_ID)
	for peer in _coopplus_absent_since.keys():
		if not seen.has(peer):
			_coopplus_absent_since.erase(peer)
