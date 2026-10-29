# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: remote seats up to the gate capacity on virtual device ids, refusals reported, over-capacity layouts rejected whole. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/online_player_slot_manager.gd"
# Remote player slots for 5..8 player sessions (AP-006; R01, R02, R08;
# INP-01, INP-03, INP-04, INP-07, CAP-08, CAP-09, CAP-15; F01 F02 F03).
# Installed from mod_main._enter_tree: the parent's const
# REMOTE_PLACEHOLDER_PLAYER_TYPE reads the CoopService autoload, so the parent
# cannot be compiled during ModLoader._init (INP-M02, ADR-001 rule 5).
# While RuntimeGate.is_extended() is false every override runs the parent
# method unchanged (R08). The one vanilla-mode addition: a selection layout
# larger than the gate capacity, which a vanilla host never sends, is refused
# as a whole instead of being cut.
# Extended mode:
#   - the host seats at most RuntimeGate.max_remote_players() remote players
#     and RuntimeGate.capacity() players in total (the parent's
#     MAX_REMOTE_PLAYERS = 3 and CoopService.get_max_players() = 4). A seat
#     that cannot be given is logged and reported through
#     coopplus_remote_slot_rejected, never dropped silently.
#   - every remote placeholder uses a virtual device id from
#     RuntimeGate.virtual_device_ids() (16 and up), never the parent's shared
#     ids [1, 2, 3, 4, 5, 0]. The InputService extension gives those ids
#     actions without physical events, so no local keyboard, controller,
#     unplug signal or echo reaches them (INP-04, INP-06).
#   - a device id stays with its remote identity (peer key), not with the
#     player_index that compaction shifts (INP-07). An id freed by a player
#     who left goes to a newcomer only when no other id is free, so a player
#     who comes back usually gets the old id again, and a just-released id
#     is not handed straight to someone else (F03).
# Device bookkeeping stays in the parent's three maps (_remote_devices,
# _remote_steam_id_by_device, _device_by_remote_steam_id). This file only adds
# a preference map peer key -> last virtual id, with at most one key per id,
# so it never holds more entries than there are virtual ids.
# virtual_device_pool.gd is not used: it would be a second owner of the same
# ids beside maps the parent rewrites in paths this file does not override
# (remove_online_player_slots, online_reset_to_offline, _remove_remote_steam_id),
# and its release() forgets the owner, which cannot express "prefer the id
# this identity had before".
# Left for later work: the Continue layout itself (apply_resume_identity_layout
# keeps the parent's steps; identity registry limit INP-M03 is AP-016/017),
# physical joypads 6+ (INP-11), FocusEmulator 5..8 (INP-08, AP-014/015).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_NO_DEVICE := -1
# Keys the parent invents for client slots whose identity is not known yet
# (online_player_slot_manager.gd:580). They name a position, not a player, so
# they never get a device preference.
const COOPPLUS_UNKNOWN_REMOTE_PREFIX := "unknown_remote_player_"

const COOPPLUS_REFUSE_REMOTE_LIMIT := "remote_player_limit"
const COOPPLUS_REFUSE_CAPACITY := "session_capacity"
const COOPPLUS_REFUSE_DEVICE := "virtual_device_exhausted"
const COOPPLUS_LAYOUT_OVER_CAPACITY := "layout_over_capacity"
const COOPPLUS_LAYOUT_NO_DEVICE := "layout_virtual_device_exhausted"
const COOPPLUS_RUN_SNAPSHOT_MISSING := "run_snapshot_missing"
const COOPPLUS_RUN_SNAPSHOT_OVER_CAPACITY := "run_snapshot_over_capacity"
const COOPPLUS_RUN_SNAPSHOT_MISMATCH := "run_snapshot_player_mismatch"

# The host retries a seat for an unseated member on every packet it sends
# (session_manager.gd:2460-2467, INP-01), so refusals are logged at most once
# per reason and interval and tracked for a bounded number of peers (F18).
const COOPPLUS_LOG_INTERVAL_MSEC := 5000
const COOPPLUS_MAX_TRACKED_REFUSALS := 32

# A remote seat could not be given (reason: one of COOPPLUS_REFUSE_*). Sent
# once per peer and reason, deferred, so a handler may reject or detach the
# member without re-entering the slot sync that refused it.
signal coopplus_remote_slot_rejected(peer_key, reason)
# The first lock of an online run found a slot snapshot that does not match
# the run (CAP-15). details: {"ok", "reason", "snapshot", "run_players",
# "capacity"}. Deferred like the signal above.
signal coopplus_run_slot_check_failed(reason, details)

