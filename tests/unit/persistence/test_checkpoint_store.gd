extends "res://tests/runner/test_case.gd"
# AP-016 checkpoint store: T12 (recover the last valid checkpoint after the
# host dies), T13 (refuse checkpoints of another schema), T14 (every write
# stage interrupted, corrupted/mixed state or identity files), plus unreadable
# (locked) files and the OS path-length bound.
# Every test works in its own user:// directory and removes it afterwards.

const CheckpointStore = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/persistence/checkpoint_store.gd")

# Kept short: absolute paths count against MAX_OS_PATH_LENGTH, and the test
# tool's user:// folder is already long.
const TEST_ROOT := "user://cps"
const RUN := "run-1"
const CORRUPTIONS := ["flip", "truncate", "empty", "append", "delete"]
const FULL_SLOT := ["commit.bin", "identities.bin", "state.bin"]
const PAYLOADS_ONLY := ["identities.bin", "state.bin"]

var root := ""
var base := ""


# Reads of files whose path ends with one of `unreadable` fail as an existing
# but locked file would (open error), everything else is the real store.
class UnreadableStore extends "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/persistence/checkpoint_store.gd":
	var unreadable := []

	func _init(p_base_dir: String, p_schema_version: int = 1).(p_base_dir, p_schema_version) -> void:
		pass

	func _read_file(path: String, max_bytes: int) -> Dictionary:
		for suffix in unreadable:
			if path.ends_with(suffix):
				return {"ok": false, "missing": false, "too_large": false, "bytes": PoolByteArray()}
		return ._read_file(path, max_bytes)


func before_each() -> void:
	root = TEST_ROOT.plus_file(str(OS.get_ticks_usec()))
	base = root.plus_file("s")
	Directory.new().make_dir_recursive(root)


func after_each() -> void:
	_remove_tree(root)
	Directory.new().remove(TEST_ROOT)


# --- round trip -------------------------------------------------------------

func test_round_trip_for_one_to_nine_players() -> void:
	# The store has no player limit (capacity is enforced elsewhere) and must
	# return exactly what it was given; 9 is here to catch any clamp to 8 (F01).
	for n in range(1, 10):
		var run: String = "players-%d" % n
		var w = _store().write_checkpoint(run, _state(n, "A"), _identities(n, "A"))
		assert_true(w.ok, "n %d: %s" % [n, w.reason])
		assert_eq(w.sequence, 1, "n %d" % n)
		var r = _store().read_latest(run)
		_assert_checkpoint(r, "A", n, CheckpointStore.SOURCE_CURRENT, "n %d" % n)
		assert_eq(r.checkpoint_id, w.checkpoint_id, "n %d" % n)
		assert_eq(r.state.players.size(), n, "n %d" % n)
		assert_eq(r.identities.slots.size(), n, "n %d" % n)
		assert_eq(_entries(base.plus_file(run)), ["current"], "n %d" % n)


func test_eight_player_payload_keeps_every_slot_and_type() -> void:
	var state := _state(8, "P8")
	state["extras"] = {
		"lobby_id": 109775242356546048,
		"max_int": 9223372036854775807,
		"min_int": -9223372036854775807 - 1,
		"tenth": 0.1,
		"third": 1.0 / 3.0,
		"zero_int": 0,
		"zero_float": 0.0,
		"text": "玩家五 P5",
		"flags": [true, false, null],
		"empty_array": [],
		"empty_dict": {},
		"int_keys": {1: "one", 5: "five", 8: "eight"},
		"mixed_keys": {1: "int key", "1": "string key"},
		"names": PoolStringArray(["a", "b"]),
		"ints": PoolIntArray([1, -2, 3]),
		"blob": PoolByteArray([0, 255, 7]),
		"pos": Vector2(1.5, -2.25),
		"color": Color(0.25, 0.5, 0.75, 1.0),
	}
	var identities := _identities(8, "P8")
	var w = _store().write_checkpoint(RUN, state, identities)
	assert_true(w.ok, w.reason)
	var r = _store().read_latest(RUN)
	assert_true(r.ok, r.reason)
	if not r.ok:
		return
	assert_eq(_diff(r.state, state), "")
	assert_eq(_diff(r.identities, identities), "")
	assert_eq(r.state.players.size(), 8)
	for slot in range(8):
		assert_has(r.identities.slots, slot, "slot %d keeps an int key" % slot)
		assert_eq(r.identities.slots[slot].steam_id, 76561198000000001 + slot, "64-bit steam id of slot %d" % slot)
		assert_eq(r.state.players[slot].slot, slot)
	var extras: Dictionary = r.state.extras
	assert_eq(extras.tenth, 0.1, "float keeps double precision")
	assert_eq(typeof(extras.zero_int), TYPE_INT)
	assert_eq(typeof(extras.zero_float), TYPE_REAL)
	assert_eq(extras.max_int, 9223372036854775807)
	assert_eq(extras.mixed_keys.size(), 2, "int key 1 and string key \"1\" stay distinct")


func test_second_write_keeps_first_as_previous() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var b = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	assert_true(a.ok and b.ok)
	assert_eq(b.sequence, 2)
	assert_ne(a.checkpoint_id, b.checkpoint_id)
	var r = _store().read_latest(RUN)
	_assert_checkpoint(r, "B", 5, CheckpointStore.SOURCE_CURRENT, "latest")
	assert_eq(r.checkpoint_id, b.checkpoint_id)
	assert_eq(_entries(base.plus_file(RUN)), ["current", "previous"])
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	r = _store().read_latest(RUN)
	_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, "fallback")
	assert_eq(r.checkpoint_id, a.checkpoint_id)
	assert_eq(r.current_reason, CheckpointStore.REASON_HASH_MISMATCH)


func test_third_write_rotates_out_the_oldest() -> void:
	var s = _store()
	for tag in ["A", "B", "C"]:
		assert_true(s.write_checkpoint(RUN, _state(6, tag), _identities(6, tag)).ok, tag)
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE), "flip")
	_assert_checkpoint(_store().read_latest(RUN), "B", 6, CheckpointStore.SOURCE_PREVIOUS, "previous is B, not A")
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_PREVIOUS, CheckpointStore.STATE_FILE), "flip")
	var r = _store().read_latest(RUN)
	assert_false(r.ok)
	assert_eq(r.reason, CheckpointStore.REASON_NO_VALID_CHECKPOINT, "A must not linger as a third copy")


func test_sequence_and_ids_are_unique_for_identical_payloads() -> void:
	var s = _store()
	var ids := []
	for i in range(3):
		var w = s.write_checkpoint(RUN, _state(4, "same"), _identities(4, "same"))
		assert_true(w.ok, w.reason)
		assert_eq(w.sequence, i + 1)
		assert_not_has(ids, w.checkpoint_id)
		ids.append(w.checkpoint_id)
	var r = _store().read_latest(RUN)
	assert_eq(r.checkpoint_id, ids[2])
	assert_eq(r.sequence, 3)


# --- interrupted writes (T12, T14) ------------------------------------------

func test_fault_stages_are_declared_once_in_write_order() -> void:
	var stages: Array = CheckpointStore.FAULT_STAGES
	assert_eq(stages.size(), 9)
	for i in range(stages.size()):
		assert_eq(stages.find(stages[i]), i, "duplicate stage %s" % stages[i])
	assert_eq(stages[0], CheckpointStore.STAGE_STAGING_READY)
	assert_eq(stages[stages.size() - 1], CheckpointStore.STAGE_PROMOTED)


