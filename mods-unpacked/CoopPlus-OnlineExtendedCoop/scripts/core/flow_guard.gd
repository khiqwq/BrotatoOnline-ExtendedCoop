extends Reference
# Scene/phase guard for one session (AP-012; F01, F06, F07, F08). Holds the
# committed flow stamp and decides what a message stamped with some flow
# state may do:
#   run_id             - opaque id of the run; a continued run keeps its id
#   wave, phase        - where the run is; wave never goes back between two
#                        begin_run() calls
#   roster_generation  - bumped by every committed roster remap (F11)
#   seq                - session-wide commit counter; every change bumps it
# The host is authoritative: it calls begin_run/advance/set_roster_generation
# and sends stamp() with each transition; clients adopt() that stamp so all
# peers share one seq order (a client must never advance on its own).
# seq alone orders stamps. A run continued from a checkpoint keeps its run id
# but starts wave and roster generation over, so those two never decide
# whether a message is old or new.
# Use one guard per session: seq never resets, so nothing from an earlier
# run or a retried attempt can match again.
# Pure rules: no autoloads, no scene tree, no clock.

const PHASE_RUN_START := "run_start"

const MAX_RUN_ID_LENGTH := 128
const MAX_PHASE_LENGTH := 64
const MAX_KEY_LENGTH := 128
# Commit keys are remembered for the current seq and the few before it. Only
# the current seq can be committed, so forgetting older ones never allows a
# second commit; the bound keeps memory fixed over long runs (F08).
const KEPT_COMMIT_SEQS := 4
const MAX_KEYS_PER_SEQ := 64
# Largest integer a float (parse_json output) holds exactly: 2^53 - 1.
const MAX_EXACT_INT := 9007199254740991

const REASON_NONE := ""
const REASON_UNCHANGED := "unchanged"
const REJECT_MALFORMED := "malformed_stamp"
const REJECT_NO_RUN := "no_active_run"
const REJECT_OTHER_RUN := "other_run"
const REJECT_STALE := "stale_stamp"
const REJECT_ROSTER_MISMATCH := "roster_generation_mismatch"
const REJECT_FUTURE := "future_stamp"
const REJECT_CONFLICT := "conflicting_stamp"
const REJECT_INVALID_RUN_ID := "invalid_run_id"
const REJECT_INVALID_WAVE := "invalid_wave"
const REJECT_WAVE_REGRESS := "wave_regress"
const REJECT_INVALID_PHASE := "invalid_phase"
const REJECT_ROSTER_REGRESS := "roster_generation_regress"
const REJECT_INVALID_KEY := "invalid_commit_key"
const REJECT_ALREADY_COMMITTED := "already_committed"
const REJECT_KEY_LIMIT := "commit_key_limit"

var _run_id := ""
var _wave := 0
var _phase := ""
var _roster_generation := 0
var _seq := 0
# seq -> {key: true}, only for the last KEPT_COMMIT_SEQS seqs.
var _committed := {}


func has_run() -> bool:
	return _seq > 0


# Copy of the committed stamp; changing it does not touch the guard.
func stamp() -> Dictionary:
	return {
		"run_id": _run_id,
		"wave": _wave,
		"phase": _phase,
		"roster_generation": _roster_generation,
		"seq": _seq
	}


# Starts or restarts a run (continuing from a checkpoint keeps the run id).
# Wave, phase and roster generation start over; seq keeps counting.
func begin_run(run_id: String) -> Dictionary:
	if not _is_valid_name(run_id, MAX_RUN_ID_LENGTH):
		return _change(false, REJECT_INVALID_RUN_ID, false)
	_run_id = run_id
	_wave = 0
	_phase = PHASE_RUN_START
	_roster_generation = 0
	_bump()
	return _change(true, REASON_NONE, true)


# Commits the next flow state. Every call is a new commit, also for the same
# wave and phase: a retried phase must not accept the failed attempt's messages.
func advance(wave: int, phase: String) -> Dictionary:
	if not has_run():
		return _change(false, REJECT_NO_RUN, false)
	if wave < 0:
		return _change(false, REJECT_INVALID_WAVE, false)
	if wave < _wave:
		return _change(false, REJECT_WAVE_REGRESS, false)
	if not _is_valid_name(phase, MAX_PHASE_LENGTH):
		return _change(false, REJECT_INVALID_PHASE, false)
	_wave = wave
	_phase = phase
	_bump()
	return _change(true, REASON_NONE, true)


