extends Reference
# Runtime gate for extended (5-8 player) sessions (R01, R03, R04, R07, F16, F17).
# Decided once by mod_main._init through initialize(); every extension then asks
# the static getters. Extended mode is allowed only when nothing speaks against
# it: no --coopplus-vanilla, a valid compatibility.json, the locked game /
# engine / Mod Loader versions, a running Brotato Online whose normalized
# fingerprint equals the lock, no unsupported mod, and optional mods
# (CoopFix-OnlineMouseUI, needed for mouse input in co-op, D-011) only in
# their locked version.
# Otherwise capacity stays 4 and the extensions keep upstream behaviour (R08).
# The extensions are only installed on the verified target (install_extensions):
# against a changed game or Brotato Online (e.g. a workshop auto-update) an
# override can fail to compile; its "SCRIPT ERROR ... At: res://mods-unpacked/"
# lines make CrashReporter disable every mod, BO included, on the next start
# (LIFE-03). An opt-out or an unsupported mod keeps them installed: the target
# is verified, the parents are the known ones.
# The capacity only applies to NEW sessions; nothing here changes mid-run.
# State is one Engine metadata entry. Before initialize() runs (or if the
# stored state is unusable) every getter returns the vanilla values, so a
# missing gate degrades to vanilla.
# decide() is pure (no files, no autoloads) so the rules are unit-testable;
# initialize() only gathers the facts it needs. Safe in mod_main._init: no
# scene tree, no Engine.get_main_loop(), no autoload names (Mod Loader facts
# arrive through the argument, the rule-test project has no Mod Loader).

const UpstreamFingerprint = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/upstream_fingerprint.gd")

const MOD_ID := "CoopPlus-OnlineExtendedCoop"
const META_KEY := "coopplus_runtime_gate"
# Capacity of the online room this machine is in (D-008), see set_room_capacity.
const ROOM_META_KEY := "coopplus_room_capacity"
const COMPATIBILITY_PATH := "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/compatibility.json"
const COMPATIBILITY_SCHEMA := 1
const UNPACKED_ROOT := "res://mods-unpacked"
# Mod Loader's logger, called through its script so this file also compiles
# where the ModLoaderLog class does not exist (rule tests).
const LOG_SCRIPT_PATH := "res://addons/mod_loader/api/log.gd"

const VANILLA_CAPACITY := 4
const EXTENDED_CAPACITY := 8
# First virtual input device id for remote players. Godot 3 numbers physical
# joypads 0..15 (JOYPADS_MAX), vanilla uses remapped ids 0..7 and debug
# keyboards 8..11, so ids from 16 never match a physical event, a joypad
# disconnect or InputService's echo emulation (INP-05, INP-06).
const VIRTUAL_DEVICE_BASE := 16

const DISABLE_FLAG := "--coopplus-vanilla"
const REQUIRED_UPSTREAM_ID := "six666-BrotatoOnline"
const ROLE_REQUIRED := "required"
const ROLE_NOT_SUPPORTED := "not-supported"
# May run alongside extended mode, but only byte-identical to the locked
# version (normalized_fingerprint); any other version blocks extended mode.
const ROLE_OPTIONAL := "optional"
# Mods that change co-op UI input: allowed alongside extended mode only as an
# "optional" entry of compatibility.json, refused when it omits them (R07, D-011).
const ALWAYS_CHECKED_MODS := ["CoopFix-OnlineMouseUI"]

const COMPAT_OK := "ok"
const COMPAT_MISSING := "missing"
const COMPAT_INVALID := "invalid"

const REASON_NOT_INITIALIZED := "not_initialized"
const REASON_INVALID_STATE := "invalid_gate_state"
const REASON_DISABLED := "disabled"
const REASON_COMPAT_MISSING := "compatibility_missing"
const REASON_COMPAT_INVALID := "compatibility_invalid"
const REASON_GAME_VERSION := "game_version_unverified"
const REASON_ENGINE_VERSION := "engine_version_unverified"
const REASON_MOD_LOADER_VERSION := "mod_loader_version_unverified"
const REASON_UPSTREAM_INACTIVE := "upstream_inactive"
const REASON_FINGERPRINT_UNAVAILABLE := "upstream_fingerprint_unavailable"
const REASON_FINGERPRINT_MISMATCH := "upstream_fingerprint_mismatch"
const REASON_UNSUPPORTED_MOD_PREFIX := "unsupported_mod:"

