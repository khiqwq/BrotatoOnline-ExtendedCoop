extends Reference
# Seat map of one run (R01, R02, R11; F01 F02 F03 F09 F10 F11). Keeps apart:
#   identity      - opaque String from the transport ("steam:<id>", "lan:<key>")
#   slot          - stable id given at the first seat, never reused in the run
#   player_index  - 0-based position in the run roster, contiguous; changes
#                   only on an explicit remove()
#   device_id     - virtual input device of a REMOTE player, owned by the pool
#   is_local      - the single player sitting at this machine (R02)
# Disconnect keeps slot and player_index (the seat still counts against
# capacity); only remove() compacts indices, and it returns the remap callers
# must apply to every index-keyed structure in one step (F11).
# One player per machine: at most capacity - 1 remote seats, so the local
# player always has a seat, and a run cannot be frozen without it.
# The pool is dedicated to this registry and keyed by identity; device ids are
# never stored here, so the pool is the single source of truth for them.
# Whenever a device id is freed (disconnect, remove, local unplug) online
# remote players left without one are re-homed first, so a newcomer or a
# reconnecting player never takes the id ahead of someone already playing.
# Results keep the same keys on success and failure.
# Pure rules: no autoloads, no scene tree.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const VirtualDevicePool = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/virtual_device_pool.gd")

const SCHEMA_VERSION := 1
const NO_SLOT := -1
const NO_INDEX := -1
const NO_DEVICE := VirtualDevicePool.NO_DEVICE
const NO_IDENTITY := ""
const MAX_IDENTITY_LENGTH := 128
# Bound for slot ids and generations read back from checkpoints.
const MAX_COUNTER := 1000000

const REASON_NONE := ""
const REASON_INVALID_SETUP := "invalid_registry_setup"
const REASON_INVALID_IDENTITY := "invalid_identity"
const REASON_INVALID_ARGUMENT := "invalid_argument"
const REASON_UNKNOWN_IDENTITY := "unknown_identity"
const REASON_SECOND_LOCAL := "second_local_identity"
const REASON_LOCAL_MISMATCH := "local_flag_mismatch"
const REASON_LOCAL_NOT_REMOVABLE := "local_identity_not_removable"
const REASON_LOCAL_SEAT_RESERVED := "seat_reserved_for_local"
const REASON_NO_LOCAL := "no_local_identity"
const REASON_DEVICE_UNAVAILABLE := "virtual_device_unavailable"
const REASON_DEVICE_SHORTFALL := "virtual_device_shortfall"
const REASON_EMPTY_ROSTER := "empty_roster"
const REASON_INVARIANT_VIOLATION := "roster_invariant_violation"
const REASON_MALFORMED := "malformed_roster_data"
const REASON_UNSUPPORTED_SCHEMA := "unsupported_roster_schema"
const REASON_OVER_CAPACITY := "roster_over_capacity"
const REASON_BAD_REMAP := "invalid_remap"
# Capacity decisions come from capacity_policy.gd and keep its reasons.
const REASON_FULL := CapacityPolicy.REJECT_FULL
const REASON_RUN_FROZEN := CapacityPolicy.REJECT_RUN_FROZEN
const REASON_INVALID_CAPACITY := CapacityPolicy.REJECT_INVALID_CAPACITY

# validate() / check_roster() codes. Details name slots and indices only,
# never identities (R21).
const VIOLATION_INVALID_SETUP := "invalid_setup"
const VIOLATION_MALFORMED_ENTRY := "malformed_entry"
const VIOLATION_DUPLICATE_IDENTITY := "duplicate_identity"
const VIOLATION_DUPLICATE_SLOT := "duplicate_slot"
const VIOLATION_DUPLICATE_INDEX := "duplicate_player_index"
const VIOLATION_INDEX_GAP := "player_index_gap"
const VIOLATION_DUPLICATE_DEVICE := "duplicate_device"
const VIOLATION_OVER_CAPACITY := "over_capacity"
const VIOLATION_REMOTE_OVER_CAPACITY := "remote_over_capacity"
const VIOLATION_MULTIPLE_LOCAL := "multiple_local"
const VIOLATION_MISSING_DEVICE := "online_remote_without_device"
const VIOLATION_STALE_DEVICE := "device_without_online_remote"
const VIOLATION_SLOT_COUNTER := "slot_not_below_counter"
const VIOLATION_ORPHAN_DEVICE := "orphan_pool_device"

