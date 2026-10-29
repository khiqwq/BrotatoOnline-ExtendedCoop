extends Node
# AP-006 capacity probe (debug/ only, never packaged). Started by mod_main when
# the game runs with --coopplus-capacity-probe. Once the title screen has
# settled it drives Brotato Online's host slot path WITHOUT a network session
# and writes user://coopplus_probe/capacity.json, then prints one line
#   COOPPLUS_CAPACITY_PROBE done|failed kind=capacity|observe mode=<extended|vanilla> ...
# --coopplus-probe-quit exits afterwards. --coopplus-probe-expect=extended|vanilla
# adds a check on the gate mode (for runs that must be extended, or must not).
# Run it without --coopplus-probe when quitting: the lifecycle probe quits on
# its own timer and could cut this run short.
#
# Entry point: BrotatoOnlineOnlinePlayerSlotManager.online_sync_remote_steam_ids,
# which SessionManager calls on the host with its whole remote peer-key list on
# every lobby/connection change (session_manager.gd:2393) and which adds each
# new key through _add_remote_steam_id (online_player_slot_manager.gd:279-317,
# 745-769; CAP-08, INP-01). Removal goes through the same call with an empty
# list (_remove_remote_steam_id) and then online_reset_to_offline, the path BO
# takes when the host leaves its lobby.
# Deviation from a real host: no SessionManager, lobby or transport state is set
# up and peer keys are fake ("lan:coopplus-capacity-probe-N"). The slot path
# only needs an unlocked slot topology, which the title screen has, and
# switches to COOP itself (_ensure_coop_mode_if_possible). The root meta
# "brotato_online_session_active" stays false, so BO's 500 ms restore guard and
# joypad migration stay idle exactly as before a lobby exists. Session-level
# gates (CAP-02 admission, Steam/LAN member limits) are NOT exercised here.
#
# Checks (expectations follow RuntimeGate: capacity 8 extended, 4 vanilla):
#   joined.*        one sync with 7 remote keys -> min(8, capacity) players,
#                   host local at P1, devices unique, remote devices virtual
#                   (extended) / BO placeholders (vanilla), RunData count equal
#   held.*          layout unchanged after HOLD_SEC (> one restore interval)
#   input_map.*     every per-device action base exists for every virtual id
#                   with no physical event (extended) / none exists (vanilla)
#   isolation.*     Input.action_press on one remote device leaves every other
#                   device, the plain action and the other movement vector at 0
#   bo_injection.*  all remote players at once through BO's host injection
#                   (online_input_manager.gd:112-143), one direction each: every
#                   device reads back only its own movement, host and local ids
#                   read zero, clear_remote_inputs releases everything
#   ninth.*         an 8th remote key (9th player) is refused by the sync path
#                   and by a direct _add_remote_steam_id; layout unchanged;
#                   extended: listed by coopplus_get_remote_slot_refusals()
#   removed.*       empty sync -> exactly one local player, RunData count 1
#   reset.*         online_reset_to_offline -> connected players as before
#
# --coopplus-probe-observe=<sec> replaces all of the above with a passive run:
# nothing is driven, the probe only checks after <sec> seconds that the title
# screen is still current and the offline slot state unchanged, and writes
# user://coopplus_probe/observe.json (title screen with production code only).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const REPORT_DIR := "user://coopplus_probe"
const REPORT_PATH := "user://coopplus_probe/capacity.json"
const LINE_PREFIX := "COOPPLUS_CAPACITY_PROBE"
const TITLE_SCENE := "res://ui/menus/title_screen/title_screen.tscn"
const SLOT_MANAGER_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlineOnlinePlayerSlotManager"
const INPUT_MANAGER_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlineOnlineInputManager"
const SESSION_ACTIVE_META := "brotato_online_session_active"
const EXPECT_PREFIX := "--coopplus-probe-expect="
const OBSERVE_PREFIX := "--coopplus-probe-observe="
const OBSERVE_REPORT_PATH := "user://coopplus_probe/observe.json"
const SETTLE_MSEC := 3000
const TITLE_TIMEOUT_MSEC := 90000
# Longer than the slot manager's RESTORE_CHECK_INTERVAL_MSEC (500).
const HOLD_SEC := 1.2
const REMOTE_JOINS := 7
const PEER_KEY_FORMAT := "lan:coopplus-capacity-probe-%d"
# Remapped ids vanilla gives local devices (CoopService.REMAP_END = 8).
const LOCAL_REMAPPED_DEVICES := [0, 1, 2, 3, 4, 5, 6, 7]
const ISOLATION_PREFIX := "button_move_"
# Per-device actions BO injects for remote players (online_input_manager.gd:150-152)
# or vanilla reads per device (CoopService._input, Utils.is_player_action_pressed).
const CORE_ACTION_BASES := [
	"button_move_left", "button_move_right", "button_move_up", "button_move_down",
	"analog_move_left", "analog_move_right", "analog_move_up", "analog_move_down",
	"rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down",
	"ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left", "ui_right",
]
const REQUIRED_SLOT_API := [
	"online_sync_remote_steam_ids", "online_reset_to_offline", "is_remote_player_index",
	"get_remote_steam_id", "get_player_index_for_steam_id", "are_online_run_slots_locked",
]

