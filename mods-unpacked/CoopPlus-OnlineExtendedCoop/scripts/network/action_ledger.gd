extends Reference
# Host-side idempotency for menu actions (AP-011; F05 repeated spend, F08
# replayed/stale packets): buy, sell, reroll, lock, upgrade choice, chest
# choice, ready. An action is identified by (scope_key, sender, action_id):
#   scope_key  opaque non-empty String from the phase guard, built from the
#              session id plus run/wave/phase/roster generation. Only equality
#              is used, so every new phase must produce a new key. Parts that
#              can be longer than MAX_SCOPE_KEY_LENGTH together (FlowGuard
#              allows a 128 character run id) are hashed with
#              make_fingerprint([session, run_id, seq, ...]), 64 characters.
#   sender     identity String the transport authenticated, never a value read
#              from the payload; int Steam ids are passed as str(id).
#   action_id  int 1..MAX_ACTION_ID, counted up from 1 by each sender, unique
#              per sender within a scope. A retry reuses both the id and the
#              scope_key of its first copy; a retry stamped with a newer scope
#              is a new action there.
# Host flow, check and commit in the same frame:
#   var c = ledger.check(scope, sender, msg.action_id, msg.player_index, owns, fp)
#   STATUS_NEW        execute once, then commit(scope, sender, id, result); also
#                     commit refusals, e.g. {"ok": false, "reason": "no_gold"}
#   STATUS_DUPLICATE  do not execute; send c.result again
#   STATUS_PENDING    do not execute; the first copy has not committed yet
#   STATUS_REJECTED   do not execute; c.reason says why. For a retry this does
#                     not prove the first copy never ran (its id went stale or
#                     its scope closed meanwhile), so the client takes the
#                     host's state as the truth rather than "action failed".
# owns comes from the slot registry (does this sender control target_index?);
# fp is an optional make_fingerprint(...) of the action body, so an id reused
# for different content is refused instead of getting the earlier result.
#
# Bounds and "never twice": entries are capped per sender and in total, oldest
# (by arrival) evicted first. Each sender has a watermark, the highest id ever
# evicted for it (arrival order is not id order, so it only ever rises); an id
# at or below the watermark that is no longer stored is refused as stale. An
# evicted action is therefore refused, never executed again. Cost: a never-seen
# id lower than an evicted one (a very late, reordered packet) is refused too,
# and ids must grow per sender. The per-sender cap keeps one flooding sender
# from evicting the others' entries as long as max_entries is at least
# max_entries_per_sender x senders (the defaults: 512 = 64 x 8).
# Changing scope drops every entry. Closed scope keys are retired (the last
# MAX_RETIRED_SCOPES of them) and cannot be opened again, so old-phase traffic
# has no effect. Pure rules: no autoloads, no scene tree, no clock.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const STATUS_NEW := "new"
const STATUS_DUPLICATE := "duplicate"
const STATUS_PENDING := "pending"
const STATUS_REJECTED := "rejected"

const REASON_NONE := ""
const REASON_INVALID_CONFIG := "invalid_config"
const REASON_INVALID_SCOPE := "invalid_scope"
const REASON_NO_SCOPE := "no_scope"
const REASON_WRONG_SCOPE := "wrong_scope"
const REASON_SCOPE_RETIRED := "scope_retired"
const REASON_INVALID_SENDERS := "invalid_senders"
const REASON_NO_SENDERS := "no_senders"
const REASON_TOO_MANY_SENDERS := "too_many_senders"
const REASON_DUPLICATE_SENDER := "duplicate_sender"
const REASON_INVALID_SENDER := "invalid_sender"
const REASON_UNKNOWN_SENDER := "unknown_sender"
const REASON_MISSING_ACTION_ID := "missing_action_id"
const REASON_INVALID_ACTION_ID := "invalid_action_id"
const REASON_ACTION_ID_OUT_OF_RANGE := "action_id_out_of_range"
const REASON_INVALID_TARGET := "invalid_target"
const REASON_NOT_OWNER := "sender_not_owner"
const REASON_INVALID_FINGERPRINT := "invalid_fingerprint"
const REASON_ACTION_ID_REUSED := "action_id_reused"
const REASON_STALE_ACTION_ID := "stale_action_id"
const REASON_NOT_RESERVED := "not_reserved"
const REASON_ALREADY_COMMITTED := "already_committed"
const REASON_INVALID_RESULT := "invalid_result"

# Fits int32, so it survives var2bytes compactly and a float round trip exactly.
const MAX_ACTION_ID := 2147483647
const MAX_SCOPE_KEY_LENGTH := 128
const MAX_SENDER_LENGTH := 64
const MAX_FINGERPRINT_LENGTH := 64
const MAX_RETIRED_SCOPES := 64
const MAX_RESULT_DEPTH := 16
const DEFAULT_MAX_ENTRIES := 512
const DEFAULT_MAX_ENTRIES_PER_SENDER := 64

var max_entries: int = DEFAULT_MAX_ENTRIES
var max_entries_per_sender: int = DEFAULT_MAX_ENTRIES_PER_SENDER

