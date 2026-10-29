extends Reference
# Isolated checkpoint store for >4-player runs (AP-016; R12, R13; F12, F13, F14).
# One checkpoint = game state + identity mapping, written and recovered as one
# unit, so state from one checkpoint is never paired with identities from
# another. Everything lives under the caller's base_dir (a user:// path);
# nothing outside it is read, written or removed:
#   <base_dir>/<run_id>/staging/   being written; never loaded
#   <base_dir>/<run_id>/current/   newest committed checkpoint
#   <base_dir>/<run_id>/previous/  the one before it
# Each slot holds state.bin, identities.bin and commit.bin. The commit record
# (checkpoint id, schema, SHA-256 + size of both payload files) is written last
# and removed first, so a slot without a matching record is never loaded.
# Write order: staging payloads -> read back + hash check -> commit record ->
# remove the slot being discarded -> current to previous -> staging to current.
# Directory.rename never overwrites here: the target is always removed first
# (on Windows the engine refuses to rename onto an existing directory).
# Paths are bounded (MAX_OS_PATH_LENGTH): on the game's engine, opening a file,
# dir_exists and rename fail beyond 259 characters on Windows while
# make_dir_recursive still succeeds, so an over-long run could be written but
# its previous copy never read back.
# A slot that exists but cannot be read (I/O error, e.g. a locked file) may
# still hold the newest commit: it is reported, never skipped or discarded.
# Pure rules: no autoloads, no scene tree, no clock. Single writer per run.

const STORE_FORMAT := 1
const DEFAULT_SCHEMA_VERSION := 1

const SLOT_STAGING := "staging"
const SLOT_CURRENT := "current"
const SLOT_PREVIOUS := "previous"
const SLOTS := [SLOT_STAGING, SLOT_CURRENT, SLOT_PREVIOUS]
const STATE_FILE := "state.bin"
const IDENTITIES_FILE := "identities.bin"
const COMMIT_FILE := "commit.bin"
# Removal order: commit record first, so a half-removed slot reads as
# "missing commit" instead of a loadable mix.
const SLOT_FILES := [COMMIT_FILE, STATE_FILE, IDENTITIES_FILE]

const KIND_STATE := "state"
const KIND_IDENTITIES := "identities"

const SOURCE_CURRENT := "current"
const SOURCE_PREVIOUS := "previous"

# write_checkpoint(..., fault_stage) returns right after the named stage as if
# the process had died there (no cleanup). Every stage is passed on every
# write, possibly as a no-op, so a requested fault always fires.
const STAGE_STAGING_READY := "staging_ready"
const STAGE_STATE_WRITTEN := "state_written"
const STAGE_IDENTITIES_WRITTEN := "identities_written"
const STAGE_VERIFIED := "verified"
const STAGE_COMMIT_WRITTEN := "commit_written"
const STAGE_OLD_COMMIT_REMOVED := "old_commit_removed"
const STAGE_OLD_REMOVED := "old_removed"
const STAGE_CURRENT_ROTATED := "current_rotated"
const STAGE_PROMOTED := "promoted"
const FAULT_STAGES := [
	STAGE_STAGING_READY,
	STAGE_STATE_WRITTEN,
	STAGE_IDENTITIES_WRITTEN,
	STAGE_VERIFIED,
	STAGE_COMMIT_WRITTEN,
	STAGE_OLD_COMMIT_REMOVED,
	STAGE_OLD_REMOVED,
	STAGE_CURRENT_ROTATED,
	STAGE_PROMOTED,
]