var _coopplus_device_by_peer_key := {}  # peer key -> last virtual device id
var _coopplus_refusals := {}            # peer key -> reason of its refused seat
var _coopplus_log_msec := {}            # reason -> time of the last log line
var _coopplus_log_suppressed := {}      # reason -> lines skipped since then
var _coopplus_run_slot_check := {}


# Remote peers whose last seat request was refused and who are still listed
# by the session: peer key -> reason. Raw keys; never log them (R21).
func coopplus_get_remote_slot_refusals() -> Dictionary:
	return _coopplus_refusals.duplicate()


# Result of the check made at the first lock of the current run; empty
# before that run was locked.
func coopplus_get_run_slot_check() -> Dictionary:
	return _coopplus_run_slot_check.duplicate()


# Virtual device id currently held by a remote peer, or -1.
func coopplus_get_remote_device(peer_key: String) -> int:
	if not _device_by_remote_steam_id.has(peer_key):
		return COOPPLUS_NO_DEVICE
	return int(_device_by_remote_steam_id[peer_key])


# Parent: online_player_slot_manager.gd:279. Unchanged apart from forgetting
# refusals of peers the session no longer lists, before the parent seats the
# others.
func online_sync_remote_steam_ids(remote_steam_ids: Array) -> void:
	if RuntimeGate.is_extended() and not _coopplus_refusals.empty() and not _is_slot_mutation_locked():
		var listed := {}
		for steam_id_value in remote_steam_ids:
			listed[str(steam_id_value)] = true
		for peer_key in _coopplus_refusals.keys():
			if not listed.has(peer_key):
				_coopplus_refusals.erase(peer_key)
	.online_sync_remote_steam_ids(remote_steam_ids)


# Parent: online_player_slot_manager.gd:745 (only reader of MAX_REMOTE_PLAYERS,
# :752). Same steps with the gate limits instead of 3 remote / 4 total, a
# virtual device that follows the peer, and a reported refusal instead of a
# bare -1 that online_sync_remote_steam_ids (:313) ignores.
func _add_remote_steam_id(steam_id: String) -> int:
	if not RuntimeGate.is_extended():
		return ._add_remote_steam_id(steam_id)
	if steam_id == "":
		return -1

	if _device_by_remote_steam_id.has(steam_id):
		return get_player_index_for_steam_id(steam_id)

	if _remote_devices.size() >= int(RuntimeGate.max_remote_players()):
		return _coopplus_refuse_seat(steam_id, COOPPLUS_REFUSE_REMOTE_LIMIT)

	if CoopService.connected_players.size() >= int(RuntimeGate.capacity()):
		return _coopplus_refuse_seat(steam_id, COOPPLUS_REFUSE_CAPACITY)

	var device := _coopplus_pick_device(steam_id, _coopplus_devices_in_use())
	if device < 0:
		return _coopplus_refuse_seat(steam_id, COOPPLUS_REFUSE_DEVICE)

	_remote_devices.append(device)
	_remote_steam_id_by_device[device] = steam_id
	_device_by_remote_steam_id[steam_id] = device
	_coopplus_remember_device(steam_id, device)
	_coopplus_refusals.erase(steam_id)
	CoopService._add_player(device, REMOTE_PLACEHOLDER_PLAYER_TYPE)
	_sync_run_data_player_count()

	var player_index = _get_player_index_for_device(device)
	return player_index


# Parent: online_player_slot_manager.gd:1271. Its only remaining caller is the
# parent's controller migration (:1130), which starts only when a remote
# placeholder holds a local controller id - impossible for a virtual id - so
# this just keeps the answer inside the virtual ids.
func _get_next_free_remote_device() -> int:
	if not RuntimeGate.is_extended():
		return ._get_next_free_remote_device()
	return _coopplus_pick_device("", _coopplus_devices_in_use())


# Parent: online_player_slot_manager.gd:1282. Called by the parent's
# apply_resume_identity_layout (Continue on the host); picks a virtual id the
# layout being built does not use yet.
func _get_next_remote_placeholder_device_from_lists(remote_devices: Array, connected_players: Array, reserved_devices: Array = []) -> int:
	if not RuntimeGate.is_extended():
		return ._get_next_remote_placeholder_device_from_lists(remote_devices, connected_players, reserved_devices)
	return _coopplus_pick_device("", _coopplus_devices_in_lists(remote_devices, connected_players, reserved_devices))