# Mod Loader view of one mod.
const MOD_RUNNING := "running"
const MOD_STOPPED := "stopped"
const MOD_UNKNOWN := "unknown"

# Fact keys of decide() that are checked against compatibility.json lists.
const VERSION_FACTS := [
	["game_version", "game_versions", REASON_GAME_VERSION],
	["engine_version", "engine_versions", REASON_ENGINE_VERSION],
	["mod_loader_version", "mod_loader_versions", REASON_MOD_LOADER_VERSION],
]
# Reasons meaning the parents our extensions were written against are not the
# verified ones; any of them keeps every extension uninstalled.
const UNVERIFIED_TARGET_REASONS := [
	REASON_COMPAT_MISSING,
	REASON_COMPAT_INVALID,
	REASON_GAME_VERSION,
	REASON_ENGINE_VERSION,
	REASON_MOD_LOADER_VERSION,
	REASON_UPSTREAM_INACTIVE,
	REASON_FINGERPRINT_UNAVAILABLE,
	REASON_FINGERPRINT_MISMATCH,
]


# --- Getters (contract used by every extension) ---------------------------

# Capacity: 8 in extended mode, else 4; inside an online room the room's
# capacity (D-008: 4 in a standard room, so every extension behaves as
# vanilla there), never above the decision's.
static func capacity() -> int:
	var state := _state()
	if state.empty():
		return VANILLA_CAPACITY
	var cap := int(state["capacity"])
	var room := room_capacity()
	if room > 0:
		cap = int(min(cap, room))
	return cap


# Network capability version from compatibility.json (capability.gd hello,
# room metadata); 0 when unknown.
static func capability_version() -> int:
	var details = _state().get("details", {})
	return int(details.get("capability_version", 0)) if typeof(details) == TYPE_DICTIONARY else 0


# What this machine supports regardless of the room: 8 when extended mode is
# verified, else 4. A host picks its room within it (room_policy.gd).
static func verified_capacity() -> int:
	var state := _state()
	return VANILLA_CAPACITY if state.empty() else int(state["capacity"])


# Set when this machine opens or joins an online room, before any remote seat
# exists, and kept for the whole room; cleared when it leaves. Without a room
# (offline play) the decision's capacity applies.
static func set_room_capacity(room_capacity: int) -> void:
	Engine.set_meta(ROOM_META_KEY, int(clamp(room_capacity, 1, 64)))


static func clear_room() -> void:
	if Engine.has_meta(ROOM_META_KEY):
		Engine.remove_meta(ROOM_META_KEY)


# 0 when this machine is in no room.
static func room_capacity() -> int:
	if not Engine.has_meta(ROOM_META_KEY):
		return 0
	var value = Engine.get_meta(ROOM_META_KEY)
	return int(value) if typeof(value) == TYPE_INT else 0


static func is_extended() -> bool:
	return capacity() > VANILLA_CAPACITY


# One player per machine (R02): every slot except the host's is remote.
static func max_remote_players() -> int:
	return capacity() - 1


# Why extended mode is off; empty when it is on.
static func block_reasons() -> Array:
	if not Engine.has_meta(META_KEY):
		return [REASON_NOT_INITIALIZED]
	var state := _state()
	if state.empty():
		return [REASON_INVALID_STATE]
	return state["reasons"].duplicate()


# Remote virtual device ids, [16..22] in extended mode, [] otherwise.
static func virtual_device_ids() -> Array:
	return _virtual_ids(capacity())


static func is_virtual_device(device: int) -> bool:
	var cap := capacity()
	return cap > VANILLA_CAPACITY and device >= VIRTUAL_DEVICE_BASE and device < VIRTUAL_DEVICE_BASE + cap - 1