const REASON_NONE := ""
const REASON_INVALID_BASE_DIR := "invalid_base_dir"
const REASON_INVALID_SCHEMA_VERSION := "invalid_schema_version"
const REASON_INVALID_RUN_ID := "invalid_run_id"
const REASON_PATH_TOO_LONG := "path_too_long"
const REASON_UNKNOWN_FAULT_STAGE := "unknown_fault_stage"
const REASON_UNSUPPORTED_VALUE := "unsupported_value"
const REASON_PAYLOAD_TOO_LARGE := "payload_too_large"
const REASON_FOREIGN_FILES := "foreign_files"
const REASON_IO_ERROR := "io_error"
const REASON_VERIFY_FAILED := "verify_failed"
const REASON_SIMULATED_FAULT := "simulated_fault"
const REASON_UNSUPPORTED_SCHEMA := "unsupported_schema"
const REASON_NOT_FOUND := "not_found"
const REASON_NO_VALID_CHECKPOINT := "no_valid_checkpoint"
# Per-slot reasons, reported as current_reason / previous_reason.
const REASON_SLOT_MISSING := "slot_missing"
const REASON_MISSING_COMMIT := "missing_commit"
const REASON_MISSING_PAYLOAD := "missing_payload"
const REASON_CORRUPTED := "corrupted"
const REASON_HASH_MISMATCH := "hash_mismatch"
const REASON_CHECKPOINT_MISMATCH := "checkpoint_mismatch"

const USER_PREFIX := "user://"
# Lowercase only: Windows paths are case-insensitive, so "Run" and "run" would
# share a directory and one run could discard the other's checkpoint.
const RUN_ID_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789_-"
const MAX_RUN_ID_LENGTH := 64
const RESERVED_NAMES := [
	"con", "prn", "aux", "nul",
	"com0", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
	"lpt0", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
]
# Longest absolute path (ProjectSettings.globalize_path) of any file the store
# writes for a run. Measured limit on the game's engine is 259; the rest is
# headroom.
const MAX_OS_PATH_LENGTH := 250

const MAX_PAYLOAD_FILE_BYTES := 16 * 1024 * 1024
const MAX_COMMIT_FILE_BYTES := 64 * 1024
# Bounds for payload validation; also stop self-containing arrays before
# var2bytes would recurse forever on them.
const MAX_VALUE_DEPTH := 32
const MAX_VALUE_NODES := 500000
# Plain data only. Objects (and RIDs/NodePaths) are refused on write and on read.
const LEAF_TYPES := [
	TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_REAL, TYPE_STRING,
	TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR,
	TYPE_RAW_ARRAY, TYPE_INT_ARRAY, TYPE_REAL_ARRAY, TYPE_STRING_ARRAY, TYPE_VECTOR2_ARRAY,
]

# File frame: "CPCK" | u32 frame version | u32 payload length | SHA-256(payload) | payload.
# The payload is var2bytes() output, decoded with objects disallowed.
const FRAME_MAGIC := "CPCK"
const FRAME_VERSION := 1
const FRAME_HEADER_SIZE := 44
const SHA256_HEX_LENGTH := 64

var base_dir: String = ""
var schema_version: int = DEFAULT_SCHEMA_VERSION


func _init(p_base_dir: String, p_schema_version: int = DEFAULT_SCHEMA_VERSION) -> void:
	base_dir = p_base_dir
	if base_dir.ends_with("/") and not base_dir.ends_with("://"):
		base_dir = base_dir.substr(0, base_dir.length() - 1)
	schema_version = p_schema_version


func is_valid() -> bool:
	return _config_reason() == REASON_NONE


func is_valid_run_id(run_id: String) -> bool:
	if run_id.length() < 1 or run_id.length() > MAX_RUN_ID_LENGTH:
		return false
	for i in range(run_id.length()):
		if RUN_ID_CHARS.find(run_id[i]) < 0:
			return false
	return not RESERVED_NAMES.has(run_id)


# "" for an invalid store or run id (or a path over MAX_OS_PATH_LENGTH), so
# callers cannot build a path from it.
func get_run_dir(run_id: String) -> String:
	if _target_reason(run_id) != REASON_NONE:
		return ""
	return base_dir.plus_file(run_id)