# Parent: online_player_slot_manager.gd:1175. Same loop; the parent only treats
# its own ids [1, 2, 3, 4, 5, 0] as placeholders (:1182), so a stale virtual
# placeholder would never be removed.
func _remove_untracked_remote_placeholder_slots() -> bool:
	if not RuntimeGate.is_extended():
		return ._remove_untracked_remote_placeholder_slots()
	var removed = false
	for i in range(CoopService.connected_players.size() - 1, -1, -1):
		var player = CoopService.connected_players[i]
		if typeof(player) != TYPE_ARRAY or player.size() < 2:
			continue
		var device = int(player[0])
		if not REMOTE_PLACEHOLDER_DEVICE_IDS.has(device) and not RuntimeGate.is_virtual_device(device):
			continue
		if _remote_steam_id_by_device.has(device):
			continue
		# Only placeholders this manager created; see the parent (:1186-1188).
		if not _remote_devices.has(device):
			continue
		_bo_slot_diag_log("REMOVE_UNTRACKED_REMOTE_PLACEHOLDER", "idx=" + str(i) + " device=" + str(device) + " before=" + _bo_slot_diag_players() + " maps=" + _bo_slot_diag_maps())
		CoopService.connected_players.remove(i)
		_remote_devices.erase(device)
		removed = true

	if removed:
		_sync_run_data_player_count()
		_bo_emit_connected_players_updated("generic_emit")
	return removed


# Parent: online_player_slot_manager.gd:482. The device follows the new key,
# and so does its preference.
func rebind_remote_peer_key(old_peer_key: String, new_peer_key: String) -> int:
	var player_index = .rebind_remote_peer_key(old_peer_key, new_peer_key)
	if RuntimeGate.is_extended() and _device_by_remote_steam_id.has(new_peer_key):
		_coopplus_remember_device(new_peer_key, int(_device_by_remote_steam_id[new_peer_key]))
		_coopplus_refusals.erase(new_peer_key)
	return player_index


# Parent: online_player_slot_manager.gd:320. Unchanged; afterwards the
# restored seats become the device preferences.
func apply_resume_identity_layout(layout: Array) -> bool:
	var applied = .apply_resume_identity_layout(layout)
	if applied and RuntimeGate.is_extended():
		_coopplus_remember_devices(_device_by_remote_steam_id)
	return applied


# Parent: online_player_slot_manager.gd:383. Leaving the session ends every
# preference and refusal of that session.
func online_reset_to_offline(reason: String = "") -> void:
	.online_reset_to_offline(reason)
	_coopplus_device_by_peer_key.clear()
	_coopplus_refusals.clear()
	_coopplus_run_slot_check = {}


# Parent: online_player_slot_manager.gd:257. CAP-15: after the parent took
# the first-lock snapshot, check that it holds every player of the run and
# fits the capacity. A mismatch is logged and reported; stopping the start is
# the flow guard's job (AP-012), so the lock itself is left as the parent set it.
func set_online_run_slots_locked(locked: bool) -> void:
	var first_lock: bool = locked and not _online_run_slots_locked
	.set_online_run_slots_locked(locked)
	if first_lock and RuntimeGate.is_extended():
		_coopplus_check_run_slots()


