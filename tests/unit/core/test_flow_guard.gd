extends "res://tests/runner/test_case.gd"
# FlowGuard rules: T06 (single commit), T07 (future stamps from faster peers),
# T08 (stale, replayed and reordered messages, restarts that keep the run
# id), F01 (nothing silently passes).

const FlowGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd")

const STAMP_KEYS := ["run_id", "wave", "phase", "roster_generation", "seq"]


func _guard_at(wave: int, phase: String) -> Reference:
	var g = FlowGuard.new()
	g.begin_run("run-a")
	g.advance(wave, phase)
	return g


func _with(stamp: Dictionary, key: String, value) -> Dictionary:
	var s: Dictionary = stamp.duplicate()
	s[key] = value
	return s


func _without(stamp: Dictionary, key: String) -> Dictionary:
	var s: Dictionary = stamp.duplicate()
	s.erase(key)
	return s


func _long_string(length: int) -> String:
	var s := ""
	for i in range(length):
		s += "x"
	return s


func _shuffled(items: Array, rng: RandomNumberGenerator) -> Array:
	var out: Array = items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


# Dictionaries compare by reference in Godot 3, so compare field by field.
func _assert_stamp(actual: Dictionary, expected: Dictionary, message: String) -> void:
	for key in STAMP_KEYS:
		assert_eq(actual.get(key), expected.get(key), "%s: %s" % [message, key])


func test_new_guard_has_no_run_and_refuses_everything() -> void:
	var g = FlowGuard.new()
	assert_false(g.has_run())
	assert_eq(g.stamp().seq, 0)
	var r = g.check_stamp(_guard_at(1, "wave").stamp())
	assert_false(r.accepted)
	assert_eq(r.reason, FlowGuard.REJECT_NO_RUN)
	assert_true(r.ahead, "a peer without a run is behind everyone")
	assert_eq(g.advance(1, "wave").reason, FlowGuard.REJECT_NO_RUN)
	assert_eq(g.set_roster_generation(1).reason, FlowGuard.REJECT_NO_RUN)
	assert_false(g.try_commit("start_wave"))
	assert_eq(g.commit("start_wave").reason, FlowGuard.REJECT_NO_RUN)
	assert_eq(g.stamp().seq, 0)


func test_begin_run_starts_at_wave_zero() -> void:
	var g = FlowGuard.new()
	var r = g.begin_run("run-a")
	assert_true(r.ok)
	assert_true(r.changed)
	_assert_stamp(r.stamp, {"run_id": "run-a", "wave": 0, "phase": FlowGuard.PHASE_RUN_START, "roster_generation": 0, "seq": 1}, "begin")
	_assert_stamp(g.stamp(), r.stamp, "stamp() matches result")
	assert_true(g.check_stamp(g.stamp()).accepted)


func test_begin_run_rejects_bad_ids_without_changes() -> void:
	var g = FlowGuard.new()
	for bad in ["", _long_string(FlowGuard.MAX_RUN_ID_LENGTH + 1)]:
		var r = g.begin_run(bad)
		assert_false(r.ok, "id length %d" % bad.length())
		assert_eq(r.reason, FlowGuard.REJECT_INVALID_RUN_ID)
	assert_false(g.has_run())
	g.begin_run("run-a")
	g.advance(2, "shop")
	var before = g.stamp()
	assert_false(g.begin_run("").ok)
	_assert_stamp(g.stamp(), before, "failed begin_run")
	assert_true(g.begin_run(_long_string(FlowGuard.MAX_RUN_ID_LENGTH)).ok, "longest id")


func test_every_commit_bumps_seq_by_exactly_one() -> void:
	var g = FlowGuard.new()
	var steps = [
		g.begin_run("run-a"),
		g.advance(1, "wave"),
		g.advance(1, "wave"),
		g.advance(1, "shop"),
		g.set_roster_generation(1),
		g.advance(2, "wave"),
		g.begin_run("run-b")
	]
	for i in range(steps.size()):
		assert_true(steps[i].ok, "step %d" % i)
		assert_true(steps[i].changed, "step %d" % i)
		assert_eq(steps[i].stamp.seq, i + 1, "step %d" % i)
	_assert_stamp(g.stamp(), {"run_id": "run-b", "wave": 0, "phase": FlowGuard.PHASE_RUN_START, "roster_generation": 0, "seq": 7}, "after second run")