const _ENTRY_KEYS := ["slot", "identity", "player_index", "device_id", "online", "is_local"]
const _DATA_KEYS := ["schema", "capacity", "next_slot", "generation", "frozen", "entries"]
const _DATA_ENTRY_KEYS := ["slot", "identity", "player_index", "is_local"]

var _policy = null
var _pool = null
# Position in _entries is the player_index. Each entry:
# {"slot": int, "identity": String, "is_local": bool, "online": bool}
var _entries := []
var _by_identity := {}
var _next_slot := 0
var _generation := 0
var _frozen := false


func _init(p_policy = null, p_pool = null) -> void:
	_policy = p_policy
	_pool = p_pool


func is_valid() -> bool:
	return _setup_ok()


# Can the pool give every possible remote player its own device right now?
# Meant for session creation, so an 8-player session is refused up front
# instead of failing at the seventh remote join (F02).
func check_setup() -> Dictionary:
	if not _setup_ok():
		return {"ok": false, "reason": REASON_INVALID_SETUP, "remote_capacity": 0, "usable_devices": 0, "shortfall": 0}
	var needed: int = _policy.max_remote_players()
	var usable: int = _pool.usable_count()
	var shortfall := int(max(0, needed - usable))
	return {
		"ok": shortfall == 0,
		"reason": REASON_NONE if shortfall == 0 else REASON_DEVICE_SHORTFALL,
		"remote_capacity": needed,
		"usable_devices": usable,
		"shortfall": shortfall,
	}


# New or returning identity. New identities need room (policy.check_join on
# the roster count, offline seats included), an unfrozen run, a device if
# remote, and at most one local identity; a new remote is also refused when
# it would take the seat the local player still needs (one player per
# machine: at most capacity - 1 remotes). Returning identities keep their
# slot and index whatever the capacity or freeze state; seating one that is
# already online is a no-op (changed = false).
# Result: an entry (see roster()) plus ok, reason, changed, returning and
# device_reason (the pool's reason when no device could be given).
func seat(identity, is_local) -> Dictionary:
	if not _setup_ok():
		return _seat_fail(REASON_INVALID_SETUP, false)
	if not _is_identity(identity):
		return _seat_fail(REASON_INVALID_IDENTITY, false)
	if typeof(is_local) != TYPE_BOOL:
		return _seat_fail(REASON_INVALID_ARGUMENT, false)
	if _by_identity.has(identity):
		var entry = _by_identity[identity]
		if entry.is_local != is_local:
			return _seat_fail(REASON_LOCAL_MISMATCH, true)
		var again := _bring_online(entry)
		again["returning"] = true
		return again
	if is_local and local_identity() != NO_IDENTITY:
		return _seat_fail(REASON_SECOND_LOCAL, false)
	var join: Dictionary = _policy.check_join(_entries.size(), _frozen)
	if not join.accepted:
		return _seat_fail(join.reason, false)
	if not is_local and _remote_count() >= _policy.max_remote_players():
		return _seat_fail(REASON_LOCAL_SEAT_RESERVED, false)
	if not is_local:
		var alloc: Dictionary = _pool.allocate(identity)
		if not alloc.ok:
			var refused := _seat_fail(REASON_DEVICE_UNAVAILABLE, false)
			refused["device_reason"] = alloc.reason
			return refused
	var new_entry := {"slot": _next_slot, "identity": identity, "is_local": is_local, "online": true}
	_next_slot += 1
	_entries.append(new_entry)
	_by_identity[identity] = new_entry
	var seated := _entry_result(new_entry, true)
	seated["returning"] = false
	return seated