static func is_initialized() -> bool:
	return not _state().empty()


# Full decision (copy) for diagnostics and probes.
static func decision() -> Dictionary:
	var state := _state()
	if state.empty():
		return _result(block_reasons(), true, {})
	return state.duplicate(true)


# --- Decision --------------------------------------------------------------

# Gathers the facts, decides and stores the result. Runs once: later calls
# return the stored decision unchanged.
# environment (from mod_main, Mod Loader data the rule tests do not have):
#   mods: {mod_id: {"loadable": bool, "active": bool}}  ModLoaderStore.mod_data
#   game_version: String                                CrashReporter.VERSION
#   mod_loader_version: String                          ModLoaderStore.MODLOADER_VERSION
static func initialize(environment: Dictionary = {}) -> Dictionary:
	if is_initialized():
		return decision()
	var result := decide(gather_inputs(environment))
	_store(result)
	_log_info(describe(result))
	return result.duplicate(true)


# inputs (every key optional; a missing fact never enables extended mode, a
# missing or empty version counts as unverified, R04):
#   cmdline_args: Array of String
#   compatibility_state: COMPAT_OK | COMPAT_MISSING | COMPAT_INVALID
#   compatibility: Dictionary        parsed compatibility.json (state "ok")
#   game_version, engine_version, mod_loader_version: String
#   fingerprints: {mod_id: UpstreamFingerprint.compute() result}
#   mods: {mod_id: {"loadable": bool, "active": bool}}   absent id = unknown
#   mod_dirs: {mod_id: bool}         res://mods-unpacked/<id> exists
# Returns {capacity, extended, max_remote_players, virtual_device_ids,
# reasons (fixed check order), install_extensions, details}.
# install_extensions is false when any UNVERIFIED_TARGET_REASONS applies,
# including a Brotato Online that is stopped while this mod still runs
# (LIFE-20): the parents our extensions stack on are not the verified ones.
static func decide(inputs: Dictionary) -> Dictionary:
	var reasons := []
	var details := {}
	var mods = inputs.get("mods", {})
	var mod_dirs = inputs.get("mod_dirs", {})
	var fingerprints = inputs.get("fingerprints", {})

	# 1. Explicit opt-out.
	var args = inputs.get("cmdline_args", [])
	if (typeof(args) == TYPE_ARRAY or typeof(args) == TYPE_STRING_ARRAY) and DISABLE_FLAG in args:
		reasons.append(REASON_DISABLED)

	# 2. compatibility.json (expected versions and fingerprints).
	var compat_state := str(inputs.get("compatibility_state", COMPAT_MISSING))
	var compat = inputs.get("compatibility", {})
	var compat_usable := false
	if compat_state == COMPAT_MISSING:
		reasons.append(REASON_COMPAT_MISSING)
	elif compat_state != COMPAT_OK:
		reasons.append(REASON_COMPAT_INVALID)
	else:
		var problem := _compatibility_problem(compat)
		if problem == "":
			compat_usable = true
		else:
			reasons.append(REASON_COMPAT_INVALID)
			details["compatibility_problem"] = problem
	details["compatibility"] = compat_state
	if compat_usable:
		details["capability_version"] = int(compat.get("network_capability_version", 0))

	# 3. Locked game / engine / Mod Loader versions (R04). An unknown version is
	# not a verified one.
	for fact in VERSION_FACTS:
		var actual := str(inputs.get(fact[0], ""))
		details[fact[0]] = actual if actual != "" else "missing"
		if compat_usable and (actual == "" or not (actual in compat[fact[1]])):
			reasons.append(fact[2])

	# 4. Required upstream: running and byte-identical to the lock (R03, F17).
	var expected := {REQUIRED_UPSTREAM_ID: ""}
	var optional := {}
	var unsupported := []
	if compat_usable:
		for entry in compat["upstream"]:
			if entry["role"] == ROLE_REQUIRED:
				expected[entry["id"]] = entry["normalized_fingerprint"]
			elif entry["role"] == ROLE_OPTIONAL:
				optional[entry["id"]] = entry["normalized_fingerprint"]
			elif entry["role"] == ROLE_NOT_SUPPORTED and not unsupported.has(entry["id"]):
				unsupported.append(entry["id"])
	for mod_id in ALWAYS_CHECKED_MODS:
		if not optional.has(mod_id) and not unsupported.has(mod_id):
			unsupported.append(mod_id)
	var upstream_details := {}
	var required_ids: Array = expected.keys()
	required_ids.sort()
	for mod_id in required_ids:
		var info := {"loader": _mod_loader_state(mods, mod_id)}
		if info["loader"] == MOD_STOPPED:
			_append_once(reasons, REASON_UPSTREAM_INACTIVE)
		var fp = fingerprints.get(mod_id) if typeof(fingerprints) == TYPE_DICTIONARY else null
		var fp_ok: bool = typeof(fp) == TYPE_DICTIONARY and bool(fp.get("ok", false)) and typeof(fp.get("fingerprint")) == TYPE_STRING
		info["actual"] = short_fingerprint(fp["fingerprint"]) if fp_ok else ""
		info["file_count"] = int(fp.get("file_count", 0)) if typeof(fp) == TYPE_DICTIONARY else 0
		info["expected"] = short_fingerprint(expected[mod_id])
		if not compat_usable:
			info["result"] = "not_checked"
		elif not fp_ok:
			info["result"] = "unavailable"
			_append_once(reasons, REASON_FINGERPRINT_UNAVAILABLE)
		elif fp["fingerprint"] != expected[mod_id]:
			info["result"] = "mismatch"
			_append_once(reasons, REASON_FINGERPRINT_MISMATCH)
		else:
			info["result"] = "match"
		upstream_details[mod_id] = info
	details["upstream"] = upstream_details

	# 5. Mods that must not run together with extended mode (R07, F16), and
	# optional ones running in a version other than the locked one.
	var optional_ids: Array = optional.keys()
	optional_ids.sort()
	var optional_running := {}
	for mod_id in optional_ids:
		if not _is_mod_running(mods, mod_dirs, mod_id):
			continue
		var fp = fingerprints.get(mod_id) if typeof(fingerprints) == TYPE_DICTIONARY else null
		var fp_ok: bool = typeof(fp) == TYPE_DICTIONARY and bool(fp.get("ok", false)) and typeof(fp.get("fingerprint")) == TYPE_STRING
		if not fp_ok:
			optional_running[mod_id] = "unavailable"
		elif fp["fingerprint"] != optional[mod_id]:
			optional_running[mod_id] = "mismatch"
		else:
			optional_running[mod_id] = "match"
			continue
		unsupported.append(mod_id)
	details["optional_running"] = optional_running
	unsupported.sort()
	var running := []
	for mod_id in unsupported:
		if _is_mod_running(mods, mod_dirs, mod_id):
			running.append(mod_id)
			reasons.append(REASON_UNSUPPORTED_MOD_PREFIX + mod_id)
	details["unsupported_running"] = running

	var install := true
	for reason in reasons:
		if UNVERIFIED_TARGET_REASONS.has(reason):
			install = false
	return _result(reasons, install, details)