var _quit_after := false
var _expect_mode := ""
var _observe_sec := 0.0
var _report_path := REPORT_PATH
var _started_msec := 0
var _title_seen_msec := -1
var _running := false
var _checks := {}
var _report := {}


func _ready() -> void:
	_quit_after = "--coopplus-probe-quit" in OS.get_cmdline_args()
	for arg in OS.get_cmdline_args():
		if arg.begins_with(EXPECT_PREFIX):
			_expect_mode = arg.substr(EXPECT_PREFIX.length())
		elif arg.begins_with(OBSERVE_PREFIX):
			_observe_sec = max(0.0, arg.substr(OBSERVE_PREFIX.length()).to_float())
	if _observe_sec > 0.0:
		_report_path = OBSERVE_REPORT_PATH
	_started_msec = OS.get_ticks_msec()
	print("%s waiting for the title screen" % LINE_PREFIX)


func _process(_delta: float) -> void:
	if _running:
		return
	var now := OS.get_ticks_msec()
	if _title_seen_msec < 0:
		if _is_title_screen():
			_title_seen_msec = now
		elif now - _started_msec > TITLE_TIMEOUT_MSEC:
			_running = true
			set_process(false)
			_report = _header()
			_finish("title_screen_timeout")
		return
	if now - _title_seen_msec < SETTLE_MSEC:
		return
	_running = true
	set_process(false)
	if _observe_sec > 0.0:
		_observe()
	else:
		_run()


# Passive: reads state before and after the wait, calls nothing that changes it.
func _observe() -> void:
	_report = _header()
	_report["observe_sec"] = _observe_sec
	var slot_manager = get_node_or_null(SLOT_MANAGER_PATH)
	_report["chains"] = {
		"slot_manager": _script_levels(slot_manager),
		"coop_service": _script_levels(get_node_or_null("/root/CoopService")),
		"input_service": _script_levels(get_node_or_null("/root/InputService")),
	}
	var error := _precondition_error(slot_manager)
	if error != "":
		_finish(error)
		return
	if _expect_mode != "":
		_check("gate.mode", _expect_mode, _mode())
	var before := _capture(slot_manager)
	yield(get_tree().create_timer(_observe_sec), "timeout")
	var after := _capture(slot_manager)
	_report["steps"] = {"before": before, "after": after}
	_report["scene_after"] = _scene_path()
	_check("observe.title_screen_current", TITLE_SCENE, _scene_path())
	_check("observe.state_unchanged", var2str(_comparable(before)), var2str(_comparable(after)))
	_check("observe.no_session", false, bool(get_tree().root.get_meta(SESSION_ACTIVE_META, false)))
	_check("coop_service.max_players_unchanged", 4, int(CoopService.get_max_players()))
	_finish("")