# Writes state + identities as one checkpoint. ok is true only once the new
# checkpoint is current and has been read back; any earlier failure leaves the
# last committed checkpoint readable.
func write_checkpoint(run_id: String, state: Dictionary, identities: Dictionary, fault_stage: String = "") -> Dictionary:
	var reason := _target_reason(run_id)
	if reason != REASON_NONE:
		return _write_result(false, reason, "", 0)
	if fault_stage != "" and not FAULT_STAGES.has(fault_stage):
		return _write_result(false, REASON_UNKNOWN_FAULT_STAGE, "", 0)
	if not _is_plain_value(state, 0, [0]) or not _is_plain_value(identities, 0, [0]):
		return _write_result(false, REASON_UNSUPPORTED_VALUE, "", 0)

	var run_dir := base_dir.plus_file(run_id)
	var staging := run_dir.plus_file(SLOT_STAGING)
	var current := run_dir.plus_file(SLOT_CURRENT)
	var previous := run_dir.plus_file(SLOT_PREVIOUS)
	# Refuse up front rather than stopping half-way on files we did not create.
	for slot_dir in [staging, current, previous]:
		if not _slot_is_clean(slot_dir):
			return _write_result(false, REASON_FOREIGN_FILES, "", 0)
	var cur := _inspect_slot(run_id, current)
	var prev := _inspect_slot(run_id, previous)
	# A checkpoint from another schema is never rotated away or overwritten.
	if cur.reason == REASON_UNSUPPORTED_SCHEMA or prev.reason == REASON_UNSUPPORTED_SCHEMA:
		return _write_result(false, REASON_UNSUPPORTED_SCHEMA, "", 0)
	# An unreadable current may be the newest commit; discarding it (the path
	# for a broken current) could lose it if this write then fails.
	if cur.reason == REASON_IO_ERROR:
		return _write_result(false, REASON_IO_ERROR, "", 0)

	var sequence: int = cur.sequence
	if prev.sequence > sequence:
		sequence = prev.sequence
	sequence += 1
	var state_raw: PoolByteArray = var2bytes(state, false)
	var identities_raw: PoolByteArray = var2bytes(identities, false)
	var id_source: String = "%s|%d|%s|%s" % [run_id, sequence, _sha256_hex(state_raw), _sha256_hex(identities_raw)]
	var checkpoint_id: String = "%08d-%s" % [sequence, id_source.sha256_text().substr(0, 16)]
	var state_file := _frame(var2bytes(_envelope(KIND_STATE, run_id, checkpoint_id, state), false))
	var identities_file := _frame(var2bytes(_envelope(KIND_IDENTITIES, run_id, checkpoint_id, identities), false))
	if state_file.size() > MAX_PAYLOAD_FILE_BYTES or identities_file.size() > MAX_PAYLOAD_FILE_BYTES:
		return _write_result(false, REASON_PAYLOAD_TOO_LARGE, checkpoint_id, sequence)

	var dir := Directory.new()
	reason = _remove_slot(staging)
	if reason != REASON_NONE:
		return _write_result(false, reason, checkpoint_id, sequence)
	if dir.make_dir_recursive(staging) != OK:
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_STAGING_READY:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	if not _write_file(staging.plus_file(STATE_FILE), state_file):
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_STATE_WRITTEN:
		return _fault_result(fault_stage, checkpoint_id, sequence)
	if not _write_file(staging.plus_file(IDENTITIES_FILE), identities_file):
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_IDENTITIES_WRITTEN:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	var state_hash := _sha256_hex(state_file)
	var identities_hash := _sha256_hex(identities_file)
	if not _file_matches(staging.plus_file(STATE_FILE), state_file.size(), state_hash) \
			or not _file_matches(staging.plus_file(IDENTITIES_FILE), identities_file.size(), identities_hash):
		return _write_result(false, REASON_VERIFY_FAILED, checkpoint_id, sequence)
	if fault_stage == STAGE_VERIFIED:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	var record := {
		"store_format": STORE_FORMAT,
		"schema": schema_version,
		"run_id": run_id,
		"checkpoint_id": checkpoint_id,
		"sequence": sequence,
		"state_sha256": state_hash,
		"state_size": state_file.size(),
		"identities_sha256": identities_hash,
		"identities_size": identities_file.size(),
	}
	var commit_file := _frame(var2bytes(record, false))
	if not _write_file(staging.plus_file(COMMIT_FILE), commit_file):
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if not _file_matches(staging.plus_file(COMMIT_FILE), commit_file.size(), _sha256_hex(commit_file)):
		return _write_result(false, REASON_VERIFY_FAILED, checkpoint_id, sequence)
	if fault_stage == STAGE_COMMIT_WRITTEN:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	# A valid current becomes previous; a broken or missing current is the one
	# discarded, so the last good previous survives.
	var discard: String = previous if cur.ok else current
	if not _remove_file(discard.plus_file(COMMIT_FILE)):
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_OLD_COMMIT_REMOVED:
		return _fault_result(fault_stage, checkpoint_id, sequence)
	reason = _remove_slot(discard)
	if reason != REASON_NONE:
		return _write_result(false, reason, checkpoint_id, sequence)
	if fault_stage == STAGE_OLD_REMOVED:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	if cur.ok:
		if dir.dir_exists(previous) or dir.rename(current, previous) != OK:
			return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_CURRENT_ROTATED:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	if dir.dir_exists(current) or dir.rename(staging, current) != OK:
		return _write_result(false, REASON_IO_ERROR, checkpoint_id, sequence)
	if fault_stage == STAGE_PROMOTED:
		return _fault_result(fault_stage, checkpoint_id, sequence)

	var check := _inspect_slot(run_id, current)
	if not check.ok or check.checkpoint_id != checkpoint_id:
		return _write_result(false, REASON_VERIFY_FAILED, checkpoint_id, sequence)
	return _write_result(true, REASON_NONE, checkpoint_id, sequence)


