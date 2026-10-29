extends Reference
# Bounded in-memory diagnostics for detections, rejections and recoveries
# (R16, R21, AP-008/AP-018; BACKGROUND section 8). Every record goes through
# the redactor before it is stored, so nothing kept in memory, exported or
# reported holds a raw Steam id, a token or the salt. The ring keeps the
# newest max_entries records; older ones are evicted and counted in
# dropped_count(), never lost without trace. Malformed calls are still
# stored (as KIND_MALFORMED or with problems listed) so a fault report is
# not lost because its caller was wrong.
# Also limits automatic recovery attempts per key (requirements section 5:
# at most 3 per phase, then stop advancing and offer a next step).
# Pure rules: time is passed in as now_msec, no autoloads, no scene tree.

const Redact = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/diagnostics/redact.gd")

const REPORT_SCHEMA := 1
const DEFAULT_MAX_ENTRIES := 256
const MAX_ENTRIES_LIMIT := 4096
const DEFAULT_MAX_RECOVERY_ATTEMPTS := 3
const MAX_RECOVERY_ATTEMPTS_LIMIT := 10
const MAX_RECOVERY_KEYS := 256
const MAX_RECOVERY_KEY_LENGTH := 256
const MAX_KIND_LENGTH := 64
const KIND_MALFORMED := "malformed_record"
# counts_by_kind keeps at most this many distinct kinds; further new kinds
# are counted together under KIND_OTHER (records keep their own kind). The
# bucket name holds characters a legal kind cannot, so it never collides.
const MAX_COUNTED_KINDS := 128
const KIND_OTHER := "<other_kinds>"
const NO_TIME := -1
# A context or header that is not a Dictionary is kept under this key.
const WRAPPED_VALUE_KEY := "value"

# Recommended context keys (BACKGROUND section 8: versions/fingerprints,
# session and phase stamps, slot summary, reason, recovery action, result).
# Free-form otherwise; slot entries should be {"identity": ..., "slot": n}
# so identities are hashed while slot numbers stay readable.
const CTX_RISK := "risk"
const CTX_VERSIONS := "versions"
const CTX_STAMP := "stamp"
const CTX_SLOTS := "slots"
const CTX_ACTION := "action"
const CTX_RESULT := "result"

const REASON_NONE := ""
const REASON_INVALID_CONFIG := "invalid_config"
const REASON_INVALID_KIND := "invalid_kind"
const REASON_INVALID_REASON := "invalid_reason"
const REASON_INVALID_CONTEXT := "invalid_context"
const REASON_INVALID_TIME := "invalid_time"
const REASON_INVALID_HEADER := "invalid_header"
const REASON_INVALID_KEY := "invalid_recovery_key"
const REASON_RECOVERY_EXHAUSTED := "recovery_attempts_exhausted"
const REASON_RECOVERY_TABLE_FULL := "recovery_key_table_full"

var max_entries: int = DEFAULT_MAX_ENTRIES
var max_recovery_attempts: int = DEFAULT_MAX_RECOVERY_ATTEMPTS
var redactor = null

var _salt := ""
var _kind_re := RegEx.new()
var _entries := []
var _next_seq := 1
var _total := 0
var _dropped := 0
var _counts := {}
# Raw key -> {"attempts", "denied"}. Raw keys stay in memory for matching
# and are redacted whenever they leave this object.
var _recovery := {}


# The salt should be random per session or report (for example from
# Crypto.generate_random_bytes in the adapter) and is never exported. A salt
# shorter than Redact.MIN_SALT_LENGTH is ignored (has_salt() is false).
func _init(p_salt = "", p_max_entries: int = DEFAULT_MAX_ENTRIES, p_max_recovery_attempts: int = DEFAULT_MAX_RECOVERY_ATTEMPTS, p_redactor = null) -> void:
	_salt = p_salt if typeof(p_salt) == TYPE_STRING and p_salt.length() >= Redact.MIN_SALT_LENGTH else ""
	max_entries = p_max_entries
	max_recovery_attempts = p_max_recovery_attempts
	redactor = p_redactor if typeof(p_redactor) == TYPE_OBJECT and p_redactor is Redact else Redact.new()
	_kind_re.compile("^[A-Za-z0-9_.:-]+$")