func test_reasserting_roster_generation_is_a_no_op() -> void:
	var g = _guard_at(1, "shop")
	g.set_roster_generation(2)
	var msg = g.stamp()
	var r = g.set_roster_generation(2)
	assert_true(r.ok)
	assert_false(r.changed)
	assert_eq(r.reason, FlowGuard.REASON_UNCHANGED)
	_assert_stamp(g.stamp(), msg, "no new commit")
	assert_true(g.check_stamp(msg).accepted, "in-flight message still valid")


func test_rejected_changes_leave_state_untouched() -> void:
	var g = _guard_at(3, "wave")
	g.set_roster_generation(2)
	var before = g.stamp()
	var cases = [
		[g.advance(-1, "wave"), FlowGuard.REJECT_INVALID_WAVE],
		[g.advance(2, "shop"), FlowGuard.REJECT_WAVE_REGRESS],
		[g.advance(3, ""), FlowGuard.REJECT_INVALID_PHASE],
		[g.advance(4, _long_string(FlowGuard.MAX_PHASE_LENGTH + 1)), FlowGuard.REJECT_INVALID_PHASE],
		[g.set_roster_generation(1), FlowGuard.REJECT_ROSTER_REGRESS],
		[g.set_roster_generation(-1), FlowGuard.REJECT_ROSTER_REGRESS]
	]
	for i in range(cases.size()):
		assert_false(cases[i][0].ok, "case %d" % i)
		assert_false(cases[i][0].changed, "case %d" % i)
		assert_eq(cases[i][0].reason, cases[i][1], "case %d" % i)
	_assert_stamp(g.stamp(), before, "after rejected changes")
	assert_true(g.advance(3, _long_string(FlowGuard.MAX_PHASE_LENGTH)).ok, "longest phase")


func test_stamp_is_a_copy() -> void:
	var g = _guard_at(1, "wave")
	var s = g.stamp()
	s.seq = 999
	s.run_id = "other"
	assert_eq(g.stamp().seq, 2)
	assert_eq(g.stamp().run_id, "run-a")
	assert_false(g.check_stamp(s).accepted)


func test_current_stamp_survives_json_and_binary_round_trips() -> void:
	var g = _guard_at(4, "shop")
	g.set_roster_generation(3)
	var wire = parse_json(to_json(g.stamp()))
	assert_eq(typeof(wire.seq), TYPE_REAL, "parse_json turns ints into floats")
	var r = g.check_stamp(wire)
	assert_true(r.accepted)
	assert_eq(r.reason, FlowGuard.REASON_NONE)
	assert_false(r.ahead)
	var n = FlowGuard.normalize_stamp(wire)
	assert_true(n.ok)
	for key in ["wave", "roster_generation", "seq"]:
		assert_eq(typeof(n.stamp[key]), TYPE_INT, key)
	_assert_stamp(n.stamp, g.stamp(), "normalized wire stamp")
	assert_true(g.check_stamp(bytes2var(var2bytes(g.stamp()), false)).accepted, "var2bytes")
	assert_true(g.check_stamp(_with(g.stamp(), "extra", [1, 2])).accepted, "extra keys ignored")
	assert_true(FlowGuard.same_stamp(wire, g.stamp()))