var _scope := ""
var _senders := {}
# sender -> {action_id: {"target", "fingerprint", "committed", "result"}}
var _entries := {}
# sender -> watermark; stored-less ids at or below it are stale
var _floors := {}
var _highest := {}
# [sender, action_id] pairs, oldest first; its size is the entry count
var _order := []
var _retired := []
var _evicted := 0


func _init(p_max_entries: int = DEFAULT_MAX_ENTRIES, p_max_entries_per_sender: int = DEFAULT_MAX_ENTRIES_PER_SENDER) -> void:
	max_entries = p_max_entries
	max_entries_per_sender = p_max_entries_per_sender


func is_valid() -> bool:
	return max_entries >= 1 and max_entries_per_sender >= 1


# Opens scope_key for the identities allowed to submit in it (the current
# roster, 1..8). Repeating the open key only replaces the sender set and keeps
# every entry, so a sender removed and re-added still gets its stored results.
# Any failure closes the open scope (fail closed): nothing is accepted until a
# valid scope is begun. That includes a failed refresh of the open key, which
# retires it, so check the identity list (no empty slots) before refreshing.
# "dropped" counts the entries that were discarded.
func begin_scope(scope_key, senders) -> Dictionary:
	var reason := _begin_problem(scope_key, senders)
	if reason != REASON_NONE:
		return {"ok": false, "reason": reason, "dropped": end_scope()}
	var dropped := 0
	if scope_key != _scope:
		dropped = end_scope()
		_scope = scope_key
	_senders = {}
	for s in senders:
		_senders[s] = true
	return {"ok": true, "reason": REASON_NONE, "dropped": dropped}


# Drops every entry and retires the open scope key. Returns the dropped count.
func end_scope() -> int:
	var dropped := size()
	if _scope != "":
		_retired.append(_scope)
		while _retired.size() > MAX_RETIRED_SCOPES:
			_retired.pop_front()
	_scope = ""
	_senders = {}
	_entries = {}
	_floors = {}
	_highest = {}
	_order = []
	return dropped


# Same as end_scope(), and also resets the eviction counter. The retired keys
# are kept, so clearing never reopens an old phase.
func clear() -> void:
	end_scope()
	_evicted = 0


func current_scope() -> String:
	return _scope


func size() -> int:
	return _order.size()


func evicted_count() -> int:
	return _evicted


# Highest action id accepted from sender in the open scope (0 if none). The
# host can send it to a client that lost its counter so it resumes above it.
func highest_action_id(sender) -> int:
	return int(_highest.get(sender, 0))


func watermark(sender) -> int:
	return int(_floors.get(sender, 0))


# Rejections never reserve anything, so a refused message leaves no trace.
func check(scope_key, sender, action_id, target_index, sender_owns_target, fingerprint = "") -> Dictionary:
	var reason := _check_problem(scope_key, sender, action_id, target_index, sender_owns_target, fingerprint)
	if reason != REASON_NONE:
		return _rejected(reason)
	var per_sender: Dictionary = _entries.get(sender, {})
	if per_sender.has(action_id):
		var entry: Dictionary = per_sender[action_id]
		if entry.target != target_index or entry.fingerprint != fingerprint:
			return _rejected(REASON_ACTION_ID_REUSED)
		if not entry.committed:
			return {"status": STATUS_PENDING, "reason": REASON_NONE, "result": null}
		return {"status": STATUS_DUPLICATE, "reason": REASON_NONE, "result": _copy(entry.result)}
	if action_id <= watermark(sender):
		return _rejected(REASON_STALE_ACTION_ID)
	_reserve(sender, action_id, target_index, fingerprint)
	return {"status": STATUS_NEW, "reason": REASON_NONE, "result": null}


# Stores the outcome of an action check() reported as new. Only the first
# commit counts; later ones are refused and leave the stored result alone.
# Sender membership is not rechecked: a sender may leave while its action runs.
# result must be plain data (bool, int, float, String, Array, Dictionary).
func commit(scope_key, sender, action_id, result) -> Dictionary:
	var reason := _key_problem(scope_key, sender, action_id)
	if reason == REASON_NONE and (typeof(result) == TYPE_NIL or not _is_plain(result, 0)):
		reason = REASON_INVALID_RESULT
	if reason != REASON_NONE:
		return {"ok": false, "reason": reason}
	var per_sender: Dictionary = _entries.get(sender, {})
	if not per_sender.has(action_id):
		return {"ok": false, "reason": REASON_NOT_RESERVED}
	var entry: Dictionary = per_sender[action_id]
	if entry.committed:
		return {"ok": false, "reason": REASON_ALREADY_COMMITTED}
	entry.committed = true
	entry.result = _copy(result)
	return {"ok": true, "reason": REASON_NONE}


# SHA-256 hex of the action body for check(). Pass an Array of plain values in
# a fixed order, e.g. ["buy", player_index, shop_slot, item_id]; int and float
# encode differently, so normalise numbers before hashing, and avoid
# Dictionaries (their key order is part of the encoding). parts is untyped on
# purpose: in a release build a wrong type into a typed parameter is undefined,
# while var2bytes takes any value.
static func make_fingerprint(parts) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var2bytes(parts))
	return ctx.finish().hex_encode()