# Facts for decide() from the running game. No scene tree, no autoloads.
static func gather_inputs(environment: Dictionary = {}) -> Dictionary:
	var inputs := {"cmdline_args": Array(OS.get_cmdline_args()), "engine_version": engine_version_string()}
	for key in ["game_version", "mod_loader_version"]:
		if environment.has(key) and str(environment[key]) != "":
			inputs[key] = str(environment[key])
	var mods = environment.get("mods", {})
	inputs["mods"] = mods if typeof(mods) == TYPE_DICTIONARY else {}

	var compat := _read_compatibility()
	inputs["compatibility_state"] = compat["state"]
	inputs["compatibility"] = compat["data"]

	var required := [REQUIRED_UPSTREAM_ID]
	var optional := []
	var unsupported := ALWAYS_CHECKED_MODS.duplicate()
	if compat["state"] == COMPAT_OK and _compatibility_problem(compat["data"]) == "":
		for entry in compat["data"]["upstream"]:
			if entry["role"] == ROLE_REQUIRED and not required.has(entry["id"]):
				required.append(entry["id"])
			elif entry["role"] == ROLE_OPTIONAL and not optional.has(entry["id"]):
				optional.append(entry["id"])
			elif entry["role"] == ROLE_NOT_SUPPORTED and not unsupported.has(entry["id"]):
				unsupported.append(entry["id"])
	var fingerprints := {}
	var dirs := {}
	var dir := Directory.new()
	for mod_id in required:
		fingerprints[mod_id] = UpstreamFingerprint.compute(mod_id)
	for mod_id in optional:
		dirs[mod_id] = dir.dir_exists(UNPACKED_ROOT.plus_file(mod_id))
		if dirs[mod_id]:
			fingerprints[mod_id] = UpstreamFingerprint.compute(mod_id)
	inputs["fingerprints"] = fingerprints
	for mod_id in unsupported:
		dirs[mod_id] = dir.dir_exists(UNPACKED_ROOT.plus_file(mod_id))
	inputs["mod_dirs"] = dirs
	return inputs