func test_malformed_stamps_are_rejected() -> void:
	var g = _guard_at(2, "wave")
	var good = g.stamp()
	var cases = [
		null, 7, "stamp", [], {},
		_without(good, "run_id"), _without(good, "wave"), _without(good, "phase"),
		_without(good, "roster_generation"), _without(good, "seq"),
		_with(good, "run_id", ""), _with(good, "run_id", 5), _with(good, "run_id", _long_string(FlowGuard.MAX_RUN_ID_LENGTH + 1)),
		_with(good, "phase", ""), _with(good, "phase", null), _with(good, "phase", _long_string(FlowGuard.MAX_PHASE_LENGTH + 1)),
		_with(good, "wave", -1), _with(good, "wave", 2.5), _with(good, "wave", "2"), _with(good, "wave", true),
		_with(good, "roster_generation", -1), _with(good, "roster_generation", null),
		_with(good, "seq", 0), _with(good, "seq", -3), _with(good, "seq", 2.000001), _with(good, "seq", "2"),
		_with(good, "seq", INF), _with(good, "seq", NAN), _with(good, "seq", 1e300), _with(good, "seq", [2])
	]
	for i in range(cases.size()):
		var r = g.check_stamp(cases[i])
		assert_false(r.accepted, "case %d" % i)
		assert_eq(r.reason, FlowGuard.REJECT_MALFORMED, "case %d" % i)
		assert_false(r.ahead, "case %d" % i)
		assert_false(FlowGuard.is_valid_stamp(cases[i]), "case %d" % i)
		assert_false(FlowGuard.same_stamp(cases[i], good), "case %d" % i)
	assert_eq(FlowGuard.normalize_stamp(_with(good, "seq", "2")).field, "seq")
	_assert_stamp(g.stamp(), good, "checks never change the guard")


func test_other_run_is_rejected_and_direction_reported() -> void:
	var host = FlowGuard.new()
	host.begin_run("run-a")
	host.advance(1, "wave")
	var client = FlowGuard.new()
	client.adopt(host.stamp())
	var old_run = host.stamp()
	host.begin_run("run-b")
	var r = client.check_stamp(host.stamp())
	assert_false(r.accepted)
	assert_eq(r.reason, FlowGuard.REJECT_OTHER_RUN)
	assert_true(r.ahead, "host already started the next run")
	r = host.check_stamp(old_run)
	assert_eq(r.reason, FlowGuard.REJECT_OTHER_RUN)
	assert_false(r.ahead, "message from the finished run")
	r = host.check_stamp(_with(host.stamp(), "run_id", "run-z"))
	assert_eq(r.reason, FlowGuard.REJECT_OTHER_RUN)
	assert_false(r.accepted)
	assert_false(r.ahead)


func test_stale_stamps_are_rejected() -> void:
	var g = FlowGuard.new()
	g.begin_run("run-a")
	var history := []
	for step in [[1, "wave"], [1, "shop"], [2, "wave"], [2, "wave"]]:
		g.advance(step[0], step[1])
		history.append(g.stamp())
	var current = g.stamp()
	# history[2] has the same wave and phase as now: the failed first attempt.
	for i in range(history.size() - 1):
		var r = g.check_stamp(history[i])
		assert_false(r.accepted, "history %d" % i)
		assert_eq(r.reason, FlowGuard.REJECT_STALE, "history %d" % i)
		assert_false(r.ahead, "history %d" % i)
	assert_true(g.check_stamp(current).accepted)
	_assert_stamp(g.stamp(), current, "checks never change the guard")
	# Older wave with a newer seq: only seq can tell old from new (a restart
	# lowers the wave), so it waits as "ahead" and fails once that seq exists.
	var forged = _with(_with(current, "wave", 1), "seq", current.seq + 1)
	var r = g.check_stamp(forged)
	assert_false(r.accepted, "older wave with a newer seq")
	assert_eq(r.reason, FlowGuard.REJECT_FUTURE)
	assert_true(r.ahead)
	g.advance(2, "shop")
	r = g.check_stamp(forged)
	assert_false(r.accepted, "the real commit at that seq differs")
	assert_eq(r.reason, FlowGuard.REJECT_CONFLICT)
	assert_false(r.ahead)


func test_restarted_run_rejects_the_previous_attempt() -> void:
	var g = FlowGuard.new()
	g.begin_run("run-a")
	g.advance(7, "shop")
	g.set_roster_generation(1)
	var before = g.stamp()
	# Continue from a checkpoint: same run id, same wave/phase/roster again.
	g.begin_run("run-a")
	g.advance(7, "shop")
	g.set_roster_generation(1)
	assert_true(g.stamp().seq > before.seq)
	var r = g.check_stamp(before)
	assert_false(r.accepted, "same run, wave, phase and roster but an older seq")
	assert_eq(r.reason, FlowGuard.REJECT_STALE)
	assert_false(r.ahead)