func _run() -> void:
	_report = _header()
	var slot_manager = get_node_or_null(SLOT_MANAGER_PATH)
	_report["chains"] = {
		"slot_manager": _script_levels(slot_manager),
		"coop_service": _script_levels(get_node_or_null("/root/CoopService")),
		"input_service": _script_levels(get_node_or_null("/root/InputService")),
	}
	var error := _precondition_error(slot_manager)
	if error != "":
		_finish(error)
		return
	if _expect_mode != "":
		_check("gate.mode", _expect_mode, _mode())
	# CAP-10/INP-02: never raised globally (main.gd and selection have 4 panels).
	_check("coop_service.max_players_unchanged", 4, int(CoopService.get_max_players()))

	var steps := {}
	_report["steps"] = steps
	var baseline := _capture(slot_manager)
	steps["baseline"] = baseline
	var keys := []
	for i in range(1, REMOTE_JOINS + 1):
		keys.append(PEER_KEY_FORMAT % i)

	# 1. Seven remote players join in one sync, as SessionManager hands them over.
	slot_manager.online_sync_remote_steam_ids(keys)
	var joined := _capture(slot_manager)
	steps["joined"] = joined
	_check_joined(joined, keys)

	# 2. The layout must survive the slot manager's periodic checks.
	yield(get_tree().create_timer(HOLD_SEC), "timeout")
	var held := _capture(slot_manager)
	steps["held"] = held
	_check("held.layout_unchanged", joined["players"], held["players"])
	_check("held.run_data_player_count", joined["run_data_player_count"], held["run_data_player_count"])

	# 3. Virtual per-device actions; 4. one device's input does not reach another.
	_report["input_map"] = _check_input_map()
	_report["isolation"] = _check_isolation(held)
	_report["bo_injection"] = _check_bo_injection(held)

	# 5. The ninth player (eighth remote key) is refused.
	var ninth_key: String = PEER_KEY_FORMAT % (REMOTE_JOINS + 1)
	var with_ninth := keys.duplicate()
	with_ninth.append(ninth_key)
	slot_manager.online_sync_remote_steam_ids(with_ninth)
	var after_sync := _capture(slot_manager)
	steps["ninth_sync"] = after_sync
	_check("ninth.sync_layout_unchanged", held["players"], after_sync["players"])
	_check("ninth.sync_not_seated", -1, int(slot_manager.get_player_index_for_steam_id(ninth_key)))
	var direct = null
	if slot_manager.has_method("_add_remote_steam_id"):
		direct = slot_manager.call("_add_remote_steam_id", ninth_key)
	_check("ninth.direct_add_refused", -1, int(direct) if typeof(direct) == TYPE_INT else direct)
	var after_direct := _capture(slot_manager)
	steps["ninth_direct"] = after_direct
	_check("ninth.direct_layout_unchanged", held["players"], after_direct["players"])
	_check("ninth.run_data_player_count", held["run_data_player_count"], after_direct["run_data_player_count"])
	# The slot extension reports refusals instead of the parent's bare -1 (CAP-08).
	if RuntimeGate.is_extended() and slot_manager.has_method("coopplus_get_remote_slot_refusals"):
		var refusals = slot_manager.coopplus_get_remote_slot_refusals()
		var listed := {}
		for key in refusals:
			listed[_safe_key(str(key))] = str(refusals[key])
		_report["refusals"] = listed
		_check("ninth.refusal_reported", true, listed.has(ninth_key))

	# 6. Every fake player leaves; then BO's leave-lobby reset.
	slot_manager.online_sync_remote_steam_ids([])
	var removed := _capture(slot_manager)
	steps["removed"] = removed
	_check("removed.one_player", 1, removed["players"].size())
	_check("removed.only_local", [false], removed["remote"])
	_check("removed.host_kept", _first(joined["players"]), _first(removed["players"]))
	_check("removed.run_data_player_count", 1, removed["run_data_player_count"])
	slot_manager.online_reset_to_offline("coopplus_capacity_probe")
	var reset := _capture(slot_manager)
	steps["reset"] = reset
	_check("reset.players_match_baseline", baseline["players"], reset["players"])
	_report["baseline_restored_by_upstream"] = var2str(_comparable(baseline)) == var2str(_comparable(reset))
	if not _report["baseline_restored_by_upstream"]:
		_restore(baseline)
		steps["restored_by_probe"] = _capture(slot_manager)
	_finish("")