func is_valid() -> bool:
	return max_entries >= 1 and max_entries <= MAX_ENTRIES_LIMIT and max_recovery_attempts >= 1 and max_recovery_attempts <= MAX_RECOVERY_ATTEMPTS_LIMIT


# Without a salt identities are shown as "<prefix>:#nosalt" (not told apart).
func has_salt() -> bool:
	return _salt != ""


# kind: short code such as "recovery" or "join_rejected"; reason: one of the
# callers' reason constants; context: Dictionary (see CTX_*); now_msec: int.
# Returns {"ok", "reason", "seq", "evicted"}; ok is false when the input was
# malformed (the record is still stored) or when the log is misconfigured
# (nothing stored, counted as dropped, seq 0).
func record(kind, reason, context, now_msec) -> Dictionary:
	_total += 1
	if not is_valid():
		_dropped += 1
		return {"ok": false, "reason": REASON_INVALID_CONFIG, "seq": 0, "evicted": 0}
	var problems := []
	var safe_kind := _safe_kind(kind)
	if safe_kind == "":
		problems.append(REASON_INVALID_KIND)
		safe_kind = KIND_MALFORMED
	var safe_reason := ""
	if typeof(reason) == TYPE_STRING:
		safe_reason = str(redactor.redact_value(reason, _salt))
	elif typeof(reason) != TYPE_NIL:
		problems.append(REASON_INVALID_REASON)
		safe_reason = _cut_text(str(redactor.redact_value(reason, _salt)))
	var safe_context := _safe_dict(context, problems, REASON_INVALID_CONTEXT)
	var at_msec := _safe_time(now_msec)
	if at_msec == NO_TIME:
		problems.append(REASON_INVALID_TIME)
	var entry := {
		"seq": _next_seq,
		"at_msec": at_msec,
		"kind": safe_kind,
		"reason": safe_reason,
		"context": safe_context,
		"problems": problems.duplicate(),
	}
	_next_seq += 1
	_entries.append(entry)
	_count_kind(safe_kind)
	var evicted := 0
	while _entries.size() > max_entries:
		_entries.pop_front()
		evicted += 1
	_dropped += evicted
	return {"ok": problems.empty(), "reason": REASON_NONE if problems.empty() else problems[0], "seq": entry.seq, "evicted": evicted}


func entry_count() -> int:
	return _entries.size()


# Calls to record(), including ones that were not retained.
func total_recorded() -> int:
	return _total


# Records evicted by the ring plus records refused by a misconfigured log.
func dropped_count() -> int:
	return _dropped


# Counted when recorded, so eviction does not change these numbers. Kinds
# beyond MAX_COUNTED_KINDS distinct ones are summed under KIND_OTHER.
func counts_by_kind() -> Dictionary:
	return _counts.duplicate()


# Deep copies of the retained records, oldest first. ("export" is a GDScript
# keyword, hence the longer name.)
func export_records() -> Array:
	var out := []
	for e in _entries:
		out.append(e.duplicate(true))
	return out


# Everything a sanitized problem report needs. header carries run-level facts
# (versions, fingerprints, player count, backend, test ids) and is redacted
# with the same salt, so one player has the same short hash everywhere.
# A misconfigured log lists REASON_INVALID_CONFIG first, so an empty record
# list is never mistaken for "nothing happened".
func to_report(header) -> Dictionary:
	var problems := []
	if not is_valid():
		problems.append(REASON_INVALID_CONFIG)
	var safe_header := _safe_dict(header, problems, REASON_INVALID_HEADER)
	return {
		"schema": REPORT_SCHEMA,
		"problems": problems,
		"header": safe_header,
		"salted": has_salt(),
		"max_entries": max_entries,
		"total_recorded": _total,
		"retained": _entries.size(),
		"dropped": _dropped,
		"counts_by_kind": counts_by_kind(),
		"records": export_records(),
		"max_recovery_attempts": max_recovery_attempts,
		"recovery": recovery_summary(),
	}


