extends Reference
# Ready barrier for one scene/phase transition (AP-012; F01, F06, F07). The
# host lists the stable slots that must confirm; a confirmation counts only
# with the exact flow stamp the barrier was built for. poll() reports progress
# against the R18 budget (hint after 10 s, retry/return path after 30 s).
#   - complete only when every expected slot is ready, never "the first four"
#   - a slot leaves the expected set only through remove_expected(), an
#     explicit host decision; nothing is dropped automatically (F01)
#   - complete and timed out are terminal; a retry builds a new barrier,
#     normally after FlowGuard.advance() so old confirmations cannot count
#   - the deadline is evaluated by poll() only: readies recorded before the
#     poll that reports STATE_TIMED_OUT still count
# Slot ids are the slot registry's stable ids (non-negative ints); they need
# not be 0-based or contiguous. Integral floats (JSON) are the same slot.
# Pure rules: the caller passes the time in; nothing reads a clock.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const FlowGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd")

# docs/requirements.md section 5 (R18), scene/phase ready barrier.
const DEFAULT_HINT_AFTER_MSEC := 10000
const DEFAULT_TIMEOUT_MSEC := 30000

const STATE_WAITING := "waiting"
const STATE_WAITING_HINT := "waiting_hint"
const STATE_COMPLETE := "complete"
const STATE_TIMED_OUT := "timed_out"
# Only for a barrier built from bad arguments (see init_reason()). It never
# completes, so a caller bug cannot let the flow continue without players.
const STATE_INVALID := "invalid"

const REASON_NONE := ""
const REASON_ALREADY_READY := "already_ready"
const REASON_ALREADY_REMOVED := "already_removed"
const REJECT_INVALID_BARRIER := "invalid_barrier"
const REJECT_NO_SLOTS := "no_expected_slots"
const REJECT_TOO_MANY_SLOTS := "too_many_slots"
const REJECT_INVALID_SLOT := "invalid_slot"
const REJECT_DUPLICATE_SLOT := "duplicate_slot"
const REJECT_INVALID_TIMING := "invalid_timing"
const REJECT_MALFORMED_STAMP := "malformed_stamp"
const REJECT_WRONG_STAMP := "wrong_stamp"
const REJECT_NOT_EXPECTED := "slot_not_expected"
const REJECT_REMOVED := "slot_removed"
const REJECT_TIMED_OUT := "barrier_timed_out"
const REJECT_COMPLETE := "barrier_complete"
const REJECT_LAST_SLOT := "last_expected_slot"

var _init_reason := REASON_NONE
var _stamp := {}
var _expected := []
var _ready_set := {}
var _removed := []
var _started_msec := 0
var _hint_after_msec := DEFAULT_HINT_AFTER_MSEC
var _timeout_msec := DEFAULT_TIMEOUT_MSEC
var _state := STATE_INVALID


# p_expected_slots: Array of slot ids (1..8 of them, no duplicates);
# p_stamp: the committed FlowGuard stamp this transition belongs to.
# Bad arguments give an invalid barrier instead of a script error.
func _init(p_expected_slots, p_stamp, p_started_msec: int, p_hint_after_msec: int = DEFAULT_HINT_AFTER_MSEC, p_timeout_msec: int = DEFAULT_TIMEOUT_MSEC) -> void:
	_started_msec = p_started_msec
	_hint_after_msec = p_hint_after_msec
	_timeout_msec = p_timeout_msec
	_init_reason = _setup(p_expected_slots, p_stamp)
	_state = STATE_WAITING if _init_reason == REASON_NONE else STATE_INVALID


func is_valid() -> bool:
	return _init_reason == REASON_NONE


func init_reason() -> String:
	return _init_reason


# Records one slot's confirmation. Repeats are harmless: ok with
# REASON_ALREADY_READY and changed == false.
func mark_ready(slot, msg_stamp) -> Dictionary:
	if not is_valid():
		return _result(false, REJECT_INVALID_BARRIER, false)
	var n = FlowGuard.normalize_stamp(msg_stamp)
	if not n.ok:
		return _result(false, REJECT_MALFORMED_STAMP, false)
	if not FlowGuard.same_stamp(n.stamp, _stamp):
		return _result(false, REJECT_WRONG_STAMP, false)
	var s = _slot_or_null(slot)
	if typeof(s) != TYPE_INT:
		return _result(false, REJECT_INVALID_SLOT, false)
	if _removed.has(s):
		return _result(false, REJECT_REMOVED, false)
	if not _expected.has(s):
		return _result(false, REJECT_NOT_EXPECTED, false)
	if _ready_set.has(s):
		return _result(true, REASON_ALREADY_READY, false)
	if _state == STATE_TIMED_OUT:
		return _result(false, REJECT_TIMED_OUT, false)
	_ready_set[s] = true
	_update_complete()
	return _result(true, REASON_NONE, true)