func _check_joined(joined: Dictionary, keys: Array) -> void:
	var players: Array = joined["players"]
	var expected_total := int(min(1 + keys.size(), RuntimeGate.capacity()))
	_check("joined.player_count", expected_total, players.size())
	_check("joined.run_data_player_count", players.size(), joined["run_data_player_count"])
	_check("joined.coop_run", true, joined["is_coop_run"])
	if players.empty():
		return
	_check("joined.host_local_p1", false, joined["remote"][0])
	var devices := []
	var remote_devices := []
	var seated_keys := []
	for i in range(players.size()):
		devices.append(int(players[i][0]))
		if joined["remote"][i]:
			remote_devices.append(int(players[i][0]))
			seated_keys.append(joined["remote_keys"][i])
	var expected_keys := []
	for i in range(expected_total - 1):
		expected_keys.append(keys[i])
	_check("joined.remote_keys_in_order", expected_keys, seated_keys)
	_check("joined.devices_unique", devices.size(), _unique(devices).size())
	_check("joined.host_device_not_virtual", false, RuntimeGate.is_virtual_device(devices[0]))
	var virtual := []
	for d in remote_devices:
		if RuntimeGate.is_virtual_device(d):
			virtual.append(d)
	if RuntimeGate.is_extended():
		_check("joined.remote_devices_virtual", remote_devices, virtual)
		_check("joined.remote_devices_from_gate", RuntimeGate.virtual_device_ids(), _sorted(remote_devices))
	else:
		# Vanilla gate: BO's own placeholders, untouched (R08).
		_check("joined.remote_devices_not_virtual", [], virtual)


# Extended: every per-device action base (the names vanilla creates for remapped
# device 1) exists for every virtual id and carries no physical event (INP-05).
# Vanilla: no action exists for the would-be virtual ids.
func _check_input_map() -> Dictionary:
	var bases := _per_device_action_bases()
	var out := {"base_count": bases.size(), "ids": {}}
	_check("input_map.bases_found", true, bases.size() > 0)
	if RuntimeGate.is_extended():
		var missing_total := 0
		var core_missing := []
		var with_events := []
		for id in RuntimeGate.virtual_device_ids():
			var missing := []
			var evented := []
			for base in bases:
				var action := "%s_%d" % [base, id]
				if not InputMap.has_action(action):
					missing.append(base)
				elif InputMap.get_action_list(action).size() > 0:
					evented.append(base)
			for base in CORE_ACTION_BASES:
				if bases.has(base) and missing.has(base):
					core_missing.append("%s_%d" % [base, id])
			for base in evented:
				with_events.append("%s_%d" % [base, id])
			missing_total += missing.size()
			out["ids"][str(id)] = {"missing": missing, "with_events": evented}
		_check("input_map.core_actions_present", [], core_missing)
		_check("input_map.all_bases_present", 0, missing_total)
		_check("input_map.no_physical_events", [], with_events)
	else:
		var extra := []
		for offset in range(RuntimeGate.EXTENDED_CAPACITY - 1):
			var id: int = RuntimeGate.VIRTUAL_DEVICE_BASE + offset
			for base in bases:
				if InputMap.has_action("%s_%d" % [base, id]):
					extra.append("%s_%d" % [base, id])
		out["unexpected"] = extra
		_check("input_map.no_virtual_actions", [], extra)
	return out