# Newest fully committed checkpoint: current, else previous. An unsupported
# schema stops the search (no silent rollback to an older checkpoint) and is
# reported before any payload is loaded. So does an unreadable current
# (REASON_IO_ERROR, worth retrying): it may hold the newest commit.
func read_latest(run_id: String) -> Dictionary:
	var reason := _target_reason(run_id)
	if reason != REASON_NONE:
		return _read_failure(reason)
	var run_dir := base_dir.plus_file(run_id)
	var cur := _inspect_slot(run_id, run_dir.plus_file(SLOT_CURRENT))
	if cur.ok:
		return _read_success(cur, SOURCE_CURRENT, REASON_NONE)
	if cur.reason == REASON_UNSUPPORTED_SCHEMA:
		return _unsupported_schema(cur, REASON_NONE)
	if cur.reason == REASON_IO_ERROR:
		var unreadable := _read_failure(REASON_IO_ERROR)
		unreadable.current_reason = cur.reason
		return unreadable
	var prev := _inspect_slot(run_id, run_dir.plus_file(SLOT_PREVIOUS))
	if prev.ok:
		return _read_success(prev, SOURCE_PREVIOUS, cur.reason)
	if prev.reason == REASON_UNSUPPORTED_SCHEMA:
		return _unsupported_schema(prev, cur.reason)
	var nothing: bool = cur.reason == REASON_SLOT_MISSING and prev.reason == REASON_SLOT_MISSING
	var out := _read_failure(REASON_NOT_FOUND if nothing else REASON_NO_VALID_CHECKPOINT)
	if prev.reason == REASON_IO_ERROR:
		out.reason = REASON_IO_ERROR
	out.current_reason = cur.reason
	out.previous_reason = prev.reason
	return out