# Keeps slot and player_index, releases the remote device, marks offline.
# The freed id goes straight to an online remote player that had none
# (rehomed / unhomed as in rehome_devices()). Callers must clear any input
# still held on released_device_id before routing a rehomed player to it (F03).
func disconnect_identity(identity) -> Dictionary:
	var unknown := _check_known(identity)
	if unknown != REASON_NONE:
		return _with_release(_fail(unknown), NO_DEVICE, _no_rehome())
	var entry: Dictionary = _by_identity[identity]
	var released: Dictionary = _pool.release(identity)
	var changed: bool = entry.online or released.changed
	entry.online = false
	var rehome := _rehome_missing()
	return _with_release(_entry_result(entry, changed), released.device_id, rehome)


# Same slot and index, freshly allocated device for a remote identity. Fails
# without changing anything when no device is free.
func reconnect(identity) -> Dictionary:
	var unknown := _check_known(identity)
	if unknown != REASON_NONE:
		return _fail(unknown)
	var entry: Dictionary = _by_identity[identity]
	return _bring_online(entry)


# Explicit removal only. Indices above the removed one move down by one;
# "remap" maps every surviving old index to its new index (removed index
# absent) and must be applied to ALL index-keyed data together, for example
# with remap_array(). Bumps the roster generation. The removed player's
# device comes back as released_device_id and is re-homed like on disconnect.
# On failure nothing changes and remap is the identity map of the current
# roster, so applying it by mistake moves nothing.
func remove(identity) -> Dictionary:
	var unknown := _check_known(identity)
	if unknown != REASON_NONE:
		return _remove_fail(unknown)
	var entry: Dictionary = _by_identity[identity]
	if entry.is_local:
		return _remove_fail(REASON_LOCAL_NOT_REMOVABLE)
	var old_index := _index_of(identity)
	var old_count := _entries.size()
	var released: Dictionary = _pool.release(identity)
	_entries.remove(old_index)
	_by_identity.erase(identity)
	var remap := {}
	for i in range(old_count):
		if i < old_index:
			remap[i] = i
		elif i > old_index:
			remap[i] = i - 1
	_generation += 1
	var rehome := _rehome_missing()
	return {
		"ok": true,
		"reason": REASON_NONE,
		"removed_slot": entry.slot,
		"removed_index": old_index,
		"remap": remap,
		"old_count": old_count,
		"new_count": old_count - 1,
		"generation": _generation,
		"released_device_id": released.device_id,
		"rehomed": rehome.rehomed,
		"unhomed": rehome.unhomed,
	}


# One-way for the run. Refused for an empty roster, a roster without the
# local player, or one that breaks an invariant, so a damaged roster is never
# locked in (F01). Result: ok, reason, changed, violations.
func freeze() -> Dictionary:
	if not _setup_ok():
		return _freeze_result(REASON_INVALID_SETUP, [])
	if _entries.empty():
		return _freeze_result(REASON_EMPTY_ROSTER, [])
	if local_identity() == NO_IDENTITY:
		return _freeze_result(REASON_NO_LOCAL, [])
	var violations := validate()
	if not violations.empty():
		return _freeze_result(REASON_INVARIANT_VIOLATION, violations)
	var changed := not _frozen
	_frozen = true
	return {"ok": true, "reason": REASON_NONE, "changed": changed, "violations": []}


func is_frozen() -> bool:
	return _frozen