# Commits a roster remap. Re-asserting the current generation is a no-op, so
# adapters may call it on every scene entry without invalidating messages.
func set_roster_generation(generation: int) -> Dictionary:
	if not has_run():
		return _change(false, REJECT_NO_RUN, false)
	if generation < _roster_generation:
		return _change(false, REJECT_ROSTER_REGRESS, false)
	if generation == _roster_generation:
		return _change(true, REASON_UNCHANGED, false)
	_roster_generation = generation
	_bump()
	return _change(true, REASON_NONE, true)


# Client side: take over a stamp committed by the host. Only a newer seq moves
# the guard (skipped seqs are fine); the same stamp again is a no-op. A newer
# seq wins even with a lower wave or roster generation: that is a restart from
# a checkpoint (begin_run with the same id), which this client may have
# skipped. Pass only stamps that really came from the host.
func adopt(host_stamp) -> Dictionary:
	var n = normalize_stamp(host_stamp)
	if not n.ok:
		return _change(false, REJECT_MALFORMED, false)
	var s: Dictionary = n.stamp
	if s.seq < _seq:
		return _change(false, REJECT_STALE, false)
	if s.seq == _seq:
		if _equals_current(s):
			return _change(true, REASON_UNCHANGED, false)
		return _change(false, REJECT_CONFLICT, false)
	_run_id = s.run_id
	_wave = s.wave
	_phase = s.phase
	_roster_generation = s.roster_generation
	_seq = s.seq
	_prune()
	return _change(true, REASON_NONE, true)


# Decides whether a message stamped with msg_stamp may act now: only the exact
# committed stamp is accepted. "ahead" is true when the message comes from a
# state this peer has not reached yet (e.g. a faster peer, F07): buffer it or
# request state, never execute it now. Anything else that is rejected is old
# or inconsistent and must be dropped without side effects (F08).
# A newer seq is always "ahead", even with a lower wave (a restart this peer
# has not seen yet); an inconsistent one fails once the peer has caught up.
# An older seq is a roster mismatch when its generation differs, else stale.
func check_stamp(msg_stamp) -> Dictionary:
	var n = normalize_stamp(msg_stamp)
	if not n.ok:
		return _verdict(false, REJECT_MALFORMED, false)
	var s: Dictionary = n.stamp
	if not has_run():
		return _verdict(false, REJECT_NO_RUN, true)
	if s.run_id != _run_id:
		# Relies on the shared host seq: a newer run always has a higher seq.
		return _verdict(false, REJECT_OTHER_RUN, s.seq > _seq)
	if s.seq > _seq:
		return _verdict(false, REJECT_FUTURE, true)
	if s.roster_generation != _roster_generation:
		return _verdict(false, REJECT_ROSTER_MISMATCH, false)
	if s.seq < _seq:
		return _verdict(false, REJECT_STALE, false)
	if not _equals_current(s):
		return _verdict(false, REJECT_CONFLICT, false)
	return _verdict(true, REASON_NONE, false)


# True exactly once per (current seq, key), e.g. "start_wave" when all eight
# confirmations arrive in one frame (F06). Check the triggering message with
# check_stamp() first, so a stale confirm never gets here; or use
# try_commit_for(), which does both.
func try_commit(key: String) -> bool:
	return commit(key).committed


# check_stamp() and commit() in one step: commits only while for_stamp is
# exactly the committed stamp, e.g. try_commit_for(barrier.stamp(),
# "start_wave"). A barrier that completed for a stamp the guard has since
# moved past (a remap, a retry) then cannot start anything in the new seq.
# On refusal "reason" is the check_stamp() or commit() reason.
func try_commit_for(for_stamp, key: String) -> bool:
	return commit_for(for_stamp, key).committed


func commit_for(for_stamp, key: String) -> Dictionary:
	var verdict = check_stamp(for_stamp)
	if not verdict.accepted:
		return _commit_result(false, verdict.reason)
	return commit(key)