# Parent: online_player_slot_manager.gd:496 (client side: rebuild the local
# COOP layout from the host's selection_state).
# Extended mode repeats the parent's steps and diagnostics with three changes:
#   1. after the parent's lock and target checks, and before anything is
#      built, the whole layout is checked against the gate capacity. The
#      parent skipped entries once its six ids ran out (:567-569) and either
#      committed a short layout or abandoned it in a later hole fill
#      (:537-541), depending on what followed (INP-03).
#   2. a device that still cannot be found rejects the whole layout instead
#      of skipping the entry.
#   3. other players' placeholders get virtual ids, preferring the id their
#      identity held before; the preferences are updated only on commit.
# Vanilla mode only adds the capacity check in front of the parent.
func apply_host_selection_layout(selection_state: Dictionary, self_steam_id: String, host_steam_id: String = "", roster_change: bool = false) -> void:
	if not RuntimeGate.is_extended():
		var parent_skips = _is_slot_mutation_locked() and not (roster_change and get_tree().current_scene == null)
		if not parent_skips and _coopplus_layout_over_capacity(selection_state.get("players", [])):
			return
		.apply_host_selection_layout(selection_state, self_steam_id, host_steam_id, roster_change)
		return

	var t_apply_layout = OS.get_ticks_usec()
	if _is_slot_mutation_locked() and not (roster_change and get_tree().current_scene == null):
		_bo_slot_diag_log("APPLY_HOST_LAYOUT_SKIP", "reason=locked_run_topology self=" + self_steam_id + " host=" + host_steam_id + " players=" + _bo_slot_diag_players() + " maps=" + _bo_slot_diag_maps())
		return
	var players = selection_state.get("players", [])
	if typeof(players) != TYPE_ARRAY or players.empty():
		return

	var new_connected_players = []
	var new_remote_steam_id_by_device = {}
	var new_device_by_remote_steam_id = {}
	var new_remote_devices = []

	var new_local_mirrored_player_index = -1
	var matched_local_player_count = 0
	var local_entry_for_layout = _get_preferred_local_player_entry(true)
	var reserved_local_devices = _get_connected_local_gamepad_remapped_devices()
	if not local_entry_for_layout.empty():
		var local_layout_device = int(local_entry_for_layout[0])
		if not reserved_local_devices.has(local_layout_device):
			reserved_local_devices.append(local_layout_device)
	var target_client_player_index = int(selection_state.get("target_client_player_index", selection_state.get("client_player_index", -1)))
	var target_client_steam_id = str(selection_state.get("target_client_steam_id", self_steam_id))
	if target_client_steam_id == "":
		target_client_steam_id = self_steam_id

	# A layout aimed at another client is never consumed (parent :525-530).
	if self_steam_id != "" and target_client_steam_id != "" and target_client_steam_id != self_steam_id:
		_bo_slot_diag_log("APPLY_HOST_LAYOUT_REJECT", "reason=wrong_target self=" + self_steam_id + " target=" + target_client_steam_id + " target_idx=" + str(target_client_player_index) + " old_idx=" + str(_local_mirrored_player_index))
		return

	# Change 1: capacity first, nothing built yet.
	if _coopplus_layout_over_capacity(players):
		return

	for player_data in players:
		if typeof(player_data) != TYPE_DICTIONARY:
			continue

		var player_index = int(player_data.get("player_index", new_connected_players.size()))
		while new_connected_players.size() < player_index:
			# Hole fill, as in the parent: keeps the indices in place.
			var hole_device = _coopplus_pick_device("", _coopplus_devices_in_lists(new_remote_devices, new_connected_players, reserved_local_devices))
			if hole_device < 0:
				_coopplus_reject_layout_without_device(new_connected_players.size())
				return
			new_connected_players.append([hole_device, REMOTE_PLACEHOLDER_PLAYER_TYPE])
			new_remote_devices.append(hole_device)

		var steam_id = str(player_data.get("steam_id", ""))
		var is_self = self_steam_id != "" and steam_id == self_steam_id
		# Targeted packets name this client's index; used while players[]
		# entries still lack Steam ids (parent :547-553).
		if not is_self and steam_id == "" and target_client_player_index >= 0 and player_index == target_client_player_index:
			if target_client_steam_id == "" or target_client_steam_id == self_steam_id:
				is_self = true
		var device = CoopService.KEYBOARD_REMAPPED_DEVICE_ID
		var player_type = CoopService.PlayerType.KEYBOARD_AND_MOUSE

		if is_self:
			matched_local_player_count += 1
			# The local player keeps its real input device (parent :559-563).
			if not local_entry_for_layout.empty():
				device = int(local_entry_for_layout[0])
				player_type = int(local_entry_for_layout[1])
			new_local_mirrored_player_index = player_index
		else:
			var remote_key = steam_id
			if remote_key == "":
				# Only P0 can be the host when its id is missing (parent :574-580).
				if player_index == 0 and host_steam_id != "":
					remote_key = host_steam_id
				else:
					remote_key = COOPPLUS_UNKNOWN_REMOTE_PREFIX + str(player_index)
			# Changes 2 and 3: identity-bound virtual id, or reject the layout.
			device = _coopplus_pick_device(remote_key, _coopplus_devices_in_lists(new_remote_devices, new_connected_players, reserved_local_devices))
			if device < 0:
				_coopplus_reject_layout_without_device(new_connected_players.size())
				return
			player_type = REMOTE_PLACEHOLDER_PLAYER_TYPE
			new_remote_devices.append(device)
			new_remote_steam_id_by_device[device] = remote_key
			new_device_by_remote_steam_id[remote_key] = device

		new_connected_players.append([device, player_type])

	if new_connected_players.empty():
		_bo_slot_diag_log("APPLY_HOST_LAYOUT_SKIP", "reason=new_empty self=" + self_steam_id + " host=" + host_steam_id + " players=" + _bo_slot_diag_players())
		return

	if matched_local_player_count != 1 or new_local_mirrored_player_index < 0 or new_local_mirrored_player_index >= new_connected_players.size():
		_bo_slot_diag_log("APPLY_HOST_LAYOUT_REJECT", "reason=invalid_local_slot self=" + self_steam_id + " host=" + host_steam_id + " target=" + target_client_steam_id + " target_idx=" + str(target_client_player_index) + " matched=" + str(matched_local_player_count) + " new_idx=" + str(new_local_mirrored_player_index) + " old_idx=" + str(_local_mirrored_player_index) + " incoming=" + str(players))
		return

	# No global side effect before this point (parent :595-596).
	_ensure_coop_mode_if_possible()

	var connected_players_unchanged = _connected_players_match(new_connected_players)
	if not connected_players_unchanged:
		_bo_slot_diag_log("APPLY_HOST_LAYOUT_CHANGE", "self=" + self_steam_id + " host=" + host_steam_id + " new=" + str(new_connected_players) + " old=" + _bo_slot_diag_players())

	_local_mirrored_steam_id = self_steam_id
	_local_mirrored_player_index = new_local_mirrored_player_index
	_mirrored_connected_players = _duplicate_connected_players(new_connected_players)
	_remote_steam_id_by_device = new_remote_steam_id_by_device
	_device_by_remote_steam_id = new_device_by_remote_steam_id
	_remote_devices = new_remote_devices
	_host_player_joined_by_manager = false
	_coopplus_remember_devices(new_device_by_remote_steam_id)

	# Focus/ready packets reuse selection_state; rebuild only on a real layout
	# change (parent :610-617).
	if connected_players_unchanged:
		_sync_run_data_player_count()
		_bo_slot_diag_cost("apply_host_selection_layout_unchanged", t_apply_layout)
		return

	CoopService.connected_players.clear()
	for player in new_connected_players:
		CoopService.connected_players.append(player)

	_sync_run_data_player_count()
	_bo_emit_connected_players_updated("generic_emit")
	_refresh_current_character_selection_layout()