func test_fault_at_every_stage_on_first_write() -> void:
	# Files on disk when the process dies right after each stage.
	var layout := {
		CheckpointStore.STAGE_STAGING_READY: {"staging": []},
		CheckpointStore.STAGE_STATE_WRITTEN: {"staging": ["state.bin"]},
		CheckpointStore.STAGE_IDENTITIES_WRITTEN: {"staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_VERIFIED: {"staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_COMMIT_WRITTEN: {"staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_COMMIT_REMOVED: {"staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_REMOVED: {"staging": FULL_SLOT},
		CheckpointStore.STAGE_CURRENT_ROTATED: {"staging": FULL_SLOT},
		CheckpointStore.STAGE_PROMOTED: {"current": FULL_SLOT},
	}
	assert_eq(layout.size(), CheckpointStore.FAULT_STAGES.size())
	for stage in CheckpointStore.FAULT_STAGES:
		var run: String = "first-" + stage
		var w = _store().write_checkpoint(run, _state(8, "A"), _identities(8, "A"), stage)
		assert_false(w.ok, stage)
		assert_eq(w.reason, CheckpointStore.REASON_SIMULATED_FAULT, stage)
		assert_eq(w.stage, stage)
		var tree_before := _tree(base.plus_file(run))
		assert_eq(tree_before, _layout(layout[stage]), "files after %s" % stage)
		var r = _store().read_latest(run)
		if stage == CheckpointStore.STAGE_PROMOTED:
			_assert_checkpoint(r, "A", 8, CheckpointStore.SOURCE_CURRENT, stage)
			assert_eq(r.checkpoint_id, w.checkpoint_id, stage)
		else:
			assert_false(r.ok, stage)
			assert_eq(r.reason, CheckpointStore.REASON_NOT_FOUND, stage)
			assert_null(r.state, stage)
			assert_null(r.identities, stage)
		assert_eq(_tree(base.plus_file(run)), tree_before, "read is read-only after %s" % stage)
		# The next normal write recovers and leaves no staging behind.
		var w2 = _store().write_checkpoint(run, _state(8, "B"), _identities(8, "B"))
		assert_true(w2.ok, "%s: %s" % [stage, w2.reason])
		_assert_checkpoint(_store().read_latest(run), "B", 8, CheckpointStore.SOURCE_CURRENT, stage)
		var expected_slots: Array = ["current", "previous"] if stage == CheckpointStore.STAGE_PROMOTED else ["current"]
		assert_eq(_entries(base.plus_file(run)), expected_slots, stage)


func test_fault_at_every_stage_with_valid_current_and_previous() -> void:
	# current = B, previous = A, then writing C dies after each stage.
	var expect := {
		CheckpointStore.STAGE_STAGING_READY: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_STATE_WRITTEN: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_IDENTITIES_WRITTEN: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_VERIFIED: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_COMMIT_WRITTEN: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_OLD_COMMIT_REMOVED: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_OLD_REMOVED: ["B", CheckpointStore.SOURCE_CURRENT],
		CheckpointStore.STAGE_CURRENT_ROTATED: ["B", CheckpointStore.SOURCE_PREVIOUS],
		CheckpointStore.STAGE_PROMOTED: ["C", CheckpointStore.SOURCE_CURRENT],
	}
	var layout := {
		CheckpointStore.STAGE_STAGING_READY: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": []},
		CheckpointStore.STAGE_STATE_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": ["state.bin"]},
		CheckpointStore.STAGE_IDENTITIES_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_VERIFIED: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_COMMIT_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_COMMIT_REMOVED: {"current": FULL_SLOT, "previous": PAYLOADS_ONLY, "staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_REMOVED: {"current": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_CURRENT_ROTATED: {"previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_PROMOTED: {"current": FULL_SLOT, "previous": FULL_SLOT},
	}
	assert_eq(expect.size(), CheckpointStore.FAULT_STAGES.size())
	assert_eq(layout.size(), CheckpointStore.FAULT_STAGES.size())
	for stage in CheckpointStore.FAULT_STAGES:
		assert_has(expect, stage)
		var run: String = "rot-" + stage
		var s = _store()
		assert_true(s.write_checkpoint(run, _state(7, "A"), _identities(7, "A")).ok, stage)
		var b = s.write_checkpoint(run, _state(7, "B"), _identities(7, "B"))
		var c = s.write_checkpoint(run, _state(7, "C"), _identities(7, "C"), stage)
		assert_eq(c.reason, CheckpointStore.REASON_SIMULATED_FAULT, stage)
		assert_eq(_tree(base.plus_file(run)), _layout(layout[stage]), "files after %s" % stage)
		var r = _store().read_latest(run)
		_assert_checkpoint(r, expect[stage][0], 7, expect[stage][1], stage)
		assert_eq(r.checkpoint_id, c.checkpoint_id if expect[stage][0] == "C" else b.checkpoint_id, stage)
		# Recovery write, then lose it: the copy kept as previous is still whole.
		assert_true(_store().write_checkpoint(run, _state(7, "D"), _identities(7, "D")).ok, stage)
		_assert_checkpoint(_store().read_latest(run), "D", 7, CheckpointStore.SOURCE_CURRENT, stage)
		_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
		var kept: String = "C" if stage == CheckpointStore.STAGE_PROMOTED else "B"
		_assert_checkpoint(_store().read_latest(run), kept, 7, CheckpointStore.SOURCE_PREVIOUS, "kept after %s" % stage)


func test_fault_at_every_stage_with_corrupted_current() -> void:
	# current = B (broken), previous = A: a write must never discard A until
	# the new checkpoint is current. The broken current is the slot removed.
	var layout := {
		CheckpointStore.STAGE_STAGING_READY: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": []},
		CheckpointStore.STAGE_STATE_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": ["state.bin"]},
		CheckpointStore.STAGE_IDENTITIES_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_VERIFIED: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": PAYLOADS_ONLY},
		CheckpointStore.STAGE_COMMIT_WRITTEN: {"current": FULL_SLOT, "previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_COMMIT_REMOVED: {"current": PAYLOADS_ONLY, "previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_OLD_REMOVED: {"previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_CURRENT_ROTATED: {"previous": FULL_SLOT, "staging": FULL_SLOT},
		CheckpointStore.STAGE_PROMOTED: {"current": FULL_SLOT, "previous": FULL_SLOT},
	}
	assert_eq(layout.size(), CheckpointStore.FAULT_STAGES.size())
	for stage in CheckpointStore.FAULT_STAGES:
		var run: String = "broken-" + stage
		var s = _store()
		var a = s.write_checkpoint(run, _state(5, "A"), _identities(5, "A"))
		assert_true(s.write_checkpoint(run, _state(5, "B"), _identities(5, "B")).ok, stage)
		_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
		var c = s.write_checkpoint(run, _state(5, "C"), _identities(5, "C"), stage)
		assert_eq(c.reason, CheckpointStore.REASON_SIMULATED_FAULT, stage)
		assert_eq(_tree(base.plus_file(run)), _layout(layout[stage]), "files after %s" % stage)
		var r = _store().read_latest(run)
		if stage == CheckpointStore.STAGE_PROMOTED:
			_assert_checkpoint(r, "C", 5, CheckpointStore.SOURCE_CURRENT, stage)
		else:
			_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, stage)
			assert_eq(r.checkpoint_id, a.checkpoint_id, stage)
		assert_true(_store().write_checkpoint(run, _state(5, "D"), _identities(5, "D")).ok, stage)
		_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE), "flip")
		var kept: String = "C" if stage == CheckpointStore.STAGE_PROMOTED else "A"
		_assert_checkpoint(_store().read_latest(run), kept, 5, CheckpointStore.SOURCE_PREVIOUS, "kept after %s" % stage)


func test_unknown_fault_stage_is_rejected_without_writing() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var before := _snapshot(base)
	for stage in ["bogus", "PROMOTED", " promoted", "promoted "]:
		var w = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"), stage)
		assert_false(w.ok, stage)
		assert_eq(w.reason, CheckpointStore.REASON_UNKNOWN_FAULT_STAGE, stage)
	assert_eq(_diff(_snapshot(base), before), "")
	assert_eq(_store().read_latest(RUN).checkpoint_id, a.checkpoint_id)


# --- corrupted and mixed files (T14) ----------------------------------------

func test_corrupted_current_file_falls_back_to_previous() -> void:
	var files := [CheckpointStore.STATE_FILE, CheckpointStore.IDENTITIES_FILE, CheckpointStore.COMMIT_FILE]
	for file_name in files:
		for mode in CORRUPTIONS:
			var run: String = ("c-%s-%s" % [file_name.get_basename(), mode])
			var s = _store()
			var a = s.write_checkpoint(run, _state(6, "A"), _identities(6, "A"))
			assert_true(s.write_checkpoint(run, _state(6, "B"), _identities(6, "B")).ok, run)
			_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, file_name), mode)
			var r = _store().read_latest(run)
			_assert_checkpoint(r, "A", 6, CheckpointStore.SOURCE_PREVIOUS, run)
			assert_eq(r.checkpoint_id, a.checkpoint_id, run)
			assert_eq(r.current_reason, _expected_reason(file_name, mode), run)