func _begin_problem(scope_key, senders) -> String:
	if not is_valid():
		return REASON_INVALID_CONFIG
	if not _is_valid_scope_key(scope_key):
		return REASON_INVALID_SCOPE
	if scope_key != _scope and _retired.has(scope_key):
		return REASON_SCOPE_RETIRED
	if typeof(senders) != TYPE_ARRAY:
		return REASON_INVALID_SENDERS
	if senders.empty():
		return REASON_NO_SENDERS
	if senders.size() > CapacityPolicy.MAX_SUPPORTED_PLAYERS:
		return REASON_TOO_MANY_SENDERS
	var seen := {}
	for s in senders:
		if not _is_valid_sender(s):
			return REASON_INVALID_SENDER
		if seen.has(s):
			return REASON_DUPLICATE_SENDER
		seen[s] = true
	return REASON_NONE


func _key_problem(scope_key, sender, action_id) -> String:
	if not is_valid():
		return REASON_INVALID_CONFIG
	if not _is_valid_scope_key(scope_key):
		return REASON_INVALID_SCOPE
	if _scope == "":
		return REASON_NO_SCOPE
	if scope_key != _scope:
		return REASON_WRONG_SCOPE
	if not _is_valid_sender(sender):
		return REASON_INVALID_SENDER
	if typeof(action_id) == TYPE_NIL:
		return REASON_MISSING_ACTION_ID
	if typeof(action_id) != TYPE_INT:
		return REASON_INVALID_ACTION_ID
	if action_id < 1 or action_id > MAX_ACTION_ID:
		return REASON_ACTION_ID_OUT_OF_RANGE
	return REASON_NONE


func _check_problem(scope_key, sender, action_id, target_index, sender_owns_target, fingerprint) -> String:
	var reason := _key_problem(scope_key, sender, action_id)
	if reason != REASON_NONE:
		return reason
	if not _senders.has(sender):
		return REASON_UNKNOWN_SENDER
	if typeof(target_index) != TYPE_INT or target_index < 0 or target_index >= CapacityPolicy.MAX_SUPPORTED_PLAYERS:
		return REASON_INVALID_TARGET
	# Anything but a real true (null, 1, "true") counts as not owning the slot.
	if typeof(sender_owns_target) != TYPE_BOOL or not sender_owns_target:
		return REASON_NOT_OWNER
	if typeof(fingerprint) != TYPE_STRING or fingerprint.length() > MAX_FINGERPRINT_LENGTH:
		return REASON_INVALID_FINGERPRINT
	return REASON_NONE


func _is_valid_scope_key(scope_key) -> bool:
	return typeof(scope_key) == TYPE_STRING and scope_key.length() >= 1 and scope_key.length() <= MAX_SCOPE_KEY_LENGTH


func _is_valid_sender(sender) -> bool:
	return typeof(sender) == TYPE_STRING and sender.length() >= 1 and sender.length() <= MAX_SENDER_LENGTH


func _reserve(sender: String, action_id: int, target_index: int, fingerprint: String) -> void:
	if not _entries.has(sender):
		_entries[sender] = {}
	_entries[sender][action_id] = {"target": target_index, "fingerprint": fingerprint, "committed": false, "result": null}
	_order.append([sender, action_id])
	if action_id > highest_action_id(sender):
		_highest[sender] = action_id
	# The new entry is the newest, so neither loop can evict it.
	while _entries[sender].size() > max_entries_per_sender:
		_evict_at(_oldest_index_of(sender))
	while _order.size() > max_entries:
		_evict_at(0)


func _oldest_index_of(sender: String) -> int:
	for i in range(_order.size()):
		if _order[i][0] == sender:
			return i
	return -1


func _evict_at(index: int) -> void:
	var pair: Array = _order[index]
	_order.remove(index)
	var sender: String = pair[0]
	var action_id: int = pair[1]
	_entries[sender].erase(action_id)
	# Evictions follow arrival order, not id order: lowering the watermark here
	# would let a replay of a higher evicted id run again.
	if action_id > watermark(sender):
		_floors[sender] = action_id
	_evicted += 1


func _rejected(reason: String) -> Dictionary:
	return {"status": STATUS_REJECTED, "reason": reason, "result": null}


# Plain data only: an Object (node, resource) stored here could be freed or
# changed long before a retry asks for it. The depth limit also stops cycles.
func _is_plain(value, depth: int) -> bool:
	if depth > MAX_RESULT_DEPTH:
		return false
	var t := typeof(value)
	if t == TYPE_NIL or t == TYPE_BOOL or t == TYPE_INT or t == TYPE_REAL or t == TYPE_STRING:
		return true
	if t == TYPE_ARRAY:
		for v in value:
			if not _is_plain(v, depth + 1):
				return false
		return true
	if t == TYPE_DICTIONARY:
		for k in value:
			if not _is_plain(k, depth + 1) or not _is_plain(value[k], depth + 1):
				return false
		return true
	return false


func _copy(value):
	if typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_DICTIONARY:
		return value.duplicate(true)
	return value