# Same format as project.lock.json game.engine_version
# ("3.7.dev.custom_build.74e86be54"); patch is omitted when 0, like Godot does.
static func engine_version_string() -> String:
	var v := Engine.get_version_info()
	var text := "%d.%d" % [int(v.get("major", 0)), int(v.get("minor", 0))]
	if int(v.get("patch", 0)) > 0:
		text += ".%d" % int(v.get("patch", 0))
	return text + ".%s.%s.%s" % [str(v.get("status", "")), str(v.get("build", "")), str(v.get("hash", "")).substr(0, 9)]


static func short_fingerprint(fingerprint) -> String:
	return str(fingerprint).substr(0, 8) if typeof(fingerprint) == TYPE_STRING else ""


# One log line: mode, capacity, reasons, short upstream fingerprints. No
# identities or tokens (R21).
static func describe(result: Dictionary) -> String:
	var text := ""
	if bool(result.get("extended", false)):
		var ids: Array = result.get("virtual_device_ids", [])
		text = "runtime gate: extended capacity=%d virtual_devices=%d..%d" % [int(result.get("capacity", 0)), int(ids.front()), int(ids.back())]
	else:
		text = "runtime gate: vanilla capacity=%d reasons=%s" % [int(result.get("capacity", 0)), ",".join(PoolStringArray(result.get("reasons", [])))]
	if not bool(result.get("install_extensions", true)):
		text += " extensions=skipped"
	var upstream = result.get("details", {}).get("upstream", {})
	for mod_id in upstream:
		var info: Dictionary = upstream[mod_id]
		text += " %s=%s(%s, expected %s)" % [mod_id, info.get("actual", ""), info.get("result", ""), info.get("expected", "")]
	return text


# --- Internals -------------------------------------------------------------

static func _result(reasons: Array, install: bool, details: Dictionary) -> Dictionary:
	var extended := reasons.empty()
	var cap := EXTENDED_CAPACITY if extended else VANILLA_CAPACITY
	return {
		"capacity": cap,
		"extended": extended,
		"max_remote_players": cap - 1,
		"virtual_device_ids": _virtual_ids(cap),
		"reasons": reasons.duplicate(),
		"install_extensions": install,
		"details": details,
	}


static func _virtual_ids(cap: int) -> Array:
	if cap <= VANILLA_CAPACITY:
		return []
	return range(VIRTUAL_DEVICE_BASE, VIRTUAL_DEVICE_BASE + cap - 1)


# Stored decision, or {} when there is none or it is unusable.
static func _state() -> Dictionary:
	if not Engine.has_meta(META_KEY):
		return {}
	var state = Engine.get_meta(META_KEY)
	if typeof(state) != TYPE_DICTIONARY or typeof(state.get("capacity")) != TYPE_INT:
		return {}
	if state["capacity"] != VANILLA_CAPACITY and state["capacity"] != EXTENDED_CAPACITY:
		return {}
	if typeof(state.get("reasons")) != TYPE_ARRAY or state["reasons"].empty() != (state["capacity"] == EXTENDED_CAPACITY):
		return {}
	return state