func test_corrupted_previous_does_not_affect_valid_current() -> void:
	var s = _store()
	s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var b = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_PREVIOUS, CheckpointStore.STATE_FILE), "flip")
	var r = _store().read_latest(RUN)
	_assert_checkpoint(r, "B", 5, CheckpointStore.SOURCE_CURRENT, "current untouched")
	assert_eq(r.checkpoint_id, b.checkpoint_id)
	assert_eq(r.current_reason, CheckpointStore.REASON_NONE)


func test_both_slots_corrupted_is_an_explicit_error() -> void:
	var cases := [
		[CheckpointStore.STATE_FILE, "flip", CheckpointStore.IDENTITIES_FILE, "truncate"],
		[CheckpointStore.COMMIT_FILE, "delete", CheckpointStore.COMMIT_FILE, "flip"],
		[CheckpointStore.IDENTITIES_FILE, "delete", CheckpointStore.STATE_FILE, "empty"],
	]
	for i in range(cases.size()):
		var c: Array = cases[i]
		var run: String = "both-%d" % i
		var s = _store()
		s.write_checkpoint(run, _state(8, "A"), _identities(8, "A"))
		s.write_checkpoint(run, _state(8, "B"), _identities(8, "B"))
		_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, c[0]), c[1])
		_corrupt(_slot_file(run, CheckpointStore.SLOT_PREVIOUS, c[2]), c[3])
		var r = _store().read_latest(run)
		assert_false(r.ok, run)
		assert_eq(r.reason, CheckpointStore.REASON_NO_VALID_CHECKPOINT, run)
		assert_eq(r.current_reason, _expected_reason(c[0], c[1]), run)
		assert_eq(r.previous_reason, _expected_reason(c[2], c[3]), run)
		assert_null(r.state, run)
		assert_null(r.identities, run)
		assert_eq(r.source, "", run)


func test_write_after_corrupted_current_keeps_last_good_previous() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.COMMIT_FILE), "truncate")
	var c = s.write_checkpoint(RUN, _state(5, "C"), _identities(5, "C"))
	assert_true(c.ok, c.reason)
	assert_eq(c.sequence, 2, "broken B's sequence is unknown; A had 1")
	_assert_checkpoint(_store().read_latest(RUN), "C", 5, CheckpointStore.SOURCE_CURRENT, "new")
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var r = _store().read_latest(RUN)
	_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, "broken B was discarded, A kept")
	assert_eq(r.checkpoint_id, a.checkpoint_id)


func test_files_from_another_checkpoint_are_never_mixed() -> void:
	# Each case copies files of checkpoint A (previous) into B (current).
	var cases := [
		[CheckpointStore.IDENTITIES_FILE],
		[CheckpointStore.STATE_FILE],
		[CheckpointStore.IDENTITIES_FILE, CheckpointStore.COMMIT_FILE],
		[CheckpointStore.STATE_FILE, CheckpointStore.COMMIT_FILE],
	]
	for i in range(cases.size()):
		var run: String = "mix-%d" % i
		var s = _store()
		var a = s.write_checkpoint(run, _state(8, "A"), _identities(8, "A"))
		s.write_checkpoint(run, _state(8, "B"), _identities(8, "B"))
		for file_name in cases[i]:
			_copy(_slot_file(run, CheckpointStore.SLOT_PREVIOUS, file_name), _slot_file(run, CheckpointStore.SLOT_CURRENT, file_name))
		var r = _store().read_latest(run)
		_assert_checkpoint(r, "A", 8, CheckpointStore.SOURCE_PREVIOUS, run)
		assert_eq(r.checkpoint_id, a.checkpoint_id, run)
		assert_eq(r.current_reason, CheckpointStore.REASON_HASH_MISMATCH, run)
	# A mixed previous is refused too, even when that leaves nothing to load.
	var s2 = _store()
	s2.write_checkpoint("mix-prev", _state(8, "A"), _identities(8, "A"))
	s2.write_checkpoint("mix-prev", _state(8, "B"), _identities(8, "B"))
	_copy(_slot_file("mix-prev", CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE), _slot_file("mix-prev", CheckpointStore.SLOT_PREVIOUS, CheckpointStore.IDENTITIES_FILE))
	_corrupt(_slot_file("mix-prev", CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var r2 = _store().read_latest("mix-prev")
	assert_false(r2.ok)
	assert_eq(r2.reason, CheckpointStore.REASON_NO_VALID_CHECKPOINT)
	assert_eq(r2.previous_reason, CheckpointStore.REASON_HASH_MISMATCH)


func test_forged_commit_for_foreign_identities_is_rejected() -> void:
	# The commit hashes are rewritten to match A's identity file inside B, so
	# only the checkpoint id carried by each payload can expose the mix.
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(6, "A"), _identities(6, "A"))
	s.write_checkpoint(RUN, _state(6, "B"), _identities(6, "B"))
	var foreign := _read_bytes(_slot_file(RUN, CheckpointStore.SLOT_PREVIOUS, CheckpointStore.IDENTITIES_FILE))
	_write_bytes(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE), foreign)
	var record = _read_record(s, RUN, CheckpointStore.SLOT_CURRENT)
	assert_eq(typeof(record), TYPE_DICTIONARY)
	if typeof(record) != TYPE_DICTIONARY:
		return
	record.identities_sha256 = s._sha256_hex(foreign)
	record.identities_size = foreign.size()
	_write_record(s, RUN, CheckpointStore.SLOT_CURRENT, record)
	var r = _store().read_latest(RUN)
	_assert_checkpoint(r, "A", 6, CheckpointStore.SOURCE_PREVIOUS, "forged mix")
	assert_eq(r.checkpoint_id, a.checkpoint_id)
	assert_eq(r.current_reason, CheckpointStore.REASON_CHECKPOINT_MISMATCH)


func test_checkpoint_copied_from_another_run_is_rejected() -> void:
	var s = _store()
	s.write_checkpoint("run-a", _state(5, "X"), _identities(5, "X"))
	var b1 = s.write_checkpoint("run-b", _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint("run-b", _state(5, "B"), _identities(5, "B"))
	for file_name in CheckpointStore.SLOT_FILES:
		_copy(base.plus_file("run-a").plus_file(CheckpointStore.SLOT_CURRENT).plus_file(file_name), _slot_file("run-b", CheckpointStore.SLOT_CURRENT, file_name))
	var r = _store().read_latest("run-b")
	_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, "foreign run")
	assert_eq(r.checkpoint_id, b1.checkpoint_id)
	assert_eq(r.current_reason, CheckpointStore.REASON_CHECKPOINT_MISMATCH)