# Local physical device appeared. The id is reserved in the pool; a remote
# player that held it is moved to another free id. When none is free the
# remote player stays online without a device (new_device_id = NO_DEVICE,
# rehome_reason set): the caller must stop the flow, validate() reports it.
func reserve_local_device(device_id) -> Dictionary:
	if not _setup_ok():
		return {"ok": false, "reason": REASON_INVALID_SETUP, "displaced": NO_IDENTITY, "new_device_id": NO_DEVICE, "rehome_reason": REASON_NONE}
	var r: Dictionary = _pool.reserve(device_id)
	var out := {"ok": r.ok, "reason": r.reason, "displaced": r.displaced_owner, "new_device_id": NO_DEVICE, "rehome_reason": REASON_NONE}
	if not r.ok or r.displaced_owner == NO_IDENTITY:
		return out
	var entry = _by_identity.get(r.displaced_owner)
	if entry == null or not entry.online or entry.is_local:
		return out
	var alloc: Dictionary = _pool.allocate(entry.identity)
	if alloc.ok:
		out["new_device_id"] = alloc.device_id
	else:
		out["rehome_reason"] = REASON_DEVICE_UNAVAILABLE
	return out


# Local physical device went away: the id returns to circulation and online
# remote players left without a device are re-homed.
func release_local_device(device_id) -> Dictionary:
	if not _setup_ok():
		return {"ok": false, "reason": REASON_INVALID_SETUP, "rehomed": [], "unhomed": []}
	var r: Dictionary = _pool.unreserve(device_id)
	var out := rehome_devices()
	out["ok"] = r.ok and out.ok
	out["reason"] = r.reason if not r.ok else out.reason
	return out


# Gives a device to every online remote player missing one, in player_index
# order. rehomed: [{"identity", "device_id"}]; unhomed: identities still
# without a device.
func rehome_devices() -> Dictionary:
	if not _setup_ok():
		return {"ok": false, "reason": REASON_INVALID_SETUP, "rehomed": [], "unhomed": []}
	var rehome := _rehome_missing()
	return {
		"ok": rehome.unhomed.empty(),
		"reason": REASON_NONE if rehome.unhomed.empty() else REASON_DEVICE_UNAVAILABLE,
		"rehomed": rehome.rehomed,
		"unhomed": rehome.unhomed,
	}


# Sorted by player_index. Entry: slot, identity, player_index, device_id,
# online, is_local, display_name.
func roster() -> Array:
	var out := []
	for i in range(_entries.size()):
		out.append(_public_entry(_entries[i], i))
	return out


func roster_count() -> int:
	return _entries.size()


func online_count() -> int:
	var n := 0
	for entry in _entries:
		if entry.online:
			n += 1
	return n


# Version of the index mapping: changes only when player indices of existing
# entries change (remove) or a checkpoint is loaded. Seating, disconnecting
# and reconnecting keep it, because no index changes meaning.
func generation() -> int:
	return _generation


func next_slot() -> int:
	return _next_slot


func has_identity(identity) -> bool:
	return _is_identity(identity) and _by_identity.has(identity)


func entry_of(identity) -> Dictionary:
	if not has_identity(identity):
		return {}
	return _public_entry(_by_identity[identity], _index_of(identity))


func slot_of(identity) -> int:
	if not has_identity(identity):
		return NO_SLOT
	return _by_identity[identity].slot


func player_index_of(identity) -> int:
	if not has_identity(identity):
		return NO_INDEX
	return _index_of(identity)


func identity_at_index(player_index) -> String:
	var i = _to_int(player_index)
	if i == null or i < 0 or i >= _entries.size():
		return NO_IDENTITY
	return _entries[i].identity


# Ownership check for incoming actions: true only when identity currently sits
# at player_index. Says nothing about being online; reject offline senders
# separately with is_online().
func owns_index(identity, player_index) -> bool:
	return has_identity(identity) and identity_at_index(player_index) == identity


func device_of(identity) -> int:
	if not has_identity(identity) or not (_pool is VirtualDevicePool):
		return NO_DEVICE
	return _pool.device_of(identity)


func is_online(identity) -> bool:
	return has_identity(identity) and _by_identity[identity].online


func is_local_identity(identity) -> bool:
	return has_identity(identity) and _by_identity[identity].is_local


func local_identity() -> String:
	for entry in _entries:
		if entry.is_local:
			return entry.identity
	return NO_IDENTITY