# Continuing from a checkpoint keeps the run id while wave and roster
# generation start over. A client still at the old, higher wave must see the
# host's newer stamps as "ahead" and be able to adopt them (seq orders all).
func test_client_follows_a_restart_with_the_same_run_id() -> void:
	var host = FlowGuard.new()
	host.begin_run("run-a")
	host.advance(7, "shop")
	host.set_roster_generation(2)
	var client = FlowGuard.new()
	client.adopt(host.stamp())
	var old_shop = host.stamp()
	var restart = host.begin_run("run-a").stamp
	host.advance(1, "wave")
	var wave_one = host.stamp()
	for msg in [restart, wave_one]:
		var r = client.check_stamp(msg)
		assert_false(r.accepted, "seq %d" % msg.seq)
		assert_eq(r.reason, FlowGuard.REJECT_FUTURE, "seq %d" % msg.seq)
		assert_true(r.ahead, "seq %d must be buffered, not dropped" % msg.seq)
	var r = client.adopt(restart)
	assert_true(r.ok, "adopt the restart (%s)" % r.reason)
	assert_true(r.changed)
	_assert_stamp(client.stamp(), restart, "client restarted")
	assert_true(client.check_stamp(restart).accepted)
	assert_true(client.adopt(wave_one).ok)
	assert_true(client.check_stamp(wave_one).accepted)
	r = client.check_stamp(old_shop)
	assert_false(r.accepted, "message from before the restart")
	assert_false(r.ahead)
	assert_ne(r.reason, FlowGuard.REASON_NONE)
	assert_false(client.adopt(old_shop).ok, "no going back to the old attempt")


func test_roster_generation_mismatch() -> void:
	var g = _guard_at(3, "shop")
	var before_remap = g.stamp()
	g.set_roster_generation(1)
	var r = g.check_stamp(before_remap)
	assert_false(r.accepted)
	assert_eq(r.reason, FlowGuard.REJECT_ROSTER_MISMATCH)
	assert_false(r.ahead)
	for gen in [0, 2]:
		r = g.check_stamp(_with(g.stamp(), "roster_generation", gen))
		assert_false(r.accepted, "same seq, roster %d" % gen)
		assert_eq(r.reason, FlowGuard.REJECT_ROSTER_MISMATCH, "same seq, roster %d" % gen)
		assert_false(r.ahead, "same seq, roster %d" % gen)
	var behind = FlowGuard.new()
	behind.adopt(before_remap)
	r = behind.check_stamp(g.stamp())
	assert_false(r.accepted, "remapped roster not reached yet")
	assert_eq(r.reason, FlowGuard.REJECT_FUTURE)
	assert_true(r.ahead)


func test_future_stamp_from_faster_peer_is_distinguishable() -> void:
	var host = FlowGuard.new()
	host.begin_run("run-a")
	host.advance(5, "wave")
	var slow = FlowGuard.new()
	slow.adopt(host.stamp())
	host.advance(5, "shop")
	var fast_msg = host.stamp()
	var r = slow.check_stamp(fast_msg)
	assert_false(r.accepted)
	assert_eq(r.reason, FlowGuard.REJECT_FUTURE)
	assert_true(r.ahead)
	assert_true(slow.adopt(fast_msg).ok)
	assert_true(slow.check_stamp(fast_msg).accepted, "accepted once caught up")


func test_same_seq_with_other_wave_or_phase_conflicts() -> void:
	var g = _guard_at(2, "shop")
	for s in [_with(g.stamp(), "phase", "wave"), _with(g.stamp(), "wave", 3)]:
		var r = g.check_stamp(s)
		assert_false(r.accepted)
		assert_eq(r.reason, FlowGuard.REJECT_CONFLICT)
		assert_false(r.ahead)