# Number of slots the parent's loop builds from players, holes included:
# an entry lands at its player_index when that is beyond the slots built so
# far, otherwise it is appended (parent :536-543).
func _coopplus_layout_slot_count(players: Array) -> int:
	var count := 0
	for player_data in players:
		if typeof(player_data) != TYPE_DICTIONARY:
			continue
		var player_index := int(player_data.get("player_index", count))
		if player_index > count:
			count = player_index
		count += 1
	return count


func _coopplus_layout_over_capacity(players) -> bool:
	if typeof(players) != TYPE_ARRAY:
		return false
	var slots := _coopplus_layout_slot_count(players)
	var capacity := int(RuntimeGate.capacity())
	if slots <= capacity:
		return false
	_coopplus_log_limited(COOPPLUS_LAYOUT_OVER_CAPACITY, "host selection layout rejected as a whole: %d slots, capacity %d" % [slots, capacity])
	return true


func _coopplus_reject_layout_without_device(slot: int) -> void:
	_coopplus_log_limited(COOPPLUS_LAYOUT_NO_DEVICE, "host selection layout rejected as a whole: no free virtual device for slot %d" % slot)


# Device ids a new remote seat must not take: every id in the live layout
# and every id this manager handed out.
func _coopplus_devices_in_use() -> Dictionary:
	return _coopplus_devices_in_lists(_remote_devices, CoopService.connected_players, [])


func _coopplus_devices_in_lists(remote_devices: Array, connected_players: Array, reserved_devices: Array) -> Dictionary:
	var used := {}
	for device in remote_devices:
		used[int(device)] = true
	for device in reserved_devices:
		used[int(device)] = true
	for player in connected_players:
		if typeof(player) == TYPE_ARRAY and player.size() > 0:
			used[int(player[0])] = true
	return used