# Consumes one attempt for key when allowed. key: non-empty String or int,
# typically risk + run/wave/phase stamp so "the same phase" is one key.
# Returns {"allowed", "reason", "attempt", "remaining"}. Unknown or invalid
# input is denied: the safe answer is to stop advancing, not to retry.
func request_recovery(key) -> Dictionary:
	if not is_valid():
		return _recovery_result(false, REASON_INVALID_CONFIG, 0)
	var k := _recovery_key(key)
	if k == "":
		return _recovery_result(false, REASON_INVALID_KEY, 0)
	if not _recovery.has(k):
		if _recovery.size() >= MAX_RECOVERY_KEYS:
			return _recovery_result(false, REASON_RECOVERY_TABLE_FULL, 0)
		_recovery[k] = {"attempts": 0, "denied": 0}
	var state: Dictionary = _recovery[k]
	if state["attempts"] >= max_recovery_attempts:
		state["denied"] += 1
		return _recovery_result(false, REASON_RECOVERY_EXHAUSTED, state["attempts"])
	state["attempts"] += 1
	return _recovery_result(true, REASON_NONE, state["attempts"])


func allow_recovery(key) -> bool:
	return request_recovery(key).allowed


func recovery_attempts(key) -> int:
	var k := _recovery_key(key)
	if k == "" or not _recovery.has(k):
		return 0
	return _recovery[k].attempts


# Forgets the attempts for key (call when the phase it guards completed or
# the run moved on). Returns whether the key was known.
func reset(key) -> bool:
	var k := _recovery_key(key)
	if k == "" or not _recovery.has(k):
		return false
	_recovery.erase(k)
	return true


func reset_all_recoveries() -> void:
	_recovery.clear()


# One row per key with the key redacted; a list, not a map, so two keys that
# redact alike cannot merge.
func recovery_summary() -> Array:
	var out := []
	for k in _recovery.keys():
		var state: Dictionary = _recovery[k]
		out.append({
			"key": str(redactor.redact_value(k, _salt)),
			"attempts": state.attempts,
			"denied": state.denied,
			"exhausted": state.attempts >= max_recovery_attempts,
		})
	return out


# remaining is 0 on every denial: a denied caller must stop, not retry.
func _recovery_result(allowed: bool, reason: String, attempt: int) -> Dictionary:
	var remaining := 0
	if allowed and is_valid():
		remaining = int(max(0, max_recovery_attempts - attempt))
	return {"allowed": allowed, "reason": reason, "attempt": attempt, "remaining": remaining}


func _count_kind(kind: String) -> void:
	var bucket := kind
	if not _counts.has(kind):
		var distinct := _counts.size() - (1 if _counts.has(KIND_OTHER) else 0)
		if distinct >= MAX_COUNTED_KINDS:
			bucket = KIND_OTHER
	_counts[bucket] = int(_counts.get(bucket, 0)) + 1


# Cuts already-redacted text to the redactor's string limit, with a marker.
func _cut_text(text: String) -> String:
	var limit := int(max(0, redactor.max_string_length))
	if text.length() <= limit:
		return text
	return text.substr(0, limit) + Redact.TRUNCATED_TEXT_FORMAT % (text.length() - limit)


func _recovery_key(key) -> String:
	var k := ""
	if typeof(key) == TYPE_STRING:
		k = key
	elif typeof(key) == TYPE_INT:
		k = str(key)
	if k.strip_edges() == "" or k.length() > MAX_RECOVERY_KEY_LENGTH:
		return ""
	return k


func _safe_kind(kind) -> String:
	if typeof(kind) != TYPE_STRING:
		return ""
	var k: String = kind.strip_edges()
	if k == "" or k.length() > MAX_KIND_LENGTH or _kind_re.search(k) == null:
		return ""
	return redactor.redact_text(k, _salt)


# null counts as an empty Dictionary; any other non-Dictionary is wrapped.
func _safe_dict(value, problems: Array, problem: String) -> Dictionary:
	if typeof(value) == TYPE_NIL:
		return {}
	if typeof(value) != TYPE_DICTIONARY:
		problems.append(problem)
		return {WRAPPED_VALUE_KEY: redactor.redact_value(value, _salt)}
	var redacted = redactor.redact_value(value, _salt)
	if typeof(redacted) != TYPE_DICTIONARY:
		return {WRAPPED_VALUE_KEY: redacted}
	return redacted


func _safe_time(now_msec) -> int:
	if typeof(now_msec) == TYPE_INT and now_msec >= 0:
		return now_msec
	if typeof(now_msec) == TYPE_REAL and now_msec >= 0.0 and now_msec < 9.0e18:
		return int(now_msec)
	return NO_TIME