func display_name_of(identity) -> String:
	if not has_identity(identity):
		return ""
	return display_name_for_index(_index_of(identity))


# Invariant violations of the live state, [] when healthy. Each item:
# {"code": VIOLATION_*, "detail": String}.
func validate() -> Array:
	if not _setup_ok():
		return [_violation(VIOLATION_INVALID_SETUP, "policy or pool missing or invalid")]
	var violations := check_roster(roster(), _policy.capacity)
	for entry in _entries:
		if entry.slot >= _next_slot:
			violations.append(_violation(VIOLATION_SLOT_COUNTER, "slot %d" % entry.slot))
	for owner_key in _pool.owners():
		if not _by_identity.has(owner_key):
			violations.append(_violation(VIOLATION_ORPHAN_DEVICE, "device %d has no seat" % _pool.device_of(owner_key)))
	return violations


# Checkpoint data: plain ints, bools, Strings and Arrays (safe for var2bytes
# and JSON). Devices and online flags are runtime state and are not saved.
func serialize() -> Dictionary:
	var entries := []
	for i in range(_entries.size()):
		var entry = _entries[i]
		entries.append({"slot": entry.slot, "identity": entry.identity, "player_index": i, "is_local": entry.is_local})
	return {
		"schema": SCHEMA_VERSION,
		"capacity": _policy.capacity if _policy is CapacityPolicy else 0,
		"next_slot": _next_slot,
		"generation": _generation,
		"frozen": _frozen,
		"entries": entries,
	}


# All or nothing. Rejects malformed data, an unknown schema, more entries than
# the policy capacity (or the recorded one), duplicates, index gaps, two local
# entries, too many remote entries, a frozen run without its local player and
# slot ids not below next_slot; the registry is then unchanged.
# On success every entry is offline without a device; players come back via
# seat()/reconnect(). released_device_ids (sorted) lists the ids taken from
# players seated before the load, whose input the caller must clear (F03).
# Integral floats (JSON) are accepted as ints.
# Result: ok, reason, violations, released_device_ids.
func deserialize(data) -> Dictionary:
	if not _setup_ok():
		return _load_result(REASON_INVALID_SETUP, [])
	if typeof(data) != TYPE_DICTIONARY:
		return _load_result(REASON_MALFORMED, [])
	for key in _DATA_KEYS:
		if not data.has(key):
			return _load_result(REASON_MALFORMED, [])
	var schema = _to_int(data["schema"])
	if schema == null:
		return _load_result(REASON_MALFORMED, [])
	if schema != SCHEMA_VERSION:
		return _load_result(REASON_UNSUPPORTED_SCHEMA, [])
	var stored_capacity = _to_int(data["capacity"])
	var stored_next_slot = _to_int(data["next_slot"])
	var stored_generation = _to_int(data["generation"])
	var raw_entries = data["entries"]
	if stored_capacity == null or stored_next_slot == null or stored_generation == null \
			or typeof(data["frozen"]) != TYPE_BOOL or typeof(raw_entries) != TYPE_ARRAY:
		return _load_result(REASON_MALFORMED, [])
	if stored_capacity < 1 or stored_capacity > CapacityPolicy.MAX_SUPPORTED_PLAYERS \
			or stored_next_slot < 0 or stored_next_slot > MAX_COUNTER or stored_generation < 0 or stored_generation > MAX_COUNTER:
		return _load_result(REASON_MALFORMED, [])
	# Size first, so an oversized list is never walked.
	if raw_entries.size() > _policy.capacity or raw_entries.size() > stored_capacity:
		return _load_result(REASON_OVER_CAPACITY, [])
	if data["frozen"] and raw_entries.empty():
		return _load_result(REASON_EMPTY_ROSTER, [])
	var parsed := []
	for raw in raw_entries:
		var entry = _parse_data_entry(raw)
		if entry == null:
			return _load_result(REASON_MALFORMED, [])
		parsed.append(entry)
	var violations := check_roster(parsed, _policy.capacity)
	for entry in parsed:
		if entry.slot >= stored_next_slot:
			violations.append(_violation(VIOLATION_SLOT_COUNTER, "slot %d" % entry.slot))
	if not violations.empty():
		return _load_result(REASON_INVARIANT_VIOLATION, violations)
	if data["frozen"] and not _has_local(parsed):
		return _load_result(REASON_NO_LOCAL, [])
	# Commit. Indices are known to be exactly 0..n-1.
	var released_ids := []
	for entry in _entries + parsed:
		var released: Dictionary = _pool.release(entry.identity)
		if released.changed:
			released_ids.append(released.device_id)
	released_ids.sort()
	var ordered := []
	ordered.resize(parsed.size())
	for entry in parsed:
		ordered[entry.player_index] = {"slot": entry.slot, "identity": entry.identity, "is_local": entry.is_local, "online": false}
	_entries = ordered
	_by_identity = {}
	for entry in _entries:
		_by_identity[entry.identity] = entry
	_next_slot = stored_next_slot
	_generation = stored_generation
	_frozen = data["frozen"]
	var loaded := _load_result(REASON_NONE, [])
	loaded["released_device_ids"] = released_ids
	return loaded