# Run ids that have a directory under base_dir, sorted. Entries this store
# could not use (invalid run id, path too long) are ignored, never reported.
func list_runs() -> Dictionary:
	var reason := _config_reason()
	if reason != REASON_NONE:
		return {"ok": false, "runs": [], "reason": reason}
	var runs := []
	var dir := Directory.new()
	if dir.dir_exists(base_dir):
		var entries = _list_entries(base_dir)
		if entries == null:
			return {"ok": false, "runs": [], "reason": REASON_IO_ERROR}
		for name in entries:
			if entries[name] and _target_reason(name) == REASON_NONE:
				runs.append(name)
	runs.sort()
	return {"ok": true, "runs": runs, "reason": REASON_NONE}


# Removes one run directory. Only files this store creates are removed; any
# other entry makes the whole call refuse before anything is deleted.
func delete_run(run_id: String) -> Dictionary:
	var reason := _target_reason(run_id)
	if reason != REASON_NONE:
		return {"ok": false, "deleted": false, "reason": reason}
	var run_dir := base_dir.plus_file(run_id)
	var dir := Directory.new()
	if not dir.dir_exists(run_dir):
		return {"ok": true, "deleted": false, "reason": REASON_NONE}
	if not _run_is_clean(run_dir):
		return {"ok": false, "deleted": false, "reason": REASON_FOREIGN_FILES}
	# Newest slot last, so an interrupted delete still leaves current readable.
	for slot in [SLOT_STAGING, SLOT_PREVIOUS, SLOT_CURRENT]:
		reason = _remove_slot(run_dir.plus_file(slot))
		if reason != REASON_NONE:
			return {"ok": false, "deleted": false, "reason": reason}
	if dir.remove(run_dir) != OK:
		return {"ok": false, "deleted": false, "reason": REASON_IO_ERROR}
	return {"ok": true, "deleted": true, "reason": REASON_NONE}


func _config_reason() -> String:
	if not _is_safe_base_dir(base_dir):
		return REASON_INVALID_BASE_DIR
	if schema_version < 1:
		return REASON_INVALID_SCHEMA_VERSION
	return REASON_NONE


func _target_reason(run_id: String) -> String:
	var reason := _config_reason()
	if reason != REASON_NONE:
		return reason
	if not is_valid_run_id(run_id):
		return REASON_INVALID_RUN_ID
	if _longest_path_length(run_id) > MAX_OS_PATH_LENGTH:
		return REASON_PATH_TOO_LONG
	return REASON_NONE


# Absolute length of the longest slot file path of a run (all of them are
# checked, so renaming a slot or file cannot silently skip the bound).
func _longest_path_length(run_id: String) -> int:
	var run_dir := base_dir.plus_file(run_id)
	var longest := 0
	for slot in SLOTS:
		for file_name in SLOT_FILES:
			var length: int = ProjectSettings.globalize_path(run_dir.plus_file(slot).plus_file(file_name)).length()
			if length > longest:
				longest = length
	return longest


# user://<one or more plain segments>; never the user:// root itself, so
# list_runs/delete_run cannot reach unrelated user data.
func _is_safe_base_dir(path: String) -> bool:
	if not path.begins_with(USER_PREFIX):
		return false
	var rest := path.substr(USER_PREFIX.length())
	if rest == "" or "\\" in rest or ":" in rest:
		return false
	for part in rest.split("/"):
		if part == "" or part == "." or part == "..":
			return false
	return true