func test_malformed_commit_records_are_not_loaded() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var commit_path := _slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.COMMIT_FILE)
	var good_bytes := _read_bytes(commit_path)
	var good = _read_record(s, RUN, CheckpointStore.SLOT_CURRENT)
	assert_eq(typeof(good), TYPE_DICTIONARY)
	if typeof(good) != TYPE_DICTIONARY:
		return
	var cases := {}
	cases["garbage payload"] = s._frame(PoolByteArray([255, 255, 255, 255, 1, 2, 3, 4]))
	cases["not a dictionary"] = s._frame(var2bytes("commit", false))
	cases["schema as float"] = _patched_record(s, good, "schema", 1.0)
	cases["store format as string"] = _patched_record(s, good, "store_format", "1")
	cases["sequence as string"] = _patched_record(s, good, "sequence", "2")
	cases["zero sequence"] = _patched_record(s, good, "sequence", 0)
	cases["short hash"] = _patched_record(s, good, "state_sha256", "abc")
	cases["empty checkpoint id"] = _patched_record(s, good, "checkpoint_id", "")
	cases["size as float"] = _patched_record(s, good, "state_size", float(good.state_size))
	var missing = good.duplicate()
	missing.erase("identities_sha256")
	cases["missing field"] = s._frame(var2bytes(missing, false))
	var bad_magic := PoolByteArray(good_bytes)
	bad_magic[0] = 88
	cases["wrong magic"] = bad_magic
	var bad_version := PoolByteArray(good_bytes)
	bad_version[4] = 2
	cases["unknown frame version"] = bad_version
	var oversized := PoolByteArray()
	oversized.resize(CheckpointStore.MAX_COMMIT_FILE_BYTES + 1)
	cases["oversized"] = oversized
	for label in cases:
		_write_bytes(commit_path, cases[label])
		var r = _store().read_latest(RUN)
		_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, label)
		assert_eq(r.checkpoint_id, a.checkpoint_id, label)
		assert_eq(r.current_reason, CheckpointStore.REASON_CORRUPTED, label)


func test_forged_payload_with_object_is_not_loaded() -> void:
	# A payload that decodes to an Object (as id, or a full object refused by
	# the decoder) is never handed out, even with a matching commit record.
	var s = _store()
	s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var record = _read_record(s, RUN, CheckpointStore.SLOT_CURRENT)
	assert_eq(typeof(record), TYPE_DICTIONARY)
	if typeof(record) != TYPE_DICTIONARY:
		return
	var cases := [[false, CheckpointStore.REASON_UNSUPPORTED_VALUE], [true, CheckpointStore.REASON_CORRUPTED]]
	for c in cases:
		var data := _state(5, "B")
		data["evil"] = Reference.new()
		var envelope := {
			"store_format": CheckpointStore.STORE_FORMAT,
			"schema": s.schema_version,
			"kind": CheckpointStore.KIND_STATE,
			"run_id": RUN,
			"checkpoint_id": record.checkpoint_id,
			"data": data,
		}
		var forged: PoolByteArray = s._frame(var2bytes(envelope, c[0]))
		_write_bytes(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), forged)
		var patched = record.duplicate()
		patched.state_sha256 = s._sha256_hex(forged)
		patched.state_size = forged.size()
		_write_record(s, RUN, CheckpointStore.SLOT_CURRENT, patched)
		var label: String = "full_objects %s" % str(c[0])
		var r = _store().read_latest(RUN)
		_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, label)
		assert_eq(r.current_reason, c[1], label)
		assert_false(_contains_object(r.state), label)


func test_swapped_payload_files_are_never_loaded() -> void:
	# state.bin and identities.bin of one checkpoint traded places. With the
	# commit hashes forged to match, only the payload kind can expose it.
	for forge_commit in [false, true]:
		var run: String = "swap-%s" % str(forge_commit).to_lower()
		var s = _store()
		var a = s.write_checkpoint(run, _state(8, "A"), _identities(8, "A"))
		s.write_checkpoint(run, _state(8, "B"), _identities(8, "B"))
		var state_bytes := _read_bytes(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE))
		var identities_bytes := _read_bytes(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE))
		_write_bytes(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), identities_bytes)
		_write_bytes(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.IDENTITIES_FILE), state_bytes)
		var expected: String = CheckpointStore.REASON_HASH_MISMATCH
		if forge_commit:
			var record = _read_record(s, run, CheckpointStore.SLOT_CURRENT)
			assert_eq(typeof(record), TYPE_DICTIONARY, run)
			if typeof(record) != TYPE_DICTIONARY:
				return
			record.state_sha256 = _sha256_hex(identities_bytes)
			record.state_size = identities_bytes.size()
			record.identities_sha256 = _sha256_hex(state_bytes)
			record.identities_size = state_bytes.size()
			_write_record(s, run, CheckpointStore.SLOT_CURRENT, record)
			expected = CheckpointStore.REASON_CHECKPOINT_MISMATCH
		var r = _store().read_latest(run)
		_assert_checkpoint(r, "A", 8, CheckpointStore.SOURCE_PREVIOUS, run)
		assert_eq(r.checkpoint_id, a.checkpoint_id, run)
		assert_eq(r.current_reason, expected, run)


func test_forged_envelope_fields_are_rejected() -> void:
	# Each case rewrites one field of a payload's envelope and re-hashes the
	# commit record to match, so the envelope check alone must catch it.
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var b = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var good := {}
	for file_name in CheckpointStore.SLOT_FILES:
		good[file_name] = _read_bytes(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, file_name))
	var mismatch: String = CheckpointStore.REASON_CHECKPOINT_MISMATCH
	var cases := [
		# [payload file, envelope key, forged value, expected current_reason]
		[CheckpointStore.STATE_FILE, "", null, ""],
		[CheckpointStore.STATE_FILE, "kind", CheckpointStore.KIND_IDENTITIES, mismatch],
		[CheckpointStore.IDENTITIES_FILE, "kind", CheckpointStore.KIND_STATE, mismatch],
		[CheckpointStore.STATE_FILE, "run_id", "run-2", mismatch],
		[CheckpointStore.IDENTITIES_FILE, "run_id", "run-2", mismatch],
		[CheckpointStore.STATE_FILE, "checkpoint_id", a.checkpoint_id, mismatch],
		[CheckpointStore.IDENTITIES_FILE, "checkpoint_id", a.checkpoint_id, mismatch],
		[CheckpointStore.STATE_FILE, "schema", 2, mismatch],
		[CheckpointStore.IDENTITIES_FILE, "schema", 1.0, mismatch],
		[CheckpointStore.STATE_FILE, "store_format", CheckpointStore.STORE_FORMAT + 1, mismatch],
		[CheckpointStore.IDENTITIES_FILE, "store_format", "1", mismatch],
		[CheckpointStore.STATE_FILE, "data", [1, 2], CheckpointStore.REASON_CORRUPTED],
		[CheckpointStore.IDENTITIES_FILE, "data", null, CheckpointStore.REASON_CORRUPTED],
	]
	for c in cases:
		var label: String = "%s %s=%s" % [c[0], c[1], var2str(c[2])]
		for file_name in good:
			_write_bytes(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, file_name), good[file_name])
		var unframed = s._unframe(good[c[0]])
		assert_true(unframed.ok, label)
		var envelope = s._decode(unframed.payload)
		assert_eq(typeof(envelope), TYPE_DICTIONARY, label)
		if typeof(envelope) != TYPE_DICTIONARY:
			return
		if c[1] != "":
			assert_has(envelope, c[1], label)
			envelope[c[1]] = c[2]
		var forged: PoolByteArray = s._frame(var2bytes(envelope, false))
		_write_bytes(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, c[0]), forged)
		var record = _read_record(s, RUN, CheckpointStore.SLOT_CURRENT)
		var kind: String = c[0].get_basename()
		record[kind + "_sha256"] = _sha256_hex(forged)
		record[kind + "_size"] = forged.size()
		_write_record(s, RUN, CheckpointStore.SLOT_CURRENT, record)
		var r = _store().read_latest(RUN)
		if c[1] == "":
			# Control: re-encoding an untouched envelope still loads B.
			_assert_checkpoint(r, "B", 5, CheckpointStore.SOURCE_CURRENT, label)
			assert_eq(r.checkpoint_id, b.checkpoint_id, label)
			continue
		_assert_checkpoint(r, "A", 5, CheckpointStore.SOURCE_PREVIOUS, label)
		assert_eq(r.checkpoint_id, a.checkpoint_id, label)
		assert_eq(r.current_reason, c[3], label)