func test_simultaneous_confirms_commit_once_for_1_to_8_players() -> void:
	for n in range(1, 9):
		var g = _guard_at(1, "character_select")
		var msg = g.stamp()
		var commits := 0
		for slot in range(n):
			assert_true(g.check_stamp(msg).accepted, "n %d slot %d" % [n, slot])
			if g.try_commit("start_wave"):
				commits += 1
		assert_eq(commits, 1, "n %d" % n)
		assert_true(g.was_committed("start_wave"), "n %d" % n)


func test_t06_shuffled_duplicate_and_stale_confirms_commit_once() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261028
	for trial in range(5):
		var g = FlowGuard.new()
		g.begin_run("run-a")
		g.advance(1, "shop")
		var stale = g.stamp()
		g.advance(2, "character_ready")
		var current = g.stamp()
		var inbox := []
		for slot in range(8):
			for copy in range(3):
				inbox.append(current)
			inbox.append(stale)
		var accepted := 0
		var commits := 0
		for msg in _shuffled(inbox, rng):
			var r = g.check_stamp(msg)
			if not r.accepted:
				assert_eq(r.reason, FlowGuard.REJECT_STALE, "trial %d" % trial)
				continue
			accepted += 1
			if g.try_commit("start_wave"):
				commits += 1
		assert_eq(accepted, 24, "trial %d" % trial)
		assert_eq(commits, 1, "trial %d" % trial)


func test_commit_is_per_seq_and_key() -> void:
	var g = _guard_at(1, "shop")
	assert_true(g.try_commit("start_wave"))
	assert_false(g.try_commit("start_wave"))
	var again = g.commit("start_wave")
	assert_false(again.committed)
	assert_eq(again.reason, FlowGuard.REJECT_ALREADY_COMMITTED)
	assert_eq(again.seq, g.stamp().seq)
	assert_true(g.try_commit("close_shop"), "other keys are independent")
	# No-op changes do not open a new seq.
	g.set_roster_generation(0)
	assert_true(g.adopt(g.stamp()).ok)
	assert_false(g.try_commit("start_wave"))
	g.advance(2, "shop")
	assert_true(g.try_commit("start_wave"), "new seq")
	assert_false(g.try_commit("start_wave"))
	assert_true(g.was_committed("start_wave", g.stamp().seq - 1))


# A barrier finished for stamp S; before the host acts on it the guard moves
# on (remap, retry, other run). try_commit() alone would commit in the new
# seq; commit_for() refuses because S is no longer the committed stamp.
func test_commit_for_refuses_a_stamp_the_guard_moved_past() -> void:
	var fresh = FlowGuard.new()
	assert_eq(fresh.commit_for(_guard_at(1, "shop").stamp(), "start_wave").reason, FlowGuard.REJECT_NO_RUN)
	var moves = [
		["advance", FlowGuard.REJECT_STALE],
		["remap", FlowGuard.REJECT_ROSTER_MISMATCH],
		["new_run", FlowGuard.REJECT_OTHER_RUN]
	]
	for m in moves:
		var g = _guard_at(1, "character_select")
		var barrier_stamp = g.stamp()
		if m[0] == "advance":
			g.advance(1, "character_select")
		elif m[0] == "remap":
			g.set_roster_generation(1)
		else:
			g.begin_run("run-b")
		var r = g.commit_for(barrier_stamp, "start_wave")
		assert_false(r.committed, m[0])
		assert_eq(r.reason, m[1], m[0])
		assert_eq(r.seq, g.stamp().seq, m[0])
		assert_false(g.try_commit_for(barrier_stamp, "start_wave"), m[0])
		assert_false(g.was_committed("start_wave"), m[0])
		assert_true(g.try_commit_for(g.stamp(), "start_wave"), "%s: current stamp" % m[0])
	var shop = _guard_at(2, "shop")
	var current = shop.stamp()
	for bad in [null, {}, _with(current, "seq", current.seq + 1)]:
		assert_false(shop.try_commit_for(bad, "close_shop"))
	assert_eq(shop.commit_for(_with(current, "seq", current.seq + 1), "close_shop").reason, FlowGuard.REJECT_FUTURE)
	assert_eq(shop.commit_for(current, "").reason, FlowGuard.REJECT_INVALID_KEY)
	assert_eq(shop.committed_key_count(), 0)
	for n in range(1, 9):
		var commits := 0
		for slot in range(n):
			if shop.try_commit_for(parse_json(to_json(current)), "close_shop_%d" % n):
				commits += 1
		assert_eq(commits, 1, "n %d" % n)
	assert_eq(shop.commit_for(current, "close_shop_8").reason, FlowGuard.REJECT_ALREADY_COMMITTED)