func commit(key: String) -> Dictionary:
	if not has_run():
		return _commit_result(false, REJECT_NO_RUN)
	if not _is_valid_name(key, MAX_KEY_LENGTH):
		return _commit_result(false, REJECT_INVALID_KEY)
	var keys: Dictionary = _committed.get(_seq, {})
	if keys.has(key):
		return _commit_result(false, REJECT_ALREADY_COMMITTED)
	# Refusing is safe (nothing runs twice); the caller sees why it stalled.
	if keys.size() >= MAX_KEYS_PER_SEQ:
		return _commit_result(false, REJECT_KEY_LIMIT)
	keys[key] = true
	_committed[_seq] = keys
	return _commit_result(true, REASON_NONE)


# seq < 0 means the current seq. Seqs older than KEPT_COMMIT_SEQS answer false.
func was_committed(key: String, seq: int = -1) -> bool:
	var at: int = _seq if seq < 0 else seq
	if not _committed.has(at):
		return false
	return _committed[at].has(key)


func committed_key_count() -> int:
	var total := 0
	for at in _committed:
		total += _committed[at].size()
	return total


# Validates a stamp from any source (network, save, JSON) and returns a clean
# copy with int fields. Integral floats are accepted because parse_json turns
# every number into a float; fractional, infinite or out-of-range numbers,
# empty or oversized strings and missing keys are malformed. Extra keys are
# ignored. "field" names the first bad field for diagnostics.
static func normalize_stamp(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return _malformed("stamp")
	var run_id = raw.get("run_id")
	if typeof(run_id) != TYPE_STRING or not _is_valid_name(run_id, MAX_RUN_ID_LENGTH):
		return _malformed("run_id")
	var phase = raw.get("phase")
	if typeof(phase) != TYPE_STRING or not _is_valid_name(phase, MAX_PHASE_LENGTH):
		return _malformed("phase")
	var wave = int_or_null(raw.get("wave"))
	if typeof(wave) != TYPE_INT or wave < 0:
		return _malformed("wave")
	var roster_generation = int_or_null(raw.get("roster_generation"))
	if typeof(roster_generation) != TYPE_INT or roster_generation < 0:
		return _malformed("roster_generation")
	var seq = int_or_null(raw.get("seq"))
	if typeof(seq) != TYPE_INT or seq < 1:
		return _malformed("seq")
	return {
		"ok": true,
		"reason": REASON_NONE,
		"field": "",
		"stamp": {
			"run_id": run_id,
			"wave": wave,
			"phase": phase,
			"roster_generation": roster_generation,
			"seq": seq
		}
	}


static func is_valid_stamp(raw) -> bool:
	return normalize_stamp(raw).ok


# Field-by-field equality of two well-formed stamps (Godot 3 compares
# Dictionaries by reference, so == cannot be used).
static func same_stamp(a, b) -> bool:
	var na = normalize_stamp(a)
	var nb = normalize_stamp(b)
	if not na.ok or not nb.ok:
		return false
	for key in ["run_id", "wave", "phase", "roster_generation", "seq"]:
		if na.stamp[key] != nb.stamp[key]:
			return false
	return true


# int for ints and integral finite floats (JSON numbers), otherwise null.
# Booleans and numeric strings are not numbers here.
static func int_or_null(value):
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) != TYPE_REAL:
		return null
	if is_nan(value) or is_inf(value) or abs(value) > MAX_EXACT_INT:
		return null
	if value != floor(value):
		return null
	return int(value)


static func _is_valid_name(value: String, max_length: int) -> bool:
	return not value.empty() and value.length() <= max_length


static func _malformed(field: String) -> Dictionary:
	return {"ok": false, "reason": REJECT_MALFORMED, "field": field, "stamp": {}}


func _equals_current(s: Dictionary) -> bool:
	return s.run_id == _run_id and s.wave == _wave and s.phase == _phase \
			and s.roster_generation == _roster_generation and s.seq == _seq


func _bump() -> void:
	_seq += 1
	_prune()


func _prune() -> void:
	for at in _committed.keys():
		if at <= _seq - KEPT_COMMIT_SEQS:
			_committed.erase(at)


func _change(ok: bool, reason: String, changed: bool) -> Dictionary:
	return {"ok": ok, "reason": reason, "changed": changed, "stamp": stamp()}


func _verdict(accepted: bool, reason: String, ahead: bool) -> Dictionary:
	return {"accepted": accepted, "reason": reason, "ahead": ahead}


func _commit_result(committed: bool, reason: String) -> Dictionary:
	return {"committed": committed, "reason": reason, "seq": _seq}