# Full check of one slot. Returns ok plus the decoded data, or the first
# reason it cannot be loaded. sequence/schema are filled in whenever the
# commit record itself was readable, even if the payloads are not.
func _inspect_slot(run_id: String, slot_dir: String) -> Dictionary:
	var out := {"ok": false, "reason": REASON_NONE, "checkpoint_id": "", "sequence": 0, "schema": 0, "state": null, "identities": null}
	var dir := Directory.new()
	if not dir.dir_exists(slot_dir):
		out.reason = REASON_SLOT_MISSING
		return out
	var commit := _read_file(slot_dir.plus_file(COMMIT_FILE), MAX_COMMIT_FILE_BYTES)
	if commit.missing:
		out.reason = REASON_MISSING_COMMIT
		return out
	if not commit.ok:
		out.reason = REASON_CORRUPTED if commit.too_large else REASON_IO_ERROR
		return out
	var unframed := _unframe(commit.bytes)
	if not unframed.ok:
		out.reason = REASON_CORRUPTED
		return out
	var record = _decode(unframed.payload)
	if typeof(record) != TYPE_DICTIONARY or typeof(record.get("store_format")) != TYPE_INT or typeof(record.get("schema")) != TYPE_INT:
		out.reason = REASON_CORRUPTED
		return out
	out.schema = record.schema
	if record.store_format != STORE_FORMAT or record.schema != schema_version:
		out.reason = REASON_UNSUPPORTED_SCHEMA
		return out
	if not _record_well_formed(record):
		out.reason = REASON_CORRUPTED
		return out
	out.sequence = record.sequence
	if record.run_id != run_id:
		out.reason = REASON_CHECKPOINT_MISMATCH
		return out
	var state := _read_payload(slot_dir.plus_file(STATE_FILE), KIND_STATE, run_id, record)
	if not state.ok:
		out.reason = state.reason
		return out
	var identities := _read_payload(slot_dir.plus_file(IDENTITIES_FILE), KIND_IDENTITIES, run_id, record)
	if not identities.ok:
		out.reason = identities.reason
		return out
	out.ok = true
	out.checkpoint_id = record.checkpoint_id
	out.state = state.data
	out.identities = identities.data
	return out


func _record_well_formed(record: Dictionary) -> bool:
	for key in ["run_id", "checkpoint_id", "state_sha256", "identities_sha256"]:
		if typeof(record.get(key)) != TYPE_STRING:
			return false
	for key in ["sequence", "state_size", "identities_size"]:
		if typeof(record.get(key)) != TYPE_INT:
			return false
	if record.checkpoint_id == "" or record.sequence < 1:
		return false
	for kind in [KIND_STATE, KIND_IDENTITIES]:
		var size: int = record[kind + "_size"]
		var digest: String = record[kind + "_sha256"]
		if digest.length() != SHA256_HEX_LENGTH or size <= FRAME_HEADER_SIZE or size > MAX_PAYLOAD_FILE_BYTES:
			return false
	return true


# One payload file, accepted only if its bytes match the commit record and its
# envelope names the same run, checkpoint, schema and kind.
func _read_payload(path: String, kind: String, run_id: String, record: Dictionary) -> Dictionary:
	var size: int = record[kind + "_size"]
	var digest: String = record[kind + "_sha256"]
	var file := _read_file(path, MAX_PAYLOAD_FILE_BYTES)
	if file.missing:
		return {"ok": false, "reason": REASON_MISSING_PAYLOAD}
	if file.too_large or (file.ok and (file.bytes.size() != size or _sha256_hex(file.bytes) != digest)):
		return {"ok": false, "reason": REASON_HASH_MISMATCH}
	if not file.ok:
		return {"ok": false, "reason": REASON_IO_ERROR}
	var unframed := _unframe(file.bytes)
	if not unframed.ok:
		return {"ok": false, "reason": REASON_CORRUPTED}
	var envelope = _decode(unframed.payload)
	if typeof(envelope) != TYPE_DICTIONARY or typeof(envelope.get("data")) != TYPE_DICTIONARY:
		return {"ok": false, "reason": REASON_CORRUPTED}
	if not _is_string(envelope.get("kind"), kind) \
			or not _is_string(envelope.get("run_id"), run_id) \
			or not _is_string(envelope.get("checkpoint_id"), record.checkpoint_id) \
			or not _is_int(envelope.get("schema"), record.schema) \
			or not _is_int(envelope.get("store_format"), STORE_FORMAT):
		return {"ok": false, "reason": REASON_CHECKPOINT_MISMATCH}
	if not _is_plain_value(envelope.data, 0, [0]):
		return {"ok": false, "reason": REASON_UNSUPPORTED_VALUE}
	return {"ok": true, "reason": REASON_NONE, "data": envelope.data}