func test_invalid_commit_keys_are_rejected() -> void:
	var g = _guard_at(1, "shop")
	assert_eq(g.commit("").reason, FlowGuard.REJECT_INVALID_KEY)
	assert_eq(g.commit(_long_string(FlowGuard.MAX_KEY_LENGTH + 1)).reason, FlowGuard.REJECT_INVALID_KEY)
	assert_eq(g.committed_key_count(), 0)
	assert_true(g.commit(_long_string(FlowGuard.MAX_KEY_LENGTH)).committed)


func test_commit_memory_is_bounded() -> void:
	var g = FlowGuard.new()
	g.begin_run("run-a")
	var bound: int = FlowGuard.KEPT_COMMIT_SEQS * 2
	for wave in range(1, 201):
		g.advance(wave, "wave")
		assert_true(g.try_commit("start_wave"), "wave %d" % wave)
		assert_true(g.try_commit("end_wave"), "wave %d" % wave)
		assert_true(g.committed_key_count() <= bound, "wave %d" % wave)
	assert_eq(g.committed_key_count(), bound)
	var now: int = g.stamp().seq
	assert_true(g.was_committed("start_wave", now))
	assert_true(g.was_committed("start_wave", now - (FlowGuard.KEPT_COMMIT_SEQS - 1)))
	assert_false(g.was_committed("start_wave", now - FlowGuard.KEPT_COMMIT_SEQS))
	assert_false(g.try_commit("start_wave"), "current seq is never pruned")


func test_key_limit_refuses_instead_of_double_committing() -> void:
	var g = _guard_at(1, "shop")
	for i in range(FlowGuard.MAX_KEYS_PER_SEQ):
		assert_true(g.try_commit("key_%d" % i), "key %d" % i)
	var r = g.commit("one_more")
	assert_false(r.committed)
	assert_eq(r.reason, FlowGuard.REJECT_KEY_LIMIT)
	for i in [0, FlowGuard.MAX_KEYS_PER_SEQ - 1]:
		assert_eq(g.commit("key_%d" % i).reason, FlowGuard.REJECT_ALREADY_COMMITTED, "key %d" % i)
	g.advance(1, "shop")
	assert_true(g.try_commit("one_more"))