# Presses <prefix>left on the first remote device only, reads every other device
# the way the game does (Input.get_action_strength / PlayerMovementBehavior's
# Input.get_vector), then releases.
func _check_isolation(layout: Dictionary) -> Dictionary:
	var all_devices := []
	var remote_devices := []
	for i in range(layout["players"].size()):
		var d := int(layout["players"][i][0])
		all_devices.append(d)
		if layout["remote"][i]:
			remote_devices.append(d)
	var out := {"prefix": ISOLATION_PREFIX}
	if remote_devices.size() < 2:
		_check("isolation.two_remote_devices", true, false)
		return out
	var a := int(remote_devices[0])
	var b := int(remote_devices[1])
	var pressed := "%sleft_%d" % [ISOLATION_PREFIX, a]
	out["pressed"] = pressed
	if not InputMap.has_action(pressed):
		_check("isolation.action_exists", true, false)
		return out
	var watched := []
	for d in all_devices + LOCAL_REMAPPED_DEVICES:
		if d != a and not watched.has(d):
			watched.append(d)
	Input.action_press(pressed, 1.0)
	var own := Input.get_action_strength(pressed)
	var strengths := {}
	var leaked := []
	for d in watched:
		var action := "%sleft_%d" % [ISOLATION_PREFIX, d]
		if InputMap.has_action(action):
			var s := Input.get_action_strength(action)
			strengths[str(d)] = s
			if s != 0.0:
				leaked.append(d)
	var plain_action := ISOLATION_PREFIX + "left"
	var plain := 0.0
	if InputMap.has_action(plain_action):
		plain = Input.get_action_strength(plain_action)
	var vec_a = _prefix_vector(ISOLATION_PREFIX, a)
	var vec_b = _prefix_vector(ISOLATION_PREFIX, b)
	Input.action_release(pressed)
	var after := Input.get_action_strength(pressed)
	out["own_strength"] = own
	out["other_strengths"] = strengths
	out["plain_strength"] = plain
	out["vector_pressed"] = str(vec_a)
	out["vector_other"] = str(vec_b)
	out["after_release"] = after
	_check("isolation.own_strength", 1.0, own)
	_check("isolation.no_leak", [], leaked)
	_check("isolation.plain_action_idle", 0.0, plain)
	_check("isolation.pressed_device_moves_left", true, typeof(vec_a) == TYPE_VECTOR2 and vec_a.is_equal_approx(Vector2.LEFT))
	_check("isolation.other_device_still", true, typeof(vec_b) == TYPE_VECTOR2 and vec_b == Vector2.ZERO)
	_check("isolation.released", 0.0, after)
	return out


# BO's host path for remote battle input: receive_battle_input keeps one entry
# per player_index in _remote_input_by_player (online_input_manager.gd:66-93) and
# _apply_remote_inputs_to_official_actions presses <prefix><dir>_<device> on that
# player's device (:112-143). receive_battle_input itself needs a host session
# (_is_host), so the probe writes the entries in the same shape, gives every
# remote player its own direction (45 degrees apart, every component above BO's
# ACTION_DEADZONE), applies once and reads every device back the way the game
# moves a player.
func _check_bo_injection(layout: Dictionary) -> Dictionary:
	var out := {}
	var manager = get_node_or_null(INPUT_MANAGER_PATH)
	if manager == null or not manager.has_method("_apply_remote_inputs_to_official_actions") or not manager.has_method("clear_remote_inputs") or typeof(manager.get("_remote_input_by_player")) != TYPE_DICTIONARY:
		_check("bo_injection.input_manager_found", true, false)
		return out
	var expected := {}
	var entries := {}
	var remote_count := 0
	var now := OS.get_ticks_msec()
	for i in range(layout["players"].size()):
		var device := int(layout["players"][i][0])
		var dir := Vector2.ZERO
		if layout["remote"][i]:
			dir = Vector2.RIGHT.rotated(remote_count * PI / 4.0)
			remote_count += 1
			entries[i] = {"steam_id": PEER_KEY_FORMAT % remote_count, "move": dir, "aim": Vector2.ZERO, "share_aim": false, "tick": 1, "last_seen_msec": now}
		expected[device] = dir
	for d in LOCAL_REMAPPED_DEVICES:
		if not expected.has(d):
			expected[d] = Vector2.ZERO
	manager.set("_remote_input_by_player", entries)
	manager.call("_apply_remote_inputs_to_official_actions")
	var read := {}
	var wrong := []
	for d in expected:
		var v = _player_movement(int(d))
		read[str(d)] = {"expected": str(expected[d]), "actual": str(v)}
		if typeof(v) != TYPE_VECTOR2 or v.distance_to(expected[d]) > 0.01:
			wrong.append(int(d))
	manager.call("clear_remote_inputs")
	var stuck := []
	for d in expected:
		var v = _player_movement(int(d))
		if typeof(v) != TYPE_VECTOR2 or v != Vector2.ZERO:
			stuck.append(int(d))
	wrong.sort()
	stuck.sort()
	out["remote_players"] = remote_count
	out["devices"] = read
	_check("bo_injection.remote_players", int(min(REMOTE_JOINS, RuntimeGate.max_remote_players())), remote_count)
	_check("bo_injection.each_device_own_movement", [], wrong)
	_check("bo_injection.released", [], stuck)
	return out