func _envelope(kind: String, run_id: String, checkpoint_id: String, data: Dictionary) -> Dictionary:
	return {
		"store_format": STORE_FORMAT,
		"schema": schema_version,
		"kind": kind,
		"run_id": run_id,
		"checkpoint_id": checkpoint_id,
		"data": data,
	}


# counter is a one-element Array shared across the recursion (node budget).
func _is_plain_value(value, depth: int, counter: Array) -> bool:
	counter[0] += 1
	if depth > MAX_VALUE_DEPTH or counter[0] > MAX_VALUE_NODES:
		return false
	var value_type := typeof(value)
	if value_type == TYPE_ARRAY:
		for item in value:
			if not _is_plain_value(item, depth + 1, counter):
				return false
		return true
	if value_type == TYPE_DICTIONARY:
		for key in value:
			if not LEAF_TYPES.has(typeof(key)) or not _is_plain_value(value[key], depth + 1, counter):
				return false
		return true
	return LEAF_TYPES.has(value_type)


func _is_string(value, expected: String) -> bool:
	return typeof(value) == TYPE_STRING and value == expected


func _is_int(value, expected: int) -> bool:
	return typeof(value) == TYPE_INT and value == expected


# A slot path is clean when it is absent, or a directory holding only files
# this store writes. A plain file in place of the directory is foreign.
func _slot_is_clean(slot_dir: String) -> bool:
	var dir := Directory.new()
	if dir.file_exists(slot_dir):
		return false
	if not dir.dir_exists(slot_dir):
		return true
	var entries = _list_entries(slot_dir)
	if entries == null:
		return false
	for name in entries:
		if entries[name] or not SLOT_FILES.has(name):
			return false
	return true


func _run_is_clean(run_dir: String) -> bool:
	var entries = _list_entries(run_dir)
	if entries == null:
		return false
	for name in entries:
		if not entries[name] or not SLOTS.has(name):
			return false
		if not _slot_is_clean(run_dir.plus_file(name)):
			return false
	return true


# name -> is_dir for one directory (hidden entries included), or null.
func _list_entries(path: String):
	var dir := Directory.new()
	if dir.open(path) != OK:
		return null
	if dir.list_dir_begin(true, false) != OK:
		return null
	var entries := {}
	var name := dir.get_next()
	while name != "":
		entries[name] = dir.current_is_dir()
		name = dir.get_next()
	dir.list_dir_end()
	return entries


func _remove_file(path: String) -> bool:
	var dir := Directory.new()
	if not dir.file_exists(path):
		return true
	return dir.remove(path) == OK


# Removes a slot's known files (commit first) and then the empty directory.
func _remove_slot(slot_dir: String) -> String:
	var dir := Directory.new()
	if not dir.dir_exists(slot_dir):
		return REASON_NONE
	for name in SLOT_FILES:
		if not _remove_file(slot_dir.plus_file(name)):
			return REASON_IO_ERROR
	if dir.remove(slot_dir) != OK:
		return REASON_IO_ERROR if _slot_is_clean(slot_dir) else REASON_FOREIGN_FILES
	return REASON_NONE


func _write_file(path: String, bytes: PoolByteArray) -> bool:
	var file := File.new()
	if file.open(path, File.WRITE) != OK:
		return false
	file.store_buffer(bytes)
	file.close()
	return true


func _read_file(path: String, max_bytes: int) -> Dictionary:
	var out := {"ok": false, "missing": false, "too_large": false, "bytes": PoolByteArray()}
	var file := File.new()
	if not file.file_exists(path):
		out.missing = true
		return out
	if file.open(path, File.READ) != OK:
		return out
	var size := file.get_len()
	if size > max_bytes:
		file.close()
		out.too_large = true
		return out
	var bytes := file.get_buffer(size)
	file.close()
	out.ok = bytes.size() == size
	out.bytes = bytes
	return out