# Written by initialize(); tests use it to set a known decision.
static func _store(result: Dictionary) -> void:
	Engine.set_meta(META_KEY, result.duplicate(true))


# Tests only: forget the decision so the next initialize() runs again.
static func _reset() -> void:
	if Engine.has_meta(META_KEY):
		Engine.remove_meta(META_KEY)
	clear_room()


static func _read_compatibility() -> Dictionary:
	var file := File.new()
	if not file.file_exists(COMPATIBILITY_PATH):
		return {"state": COMPAT_MISSING, "data": {}}
	if file.open(COMPATIBILITY_PATH, File.READ) != OK:
		return {"state": COMPAT_INVALID, "data": {}}
	var text := file.get_as_text()
	file.close()
	var parsed := JSON.parse(text)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return {"state": COMPAT_INVALID, "data": {}}
	return {"state": COMPAT_OK, "data": parsed.result}


# "" when compatibility.json has everything decide() reads, else what is wrong.
static func _compatibility_problem(compat) -> String:
	if typeof(compat) != TYPE_DICTIONARY:
		return "not_an_object"
	var schema = compat.get("schema")
	if not (typeof(schema) == TYPE_INT or typeof(schema) == TYPE_REAL) or int(schema) != COMPATIBILITY_SCHEMA:
		return "schema"
	if str(compat.get("extension_id", "")) != MOD_ID:
		return "extension_id"
	for fact in VERSION_FACTS:
		if typeof(compat.get(fact[1])) != TYPE_ARRAY:
			return fact[1]
	var upstream = compat.get("upstream")
	if typeof(upstream) != TYPE_ARRAY:
		return "upstream"
	var has_required := false
	for i in range(upstream.size()):
		var entry = upstream[i]
		if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("id")) != TYPE_STRING or entry["id"] == "" or typeof(entry.get("role")) != TYPE_STRING:
			return "upstream[%d]" % i
		if entry["role"] == ROLE_REQUIRED or entry["role"] == ROLE_OPTIONAL:
			var fp = entry.get("normalized_fingerprint")
			if typeof(fp) != TYPE_STRING or fp.length() != 64:
				return "upstream[%d].normalized_fingerprint" % i
			if entry["id"] == REQUIRED_UPSTREAM_ID:
				has_required = true
	if not has_required:
		return "upstream:" + REQUIRED_UPSTREAM_ID
	return ""


static func _mod_loader_state(mods, mod_id: String) -> String:
	if typeof(mods) != TYPE_DICTIONARY or not mods.has(mod_id) or typeof(mods[mod_id]) != TYPE_DICTIONARY:
		return MOD_UNKNOWN
	var m: Dictionary = mods[mod_id]
	return MOD_RUNNING if bool(m.get("loadable", false)) and bool(m.get("active", false)) else MOD_STOPPED


# The Mod Loader view wins (a mounted but deactivated mod does not run); with
# no view, an existing mod directory counts as running (conservative).
static func _is_mod_running(mods, mod_dirs, mod_id: String) -> bool:
	var state := _mod_loader_state(mods, mod_id)
	if state != MOD_UNKNOWN:
		return state == MOD_RUNNING
	return typeof(mod_dirs) == TYPE_DICTIONARY and bool(mod_dirs.get(mod_id, false))


static func _append_once(list: Array, value: String) -> void:
	if not list.has(value):
		list.append(value)


# Info level only: CrashReporter disables every mod on the next start when an
# ERROR line mentions mods-unpacked (LIFE-03).
static func _log_info(message: String) -> void:
	if ResourceLoader.exists(LOG_SCRIPT_PATH):
		var log_script = load(LOG_SCRIPT_PATH)
		if log_script != null:
			log_script.info(message, MOD_ID)
			return
	print("%s: %s" % [MOD_ID, message])