static func display_name_for_index(player_index) -> String:
	var i = _to_int(player_index)
	if i == null or i < 0:
		return ""
	return "P%d" % (i + 1)


# Invariant check over roster-shaped entries (see roster()); usable on data
# that did not come from a live registry. Returns [] when healthy.
static func check_roster(entries, capacity: int) -> Array:
	var violations := []
	if typeof(entries) != TYPE_ARRAY:
		violations.append(_violation(VIOLATION_MALFORMED_ENTRY, "roster is not an array"))
		return violations
	var count: int = entries.size()
	if count > capacity:
		violations.append(_violation(VIOLATION_OVER_CAPACITY, "%d entries, capacity %d" % [count, capacity]))
	var identities := {}
	var slots := {}
	var indices := {}
	var devices := {}
	var locals := 0
	var remotes := 0
	for n in range(count):
		var entry = entries[n]
		if not _is_roster_entry(entry):
			violations.append(_violation(VIOLATION_MALFORMED_ENTRY, "entry %d" % n))
			continue
		if identities.has(entry.identity):
			violations.append(_violation(VIOLATION_DUPLICATE_IDENTITY, "slots %d and %d" % [identities[entry.identity], entry.slot]))
		identities[entry.identity] = entry.slot
		if slots.has(entry.slot):
			violations.append(_violation(VIOLATION_DUPLICATE_SLOT, "slot %d" % entry.slot))
		slots[entry.slot] = true
		if indices.has(entry.player_index):
			violations.append(_violation(VIOLATION_DUPLICATE_INDEX, "index %d" % entry.player_index))
		indices[entry.player_index] = true
		if entry.player_index < 0 or entry.player_index >= count:
			violations.append(_violation(VIOLATION_INDEX_GAP, "index %d out of range 0..%d" % [entry.player_index, count - 1]))
		if entry.is_local:
			locals += 1
		else:
			remotes += 1
		var needs_device: bool = entry.online and not entry.is_local
		if needs_device and entry.device_id == NO_DEVICE:
			violations.append(_violation(VIOLATION_MISSING_DEVICE, "slot %d" % entry.slot))
		elif not needs_device and entry.device_id != NO_DEVICE:
			violations.append(_violation(VIOLATION_STALE_DEVICE, "slot %d holds device %d" % [entry.slot, entry.device_id]))
		if entry.device_id != NO_DEVICE:
			if devices.has(entry.device_id):
				violations.append(_violation(VIOLATION_DUPLICATE_DEVICE, "device %d" % entry.device_id))
			devices[entry.device_id] = true
	for i in range(count):
		if not indices.has(i):
			violations.append(_violation(VIOLATION_INDEX_GAP, "index %d missing" % i))
	if locals > 1:
		violations.append(_violation(VIOLATION_MULTIPLE_LOCAL, "%d local entries" % locals))
	# One player per machine: every seat but the local player's is remote.
	var max_remotes := int(max(0, capacity - 1))
	if remotes > max_remotes:
		violations.append(_violation(VIOLATION_REMOTE_OVER_CAPACITY, "%d remote entries, at most %d" % [remotes, max_remotes]))
	return violations