# --- unreadable files (locked by another process) ---------------------------

func test_unreadable_current_is_reported_not_rolled_back() -> void:
	# An existing current that cannot be read may be the newest commit: read
	# must not silently hand out previous, and write must not discard it.
	for file_name in CheckpointStore.SLOT_FILES:
		var run: String = "io-" + file_name.get_basename()
		var s = _store()
		s.write_checkpoint(run, _state(6, "A"), _identities(6, "A"))
		var b = s.write_checkpoint(run, _state(6, "B"), _identities(6, "B"))
		var flaky = UnreadableStore.new(base)
		flaky.unreadable = ["current/" + file_name]
		var before := _snapshot(base.plus_file(run))
		var r = flaky.read_latest(run)
		assert_false(r.ok, run)
		assert_eq(r.reason, CheckpointStore.REASON_IO_ERROR, run)
		assert_eq(r.current_reason, CheckpointStore.REASON_IO_ERROR, run)
		assert_null(r.state, run)
		assert_null(r.identities, run)
		assert_eq(r.source, "", run)
		var w = flaky.write_checkpoint(run, _state(6, "C"), _identities(6, "C"))
		assert_false(w.ok, run)
		assert_eq(w.reason, CheckpointStore.REASON_IO_ERROR, run)
		assert_eq(_diff(_snapshot(base.plus_file(run)), before), "", "nothing changed: %s" % run)
		# Readable again: B is still the latest and A still backs it up.
		flaky.unreadable = []
		var again = flaky.read_latest(run)
		_assert_checkpoint(again, "B", 6, CheckpointStore.SOURCE_CURRENT, run)
		assert_eq(again.checkpoint_id, b.checkpoint_id, run)
		_corrupt(_slot_file(run, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
		_assert_checkpoint(_store().read_latest(run), "A", 6, CheckpointStore.SOURCE_PREVIOUS, run)


func test_unreadable_previous_is_kept_and_reported() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var b = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var flaky = UnreadableStore.new(base)
	flaky.unreadable = ["previous/" + CheckpointStore.IDENTITIES_FILE]
	# A valid current does not depend on previous.
	assert_eq(flaky.read_latest(RUN).checkpoint_id, b.checkpoint_id)
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var r = flaky.read_latest(RUN)
	assert_false(r.ok)
	assert_eq(r.reason, CheckpointStore.REASON_IO_ERROR, "retryable, not no_valid_checkpoint")
	assert_eq(r.current_reason, CheckpointStore.REASON_HASH_MISMATCH)
	assert_eq(r.previous_reason, CheckpointStore.REASON_IO_ERROR)
	assert_null(r.state)
	# The write replaces the broken current and leaves the unread previous.
	var c = flaky.write_checkpoint(RUN, _state(5, "C"), _identities(5, "C"))
	assert_true(c.ok, c.reason)
	flaky.unreadable = []
	_assert_checkpoint(flaky.read_latest(RUN), "C", 5, CheckpointStore.SOURCE_CURRENT, "new current")
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var kept = _store().read_latest(RUN)
	_assert_checkpoint(kept, "A", 5, CheckpointStore.SOURCE_PREVIOUS, "A kept")
	assert_eq(kept.checkpoint_id, a.checkpoint_id)


# --- schema isolation (T13) -------------------------------------------------

func test_schema_mismatch_is_rejected_explicitly() -> void:
	var v1 = _store(1)
	v1.write_checkpoint(RUN, _state(6, "A"), _identities(6, "A"))
	var b = v1.write_checkpoint(RUN, _state(6, "B"), _identities(6, "B"))
	var before := _snapshot(base)
	var v2 = _store(2)
	var r = v2.read_latest(RUN)
	assert_false(r.ok)
	assert_eq(r.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(r.schema, 1)
	assert_null(r.state)
	assert_null(r.identities)
	assert_eq(r.source, "")
	var w = v2.write_checkpoint(RUN, _state(6, "C"), _identities(6, "C"))
	assert_false(w.ok)
	assert_eq(w.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(_diff(_snapshot(base), before), "", "refused write changed nothing")
	var again = _store(1).read_latest(RUN)
	_assert_checkpoint(again, "B", 6, CheckpointStore.SOURCE_CURRENT, "v1 still reads its run")
	assert_eq(again.checkpoint_id, b.checkpoint_id)
	# The other direction: a newer store's run is refused by the older one.
	assert_true(v2.write_checkpoint("run-v2", _state(6, "C"), _identities(6, "C")).ok)
	var old = _store(1).read_latest("run-v2")
	assert_eq(old.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(old.schema, 2)


func test_newer_store_format_is_unsupported_not_corrupted() -> void:
	# A commit record from a newer store layout (same game schema) is treated
	# like another schema: no fallback to previous, nothing rotated away.
	var s = _store()
	s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var record = _read_record(s, RUN, CheckpointStore.SLOT_CURRENT)
	assert_eq(typeof(record), TYPE_DICTIONARY)
	if typeof(record) != TYPE_DICTIONARY:
		return
	record.store_format = CheckpointStore.STORE_FORMAT + 1
	_write_record(s, RUN, CheckpointStore.SLOT_CURRENT, record)
	var before := _snapshot(base)
	var r = _store().read_latest(RUN)
	assert_false(r.ok)
	assert_eq(r.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_null(r.state)
	assert_eq(r.source, "")
	var w = _store().write_checkpoint(RUN, _state(5, "C"), _identities(5, "C"))
	assert_eq(w.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(_diff(_snapshot(base), before), "")


func test_newer_schema_checkpoint_is_not_loaded_or_rolled_back() -> void:
	var base2 := root.plus_file("store2")
	var v1 = _store(1)
	var v2 = CheckpointStore.new(base2, 2)
	for run in [RUN, "run-2"]:
		v1.write_checkpoint(run, _state(5, "A"), _identities(5, "A"))
		v1.write_checkpoint(run, _state(5, "B"), _identities(5, "B"))
		assert_true(v2.write_checkpoint(run, _state(5, "N"), _identities(5, "N")).ok)
	# RUN: current replaced by a schema-2 checkpoint whose state is also broken.
	for file_name in CheckpointStore.SLOT_FILES:
		_copy(base2.plus_file(RUN).plus_file("current").plus_file(file_name), _slot_file(RUN, CheckpointStore.SLOT_CURRENT, file_name))
	_corrupt(_slot_file(RUN, CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var r = _store(1).read_latest(RUN)
	assert_false(r.ok, "no silent rollback to the schema-1 previous")
	assert_eq(r.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA, "schema checked before any payload")
	assert_eq(r.schema, 2)
	assert_null(r.state)
	var before := _snapshot(base)
	var w = _store(1).write_checkpoint(RUN, _state(5, "C"), _identities(5, "C"))
	assert_eq(w.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(_diff(_snapshot(base), before), "", "newer checkpoint kept as is")
	# run-2: previous from schema 2, current broken.
	for file_name in CheckpointStore.SLOT_FILES:
		_copy(base2.plus_file("run-2").plus_file("current").plus_file(file_name), _slot_file("run-2", CheckpointStore.SLOT_PREVIOUS, file_name))
	_corrupt(_slot_file("run-2", CheckpointStore.SLOT_CURRENT, CheckpointStore.STATE_FILE), "flip")
	var r2 = _store(1).read_latest("run-2")
	assert_eq(r2.reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)
	assert_eq(r2.current_reason, CheckpointStore.REASON_HASH_MISMATCH)
	assert_eq(_store(1).write_checkpoint("run-2", _state(5, "C"), _identities(5, "C")).reason, CheckpointStore.REASON_UNSUPPORTED_SCHEMA)


func test_invalid_schema_versions_are_rejected() -> void:
	for version in [0, -1]:
		var s = CheckpointStore.new(base, version)
		assert_false(s.is_valid(), "schema %d" % version)
		assert_eq(s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A")).reason, CheckpointStore.REASON_INVALID_SCHEMA_VERSION)
		assert_eq(s.read_latest(RUN).reason, CheckpointStore.REASON_INVALID_SCHEMA_VERSION)
		assert_false(s.list_runs().ok)
		assert_eq(s.delete_run(RUN).reason, CheckpointStore.REASON_INVALID_SCHEMA_VERSION)
	assert_false(Directory.new().dir_exists(base), "nothing created")


# --- paths stay inside base_dir ---------------------------------------------

func test_malicious_run_ids_are_rejected_and_touch_nothing() -> void:
	var s = _store()
	assert_true(s.write_checkpoint("legit", _state(5, "A"), _identities(5, "A")).ok)
	_write_bytes(root.plus_file("outside.bin"), PoolByteArray([1, 2, 3]))
	Directory.new().make_dir_recursive(root.plus_file("victim"))
	_write_bytes(root.plus_file("victim").plus_file("keep.bin"), PoolByteArray([4, 5]))
	var before := _snapshot(root)
	var ids := [
		"", ".", "..", "../victim", "..\\victim", "../outside.bin", "a/b", "a\\b", "/abs", "\\abs",
		"c:", "c:\\windows", "user://x", "res://x", "x/../y", "legit/..", "legit/current",
		"run.1", "run 1", "Run", "LEGIT", "con", "nul", "com1", "lpt9", "aux",
		"run\n", "run\t", "%2e%2e", "~", "*", "?", "a|b", "a<b", "é", _repeat("a", 65),
	]
	for id in ids:
		var label: String = "id %s" % var2str(id)
		assert_false(s.is_valid_run_id(id), label)
		assert_eq(s.get_run_dir(id), "", label)
		var w = s.write_checkpoint(id, _state(5, "X"), _identities(5, "X"))
		assert_false(w.ok, label)
		assert_eq(w.reason, CheckpointStore.REASON_INVALID_RUN_ID, label)
		var r = s.read_latest(id)
		assert_eq(r.reason, CheckpointStore.REASON_INVALID_RUN_ID, label)
		assert_null(r.state, label)
		assert_eq(s.delete_run(id).reason, CheckpointStore.REASON_INVALID_RUN_ID, label)
	assert_eq(_diff(_snapshot(root), before), "", "no file outside or inside base_dir changed")
	assert_eq(s.list_runs().runs, ["legit"])


func test_valid_run_id_edge_cases() -> void:
	# Whether the longest id also fits depends on how deep the test tool puts
	# user://; the exact path limit is covered by the boundary test below.
	var s = _store()
	for id in ["a", "0", "-", "_", "run-1", "run_1", "con-1", "lpt10", "nul0", _repeat("z", 64)]:
		assert_true(s.is_valid_run_id(id), id)
		var fits: bool = _longest_path(base, id) <= CheckpointStore.MAX_OS_PATH_LENGTH
		assert_eq(s.get_run_dir(id), base.plus_file(id) if fits else "", id)
	for id in ["a", "con-1", _repeat("z", 64)]:
		var w = s.write_checkpoint(id, _state(5, id), _identities(5, id))
		if _longest_path(base, id) > CheckpointStore.MAX_OS_PATH_LENGTH:
			assert_eq(w.reason, CheckpointStore.REASON_PATH_TOO_LONG, id)
			continue
		assert_true(w.ok, "%s: %s" % [id, w.reason])
		_assert_checkpoint(_store().read_latest(id), id, 5, CheckpointStore.SOURCE_CURRENT, id)


func test_path_length_limit_is_exact_and_checked_before_any_io() -> void:
	# Two bases one character apart: with the longest valid run id the first
	# reaches MAX_OS_PATH_LENGTH exactly, the second is one over.
	var limit: int = CheckpointStore.MAX_OS_PATH_LENGTH
	var run := _repeat("z", 64)
	var pad: int = limit - _longest_path(root.plus_file("p"), run) + 1
	if pad < 1:
		run = "z"
		pad = limit - _longest_path(root.plus_file("p"), run) + 1
	if pad < 1:
		fail("test root %s is too deep for the boundary case" % ProjectSettings.globalize_path(root))
		return
	var fits_base := root.plus_file(_repeat("p", pad))
	var over_base := root.plus_file(_repeat("p", pad + 1))
	assert_eq(_longest_path(fits_base, run), limit)
	var fits = CheckpointStore.new(fits_base)
	assert_eq(fits.get_run_dir(run), fits_base.plus_file(run))
	assert_true(fits.write_checkpoint(run, _state(8, "A"), _identities(8, "A")).ok, "write A at the limit")
	var b = fits.write_checkpoint(run, _state(8, "B"), _identities(8, "B"))
	assert_true(b.ok, "write B at the limit: %s" % b.reason)
	var longest := 0
	for rel in _tree(fits_base):
		var path: String = fits_base.plus_file(rel.trim_suffix("/"))
		longest = int(max(longest, ProjectSettings.globalize_path(path).length()))
	assert_eq(longest, limit, "the store's longest file reaches the limit, not past it")
	# The longest path is the previous copy: it must really be readable.
	_corrupt(fits_base.plus_file(run).plus_file("current").plus_file("state.bin"), "flip")
	_assert_checkpoint(fits.read_latest(run), "A", 8, CheckpointStore.SOURCE_PREVIOUS, "previous at the limit")
	assert_eq(fits.list_runs().runs, [run])
	assert_true(fits.delete_run(run).deleted)

	var over = CheckpointStore.new(over_base)
	assert_true(over.is_valid())
	assert_true(over.is_valid_run_id(run), "the name itself is fine")
	assert_eq(over.get_run_dir(run), "")
	var w = over.write_checkpoint(run, _state(8, "A"), _identities(8, "A"))
	assert_false(w.ok)
	assert_eq(w.reason, CheckpointStore.REASON_PATH_TOO_LONG)
	assert_false(Directory.new().dir_exists(over_base), "refused before creating anything")
	var r = over.read_latest(run)
	assert_eq(r.reason, CheckpointStore.REASON_PATH_TOO_LONG)
	assert_null(r.state)
	# A directory of that name made by someone else is neither listed nor removed.
	Directory.new().make_dir_recursive(over_base.plus_file(run))
	assert_eq(over.list_runs().runs, [])
	assert_eq(over.delete_run(run).reason, CheckpointStore.REASON_PATH_TOO_LONG)
	assert_true(Directory.new().dir_exists(over_base.plus_file(run)))
	if run.length() > 1:
		var shorter: String = run.substr(1)
		assert_true(over.write_checkpoint(shorter, _state(8, "A"), _identities(8, "A")).ok, "one character shorter fits")
		assert_eq(over.list_runs().runs, [shorter])


func test_invalid_base_dirs_are_rejected() -> void:
	var bad := [
		"", "user://", "user:///", "user:", "res://checkpoints", "C:/tmp/x", "/tmp/x", "checkpoints",
		"user://../x", "user://a/../b", "user://a/./b", "user://a//b", "user://a\\b", "user://c:/x",
		"userx://a", "USER://a",
	]
	var before := _snapshot(root)
	for path in bad:
		var s = CheckpointStore.new(path)
		var label: String = "base %s" % path
		assert_false(s.is_valid(), label)
		assert_eq(s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A")).reason, CheckpointStore.REASON_INVALID_BASE_DIR, label)
		assert_eq(s.read_latest(RUN).reason, CheckpointStore.REASON_INVALID_BASE_DIR, label)
		var listed = s.list_runs()
		assert_false(listed.ok, label)
		assert_eq(listed.reason, CheckpointStore.REASON_INVALID_BASE_DIR, label)
		assert_eq(s.delete_run(RUN).reason, CheckpointStore.REASON_INVALID_BASE_DIR, label)
		assert_eq(s.get_run_dir(RUN), "", label)
	assert_eq(_diff(_snapshot(root), before), "")
	# A trailing slash names the same store.
	var slash = CheckpointStore.new(base + "/")
	assert_true(slash.is_valid())
	assert_true(slash.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A")).ok)
	_assert_checkpoint(_store().read_latest(RUN), "A", 5, CheckpointStore.SOURCE_CURRENT, "trailing slash")


func test_missing_run_is_not_found_and_creates_nothing() -> void:
	var s = _store()
	var r = s.read_latest("nope")
	assert_false(r.ok)
	assert_eq(r.reason, CheckpointStore.REASON_NOT_FOUND)
	assert_eq(r.current_reason, CheckpointStore.REASON_SLOT_MISSING)
	assert_eq(r.previous_reason, CheckpointStore.REASON_SLOT_MISSING)
	var listed = s.list_runs()
	assert_true(listed.ok)
	assert_eq(listed.runs, [])
	var d = s.delete_run("nope")
	assert_true(d.ok)
	assert_false(d.deleted)
	assert_false(Directory.new().dir_exists(base), "reads never create directories")


func test_list_runs_and_delete_run() -> void:
	var s = _store()
	for run in ["run-b", "run-a", "run-c"]:
		assert_true(s.write_checkpoint(run, _state(5, run), _identities(5, run)).ok, run)
	s.write_checkpoint("run-d", _state(5, "D"), _identities(5, "D"), CheckpointStore.STAGE_COMMIT_WRITTEN)
	var dir := Directory.new()
	dir.make_dir_recursive(base.plus_file("Upper"))
	dir.make_dir_recursive(base.plus_file("bad.name"))
	_write_bytes(base.plus_file("note-file"), PoolByteArray([1]))
	assert_eq(s.list_runs().runs, ["run-a", "run-b", "run-c", "run-d"], "only valid run directories")
	var d = s.delete_run("run-b")
	assert_true(d.ok, d.reason)
	assert_true(d.deleted)
	assert_eq(s.list_runs().runs, ["run-a", "run-c", "run-d"])
	assert_eq(s.read_latest("run-b").reason, CheckpointStore.REASON_NOT_FOUND)
	var again = s.delete_run("run-b")
	assert_true(again.ok)
	assert_false(again.deleted)
	var staged = s.delete_run("run-d")
	assert_true(staged.ok and staged.deleted, "interrupted write's staging is removed with the run")
	_assert_checkpoint(s.read_latest("run-a"), "run-a", 5, CheckpointStore.SOURCE_CURRENT, "sibling kept")
	_assert_checkpoint(s.read_latest("run-c"), "run-c", 5, CheckpointStore.SOURCE_CURRENT, "sibling kept")
	assert_eq(_entries(base), ["Upper", "bad.name", "note-file", "run-a", "run-c"], "non-run entries untouched")


func test_delete_run_refuses_foreign_entries() -> void:
	var s = _store()
	s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
	var run_dir: String = s.get_run_dir(RUN)
	var dir := Directory.new()
	for path in [run_dir.plus_file("current").plus_file("notes.txt"), run_dir.plus_file("extra.txt")]:
		_write_bytes(path, PoolByteArray([1, 2, 3]))
		var before := _snapshot(base)
		var d = s.delete_run(RUN)
		assert_false(d.ok, path)
		assert_false(d.deleted, path)
		assert_eq(d.reason, CheckpointStore.REASON_FOREIGN_FILES, path)
		assert_eq(_diff(_snapshot(base), before), "", "nothing deleted: %s" % path)
		_assert_checkpoint(_store().read_latest(RUN), "B", 5, CheckpointStore.SOURCE_CURRENT, path)
		dir.remove(path)
	dir.make_dir_recursive(run_dir.plus_file("backup"))
	assert_eq(s.delete_run(RUN).reason, CheckpointStore.REASON_FOREIGN_FILES, "foreign directory")
	dir.remove(run_dir.plus_file("backup"))
	var ok = s.delete_run(RUN)
	assert_true(ok.ok and ok.deleted, ok.reason)
	assert_false(dir.dir_exists(run_dir))


func test_write_refuses_foreign_entries_in_slots() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var run_dir: String = s.get_run_dir(RUN)
	var dir := Directory.new()
	# [directory to create first, file to create, entry to remove afterwards]
	var cases := [
		["", run_dir.plus_file("current").plus_file("notes.txt"), ""],
		[run_dir.plus_file("current").plus_file("sub"), "", ""],
		[run_dir.plus_file("staging"), run_dir.plus_file("staging").plus_file("notes.txt"), run_dir.plus_file("staging")],
		["", run_dir.plus_file("previous"), ""],
	]
	for c in cases:
		var label: String = c[0] + " " + c[1]
		if c[0] != "":
			dir.make_dir_recursive(c[0])
		if c[1] != "":
			_write_bytes(c[1], PoolByteArray([9]))
		var before := _snapshot(base)
		var w = s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B"))
		assert_false(w.ok, label)
		assert_eq(w.reason, CheckpointStore.REASON_FOREIGN_FILES, label)
		assert_eq(_diff(_snapshot(base), before), "", label)
		assert_eq(_store().read_latest(RUN).checkpoint_id, a.checkpoint_id, label)
		if c[1] != "":
			dir.remove(c[1])
		if c[0] != "":
			dir.remove(c[0])
		if c[2] != "":
			dir.remove(c[2])
	assert_true(s.write_checkpoint(RUN, _state(5, "B"), _identities(5, "B")).ok, "clean again")


# --- payload rules ----------------------------------------------------------

func test_unsupported_values_are_rejected_on_write() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var too_deep = "leaf"
	for i in range(CheckpointStore.MAX_VALUE_DEPTH + 2):
		too_deep = [too_deep]
	var cyclic := []
	cyclic.append(cyclic)
	var object_key := {}
	object_key[Reference.new()] = 1
	var bad := [Reference.new(), [1, {"x": Reference.new()}], object_key, RID(), NodePath("a/b"), too_deep, cyclic]
	for i in range(bad.size()):
		var state := _state(5, "B")
		state["bad"] = bad[i]
		assert_eq(s.write_checkpoint(RUN, state, _identities(5, "B")).reason, CheckpointStore.REASON_UNSUPPORTED_VALUE, "state case %d" % i)
		var identities := _identities(5, "B")
		identities["bad"] = bad[i]
		assert_eq(s.write_checkpoint(RUN, _state(5, "B"), identities).reason, CheckpointStore.REASON_UNSUPPORTED_VALUE, "identities case %d" % i)
	cyclic.clear()
	var r = _store().read_latest(RUN)
	assert_eq(r.checkpoint_id, a.checkpoint_id, "nothing written")
	assert_eq(_entries(base.plus_file(RUN)), ["current"])
	# Nesting just inside the limit is still plain data.
	var deep_ok = "leaf"
	for i in range(CheckpointStore.MAX_VALUE_DEPTH - 2):
		deep_ok = [deep_ok]
	var state_ok := _state(5, "B")
	state_ok["deep"] = deep_ok
	assert_true(s.write_checkpoint(RUN, state_ok, _identities(5, "B")).ok)
	assert_eq(_diff(_store().read_latest(RUN).state, state_ok), "")


func test_payload_too_large_is_rejected() -> void:
	var s = _store()
	var a = s.write_checkpoint(RUN, _state(5, "A"), _identities(5, "A"))
	var blob := PoolByteArray()
	blob.resize(CheckpointStore.MAX_PAYLOAD_FILE_BYTES + 1)
	for target in ["state", "identities"]:
		var state := _state(5, "B")
		var identities := _identities(5, "B")
		if target == "state":
			state["blob"] = blob
		else:
			identities["blob"] = blob
		var w = s.write_checkpoint(RUN, state, identities)
		assert_false(w.ok, target)
		assert_eq(w.reason, CheckpointStore.REASON_PAYLOAD_TOO_LARGE, target)
		assert_eq(_store().read_latest(RUN).checkpoint_id, a.checkpoint_id, target)
		assert_eq(_entries(base.plus_file(RUN)), ["current"], target)


# --- helpers ----------------------------------------------------------------

func _store(schema_version: int = 1):
	return CheckpointStore.new(base, schema_version)


func _state(n: int, tag: String) -> Dictionary:
	var players := []
	for i in range(n):
		players.append({
			"slot": i,
			"character": "character_%d" % i,
			"gold": 30 + i * 7,
			"hp_ratio": 0.1 * (i + 1),
			"weapons": [{"id": "weapon_%d" % i, "tier": i % 4}],
			"items": ["item_%s_%d" % [tag, i]],
			"stats": {"max_hp": 10 + i, "speed": -0.05 * i},
		})
	return {"tag": tag, "player_count": n, "wave": 7, "players": players}


func _identities(n: int, tag: String) -> Dictionary:
	var slots := {}
	for i in range(n):
		slots[i] = {"steam_id": 76561198000000001 + i, "name": "P%d-%s" % [i + 1, tag], "roster_slot": i}
	return {"tag": tag, "roster_generation": 3, "slots": slots}


# Both payloads must come from the same write (same tag) and match it exactly.
func _assert_checkpoint(r, tag: String, n: int, source: String, label: String) -> void:
	assert_true(r.ok, "%s: %s" % [label, r.reason])
	if not r.ok:
		return
	assert_eq(r.source, source, label)
	assert_eq(_diff(r.state, _state(n, tag)), "", "%s state" % label)
	assert_eq(_diff(r.identities, _identities(n, tag)), "", "%s identities" % label)


func _expected_reason(file_name: String, mode: String) -> String:
	if file_name == CheckpointStore.COMMIT_FILE:
		return CheckpointStore.REASON_MISSING_COMMIT if mode == "delete" else CheckpointStore.REASON_CORRUPTED
	return CheckpointStore.REASON_MISSING_PAYLOAD if mode == "delete" else CheckpointStore.REASON_HASH_MISMATCH


func _slot_file(run: String, slot: String, file_name: String) -> String:
	return base.plus_file(run).plus_file(slot).plus_file(file_name)


func _corrupt(path: String, mode: String) -> void:
	var bytes := _read_bytes(path)
	if mode == "flip":
		var at: int = bytes.size() / 2
		bytes[at] = bytes[at] ^ 0xFF
		_write_bytes(path, bytes)
	elif mode == "truncate":
		_write_bytes(path, bytes.subarray(0, bytes.size() / 2 - 1))
	elif mode == "empty":
		_write_bytes(path, PoolByteArray())
	elif mode == "append":
		bytes.append(0)
		_write_bytes(path, bytes)
	elif mode == "delete":
		Directory.new().remove(path)
	else:
		fail("unknown corruption %s" % mode)


func _read_record(store, run: String, slot: String):
	var unframed = store._unframe(_read_bytes(_slot_file(run, slot, CheckpointStore.COMMIT_FILE)))
	if not unframed.ok:
		return null
	return store._decode(unframed.payload)


func _write_record(store, run: String, slot: String, record: Dictionary) -> void:
	_write_bytes(_slot_file(run, slot, CheckpointStore.COMMIT_FILE), store._frame(var2bytes(record, false)))


func _patched_record(store, record: Dictionary, key: String, value) -> PoolByteArray:
	var copy := record.duplicate()
	copy[key] = value
	return store._frame(var2bytes(copy, false))


func _read_bytes(path: String) -> PoolByteArray:
	var file := File.new()
	if file.open(path, File.READ) != OK:
		fail("cannot read %s" % path)
		return PoolByteArray()
	var bytes := file.get_buffer(file.get_len())
	file.close()
	return bytes


func _write_bytes(path: String, bytes: PoolByteArray) -> void:
	var file := File.new()
	if file.open(path, File.WRITE) != OK:
		fail("cannot write %s" % path)
		return
	file.store_buffer(bytes)
	file.close()


func _copy(from: String, to: String) -> void:
	_write_bytes(to, _read_bytes(from))


func _sha256_hex(bytes: PoolByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if bytes.size() > 0:
		ctx.update(bytes)
	return ctx.finish().hex_encode()


# Absolute length of a run's longest file, spelled out independently of the
# store's constants.
func _longest_path(store_base: String, run: String) -> int:
	return ProjectSettings.globalize_path(store_base.plus_file(run).plus_file("previous").plus_file("identities.bin")).length()


# {slot: [file names]} -> the sorted listing _tree() returns for a run.
func _layout(slots: Dictionary) -> Array:
	var out := []
	for slot in slots:
		out.append(slot + "/")
		for file_name in slots[slot]:
			out.append(slot + "/" + file_name)
	out.sort()
	return out


func _repeat(text: String, count: int) -> String:
	var out := ""
	for i in range(count):
		out += text
	return out


# Strict structural comparison: types must match exactly (1 != 1.0) and
# dictionary keys must come back in the same order with the same types.
func _diff(a, b, path: String = "$") -> String:
	if typeof(a) != typeof(b):
		return "%s: type %d vs %d" % [path, typeof(a), typeof(b)]
	var value_type := typeof(a)
	if value_type == TYPE_DICTIONARY:
		if a.size() != b.size():
			return "%s: size %d vs %d" % [path, a.size(), b.size()]
		var keys_a: Array = a.keys()
		var keys_b: Array = b.keys()
		for i in range(keys_a.size()):
			var d := _diff(keys_a[i], keys_b[i], "%s.<key %d>" % [path, i])
			if d != "":
				return d
			d = _diff(a[keys_a[i]], b[keys_b[i]], "%s.%s" % [path, str(keys_a[i])])
			if d != "":
				return d
		return ""
	if value_type in [TYPE_ARRAY, TYPE_RAW_ARRAY, TYPE_INT_ARRAY, TYPE_REAL_ARRAY, TYPE_STRING_ARRAY, TYPE_VECTOR2_ARRAY]:
		var items_a: Array = Array(a)
		var items_b: Array = Array(b)
		if items_a.size() != items_b.size():
			return "%s: size %d vs %d" % [path, items_a.size(), items_b.size()]
		for i in range(items_a.size()):
			var d := _diff(items_a[i], items_b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a != b:
		return "%s: %s vs %s" % [path, var2str(a), var2str(b)]
	return ""


func _contains_object(value) -> bool:
	if typeof(value) == TYPE_OBJECT:
		return true
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			if _contains_object(item):
				return true
	if typeof(value) == TYPE_DICTIONARY:
		for key in value:
			if _contains_object(key) or _contains_object(value[key]):
				return true
	return false


# Sorted names directly inside a directory ([] when it does not exist).
func _entries(path: String) -> Array:
	var names := []
	var dir := Directory.new()
	if not dir.dir_exists(path) or dir.open(path) != OK:
		return names
	dir.list_dir_begin(true, false)
	var name := dir.get_next()
	while name != "":
		names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	return names


# Relative paths of every file and directory below path, sorted.
func _tree(path: String, prefix: String = "") -> Array:
	var out := []
	var dir := Directory.new()
	for name in _entries(path):
		var rel: String = prefix.plus_file(name) if prefix != "" else name
		if dir.dir_exists(path.plus_file(name)):
			out.append(rel + "/")
			out.append_array(_tree(path.plus_file(name), rel))
		else:
			out.append(rel)
	out.sort()
	return out


# Relative path -> SHA-256 of the file ("dir" for directories).
func _snapshot(path: String) -> Dictionary:
	var out := {}
	for rel in _tree(path):
		if rel.ends_with("/"):
			out[rel] = "dir"
		else:
			out[rel] = _sha256_hex(_read_bytes(path.plus_file(rel)))
	return out


func _remove_tree(path: String) -> void:
	if not path.begins_with(TEST_ROOT + "/"):
		return
	var dir := Directory.new()
	if not dir.dir_exists(path):
		return
	for name in _entries(path):
		var child := path.plus_file(name)
		if dir.dir_exists(child):
			_remove_tree(child)
		else:
			dir.remove(child)
	dir.remove(path)
