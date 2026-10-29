extends "res://tests/runner/test_case.gd"
# ReadyBarrier rules: T06 (duplicate/simultaneous readies start once), T07
# (slow client, hint, timeout, retry), F01 (never complete on a subset).

const ReadyBarrier = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/ready_barrier.gd")
const FlowGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd")

# Non-zero start time catches absolute-vs-elapsed time mistakes.
const T0 := 1000000


func _stamp() -> Dictionary:
	return {"run_id": "run-a", "wave": 3, "phase": "shop", "roster_generation": 1, "seq": 7}


func _stamp_with(key: String, value) -> Dictionary:
	var s := _stamp()
	s[key] = value
	return s


func _slots(count: int) -> Array:
	return range(count)


func _barrier(count: int) -> Reference:
	return ReadyBarrier.new(_slots(count), _stamp(), T0)


func _shuffled(items: Array, rng: RandomNumberGenerator) -> Array:
	var out: Array = items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


func test_defaults_follow_the_requirements_budget() -> void:
	assert_eq(ReadyBarrier.DEFAULT_HINT_AFTER_MSEC, 10000)
	assert_eq(ReadyBarrier.DEFAULT_TIMEOUT_MSEC, 30000)
	var b = _barrier(2)
	assert_true(b.is_valid())
	assert_eq(b.init_reason(), ReadyBarrier.REASON_NONE)
	assert_eq(b.state(), ReadyBarrier.STATE_WAITING)
	assert_eq(b.started_msec(), T0)
	assert_eq(b.hint_at_msec(), T0 + 10000)
	assert_eq(b.deadline_msec(), T0 + 30000)
	assert_eq(b.remaining_msec(T0), 30000)
	assert_eq(b.missing(), [0, 1])
	assert_eq(b.ready_slots(), [])
	assert_true(FlowGuard.same_stamp(b.stamp(), _stamp()))


func test_completes_only_after_every_slot_for_1_to_8() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for n in range(1, 9):
		for trial in range(3):
			var b = _barrier(n)
			var order: Array = _slots(n) if trial == 0 else _shuffled(_slots(n), rng)
			for i in range(n):
				var label: String = "n %d trial %d step %d" % [n, trial, i]
				assert_eq(b.poll(T0 + 100 * i), ReadyBarrier.STATE_WAITING, label)
				var r = b.mark_ready(order[i], _stamp())
				assert_true(r.ok, label)
				assert_true(r.changed, label)
				if i < n - 1:
					assert_false(b.is_complete(), label)
					assert_eq(b.missing().size(), n - 1 - i, label)
					assert_not_has(b.missing(), order[i], label)
			assert_eq(b.poll(T0 + 100 * n), ReadyBarrier.STATE_COMPLETE, "n %d trial %d" % [n, trial])
			assert_eq(b.missing(), [], "n %d trial %d" % [n, trial])
			assert_eq(b.ready_slots(), _slots(n), "n %d trial %d" % [n, trial])