# Explicit host decision to stop waiting for one slot (for example a member
# the host chose to drop at the waiting hint). Never called automatically;
# the slot stays listed in removed() so the decision remains visible.
func remove_expected(slot) -> Dictionary:
	if not is_valid():
		return _result(false, REJECT_INVALID_BARRIER, false)
	if _state == STATE_COMPLETE:
		return _result(false, REJECT_COMPLETE, false)
	if _state == STATE_TIMED_OUT:
		return _result(false, REJECT_TIMED_OUT, false)
	var s = _slot_or_null(slot)
	if typeof(s) != TYPE_INT:
		return _result(false, REJECT_INVALID_SLOT, false)
	if _removed.has(s):
		return _result(true, REASON_ALREADY_REMOVED, false)
	if not _expected.has(s):
		return _result(false, REJECT_NOT_EXPECTED, false)
	# An empty barrier would "complete" with nobody; end the flow instead.
	if _expected.size() == 1:
		return _result(false, REJECT_LAST_SLOT, false)
	_expected.erase(s)
	_ready_set.erase(s)
	_removed.append(s)
	_removed.sort()
	_update_complete()
	return _result(true, REASON_NONE, true)


# Call every frame/tick with the current time. Elapsed time is measured from
# started_msec; a reading before the start counts as no time passed.
func poll(now_msec: int) -> String:
	if _state == STATE_INVALID or _state == STATE_COMPLETE or _state == STATE_TIMED_OUT:
		return _state
	var elapsed := now_msec - _started_msec
	if elapsed >= _timeout_msec:
		_state = STATE_TIMED_OUT
	elif elapsed >= _hint_after_msec:
		_state = STATE_WAITING_HINT
	else:
		_state = STATE_WAITING
	return _state


# Last state reported or latched, without looking at the time.
func state() -> String:
	return _state


func is_complete() -> bool:
	return _state == STATE_COMPLETE


func is_timed_out() -> bool:
	return _state == STATE_TIMED_OUT


func stamp() -> Dictionary:
	return _stamp.duplicate()


# Slot lists are sorted ascending copies. An invalid barrier has no slots, so
# missing() is empty there too: test is_complete(), never missing().empty().
func expected() -> Array:
	return _expected.duplicate()


func ready_slots() -> Array:
	var out := []
	for s in _expected:
		if _ready_set.has(s):
			out.append(s)
	return out


func missing() -> Array:
	var out := []
	for s in _expected:
		if not _ready_set.has(s):
			out.append(s)
	return out


func removed() -> Array:
	return _removed.duplicate()


func started_msec() -> int:
	return _started_msec


func hint_at_msec() -> int:
	return _started_msec + _hint_after_msec


func deadline_msec() -> int:
	return _started_msec + _timeout_msec


# Time left before the timeout, 0..timeout; 0 once the barrier is no longer
# waiting. Like poll(), a reading before the start counts as no time passed.
func remaining_msec(now_msec: int) -> int:
	if _state != STATE_WAITING and _state != STATE_WAITING_HINT:
		return 0
	var elapsed := int(max(0, now_msec - _started_msec))
	return int(max(0, _timeout_msec - elapsed))


func _setup(slots, p_stamp) -> String:
	if _hint_after_msec < 0 or _timeout_msec <= 0 or _hint_after_msec > _timeout_msec:
		return REJECT_INVALID_TIMING
	var n = FlowGuard.normalize_stamp(p_stamp)
	if not n.ok:
		return REJECT_MALFORMED_STAMP
	if typeof(slots) != TYPE_ARRAY or slots.empty():
		return REJECT_NO_SLOTS
	# Reported, never cut down to the first eight (F01).
	if slots.size() > CapacityPolicy.MAX_SUPPORTED_PLAYERS:
		return REJECT_TOO_MANY_SLOTS
	var clean := []
	for raw in slots:
		var s = _slot_or_null(raw)
		if typeof(s) != TYPE_INT:
			return REJECT_INVALID_SLOT
		if clean.has(s):
			return REJECT_DUPLICATE_SLOT
		clean.append(s)
	clean.sort()
	_expected = clean
	_stamp = n.stamp
	return REASON_NONE


func _update_complete() -> void:
	for s in _expected:
		if not _ready_set.has(s):
			return
	_state = STATE_COMPLETE


static func _slot_or_null(raw):
	var s = FlowGuard.int_or_null(raw)
	if typeof(s) == TYPE_INT and s >= 0:
		return s
	return null


func _result(ok: bool, reason: String, changed: bool) -> Dictionary:
	return {"ok": ok, "reason": reason, "changed": changed}
