extends Reference
# Virtual input device ids for REMOTE players (R02, F02, F03). Every remote
# player is driven through a device id of its own; ids of local physical
# devices and special ids are reserved and never handed out. The pool never
# lets two owners share an id: when it runs out, allocate() fails and the
# caller must refuse the join (F02) instead of doubling players up.
# Candidate ids are configuration; the real ranges come from the upstream
# audit. For reference: Brotato's CoopService remaps a gamepad to 6 and the
# keyboard to 7 (debug devices 8..11), and Brotato Online gives remote players
# the placeholder ids [1, 2, 3, 4, 5, 0].
# Owner keys are opaque non-empty Strings (the slot registry uses identities).
# Device ids are ints in 0..MAX_DEVICE_ID everywhere (candidates, reservations,
# snapshots), so everything the pool holds survives a JSON round trip.
# Pure rules: no autoloads, no scene tree, no Input calls.

const NO_DEVICE := -1
const NO_OWNER := ""
# Upper bound for every device id (JSON turns ints into floats).
const MAX_DEVICE_ID := 1000000

const REASON_NONE := ""
const REASON_EXHAUSTED := "device_pool_exhausted"
const REASON_INVALID_CONFIG := "invalid_pool_config"
const REASON_INVALID_OWNER := "invalid_owner_key"
const REASON_INVALID_DEVICE := "invalid_device_id"
const REASON_FIXED_RESERVED := "device_fixed_reserved"
const REASON_MALFORMED_SNAPSHOT := "malformed_pool_snapshot"
const REASON_CONFIG_MISMATCH := "pool_snapshot_config_mismatch"

var _candidates := []        # ordered ids that may be handed to remote owners
var _fixed_reserved := {}    # id -> true; constructor reservations, never released
var _reserved := {}          # id -> true; local physical devices seen at runtime
var _device_by_owner := {}   # owner key -> id
var _owner_by_device := {}   # id -> owner key
var _config_errors := []


# candidate_ids: allocation order, unique ints in 0..MAX_DEVICE_ID.
# reserved_ids: ids that must never be allocated (local devices, remap ids),
# ints in 0..MAX_DEVICE_ID; repeats are harmless.
# A bad configuration is reported by config_errors(), never silently repaired.
func _init(p_candidate_ids: Array = [], p_reserved_ids: Array = []) -> void:
	var seen := {}
	for i in range(p_candidate_ids.size()):
		var id = p_candidate_ids[i]
		if typeof(id) != TYPE_INT:
			_config_errors.append("candidate %d is not an int" % i)
		elif not _is_device_id(id):
			_config_errors.append("candidate %d is out of range" % i)
		elif seen.has(id):
			_config_errors.append("candidate %d repeats id %d" % [i, id])
		else:
			seen[id] = true
			_candidates.append(id)
	for i in range(p_reserved_ids.size()):
		var id = p_reserved_ids[i]
		if typeof(id) != TYPE_INT:
			_config_errors.append("reserved %d is not an int" % i)
		elif not _is_device_id(id):
			_config_errors.append("reserved %d is out of range" % i)
		else:
			_fixed_reserved[id] = true


func is_valid() -> bool:
	return _config_errors.empty()


func config_errors() -> Array:
	return _config_errors.duplicate()


func candidate_ids() -> Array:
	return _candidates.duplicate()


func is_reserved(device_id) -> bool:
	return _is_device_id(device_id) and (_fixed_reserved.has(device_id) or _reserved.has(device_id))


# Candidates not reserved, whether allocated or not.
func usable_count() -> int:
	if not is_valid():
		return 0
	var n := 0
	for id in _candidates:
		if not is_reserved(id):
			n += 1
	return n


func allocated_count() -> int:
	return _device_by_owner.size()


func free_count() -> int:
	if not is_valid():
		return 0
	var n := 0
	for id in _candidates:
		if not is_reserved(id) and not _owner_by_device.has(id):
			n += 1
	return n


# Idempotent per owner: an owner that already holds an id gets the same one
# back (changed = false). Otherwise the first free candidate in order.
func allocate(owner_key) -> Dictionary:
	if not is_valid():
		return _device_result(false, REASON_INVALID_CONFIG, NO_DEVICE, false)
	if not _is_owner_key(owner_key):
		return _device_result(false, REASON_INVALID_OWNER, NO_DEVICE, false)
	if _device_by_owner.has(owner_key):
		return _device_result(true, REASON_NONE, _device_by_owner[owner_key], false)
	for id in _candidates:
		if not is_reserved(id) and not _owner_by_device.has(id):
			_device_by_owner[owner_key] = id
			_owner_by_device[id] = owner_key
			return _device_result(true, REASON_NONE, id, true)
	return _device_result(false, REASON_EXHAUSTED, NO_DEVICE, false)


# Releasing an owner that holds nothing is a successful no-op.
# Callers must clear any input still pressed on the returned id before it is
# handed to someone else (F03).
func release(owner_key) -> Dictionary:
	if not _is_owner_key(owner_key):
		return _device_result(false, REASON_INVALID_OWNER, NO_DEVICE, false)
	if not _device_by_owner.has(owner_key):
		return _device_result(true, REASON_NONE, NO_DEVICE, false)
	var id: int = _device_by_owner[owner_key]
	_device_by_owner.erase(owner_key)
	_owner_by_device.erase(id)
	return _device_result(true, REASON_NONE, id, true)