# PlayerMovementBehavior.get_movement in a coop run (player_movement_behavior.gd:19-24):
# the longer of the analog and button vectors; null when an action is missing.
func _player_movement(device: int):
	var analog = _prefix_vector("analog_move_", device)
	var button = _prefix_vector("button_move_", device)
	if typeof(analog) != TYPE_VECTOR2 or typeof(button) != TYPE_VECTOR2:
		return null
	return analog if analog.length() > button.length() else button


# PlayerMovementBehavior.get_vector_for_input_prefix in a coop run; null when
# one of the four actions is missing.
func _prefix_vector(prefix: String, device: int):
	var names := []
	for dir in ["left", "right", "up", "down"]:
		var action := "%s%s_%d" % [prefix, dir, device]
		if not InputMap.has_action(action):
			return null
		names.append(action)
	return Input.get_vector(names[0], names[1], names[2], names[3])


# Bases that vanilla copies for every remapped device (InputService._copy_device_actions).
func _per_device_action_bases() -> Array:
	var bases := []
	for action in InputMap.get_actions():
		var name := str(action)
		if InputMap.has_action(name + "_1"):
			bases.append(name)
	bases.sort()
	return bases


func _capture(slot_manager) -> Dictionary:
	var players := []
	var remote := []
	var remote_keys := []
	for i in range(CoopService.connected_players.size()):
		var p = CoopService.connected_players[i]
		if typeof(p) == TYPE_ARRAY and p.size() >= 2:
			players.append([int(p[0]), int(p[1])])
		else:
			players.append(str(p))
		remote.append(bool(slot_manager.is_remote_player_index(i)))
		remote_keys.append(_safe_key(str(slot_manager.get_remote_steam_id(i))))
	return {
		"players": players,
		"remote": remote,
		"remote_keys": remote_keys,
		"run_data_player_count": int(RunData.get_player_count()),
		"is_coop_run": bool(RunData.is_coop_run),
		"play_mode": int(RunData.play_mode),
		"listening_for_inputs": bool(CoopService.listening_for_inputs),
	}


# Puts back what BO's reset did not (only reached when it differs).
func _restore(baseline: Dictionary) -> void:
	var players := []
	for p in baseline["players"]:
		if typeof(p) == TYPE_ARRAY:
			players.append(p.duplicate())
	CoopService.connected_players = players
	RunData.set_player_count(int(baseline["run_data_player_count"]))
	RunData.play_mode = int(baseline["play_mode"])
	RunData.set_coop_run(bool(baseline["is_coop_run"]))
	CoopService.listening_for_inputs = bool(baseline["listening_for_inputs"])
	CoopService.emit_signal("connected_players_updated", CoopService.connected_players)