# Virtual id for a remote seat. First choice: the id this peer held before,
# if free. Then a free id no other peer held. Then any free id, which takes
# the preference from the peer that held it. -1 when every id is in use.
# peer_key "" (holes, Continue layout) only gets the last two choices.
func _coopplus_pick_device(peer_key: String, used: Dictionary) -> int:
	var ids = RuntimeGate.virtual_device_ids()
	if peer_key != "" and _coopplus_device_by_peer_key.has(peer_key):
		var own := int(_coopplus_device_by_peer_key[peer_key])
		if ids.has(own) and not used.has(own):
			return own
	var held_by_others := {}
	for key in _coopplus_device_by_peer_key:
		if key != peer_key:
			held_by_others[int(_coopplus_device_by_peer_key[key])] = true
	for id in ids:
		if not used.has(int(id)) and not held_by_others.has(int(id)):
			return int(id)
	for id in ids:
		if not used.has(int(id)):
			return int(id)
	return COOPPLUS_NO_DEVICE


# Records device as the preference of peer_key; any other peer that had it
# loses it, so each id has at most one owner in the map.
func _coopplus_remember_device(peer_key: String, device: int) -> void:
	if peer_key == "" or peer_key.begins_with(COOPPLUS_UNKNOWN_REMOTE_PREFIX) or not RuntimeGate.is_virtual_device(device):
		return
	for key in _coopplus_device_by_peer_key.keys():
		if key != peer_key and int(_coopplus_device_by_peer_key[key]) == device:
			_coopplus_device_by_peer_key.erase(key)
	_coopplus_device_by_peer_key[peer_key] = device


func _coopplus_remember_devices(device_by_peer_key: Dictionary) -> void:
	for peer_key in device_by_peer_key:
		_coopplus_remember_device(str(peer_key), int(device_by_peer_key[peer_key]))


# Logs a refused seat (counts only, no identity: R21), keeps it queryable
# and tells the session layer once per peer and reason. Returns the parent's
# failure value -1.
func _coopplus_refuse_seat(peer_key: String, reason: String) -> int:
	var known: bool = str(_coopplus_refusals.get(peer_key, "")) == reason
	if not known:
		if _coopplus_refusals.size() >= COOPPLUS_MAX_TRACKED_REFUSALS and not _coopplus_refusals.has(peer_key):
			_coopplus_refusals.clear()
		_coopplus_refusals[peer_key] = reason
		call_deferred("emit_signal", "coopplus_remote_slot_rejected", peer_key, reason)
	_coopplus_log_limited(reason, "remote seat refused (%s): remote %d/%d, players %d/%d" % [
		reason,
		_remote_devices.size(),
		int(RuntimeGate.max_remote_players()),
		CoopService.connected_players.size(),
		int(RuntimeGate.capacity()),
	])
	return -1


func _coopplus_check_run_slots() -> void:
	var snapshot_count := get_online_run_slot_snapshot_count()
	var run_players := int(RunData.get_player_count())
	var capacity := int(RuntimeGate.capacity())
	var reason := ""
	if snapshot_count < 0:
		reason = COOPPLUS_RUN_SNAPSHOT_MISSING
	elif snapshot_count > capacity:
		reason = COOPPLUS_RUN_SNAPSHOT_OVER_CAPACITY
	elif snapshot_count != run_players:
		reason = COOPPLUS_RUN_SNAPSHOT_MISMATCH
	_coopplus_run_slot_check = {
		"ok": reason == "",
		"reason": reason,
		"snapshot": snapshot_count,
		"run_players": run_players,
		"capacity": capacity,
	}
	if reason == "":
		return
	# Warning, not error: extension code stays free of ERROR lines (LIFE-03),
	# and a Continue that is still waiting for a player can hit this too.
	ModLoaderLog.warning("online run locked with an inconsistent slot snapshot (%s): snapshot %d, run players %d, capacity %d" % [reason, snapshot_count, run_players, capacity], COOPPLUS_MOD_ID)
	call_deferred("emit_signal", "coopplus_run_slot_check_failed", reason, _coopplus_run_slot_check.duplicate())


# At most one line per reason and interval; the next line says how many were
# skipped. Reasons are the constants above, so the tables stay small.
func _coopplus_log_limited(reason: String, message: String) -> void:
	var now := OS.get_ticks_msec()
	if _coopplus_log_msec.has(reason) and now - int(_coopplus_log_msec[reason]) < COOPPLUS_LOG_INTERVAL_MSEC:
		_coopplus_log_suppressed[reason] = int(_coopplus_log_suppressed.get(reason, 0)) + 1
		return
	var suppressed := int(_coopplus_log_suppressed.get(reason, 0))
	_coopplus_log_msec[reason] = now
	_coopplus_log_suppressed[reason] = 0
	if suppressed > 0:
		message += " (%d similar lines suppressed)" % suppressed
	ModLoaderLog.warning(message, COOPPLUS_MOD_ID)