func test_first_four_of_eight_never_complete() -> void:
	var b = _barrier(8)
	for slot in range(4):
		b.mark_ready(slot, _stamp())
	for t in [0, 5000, 10000, 29999]:
		assert_ne(b.poll(T0 + t), ReadyBarrier.STATE_COMPLETE, "t %d" % t)
	assert_eq(b.missing(), [4, 5, 6, 7])
	assert_eq(b.poll(T0 + 30000), ReadyBarrier.STATE_TIMED_OUT)
	assert_eq(b.missing(), [4, 5, 6, 7])
	assert_eq(b.expected(), _slots(8), "nobody dropped on timeout")
	assert_eq(b.removed(), [])
	# The other direction: P5..P8 ready, P1..P4 still loading.
	var back = _barrier(8)
	for slot in range(4, 8):
		back.mark_ready(slot, _stamp())
	assert_eq(back.poll(T0 + 29999), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(back.missing(), [0, 1, 2, 3])
	assert_eq(back.ready_slots(), [4, 5, 6, 7])
	# Seven of eight, each slot in turn the missing one.
	for absent in range(8):
		var seven = _barrier(8)
		for slot in range(8):
			if slot != absent:
				seven.mark_ready(slot, _stamp())
		assert_false(seven.is_complete(), "absent %d" % absent)
		assert_eq(seven.missing(), [absent], "absent %d" % absent)
		assert_true(seven.mark_ready(absent, _stamp()).changed, "absent %d" % absent)
		assert_true(seven.is_complete(), "absent %d" % absent)


func test_duplicate_ready_is_idempotent() -> void:
	for n in range(2, 9):
		var b = _barrier(n)
		assert_true(b.mark_ready(0, _stamp()).changed, "n %d" % n)
		# More repeats than slots: a counter-based barrier would complete here.
		for i in range(n + 2):
			var r = b.mark_ready(0, _stamp())
			assert_true(r.ok, "n %d repeat %d" % [n, i])
			assert_false(r.changed, "n %d repeat %d" % [n, i])
			assert_eq(r.reason, ReadyBarrier.REASON_ALREADY_READY, "n %d repeat %d" % [n, i])
		assert_eq(b.poll(T0), ReadyBarrier.STATE_WAITING, "n %d" % n)
		assert_eq(b.ready_slots(), [0], "n %d" % n)
		assert_eq(b.missing().size(), n - 1, "n %d" % n)
	var single = _barrier(1)
	single.mark_ready(0, _stamp())
	assert_eq(single.mark_ready(0, _stamp()).reason, ReadyBarrier.REASON_ALREADY_READY)
	assert_eq(single.poll(T0), ReadyBarrier.STATE_COMPLETE)


func test_hint_and_timeout_boundaries() -> void:
	var b = _barrier(3)
	assert_eq(b.poll(T0), ReadyBarrier.STATE_WAITING)
	assert_eq(b.poll(T0 + 9999), ReadyBarrier.STATE_WAITING)
	assert_eq(b.poll(T0 + 10000), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(b.poll(T0 + 29999), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(b.remaining_msec(T0 + 29999), 1)
	assert_eq(b.poll(T0 + 30000), ReadyBarrier.STATE_TIMED_OUT)
	assert_true(b.is_timed_out())
	assert_eq(b.poll(T0 + 90000), ReadyBarrier.STATE_TIMED_OUT, "terminal")
	assert_eq(b.poll(T0), ReadyBarrier.STATE_TIMED_OUT, "an earlier time does not revive it")
	assert_eq(b.remaining_msec(T0), 0)
	var early = _barrier(3)
	assert_eq(early.poll(T0 - 50000), ReadyBarrier.STATE_WAITING, "clock before start")
	assert_eq(early.remaining_msec(T0 - 50000), 30000, "never more than the whole budget")
	assert_eq(early.remaining_msec(T0 + 12345), 30000 - 12345)
	assert_eq(early.remaining_msec(T0 + 40000), 0, "past the deadline before the next poll")
	var custom = ReadyBarrier.new(_slots(2), _stamp(), T0, 500, 2000)
	assert_eq(custom.poll(T0 + 499), ReadyBarrier.STATE_WAITING)
	assert_eq(custom.poll(T0 + 500), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(custom.poll(T0 + 1999), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(custom.poll(T0 + 2000), ReadyBarrier.STATE_TIMED_OUT)
	var no_hint = ReadyBarrier.new(_slots(2), _stamp(), T0, 2000, 2000)
	assert_true(no_hint.is_valid())
	assert_eq(no_hint.poll(T0 + 1999), ReadyBarrier.STATE_WAITING)
	assert_eq(no_hint.poll(T0 + 2000), ReadyBarrier.STATE_TIMED_OUT)


func test_late_ready_after_timeout_is_rejected() -> void:
	var b = _barrier(8)
	for slot in range(7):
		b.mark_ready(slot, _stamp())
	assert_eq(b.poll(T0 + 30000), ReadyBarrier.STATE_TIMED_OUT)
	var late = b.mark_ready(7, _stamp())
	assert_false(late.ok)
	assert_false(late.changed)
	assert_eq(late.reason, ReadyBarrier.REJECT_TIMED_OUT)
	assert_eq(b.poll(T0 + 30001), ReadyBarrier.STATE_TIMED_OUT)
	assert_false(b.is_complete())
	assert_eq(b.missing(), [7])
	var repeat = b.mark_ready(3, _stamp())
	assert_true(repeat.ok, "a slot that was ready in time stays ready")
	assert_false(repeat.changed)
	assert_eq(repeat.reason, ReadyBarrier.REASON_ALREADY_READY)


func test_readies_recorded_before_the_timeout_poll_count() -> void:
	var b = _barrier(4)
	for slot in range(4):
		b.mark_ready(slot, _stamp())
	assert_eq(b.poll(T0 + 45000), ReadyBarrier.STATE_COMPLETE)
	assert_false(b.is_timed_out())


func test_wrong_or_malformed_stamp_is_rejected() -> void:
	var b = _barrier(2)
	var wrong = [
		_stamp_with("run_id", "run-b"), _stamp_with("wave", 4), _stamp_with("wave", 2),
		_stamp_with("phase", "wave"), _stamp_with("roster_generation", 0),
		_stamp_with("roster_generation", 2), _stamp_with("seq", 6), _stamp_with("seq", 8)
	]
	for i in range(wrong.size()):
		var r = b.mark_ready(0, wrong[i])
		assert_false(r.ok, "wrong %d" % i)
		assert_eq(r.reason, ReadyBarrier.REJECT_WRONG_STAMP, "wrong %d" % i)
	var malformed = [null, {}, "stamp", [], _stamp_with("seq", 7.5), _stamp_with("seq", "7"), _stamp_with("phase", "")]
	for i in range(malformed.size()):
		var r = b.mark_ready(0, malformed[i])
		assert_false(r.ok, "malformed %d" % i)
		assert_eq(r.reason, ReadyBarrier.REJECT_MALFORMED_STAMP, "malformed %d" % i)
	assert_eq(b.ready_slots(), [])
	var wire = parse_json(to_json(_stamp()))
	assert_true(b.mark_ready(0, wire).ok, "right stamp after a JSON round trip")
	assert_eq(b.ready_slots(), [0])


func test_unknown_and_invalid_slots_are_rejected() -> void:
	var b = ReadyBarrier.new([0, 1, 2], _stamp(), T0)
	assert_eq(b.mark_ready(3, _stamp()).reason, ReadyBarrier.REJECT_NOT_EXPECTED)
	assert_eq(b.mark_ready(8, _stamp()).reason, ReadyBarrier.REJECT_NOT_EXPECTED, "ninth player's slot")
	var bad = [-1, "1", null, 1.5, true, [1], INF]
	for i in range(bad.size()):
		assert_eq(b.mark_ready(bad[i], _stamp()).reason, ReadyBarrier.REJECT_INVALID_SLOT, "bad %d" % i)
	assert_eq(b.ready_slots(), [])
	assert_true(b.mark_ready(1.0, _stamp()).ok, "integral float is slot 1")
	assert_eq(b.ready_slots(), [1])
	assert_eq(typeof(b.ready_slots()[0]), TYPE_INT)
	assert_eq(b.mark_ready(1, _stamp()).reason, ReadyBarrier.REASON_ALREADY_READY)


func test_remove_expected_is_explicit_and_can_complete() -> void:
	var b = _barrier(8)
	for slot in range(8):
		if slot != 5:
			b.mark_ready(slot, _stamp())
	assert_eq(b.poll(T0 + 10000), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(b.poll(T0 + 29999), ReadyBarrier.STATE_WAITING_HINT, "never removed automatically")
	assert_eq(b.missing(), [5])
	assert_eq(b.expected().size(), 8)
	var r = b.remove_expected(5)
	assert_true(r.ok)
	assert_true(r.changed)
	assert_eq(b.removed(), [5])
	assert_eq(b.expected(), [0, 1, 2, 3, 4, 6, 7])
	assert_eq(b.poll(T0 + 29999), ReadyBarrier.STATE_COMPLETE)
	assert_eq(b.mark_ready(5, _stamp()).reason, ReadyBarrier.REJECT_REMOVED)
	assert_eq(b.poll(T0 + 40000), ReadyBarrier.STATE_COMPLETE)


func test_remove_expected_rules() -> void:
	var b = _barrier(3)
	assert_eq(b.remove_expected(5).reason, ReadyBarrier.REJECT_NOT_EXPECTED)
	assert_eq(b.remove_expected("x").reason, ReadyBarrier.REJECT_INVALID_SLOT)
	b.mark_ready(1, _stamp())
	assert_true(b.remove_expected(1).ok)
	assert_eq(b.ready_slots(), [], "removing a ready slot drops its mark")
	var again = b.remove_expected(1)
	assert_true(again.ok)
	assert_false(again.changed)
	assert_eq(again.reason, ReadyBarrier.REASON_ALREADY_REMOVED)
	assert_true(b.remove_expected(0).ok)
	var last = b.remove_expected(2)
	assert_false(last.ok)
	assert_eq(last.reason, ReadyBarrier.REJECT_LAST_SLOT)
	assert_eq(b.expected(), [2])
	assert_eq(b.missing(), [2])
	assert_eq(b.removed(), [0, 1])
	assert_eq(b.poll(T0), ReadyBarrier.STATE_WAITING)
	var timed = _barrier(2)
	timed.poll(T0 + 30000)
	assert_eq(timed.remove_expected(0).reason, ReadyBarrier.REJECT_TIMED_OUT)
	assert_eq(timed.missing(), [0, 1])
	var done = _barrier(2)
	done.mark_ready(0, _stamp())
	done.mark_ready(1, _stamp())
	assert_eq(done.remove_expected(0).reason, ReadyBarrier.REJECT_COMPLETE)
	assert_eq(done.expected(), [0, 1])


func test_invalid_construction_never_completes() -> void:
	var cases = [
		[_slots(9), _stamp(), 10000, 30000, ReadyBarrier.REJECT_TOO_MANY_SLOTS],
		[[], _stamp(), 10000, 30000, ReadyBarrier.REJECT_NO_SLOTS],
		[null, _stamp(), 10000, 30000, ReadyBarrier.REJECT_NO_SLOTS],
		[[0, 0], _stamp(), 10000, 30000, ReadyBarrier.REJECT_DUPLICATE_SLOT],
		[[1, 1.0], _stamp(), 10000, 30000, ReadyBarrier.REJECT_DUPLICATE_SLOT],
		[[0, -1], _stamp(), 10000, 30000, ReadyBarrier.REJECT_INVALID_SLOT],
		[[0, "1"], _stamp(), 10000, 30000, ReadyBarrier.REJECT_INVALID_SLOT],
		[[0, 1.5], _stamp(), 10000, 30000, ReadyBarrier.REJECT_INVALID_SLOT],
		[_slots(2), {}, 10000, 30000, ReadyBarrier.REJECT_MALFORMED_STAMP],
		[_slots(2), null, 10000, 30000, ReadyBarrier.REJECT_MALFORMED_STAMP],
		[_slots(2), _stamp(), 30001, 30000, ReadyBarrier.REJECT_INVALID_TIMING],
		[_slots(2), _stamp(), -1, 30000, ReadyBarrier.REJECT_INVALID_TIMING],
		[_slots(2), _stamp(), 0, 0, ReadyBarrier.REJECT_INVALID_TIMING]
	]
	for i in range(cases.size()):
		var c = cases[i]
		var b = ReadyBarrier.new(c[0], c[1], T0, c[2], c[3])
		assert_false(b.is_valid(), "case %d" % i)
		assert_eq(b.init_reason(), c[4], "case %d" % i)
		for t in [0, 10000, 30000, 1000000]:
			assert_eq(b.poll(T0 + t), ReadyBarrier.STATE_INVALID, "case %d t %d" % [i, t])
		assert_eq(b.mark_ready(0, _stamp()).reason, ReadyBarrier.REJECT_INVALID_BARRIER, "case %d" % i)
		assert_eq(b.remove_expected(0).reason, ReadyBarrier.REJECT_INVALID_BARRIER, "case %d" % i)
		assert_false(b.is_complete(), "case %d" % i)
		assert_false(b.is_timed_out(), "case %d" % i)
		assert_eq(b.state(), ReadyBarrier.STATE_INVALID, "case %d" % i)
		assert_eq(b.expected(), [], "case %d: nothing kept from bad arguments" % i)
		assert_eq(b.remaining_msec(T0), 0, "case %d" % i)
	assert_true(_barrier(8).is_valid(), "eight slots are fine")
	assert_true(ReadyBarrier.new(_slots(2), _stamp(), T0, 0, 1).is_valid(), "immediate hint")


func test_slot_ids_need_not_be_contiguous() -> void:
	var b = ReadyBarrier.new([7, 2, 5], _stamp(), T0)
	assert_eq(b.expected(), [2, 5, 7])
	assert_eq(b.missing(), [2, 5, 7])
	b.mark_ready(5, _stamp())
	assert_eq(b.missing(), [2, 7])
	assert_eq(b.ready_slots(), [5])
	assert_eq(b.mark_ready(0, _stamp()).reason, ReadyBarrier.REJECT_NOT_EXPECTED)


func test_inputs_and_outputs_are_copies() -> void:
	var slots := [0, 1, 2]
	var s := _stamp()
	var b = ReadyBarrier.new(slots, s, T0)
	slots.append(3)
	s.seq = 99
	assert_eq(b.expected(), [0, 1, 2])
	assert_true(b.mark_ready(0, _stamp()).ok, "barrier kept its own stamp copy")
	b.expected().append(9)
	b.missing().clear()
	b.ready_slots().clear()
	var st = b.stamp()
	st.seq = 1
	assert_eq(b.expected(), [0, 1, 2])
	assert_eq(b.missing(), [1, 2])
	assert_eq(b.ready_slots(), [0])
	assert_eq(b.stamp().seq, 7)


func test_t07_slow_client_recovers_within_budget() -> void:
	var b = _barrier(8)
	for slot in range(8):
		if slot != 6:
			b.mark_ready(slot, _stamp())
	assert_eq(b.poll(T0 + 500), ReadyBarrier.STATE_WAITING)
	assert_eq(b.poll(T0 + 12000), ReadyBarrier.STATE_WAITING_HINT)
	assert_eq(b.missing(), [6])
	assert_true(b.mark_ready(6, _stamp()).changed)
	assert_eq(b.poll(T0 + 20000), ReadyBarrier.STATE_COMPLETE)
	assert_eq(b.poll(T0 + 40000), ReadyBarrier.STATE_COMPLETE, "complete is terminal too")
	assert_eq(b.remaining_msec(T0 + 20000), 0)


func test_t07_retry_after_timeout_needs_a_new_barrier_and_stamp() -> void:
	var guard = FlowGuard.new()
	guard.begin_run("run-a")
	guard.advance(3, "wave_load")
	var old_stamp = guard.stamp()
	var first = ReadyBarrier.new(_slots(8), old_stamp, T0)
	for slot in range(7):
		first.mark_ready(slot, old_stamp)
	assert_eq(first.poll(T0 + 30000), ReadyBarrier.STATE_TIMED_OUT)
	# Host picks "retry": a new commit for the same wave/phase and a new barrier.
	guard.advance(3, "wave_load")
	var second = ReadyBarrier.new(_slots(8), guard.stamp(), T0 + 30000)
	for slot in range(8):
		assert_eq(second.mark_ready(slot, old_stamp).reason, ReadyBarrier.REJECT_WRONG_STAMP, "slot %d" % slot)
	assert_eq(second.missing(), _slots(8))
	for slot in range(8):
		second.mark_ready(slot, guard.stamp())
	assert_eq(second.poll(T0 + 31000), ReadyBarrier.STATE_COMPLETE)
	assert_eq(first.poll(T0 + 31000), ReadyBarrier.STATE_TIMED_OUT, "old barrier stays timed out")


func test_t06_simultaneous_readies_start_the_wave_once() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 606
	for n in range(1, 9):
		var guard = FlowGuard.new()
		guard.begin_run("run-a")
		guard.advance(1, "character_select")
		var msg = guard.stamp()
		var b = ReadyBarrier.new(_slots(n), msg, T0)
		var inbox := []
		for slot in range(n):
			for copy in range(3):
				inbox.append(slot)
		inbox = _shuffled(inbox, rng)
		# The barrier must complete exactly when the last distinct slot arrives.
		var seen := {}
		var expected_index := -1
		for i in range(inbox.size()):
			seen[inbox[i]] = true
			if seen.size() == n and expected_index < 0:
				expected_index = i
		var starts := []
		for i in range(inbox.size()):
			if guard.check_stamp(msg).accepted:
				b.mark_ready(inbox[i], msg)
			if b.poll(T0 + 16 * i) == ReadyBarrier.STATE_COMPLETE and guard.try_commit_for(b.stamp(), "start_wave"):
				starts.append(i)
		for frame in range(5):
			if b.poll(T0 + 10000 + frame) == ReadyBarrier.STATE_COMPLETE and guard.try_commit_for(b.stamp(), "start_wave"):
				starts.append(inbox.size() + frame)
		assert_eq(starts, [expected_index], "n %d" % n)
		# The wave starts: the host commits the next phase. The finished barrier
		# and every late duplicate confirm are now stale and start nothing.
		guard.advance(1, "wave")
		for slot in range(n):
			assert_false(guard.check_stamp(msg).accepted, "n %d late slot %d" % [n, slot])
			assert_false(guard.try_commit_for(b.stamp(), "start_wave"), "n %d late slot %d" % [n, slot])
		assert_true(b.is_complete(), "n %d" % n)