func _precondition_error(slot_manager) -> String:
	if not _is_title_screen():
		return "not_on_title_screen"
	if slot_manager == null:
		return "slot_manager_missing"
	for method in REQUIRED_SLOT_API:
		if not slot_manager.has_method(method):
			return "slot_manager_api_missing:" + method
	if bool(get_tree().root.get_meta(SESSION_ACTIVE_META, false)):
		return "online_session_active"
	if bool(slot_manager.are_online_run_slots_locked()):
		return "run_slots_locked"
	return ""


func _header() -> Dictionary:
	return {
		"mode": _mode(),
		"gate": RuntimeGate.decision(),
		"block_reasons": RuntimeGate.block_reasons(),
		"capacity": RuntimeGate.capacity(),
		"max_remote_players": RuntimeGate.max_remote_players(),
		"virtual_device_ids": RuntimeGate.virtual_device_ids(),
		"scene": _scene_path(),
		"connected_joypads": Input.get_connected_joypads(),
		"t_msec": OS.get_ticks_msec(),
	}


func _finish(error: String) -> void:
	var failed := []
	for name in _checks:
		if not _checks[name]["ok"]:
			failed.append(name)
	failed.sort()
	var ok := error == "" and failed.empty() and not _checks.empty()
	_report["error"] = error
	_report["checks"] = _checks
	_report["failed_checks"] = failed
	_report["result"] = "done" if ok else "failed"
	var dir := Directory.new()
	var _mk = dir.make_dir_recursive(REPORT_DIR)
	var f := File.new()
	var written := false
	if f.open(_report_path, File.WRITE) == OK:
		f.store_string(JSON.print(_report, "\t"))
		f.close()
		written = true
	var kind := "observe" if _observe_sec > 0.0 else "capacity"
	var line := "%s %s kind=%s mode=%s capacity=%d checks=%d" % [LINE_PREFIX, _report["result"], kind, _mode(), RuntimeGate.capacity(), _checks.size()]
	if not failed.empty():
		line += " failed=" + ",".join(PoolStringArray(failed))
	if error != "":
		line += " error=" + error
	if not written:
		line += " report_not_written"
	print(line)
	if _quit_after:
		get_tree().quit()


func _check(name: String, expected, actual) -> void:
	_checks[name] = {"ok": typeof(expected) == typeof(actual) and var2str(expected) == var2str(actual), "expected": expected, "actual": actual}


func _mode() -> String:
	return "extended" if RuntimeGate.is_extended() else "vanilla"


func _is_title_screen() -> bool:
	return _scene_path() == TITLE_SCENE


func _scene_path() -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return ""
	return tree.current_scene.filename


func _comparable(state: Dictionary) -> Dictionary:
	return {
		"players": state["players"],
		"run_data_player_count": state["run_data_player_count"],
		"is_coop_run": state["is_coop_run"],
		"play_mode": state["play_mode"],
		"listening_for_inputs": state["listening_for_inputs"],
	}


# Every level of an extended script shares the vanilla resource_path; Mod
# Loader tags each level with its file (LIFE-05).
func _script_levels(obj: Object) -> Array:
	var out := []
	if obj == null:
		return out
	var script = obj.get_script()
	while script != null:
		if script.has_meta("extension_script_path"):
			out.append(str(script.get_meta("extension_script_path")))
		elif script.resource_path != "":
			out.append(script.resource_path)
		else:
			out.append("<unnamed>")
		script = script.get_base_script()
	return out


# Fake probe keys only; real peer keys never reach the report (R21).
func _safe_key(key: String) -> String:
	return key if key == "" or key.begins_with(PEER_KEY_FORMAT.replace("%d", "")) else "<other>"


func _first(list: Array):
	return list[0] if not list.empty() else null


func _unique(list: Array) -> Array:
	var out := []
	for v in list:
		if not out.has(v):
			out.append(v)
	return out


func _sorted(list: Array) -> Array:
	var out := list.duplicate()
	out.sort()
	return out