# Applies a remove() remap to an Array indexed by the old player_index.
# values.size() must equal old_count, the remap must be a bijection onto
# 0..remap.size()-1 and drop at most one index (remove() takes one player at
# a time, so an emptied or foreign remap can never wipe several players'
# data); otherwise nothing is produced (never a partial result).
# Elements are moved, not deep-copied.
static func remap_array(values: Array, remap: Dictionary, old_count: int) -> Dictionary:
	var new_count: int = remap.size()
	if values.size() != old_count or new_count > old_count or new_count < old_count - 1:
		return {"ok": false, "reason": REASON_BAD_REMAP, "values": []}
	var out := []
	out.resize(new_count)
	var filled := {}
	for old_index in remap:
		var new_index = remap[old_index]
		if typeof(old_index) != TYPE_INT or typeof(new_index) != TYPE_INT:
			return {"ok": false, "reason": REASON_BAD_REMAP, "values": []}
		if old_index < 0 or old_index >= old_count or new_index < 0 or new_index >= new_count or filled.has(new_index):
			return {"ok": false, "reason": REASON_BAD_REMAP, "values": []}
		filled[new_index] = true
		out[new_index] = values[old_index]
	return {"ok": true, "reason": REASON_NONE, "values": out}


func _setup_ok() -> bool:
	return _policy is CapacityPolicy and _policy.is_valid() and _pool is VirtualDevicePool and _pool.is_valid()


# REASON_NONE when identity is seated and the registry usable.
func _check_known(identity) -> String:
	if not _setup_ok():
		return REASON_INVALID_SETUP
	if not _is_identity(identity):
		return REASON_INVALID_IDENTITY
	if not _by_identity.has(identity):
		return REASON_UNKNOWN_IDENTITY
	return REASON_NONE


func _bring_online(entry: Dictionary) -> Dictionary:
	var changed := false
	if not entry.is_local and _pool.device_of(entry.identity) == NO_DEVICE:
		var alloc: Dictionary = _pool.allocate(entry.identity)
		if not alloc.ok:
			var refused := _fail(REASON_DEVICE_UNAVAILABLE)
			refused["device_reason"] = alloc.reason
			return refused
		changed = true
	if not entry.online:
		entry.online = true
		changed = true
	return _entry_result(entry, changed)


# Gives a device to every online remote player missing one, in player_index
# order: {"rehomed": [{"identity", "device_id"}], "unhomed": [identity]}.
func _rehome_missing() -> Dictionary:
	var rehomed := []
	var unhomed := []
	for entry in _entries:
		if not entry.online or entry.is_local or _pool.device_of(entry.identity) != NO_DEVICE:
			continue
		var alloc: Dictionary = _pool.allocate(entry.identity)
		if alloc.ok:
			rehomed.append({"identity": entry.identity, "device_id": alloc.device_id})
		else:
			unhomed.append(entry.identity)
	return {"rehomed": rehomed, "unhomed": unhomed}


func _remote_count() -> int:
	var n := 0
	for entry in _entries:
		if not entry.is_local:
			n += 1
	return n


func _index_of(identity: String) -> int:
	for i in range(_entries.size()):
		if _entries[i].identity == identity:
			return i
	return NO_INDEX


# Identity remap of the current roster (old_count = new_count): what a failed
# remove() hands back, so that applying it changes nothing.
func _remove_fail(reason: String) -> Dictionary:
	var count := _entries.size()
	var remap := {}
	for i in range(count):
		remap[i] = i
	return {
		"ok": false,
		"reason": reason,
		"removed_slot": NO_SLOT,
		"removed_index": NO_INDEX,
		"remap": remap,
		"old_count": count,
		"new_count": count,
		"generation": _generation,
		"released_device_id": NO_DEVICE,
		"rehomed": [],
		"unhomed": [],
	}