# A local physical device appeared. Its id is taken out of circulation; if a
# remote owner held it, that owner loses it and is reported as
# displaced_owner so the caller can re-home it (no two players on one id).
# Ids outside 0..MAX_DEVICE_ID are refused, which also bounds the set.
func reserve(device_id) -> Dictionary:
	if not _is_device_id(device_id):
		var bad := _device_result(false, REASON_INVALID_DEVICE, NO_DEVICE, false)
		bad["displaced_owner"] = NO_OWNER
		return bad
	var displaced := NO_OWNER
	var changed := false
	if not is_reserved(device_id):
		if _owner_by_device.has(device_id):
			displaced = _owner_by_device[device_id]
			_owner_by_device.erase(device_id)
			_device_by_owner.erase(displaced)
		_reserved[device_id] = true
		changed = true
	var r := _device_result(true, REASON_NONE, device_id, changed)
	r["displaced_owner"] = displaced
	return r


# A local physical device went away. Constructor reservations stay reserved.
func unreserve(device_id) -> Dictionary:
	if not _is_device_id(device_id):
		return _device_result(false, REASON_INVALID_DEVICE, NO_DEVICE, false)
	if _fixed_reserved.has(device_id):
		return _device_result(false, REASON_FIXED_RESERVED, device_id, false)
	if not _reserved.has(device_id):
		return _device_result(true, REASON_NONE, device_id, false)
	_reserved.erase(device_id)
	return _device_result(true, REASON_NONE, device_id, true)


func device_of(owner_key) -> int:
	if _is_owner_key(owner_key) and _device_by_owner.has(owner_key):
		return _device_by_owner[owner_key]
	return NO_DEVICE


func owner_of(device_id) -> String:
	if typeof(device_id) == TYPE_INT and _owner_by_device.has(device_id):
		return _owner_by_device[device_id]
	return NO_OWNER


func owners() -> Array:
	var keys := _device_by_owner.keys()
	keys.sort()
	return keys


# Plain data (ints, Strings, Arrays, one Dictionary keyed by owner) that
# survives var2bytes and JSON. The configuration is included only so that
# restore() can refuse a snapshot taken from a differently configured pool.
func snapshot() -> Dictionary:
	var fixed := _fixed_reserved.keys()
	fixed.sort()
	var reserved := _reserved.keys()
	reserved.sort()
	return {
		"candidates": _candidates.duplicate(),
		"fixed_reserved": fixed,
		"reserved": reserved,
		"owners": _device_by_owner.duplicate(),
	}


# All or nothing: on any problem the pool is left exactly as it was.
# Integral floats (from JSON) are accepted and stored as ints; ids outside
# 0..MAX_DEVICE_ID make the snapshot malformed.
func restore(snap) -> Dictionary:
	if not is_valid():
		return {"ok": false, "reason": REASON_INVALID_CONFIG}
	if typeof(snap) != TYPE_DICTIONARY:
		return {"ok": false, "reason": REASON_MALFORMED_SNAPSHOT}
	for key in ["candidates", "fixed_reserved", "reserved", "owners"]:
		if not snap.has(key):
			return {"ok": false, "reason": REASON_MALFORMED_SNAPSHOT}
	var candidates = _int_list(snap["candidates"])
	var fixed = _int_list(snap["fixed_reserved"])
	var reserved = _int_list(snap["reserved"])
	if candidates == null or fixed == null or reserved == null or typeof(snap["owners"]) != TYPE_DICTIONARY:
		return {"ok": false, "reason": REASON_MALFORMED_SNAPSHOT}
	var own_fixed := _fixed_reserved.keys()
	own_fixed.sort()
	fixed.sort()
	if candidates != _candidates or fixed != own_fixed:
		return {"ok": false, "reason": REASON_CONFIG_MISMATCH}
	var new_reserved := {}
	for id in reserved:
		new_reserved[id] = true
	var candidate_set := {}
	for id in _candidates:
		candidate_set[id] = true
	var new_by_owner := {}
	var new_by_device := {}
	var raw_owners: Dictionary = snap["owners"]
	for owner_key in raw_owners:
		var id = _to_device_id(raw_owners[owner_key])
		if not _is_owner_key(owner_key) or id == null:
			return {"ok": false, "reason": REASON_MALFORMED_SNAPSHOT}
		if not candidate_set.has(id) or _fixed_reserved.has(id) or new_reserved.has(id) or new_by_device.has(id):
			return {"ok": false, "reason": REASON_MALFORMED_SNAPSHOT}
		new_by_owner[owner_key] = id
		new_by_device[id] = owner_key
	_reserved = new_reserved
	_device_by_owner = new_by_owner
	_owner_by_device = new_by_device
	return {"ok": true, "reason": REASON_NONE}


static func _is_owner_key(owner_key) -> bool:
	return typeof(owner_key) == TYPE_STRING and owner_key != NO_OWNER


static func _is_device_id(device_id) -> bool:
	return typeof(device_id) == TYPE_INT and device_id >= 0 and device_id <= MAX_DEVICE_ID


# Device id as int (an integral float is accepted), or null when the value is
# not a whole number in 0..MAX_DEVICE_ID.
static func _to_device_id(value):
	if typeof(value) == TYPE_INT:
		return value if _is_device_id(value) else null
	if typeof(value) == TYPE_REAL and not is_nan(value) and not is_inf(value) \
			and value == floor(value) and value >= 0 and value <= MAX_DEVICE_ID:
		return int(value)
	return null


# Array of unique device ids as ints, or null.
static func _int_list(values):
	if typeof(values) != TYPE_ARRAY:
		return null
	var out := []
	for v in values:
		var id = _to_device_id(v)
		if id == null or out.has(id):
			return null
		out.append(id)
	return out


static func _device_result(ok: bool, reason: String, device_id: int, changed: bool) -> Dictionary:
	return {"ok": ok, "reason": reason, "device_id": device_id, "changed": changed}