func _file_matches(path: String, size: int, digest: String) -> bool:
	var file := _read_file(path, size)
	return file.ok and file.bytes.size() == size and _sha256_hex(file.bytes) == digest


func _frame(payload: PoolByteArray) -> PoolByteArray:
	var out := FRAME_MAGIC.to_ascii()
	out.append_array(_u32_bytes(FRAME_VERSION))
	out.append_array(_u32_bytes(payload.size()))
	out.append_array(_sha256(payload))
	out.append_array(payload)
	return out


# Checks magic, version, length and the frame's own hash, so only bytes that
# var2bytes produced reach the decoder.
func _unframe(bytes: PoolByteArray) -> Dictionary:
	var fail := {"ok": false, "payload": PoolByteArray()}
	if bytes.size() <= FRAME_HEADER_SIZE:
		return fail
	var magic := FRAME_MAGIC.to_ascii()
	for i in range(magic.size()):
		if bytes[i] != magic[i]:
			return fail
	if _read_u32(bytes, 4) != FRAME_VERSION or _read_u32(bytes, 8) != bytes.size() - FRAME_HEADER_SIZE:
		return fail
	var payload := bytes.subarray(FRAME_HEADER_SIZE, bytes.size() - 1)
	if bytes.subarray(12, FRAME_HEADER_SIZE - 1).hex_encode() != _sha256(payload).hex_encode():
		return fail
	return {"ok": true, "payload": payload}


# StreamPeerBuffer.get_var returns null on malformed input, where bytes2var
# raises a script error in debug builds. Objects are never instantiated.
func _decode(payload: PoolByteArray):
	var buffer := StreamPeerBuffer.new()
	buffer.put_32(payload.size())
	buffer.put_data(payload)
	buffer.seek(0)
	return buffer.get_var(false)


func _sha256(bytes: PoolByteArray) -> PoolByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if bytes.size() > 0:
		ctx.update(bytes)
	return ctx.finish()


func _sha256_hex(bytes: PoolByteArray) -> String:
	return _sha256(bytes).hex_encode()


func _u32_bytes(value: int) -> PoolByteArray:
	return PoolByteArray([value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF])


func _read_u32(bytes: PoolByteArray, at: int) -> int:
	return bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)


func _write_result(ok: bool, reason: String, checkpoint_id: String, sequence: int) -> Dictionary:
	return {"ok": ok, "checkpoint_id": checkpoint_id, "reason": reason, "sequence": sequence, "stage": ""}


func _fault_result(stage: String, checkpoint_id: String, sequence: int) -> Dictionary:
	var out := _write_result(false, REASON_SIMULATED_FAULT, checkpoint_id, sequence)
	out.stage = stage
	return out


func _read_success(slot: Dictionary, source: String, current_reason: String) -> Dictionary:
	return {
		"ok": true,
		"checkpoint_id": slot.checkpoint_id,
		"state": slot.state,
		"identities": slot.identities,
		"source": source,
		"reason": REASON_NONE,
		"schema": slot.schema,
		"sequence": slot.sequence,
		"current_reason": current_reason,
		"previous_reason": REASON_NONE,
	}


func _read_failure(reason: String) -> Dictionary:
	return {
		"ok": false,
		"checkpoint_id": "",
		"state": null,
		"identities": null,
		"source": "",
		"reason": reason,
		"schema": 0,
		"sequence": 0,
		"current_reason": REASON_NONE,
		"previous_reason": REASON_NONE,
	}


func _unsupported_schema(slot: Dictionary, current_reason: String) -> Dictionary:
	var out := _read_failure(REASON_UNSUPPORTED_SCHEMA)
	out.schema = slot.schema
	out.current_reason = current_reason
	return out