func _public_entry(entry: Dictionary, player_index: int) -> Dictionary:
	return {
		"slot": entry.slot,
		"identity": entry.identity,
		"player_index": player_index,
		"device_id": _pool.device_of(entry.identity) if _pool is VirtualDevicePool else NO_DEVICE,
		"online": entry.online,
		"is_local": entry.is_local,
		"display_name": display_name_for_index(player_index),
	}


func _entry_result(entry: Dictionary, changed: bool) -> Dictionary:
	var r := _public_entry(entry, _index_of(entry.identity))
	r["ok"] = true
	r["reason"] = REASON_NONE
	r["changed"] = changed
	r["device_reason"] = REASON_NONE
	return r


# Failed entry-shaped result: the same keys as _entry_result(), all blank.
static func _fail(reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"changed": false,
		"slot": NO_SLOT,
		"identity": NO_IDENTITY,
		"player_index": NO_INDEX,
		"device_id": NO_DEVICE,
		"online": false,
		"is_local": false,
		"display_name": "",
		"device_reason": REASON_NONE,
	}


static func _seat_fail(reason: String, returning: bool) -> Dictionary:
	var r := _fail(reason)
	r["returning"] = returning
	return r


static func _no_rehome() -> Dictionary:
	return {"rehomed": [], "unhomed": []}


static func _with_release(r: Dictionary, released_device_id: int, rehome: Dictionary) -> Dictionary:
	r["released_device_id"] = released_device_id
	r["rehomed"] = rehome.rehomed
	r["unhomed"] = rehome.unhomed
	return r


static func _freeze_result(reason: String, violations: Array) -> Dictionary:
	return {"ok": false, "reason": reason, "changed": false, "violations": violations}


static func _load_result(reason: String, violations: Array) -> Dictionary:
	return {"ok": reason == REASON_NONE, "reason": reason, "violations": violations, "released_device_ids": []}


static func _has_local(entries: Array) -> bool:
	for entry in entries:
		if entry.is_local:
			return true
	return false


static func _violation(code: String, detail: String) -> Dictionary:
	return {"code": code, "detail": detail}


static func _is_identity(identity) -> bool:
	return typeof(identity) == TYPE_STRING and identity.length() >= 1 and identity.length() <= MAX_IDENTITY_LENGTH


static func _is_roster_entry(entry) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	for key in _ENTRY_KEYS:
		if not entry.has(key):
			return false
	return typeof(entry.slot) == TYPE_INT and entry.slot >= 0 \
			and _is_identity(entry.identity) \
			and typeof(entry.player_index) == TYPE_INT \
			and typeof(entry.device_id) == TYPE_INT \
			and typeof(entry.online) == TYPE_BOOL \
			and typeof(entry.is_local) == TYPE_BOOL


# Checkpoint entry -> roster-shaped entry (offline, no device), or null.
static func _parse_data_entry(raw):
	if typeof(raw) != TYPE_DICTIONARY:
		return null
	for key in _DATA_ENTRY_KEYS:
		if not raw.has(key):
			return null
	var slot = _to_int(raw["slot"])
	var player_index = _to_int(raw["player_index"])
	if slot == null or slot < 0 or slot > MAX_COUNTER or player_index == null \
			or not _is_identity(raw["identity"]) or typeof(raw["is_local"]) != TYPE_BOOL:
		return null
	return {
		"slot": slot,
		"identity": raw["identity"],
		"player_index": player_index,
		"device_id": NO_DEVICE,
		"online": false,
		"is_local": raw["is_local"],
	}


# int, or an integral float within range; anything else gives null.
static func _to_int(value):
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_REAL and not is_nan(value) and not is_inf(value) \
			and value == floor(value) and abs(value) <= MAX_COUNTER:
		return int(value)
	return null