func test_adopt_follows_host_and_rejects_bad_stamps() -> void:
	var host = FlowGuard.new()
	host.begin_run("run-a")
	host.advance(1, "wave")
	var client = FlowGuard.new()
	var r = client.adopt(host.stamp())
	assert_true(r.ok)
	assert_true(r.changed)
	_assert_stamp(client.stamp(), host.stamp(), "first adopt")
	r = client.adopt(host.stamp())
	assert_true(r.ok, "duplicate broadcast")
	assert_false(r.changed)
	assert_eq(r.reason, FlowGuard.REASON_UNCHANGED)
	var old = host.stamp()
	host.advance(1, "shop")
	host.advance(2, "wave")
	assert_true(client.adopt(host.stamp()).ok, "skipped seqs are fine")
	_assert_stamp(client.stamp(), host.stamp(), "caught up")
	host.set_roster_generation(2)
	client.adopt(host.stamp())
	var now = client.stamp()
	var cases = [
		[old, FlowGuard.REJECT_STALE],
		[_with(now, "phase", "shop"), FlowGuard.REJECT_CONFLICT],
		[_with(now, "roster_generation", 3), FlowGuard.REJECT_CONFLICT],
		[_with(now, "seq", 0), FlowGuard.REJECT_MALFORMED],
		[{}, FlowGuard.REJECT_MALFORMED],
		[null, FlowGuard.REJECT_MALFORMED]
	]
	for i in range(cases.size()):
		r = client.adopt(cases[i][0])
		assert_false(r.ok, "case %d" % i)
		assert_false(r.changed, "case %d" % i)
		assert_eq(r.reason, cases[i][1], "case %d" % i)
	_assert_stamp(client.stamp(), now, "rejected adopts")
	# Restart from a checkpoint with the same id; the client misses its first
	# stamp. Lower wave and roster generation, newer seq: the host wins.
	host.begin_run("run-a")
	host.advance(1, "wave")
	r = client.adopt(host.stamp())
	assert_true(r.ok, "skipped restart (%s)" % r.reason)
	assert_true(r.changed)
	_assert_stamp(client.stamp(), host.stamp(), "after restart")
	host.begin_run("run-b")
	assert_true(client.adopt(host.stamp()).ok, "a new run restarts wave and roster")
	_assert_stamp(client.stamp(), host.stamp(), "new run")


func test_t08_replayed_and_reordered_history() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 808
	var phases := ["wave", "upgrade", "shop"]
	var host = FlowGuard.new()
	host.begin_run("run-a")
	var history := [host.stamp()]
	var lowering_restarts := 0
	for step in range(60):
		var cur = host.stamp()
		var op: int = rng.randi_range(0, 9)
		if op == 0 or step % 20 == 19:
			# Half the restarts keep the id (continue from a checkpoint); the
			# forced ones every 20 steps always do.
			var same: bool = step % 20 == 19 or rng.randi_range(0, 1) == 0
			var id: String = cur.run_id if same else "run-%d" % step
			if id == cur.run_id and (cur.wave > 0 or cur.roster_generation > 0):
				lowering_restarts += 1
			host.begin_run(id)
		elif op <= 2:
			host.set_roster_generation(cur.roster_generation + 1)
		elif op <= 5:
			host.advance(cur.wave, phases[rng.randi_range(0, 2)])
		else:
			host.advance(cur.wave + 1, "wave")
		history.append(host.stamp())
	assert_true(lowering_restarts >= 2, "seed covers same-id restarts (%d)" % lowering_restarts)
	for i in range(1, history.size()):
		assert_eq(history[i].seq, history[i - 1].seq + 1, "history %d" % i)
	# A client that sees every broadcast follows each one; one that sees them
	# shuffled keeps the newest and calls every older one stale.
	var follower = FlowGuard.new()
	for i in range(history.size()):
		var r = follower.adopt(history[i])
		assert_true(r.ok and r.changed, "follow %d (%s)" % [i, r.reason])
	var shuffled_follower = FlowGuard.new()
	var newest := -1
	for i in _shuffled(range(history.size()), rng):
		var r = shuffled_follower.adopt(history[i])
		if i > newest:
			assert_true(r.ok and r.changed, "shuffled follow %d (%s)" % [i, r.reason])
			newest = i
		else:
			assert_eq(r.reason, FlowGuard.REJECT_STALE, "shuffled follow %d" % i)
	_assert_stamp(shuffled_follower.stamp(), history[history.size() - 1], "shuffled follower")
	for k in [0, 7, 23, 41, history.size() - 1]:
		var client = FlowGuard.new()
		assert_true(client.adopt(history[k]).ok, "client at %d" % k)
		# Every message twice, in a random order: only the client's own state
		# is accepted, newer ones are "ahead", nothing old ever passes.
		var order := _shuffled(range(history.size()) + range(history.size()), rng)
		for i in order:
			var r = client.check_stamp(history[i])
			assert_eq(r.accepted, i == k, "client %d message %d (%s)" % [k, i, r.reason])
			assert_eq(r.ahead, i > k, "client %d message %d (%s)" % [k, i, r.reason])
		_assert_stamp(client.stamp(), history[k], "client %d unchanged" % k)
