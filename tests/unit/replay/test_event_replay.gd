extends "res://tests/runner/test_case.gd"
# AP-008: replayable events (tests/support/event_replay.gd) and seeded
# application-level faults (debug/fault_injection.gd) run through
# slot_registry, flow_guard, ready_barrier, payload_guard and action_ledger
# together (F05 F06 F08 F11; T05 T06 T08 T11).

const EventReplay = preload("res://tests/support/event_replay.gd")
const FaultInjection = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/fault_injection.gd")
const ActionLedger = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/action_ledger.gd")
const PayloadGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/payload_guard.gd")
const FlowGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd")
const ReadyBarrier = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/ready_barrier.gd")
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const SlotRegistry = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/slot_registry.gd")
const VirtualDevicePool = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/virtual_device_pool.gd")

const FIXTURE_DIR := "res://tests/fixtures/events"
const MOD_DIR := "res://mods-unpacked/CoopPlus-OnlineExtendedCoop"
const WAVES := 2
const SEED := 4242
const FAULT_SEED := 99
const STALE_REASONS := [FlowGuard.REJECT_STALE, FlowGuard.REJECT_ROSTER_MISMATCH, FlowGuard.REJECT_OTHER_RUN]
const FORGE_REASONS := [ActionLedger.REASON_NOT_OWNER, PayloadGuard.REASON_OUT_OF_RANGE]
const OVERSIZE_REASONS := {
	FaultInjection.MODE_LONG_STRING: PayloadGuard.REASON_STRING_TOO_LONG,
	FaultInjection.MODE_MANY_ITEMS: PayloadGuard.REASON_TOO_MANY_ITEMS,
	FaultInjection.MODE_DEEP: PayloadGuard.REASON_TOO_DEEP,
	FaultInjection.MODE_HUGE: PayloadGuard.REASON_TOO_LARGE,
}
# Everything committed_hash stands for; a key left out would hide its changes.
const COMMITTED_KEYS := ["roster", "roster_generation", "frozen", "violations", "flow", "players", "actions", "barriers", "phase_commits"]


# Rule modules with the double-commit bugs the fault tests exist to catch.
class LeakyLedger extends "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/action_ledger.gd":
	# A repeat runs again, as with a ledger that lost its entry.
	func check(scope_key, sender, action_id, target_index, sender_owns_target, fingerprint = "") -> Dictionary:
		var c = .check(scope_key, sender, action_id, target_index, sender_owns_target, fingerprint)
		if c.status == STATUS_DUPLICATE:
			return {"status": STATUS_NEW, "reason": REASON_NONE, "result": null}
		return c


class RepeatingFlowGuard extends "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd":
	# A key commits again, as with a guard that forgot its committed keys.
	func commit(key: String) -> Dictionary:
		var r = .commit(key)
		if r.reason == REJECT_ALREADY_COMMITTED:
			return {"committed": true, "reason": REASON_NONE, "seq": r.seq}
		return r


class StaleFlowGuard extends "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd":
	# Older stamps of the run pass, as with a guard that only compared run ids.
	func check_stamp(msg_stamp) -> Dictionary:
		var v = .check_stamp(msg_stamp)
		if v.reason == REJECT_STALE or v.reason == REJECT_ROSTER_MISMATCH:
			return {"accepted": true, "reason": REASON_NONE, "ahead": false}
		return v


# The replay harness with a rule module swapped for one of the above.
class SwappedReplay extends "res://tests/support/event_replay.gd":
	var _ledger_override = null
	var _flow_override = null

	func _init(ledger_override, flow_override) -> void:
		_ledger_override = ledger_override
		_flow_override = flow_override

	func _start(session: Dictionary) -> void:
		._start(session)
		if _ledger_override != null:
			_ledger = _ledger_override
		if _flow_override != null:
			_flow = _flow_override


# Faults whose copies and moves must leave the committed state as it was.
func _benign_faults() -> Array:
	return [
		{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 0.3, "copies": 2, "window": 5},
		{"kind": FaultInjection.FAULT_REORDER, "rate": 1.0, "window": 6},
		{"kind": FaultInjection.FAULT_STALE_REPLAY, "rate": 0.25},
		{"kind": FaultInjection.FAULT_FORGE_INDEX, "rate": 0.25},
		{"kind": FaultInjection.FAULT_OVERSIZE, "rate": 0.15},
	]


func _all_faults() -> Array:
	var faults := _benign_faults()
	faults.append({"kind": FaultInjection.FAULT_LATE_READY, "count": 1})
	return faults


func _generated(n: int, capacity: int = CapacityPolicy.MAX_SUPPORTED_PLAYERS) -> Dictionary:
	return EventReplay.generate_fixture(n, WAVES, SEED, capacity)


# Replay result, or null after a failed assertion (never dereference a failed
# result: the engine copy is a release build).
func _run(fixture: Dictionary):
	var label: String = str(fixture.get("name", "?"))
	var r = EventReplay.new().run(fixture)
	assert_true(r.ok, "replay %s: %s at %d (%s)" % [label, r.reason, r.at, r.field])
	if not r.ok:
		return null
	_assert_hashes_cover(r, label)
	return r


# The fault tests compare these hashes, so they must stand for the whole
# committed state and the whole digest; the reason summary is in key order so
# it does not depend on which refusal came first.
func _assert_hashes_cover(r, label: String) -> void:
	assert_eq(r.committed.keys(), COMMITTED_KEYS, label + " committed keys")
	assert_eq(r.committed_hash, ActionLedger.make_fingerprint(r.committed), label + " committed hash")
	assert_eq(var2str(r.digest.committed), var2str(r.committed), label + " digest holds the committed state")
	assert_eq(r.digest_hash, ActionLedger.make_fingerprint(r.digest), label + " digest hash")
	var names: Array = r.digest.reasons.keys()
	var sorted_names := names.duplicate()
	sorted_names.sort()
	assert_eq(names, sorted_names, label + " reasons in key order")


func _inject(events: Array, faults: Array, seed_value: int):
	var r = FaultInjection.new().apply(events, faults, seed_value)
	assert_true(r.ok, "inject: %s %s" % [r.reason, r.field])
	return r if r.ok else null


# Clean run of fixture, its literal events with faults, and the faulted run.
func _faulted(fixture: Dictionary, faults: Array, seed_value: int = FAULT_SEED):
	var clean = _run(fixture)
	if clean == null:
		return null
	var injected = _inject(clean.events, faults, seed_value)
	if injected == null:
		return null
	var run = _run(EventReplay.with_events(fixture, injected.events))
	if run == null:
		return null
	return {"clean": clean, "injected": injected, "run": run}


func test_fixtures_replay_to_their_expectations() -> void:
	var paths := _fixture_paths()
	assert_true(paths.size() >= 3, "fixtures in %s: %s" % [FIXTURE_DIR, str(paths)])
	for path in paths:
		var loaded = EventReplay.load_fixture(path)
		assert_true(loaded.ok, "%s loads: %s" % [path, loaded.reason])
		if not loaded.ok or typeof(loaded.fixture) != TYPE_DICTIONARY:
			continue
		var fixture: Dictionary = loaded.fixture
		assert_true(fixture.has("expect"), "%s has expectations" % path)
		var r = _run(fixture)
		if r == null:
			continue
		_check_expect(r, fixture.get("expect", {}), path)
		_assert_executed_once(r, path)
		_assert_generations_agree(r, path)
		_assert_matches_identity_model(r, path)
		var again = _run(EventReplay.with_events(fixture, r.events))
		if again != null:
			assert_eq(again.digest_hash, r.digest_hash, "%s replays identically from its literal events" % path)


func test_generated_runs_are_clean_for_one_to_eight_players() -> void:
	for n in range(1, 9):
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var r = _run(fixture)
		if r == null:
			continue
		assert_true(r.digest.setup.ok, label + " device setup")
		assert_eq(r.digest.rejections.size(), 0, label + " rejections: " + _reasons_text(r.digest.rejections))
		assert_eq(r.digest.counts[EventReplay.STATUS_DUPLICATE], 0, label + " duplicates")
		assert_eq(r.committed.roster.size(), n, label)
		for i in range(r.committed.roster.size()):
			assert_eq(r.committed.roster[i].identity, EventReplay.identity_for(i), label)
			assert_eq(r.committed.roster[i].display_name, "P%d" % (i + 1), label)
		assert_eq(r.committed.violations, [], label)
		assert_eq(r.committed.flow.wave, WAVES + 1, label)
		assert_eq(r.committed.phase_commits.size(), 2 * WAVES, label)
		assert_eq(r.committed.barriers.size(), 2 * WAVES, label)
		for b in r.committed.barriers:
			assert_eq(b.state, ReadyBarrier.STATE_COMPLETE, label + " " + b.key)
			assert_eq(b.commits, 1, label + " " + b.key)
			assert_eq(b.ready.size(), n, label + " " + b.key)
		assert_eq(_count_kind(r, EventReplay.KIND_UPGRADE), n * WAVES, label + " upgrades")
		assert_eq(_count_kind(r, EventReplay.KIND_CHEST), n * WAVES, label + " chests")
		_assert_executed_once(r, label)
		_assert_generations_agree(r, label)
		_assert_matches_identity_model(r, label)
		var again = _run(EventReplay.with_events(fixture, r.events))
		if again != null:
			assert_eq(again.digest_hash, r.digest_hash, label + " literal events replay identically")


func test_same_seed_gives_identical_digest() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		assert_eq(var2str(_generated(n)), var2str(fixture), label + " generator is seeded")
		var other := EventReplay.generate_fixture(n, WAVES, SEED + 1)
		assert_ne(var2str(_event_shape(other.events)), var2str(_event_shape(fixture.events)), label + " seed matters")
		var a = _faulted(fixture, _all_faults())
		var b = _faulted(fixture, _all_faults())
		if a == null or b == null:
			continue
		assert_eq(var2str(b.injected.events), var2str(a.injected.events), label + " same faults")
		assert_eq(var2str(b.injected.injected), var2str(a.injected.injected), label + " same report")
		assert_eq(b.run.digest_hash, a.run.digest_hash, label + " digest hash")
		assert_eq(b.run.committed_hash, a.run.committed_hash, label + " committed hash")
		assert_eq(var2str(b.run.digest), var2str(a.run.digest), label + " digest")
		for kind in FaultInjection.FAULTS:
			assert_true(int(a.injected.counts.get(kind, 0)) > 0, label + " injected " + kind)
		var c = _faulted(fixture, _all_faults(), FAULT_SEED + 1)
		if c != null:
			assert_ne(var2str(c.injected.events), var2str(a.injected.events), label + " fault seed matters")
			assert_ne(c.run.digest_hash, a.run.digest_hash, label + " digest follows the faults")


func test_duplicates_never_double_commit() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var f = _faulted(_generated(n), [{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 0.6, "copies": 2, "window": 6}])
		if f == null:
			continue
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " committed state unchanged")
		assert_eq(var2str(f.run.committed.players), var2str(f.clean.committed.players), label + " economy")
		_assert_executed_once(f.run, label)
		var copies := _tagged(f.run, FaultInjection.FAULT_DUPLICATE)
		assert_eq(copies.size(), int(f.injected.counts.get(FaultInjection.FAULT_DUPLICATE, 0)), label + " every copy delivered")
		assert_true(copies.size() >= 2 * n, label + " copies made: %d" % copies.size())
		var ledger_repeats := 0
		var barrier_repeats := 0
		var stale := 0
		for e in copies:
			var where: String = "%s copy of eid %d (%s)" % [label, e.eid, e.reason]
			assert_ne(e.status, EventReplay.STATUS_APPLIED, where)
			if e.status == EventReplay.STATUS_REJECTED:
				assert_has(STALE_REASONS, e.reason, where)
				stale += 1
			elif e.layer == EventReplay.LAYER_LEDGER:
				assert_eq(e.reason, ActionLedger.STATUS_DUPLICATE, where)
				ledger_repeats += 1
			else:
				assert_eq(e.reason, ReadyBarrier.REASON_ALREADY_READY, where)
				barrier_repeats += 1
		assert_true(ledger_repeats > 0, label + " ledger answered repeats")
		assert_true(barrier_repeats > 0, label + " barrier answered repeats")
		assert_true(stale > 0, label + " some copies crossed a phase change")


# Tiny ledger caps evict entries all the time: a copy of an evicted action is
# refused as stale, never executed a second time, and the originals (ids grow
# per sender) commit exactly as with the default caps.
func test_small_ledger_caps_never_execute_twice() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var reference = _run(fixture)
		fixture.session["ledger_max_entries"] = 3
		fixture.session["ledger_max_entries_per_sender"] = 1
		var f = _faulted(fixture, [{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 1.0, "window": 8}])
		if f == null or reference == null:
			continue
		assert_eq(f.clean.committed_hash, reference.committed_hash, label + " caps change no committed outcome")
		assert_eq(f.run.committed_hash, reference.committed_hash, label + " copies change nothing")
		_assert_executed_once(f.run, label)
		var evicted_copies := 0
		for e in _tagged(f.run, FaultInjection.FAULT_DUPLICATE):
			assert_ne(e.status, EventReplay.STATUS_APPLIED, "%s copy of eid %d" % [label, e.eid])
			if e.reason == ActionLedger.REASON_STALE_ACTION_ID:
				evicted_copies += 1
		assert_true(evicted_copies > 0, label + " copies of evicted actions were seen")


func test_reorder_within_a_phase_keeps_the_committed_state() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var f = _faulted(fixture, [{"kind": FaultInjection.FAULT_REORDER, "rate": 1.0, "window": 6}])
		if f == null:
			continue
		assert_true(int(f.injected.counts.get(FaultInjection.FAULT_REORDER, 0)) > n, label + " messages moved")
		_assert_reorder_shape(f.clean.events, f.injected.events, true, label)
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " committed state unchanged")
		assert_eq(f.run.digest.rejections.size(), 0, label + " rejections: " + _reasons_text(f.run.digest.rejections))
		# Without per-sender order a sell may now come before its buy: results
		# may change, but nothing is refused, lost or run twice.
		var g = _faulted(fixture, [{"kind": FaultInjection.FAULT_REORDER, "rate": 1.0, "window": 6, "keep_sender_order": false}])
		if g == null:
			continue
		_assert_reorder_shape(g.clean.events, g.injected.events, false, label + " any order")
		assert_eq(g.run.digest.rejections.size(), 0, label + " any order: " + _reasons_text(g.run.digest.rejections))
		assert_eq(g.run.committed.actions.size(), f.clean.committed.actions.size(), label + " any order")
		assert_eq(var2str(g.run.committed.phase_commits), var2str(f.clean.committed.phase_commits), label + " any order")
		_assert_executed_once(g.run, label + " any order")
		_assert_matches_identity_model(g.run, label + " any order")


func test_stale_replays_have_no_side_effects() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		# The generated run, then a phase that ends with a remove (copies land
		# behind an old roster generation) and a phase that ends with a new run.
		var fixture := _generated(n)
		var removed := EventReplay.identity_for(n - 1)
		var tail := [{"type": EventReplay.TYPE_BARRIER, "key": "mid_wave"}]
		for i in range(n):
			tail.append({"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(i)})
		tail.append({"type": EventReplay.TYPE_REMOVE, "identity": removed})
		tail.append({"type": EventReplay.TYPE_BARRIER, "key": "after_remove"})
		for i in range(n - 1):
			tail.append({"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(i)})
		tail.append({"type": EventReplay.TYPE_BEGIN_RUN, "run_id": "run-next"})
		for e in tail:
			fixture.events.append(e)
		var f = _faulted(fixture, [{"kind": FaultInjection.FAULT_STALE_REPLAY, "rate": 1.0}])
		if f == null:
			continue
		assert_eq(f.clean.digest.rejections.size(), 0, label + " clean tail: " + _reasons_text(f.clean.digest.rejections))
		assert_eq(f.clean.committed.flow.run_id, "run-next", label + " tail ends in a new run")
		_assert_generations_agree(f.clean, label + " after remove and begin_run")
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " committed state unchanged")
		_assert_executed_once(f.run, label)
		var replays := _tagged(f.run, FaultInjection.FAULT_STALE_REPLAY)
		assert_true(replays.size() > 4 * n, label + " replays: %d" % replays.size())
		var reasons := {}
		var types := {}
		for e in replays:
			var where: String = "%s replay of eid %d (%s)" % [label, e.eid, e.reason]
			assert_eq(e.status, EventReplay.STATUS_REJECTED, where)
			if e.from == removed and e.reason == EventReplay.REASON_SENDER_NOT_SEATED:
				continue
			assert_eq(e.layer, EventReplay.LAYER_FLOW, where)
			assert_has(STALE_REASONS, e.reason, where)
			reasons[e.reason] = true
			types[e.type] = true
		for reason in STALE_REASONS:
			assert_true(reasons.has(reason), label + " covers " + reason)
		assert_true(types.has(EventReplay.TYPE_READY) and types.has(EventReplay.TYPE_ACTION), label + " both message types")


func test_forged_player_index_is_rejected() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var f = _faulted(_generated(n), [{"kind": FaultInjection.FAULT_FORGE_INDEX, "rate": 0.5}])
		if f == null:
			continue
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " committed state unchanged")
		_assert_executed_once(f.run, label)
		var forged := _tagged(f.run, FaultInjection.FAULT_FORGE_INDEX)
		assert_true(forged.size() > 2 * n, label + " forgeries: %d" % forged.size())
		var reasons := {}
		var types := {}
		var ninth := 0
		for e in forged:
			var index = f.run.events[e.at].payload.player_index
			var where: String = "%s forged eid %d index %s" % [label, e.eid, str(index)]
			assert_eq(e.status, EventReplay.STATUS_REJECTED, where)
			# Another seat: not owner; beyond the roster (8 = a ninth player): out of range.
			var expected: String = PayloadGuard.REASON_OUT_OF_RANGE if index >= n else ActionLedger.REASON_NOT_OWNER
			assert_eq(e.reason, expected, where)
			assert_has(FORGE_REASONS, e.reason, where)
			reasons[e.reason] = true
			types[e.type] = true
			if index == CapacityPolicy.MAX_SUPPORTED_PLAYERS:
				ninth += 1
		assert_true(reasons.has(ActionLedger.REASON_NOT_OWNER) and reasons.has(PayloadGuard.REASON_OUT_OF_RANGE), label + " both reasons")
		assert_true(types.has(EventReplay.TYPE_READY) and types.has(EventReplay.TYPE_ACTION), label + " both message types")
		assert_true(ninth > 0, label + " a ninth player's index was forged")


func test_oversized_payloads_are_rejected() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		for mode in FaultInjection.OVERSIZE_MODES:
			var f = _faulted(fixture, [{"kind": FaultInjection.FAULT_OVERSIZE, "rate": 0.3, "mode": mode}])
			if f == null:
				continue
			assert_eq(f.run.committed_hash, f.clean.committed_hash, "%s %s committed state unchanged" % [label, mode])
			var padded := _tagged(f.run, FaultInjection.FAULT_OVERSIZE)
			assert_true(padded.size() > n, "%s %s copies: %d" % [label, mode, padded.size()])
			for e in padded:
				var where: String = "%s %s eid %d" % [label, mode, e.eid]
				assert_eq(e.status, EventReplay.STATUS_REJECTED, where)
				assert_eq(e.layer, EventReplay.LAYER_PAYLOAD, where)
				assert_eq(e.reason, OVERSIZE_REASONS[mode], where)
		var mixed = _faulted(fixture, [{"kind": FaultInjection.FAULT_OVERSIZE, "rate": 0.5}])
		if mixed == null:
			continue
		assert_eq(mixed.run.committed_hash, mixed.clean.committed_hash, label + " random modes")
		var seen := {}
		for e in _tagged(mixed.run, FaultInjection.FAULT_OVERSIZE):
			assert_eq(e.status, EventReplay.STATUS_REJECTED, "%s random eid %d" % [label, e.eid])
			seen[e.reason] = true
		for mode in OVERSIZE_REASONS:
			assert_true(seen.has(OVERSIZE_REASONS[mode]), label + " random modes hit " + mode)


func test_late_ready_after_timeout_stops_the_flow() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var f = _faulted(_generated(n), [{"kind": FaultInjection.FAULT_LATE_READY, "count": 1}])
		if f == null:
			continue
		var late := _tagged(f.run, FaultInjection.FAULT_LATE_READY)
		assert_eq(late.size(), 1, label)
		if late.size() != 1:
			continue
		var entry: Dictionary = late[0]
		assert_eq(entry.status, EventReplay.STATUS_REJECTED, label)
		assert_eq(entry.layer, EventReplay.LAYER_BARRIER, label)
		assert_eq(entry.reason, ReadyBarrier.REJECT_TIMED_OUT, label)
		var stalled_seq: int = f.run.events[entry.at].payload.stamp.seq
		var barrier = null
		for b in f.run.committed.barriers:
			if b.seq == stalled_seq:
				barrier = b
		assert_not_null(barrier, label + " barrier of the late ready")
		if barrier == null:
			continue
		assert_eq(barrier.state, ReadyBarrier.STATE_TIMED_OUT, label)
		assert_eq(barrier.commits, 0, label)
		assert_has(barrier.missing, _slot_of(f.run, entry.from), label + " late slot still missing")
		# Everything committed before the stalled stamp is exactly what the
		# clean run committed; nothing after it.
		var commits := []
		for c in f.clean.committed.phase_commits:
			if c.seq < stalled_seq:
				commits.append(c)
		assert_eq(var2str(f.run.committed.phase_commits), var2str(commits), label + " phase commits")
		var actions := []
		for a in f.clean.committed.actions:
			if a.seq <= stalled_seq:
				actions.append(a)
		assert_eq(var2str(f.run.committed.actions), var2str(actions), label + " actions")
		assert_true(f.run.committed.actions.size() < f.clean.committed.actions.size(), label + " the stall cost later actions")
		var after := false
		var refused := 0
		for e in f.run.digest.log:
			if e.at == entry.at:
				after = true
				continue
			if not after:
				continue
			if e.type in EventReplay.MESSAGE_TYPES:
				assert_eq(e.status, EventReplay.STATUS_REJECTED, "%s eid %d after the stall" % [label, e.eid])
			elif e.type == EventReplay.TYPE_ADVANCE and f.run.events[e.at].has("requires"):
				assert_eq(e.reason, EventReplay.REASON_PHASE_NOT_COMMITTED, "%s advance eid %d" % [label, e.eid])
				refused += 1
		assert_true(refused > 0, label + " advances waiting for the barrier were refused")


# T05: under every benign fault at once each of the 5 or 8 slots still gets
# exactly one result per queue (upgrade, chest) and per phase.
func test_every_slot_gets_a_queue_result_under_faults() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var f = _faulted(_generated(n), _benign_faults())
		if f == null:
			continue
		for kind in [FaultInjection.FAULT_DUPLICATE, FaultInjection.FAULT_REORDER, FaultInjection.FAULT_STALE_REPLAY, FaultInjection.FAULT_FORGE_INDEX, FaultInjection.FAULT_OVERSIZE]:
			assert_true(int(f.injected.counts.get(kind, 0)) > 0, label + " injected " + kind)
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " committed state unchanged")
		_assert_executed_once(f.run, label)
		assert_eq(f.run.committed.players.size(), n, label)
		for p in f.run.committed.players:
			assert_eq(p.upgrades.size(), WAVES, "%s slot %d upgrades" % [label, p.slot])
			assert_eq(p.chests.size(), WAVES, "%s slot %d chests" % [label, p.slot])
		var per_slot := {}
		for a in f.run.committed.actions:
			if a.kind == EventReplay.KIND_UPGRADE or a.kind == EventReplay.KIND_CHEST:
				var key: String = "%d:%s" % [a.slot, a.kind]
				per_slot[key] = int(per_slot.get(key, 0)) + 1
				assert_true(a.result.ok, "%s %s" % [label, key])
		for slot in range(n):
			for kind in [EventReplay.KIND_UPGRADE, EventReplay.KIND_CHEST]:
				assert_eq(per_slot.get("%d:%s" % [slot, kind], 0), WAVES, "%s slot %d %s results" % [label, slot, kind])
		assert_eq(f.run.committed.phase_commits.size(), 2 * WAVES, label)
		for b in f.run.committed.barriers:
			assert_eq(b.ready.size(), n, label + " " + b.key)
			assert_eq(b.commits, 1, label + " " + b.key)


# T06: every confirmation repeated, also after its barrier completed: each
# phase commits once, and each repeat after completion is refused.
func test_repeated_confirmations_commit_each_phase_once() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var f = _faulted(_generated(n), [{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 1.0, "types": [EventReplay.TYPE_READY]}])
		if f == null:
			continue
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label)
		assert_eq(f.run.committed.phase_commits.size(), 2 * WAVES, label)
		assert_eq(f.clean.digest.commit_refusals.size(), 0, label + " clean run never repeats a commit")
		assert_eq(f.run.digest.commit_refusals.size(), 2 * WAVES, label + " one late repeat per barrier")
		for refusal in f.run.digest.commit_refusals:
			assert_eq(refusal.reason, FlowGuard.REJECT_ALREADY_COMMITTED, label)
		for e in _tagged(f.run, FaultInjection.FAULT_DUPLICATE):
			assert_eq(e.status, EventReplay.STATUS_DUPLICATE, "%s copy of eid %d" % [label, e.eid])


func test_one_to_four_player_sequences_unaffected() -> void:
	for n in range(1, 5):
		var label: String = "%d players" % n
		var vanilla_fixture := _generated(n, CapacityPolicy.VANILLA_MAX_PLAYERS)
		var extended_fixture := _generated(n, CapacityPolicy.MAX_SUPPORTED_PLAYERS)
		var vanilla = _run(vanilla_fixture)
		var extended = _run(extended_fixture)
		if vanilla == null or extended == null:
			continue
		assert_eq(vanilla.digest.rejections.size(), 0, label + " vanilla: " + _reasons_text(vanilla.digest.rejections))
		assert_eq(extended.committed_hash, vanilla.committed_hash, label + " same committed state with capacity 4 and 8")
		assert_eq(extended.digest.counts[EventReplay.STATUS_APPLIED], vanilla.digest.counts[EventReplay.STATUS_APPLIED], label)
		for fixture in [vanilla_fixture, extended_fixture]:
			var f = _faulted(fixture, _benign_faults())
			if f == null:
				continue
			assert_eq(f.run.committed_hash, vanilla.committed_hash, "%s capacity %d under faults" % [label, fixture.session.capacity])
			_assert_executed_once(f.run, label)


func test_one_more_player_than_capacity_is_refused_without_side_effects() -> void:
	for n in range(1, 9):
		var label: String = "capacity %d" % n
		var fixture := _generated(n, n)
		var extra := EventReplay.identity_for(n)
		# Before the freeze (position n holds it), after it, then messages.
		fixture.events.insert(n, {"type": EventReplay.TYPE_JOIN, "identity": extra})
		fixture.events.insert(n + 2, {"type": EventReplay.TYPE_JOIN, "identity": extra})
		var shop_at := _first_phase(fixture.events, EventReplay.PHASE_SHOP)
		fixture.events.insert(shop_at + 1, {"type": EventReplay.TYPE_ACTION, "from": extra, "kind": EventReplay.KIND_BUY, "player_index": n, "body": {"shop_slot": 0, "item": "knife", "cost": 1}})
		fixture.events.insert(shop_at + 2, {"type": EventReplay.TYPE_READY, "from": extra, "player_index": n})
		var r = _run(fixture)
		var reference = _run(_generated(n, n))
		if r == null or reference == null:
			continue
		assert_eq(r.committed_hash, reference.committed_hash, label + " nothing changed")
		var expected := [
			[n, CapacityPolicy.REJECT_FULL],
			[n + 2, CapacityPolicy.REJECT_RUN_FROZEN],
			[shop_at + 1, EventReplay.REASON_SENDER_NOT_SEATED],
			[shop_at + 2, EventReplay.REASON_SENDER_NOT_SEATED],
		]
		for pair in expected:
			var entry: Dictionary = r.digest.log[pair[0]]
			assert_eq(entry.status, EventReplay.STATUS_REJECTED, "%s event %d" % [label, pair[0]])
			assert_eq(entry.reason, pair[1], "%s event %d" % [label, pair[0]])
		assert_eq(r.digest.rejections.size(), 4, label + ": " + _reasons_text(r.digest.rejections))


# F11: P3 is removed at the start of the first shop; every index-keyed value
# must follow its identity through the remap. Just before, the last player
# drops and comes back (a returning join), which must not give that player a
# second economy row: the remap would then no longer fit.
func test_remove_remaps_every_index_keyed_value() -> void:
	for n in [5, 6, 7, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var removed := EventReplay.identity_for(2)
		var returning := EventReplay.identity_for(n - 1)
		var shop_at := _first_phase(fixture.events, EventReplay.PHASE_SHOP)
		var remove_at := shop_at + 3
		fixture.events.insert(shop_at + 1, {"type": EventReplay.TYPE_DISCONNECT, "identity": returning})
		fixture.events.insert(shop_at + 2, {"type": EventReplay.TYPE_JOIN, "identity": returning})
		fixture.events.insert(remove_at, {"type": EventReplay.TYPE_REMOVE, "identity": removed})
		var r = _run(fixture)
		if r == null:
			continue
		assert_eq(r.digest.log[shop_at + 2].status, EventReplay.STATUS_APPLIED, label + " returning join")
		assert_eq(r.digest.log[remove_at].status, EventReplay.STATUS_APPLIED, label + " remove")
		assert_eq(r.committed.roster.size(), n - 1, label)
		assert_eq(r.committed.roster_generation, 1, label)
		assert_eq(r.committed.flow.roster_generation, 1, label)
		_assert_generations_agree(r, label)
		assert_eq(r.committed.violations, [], label)
		assert_false(r.digest.reasons.has("%s:%s" % [EventReplay.LAYER_HOST, EventReplay.REASON_REMAP_FAILED]), label)
		for e in r.committed.roster:
			assert_ne(e.identity, removed, label)
			# Slots are stable: slot k is still the k-th player that joined.
			assert_eq(e.identity, EventReplay.identity_for(e.slot), label)
		_assert_matches_identity_model(r, label)
		for p in r.committed.players:
			assert_eq(p.upgrades.size(), WAVES, "%s slot %d upgrades" % [label, p.slot])
		var removed_after := 0
		for e in r.digest.log:
			if e.from == removed and e.at > remove_at:
				assert_eq(e.reason, EventReplay.REASON_SENDER_NOT_SEATED, "%s eid %d" % [label, e.eid])
				removed_after += 1
		assert_true(removed_after > 0, label + " the removed player kept sending")
		_assert_executed_once(r, label)


# The fault tests compare committed hashes and execution counts. That proves
# something only if a double commit shows there: with a ledger that runs a
# repeat again, a flow guard that commits a phase key twice, or one that lets
# old stamps through, the clean events still give the sound committed state
# (nothing is repeated), while the faulted events change it. A replay that
# slips through is recorded as a second execution of its original action
# (actions are keyed by the stamp they carried), not as a new action.
func test_double_commits_change_the_committed_state() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var f = _faulted(fixture, [{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 1.0}])
		if f == null:
			continue
		assert_eq(f.run.committed_hash, f.clean.committed_hash, label + " sound modules")
		var faulted := EventReplay.with_events(fixture, f.injected.events)
		var runs := [
			SwappedReplay.new(LeakyLedger.new(), null).run(fixture),
			SwappedReplay.new(LeakyLedger.new(), null).run(faulted),
			SwappedReplay.new(null, RepeatingFlowGuard.new()).run(fixture),
			SwappedReplay.new(null, RepeatingFlowGuard.new()).run(faulted),
		]
		var all_ok := true
		for r in runs:
			assert_true(r.ok, "%s swapped module: %s" % [label, r.reason])
			all_ok = all_ok and r.ok
		if not all_ok:
			continue
		assert_eq(runs[0].committed_hash, f.clean.committed_hash, label + " leaky ledger, clean events")
		assert_ne(runs[1].committed_hash, f.clean.committed_hash, label + " leaky ledger, duplicated events")
		assert_ne(var2str(runs[1].committed.players), var2str(f.clean.committed.players), label + " repeats reach the economy")
		var repeated := 0
		for a in runs[1].committed.actions:
			if a.executions > 1:
				repeated += 1
		assert_eq(repeated, f.clean.committed.actions.size(), label + " every action ran twice")
		assert_eq(runs[2].committed_hash, f.clean.committed_hash, label + " repeating flow guard, clean events")
		assert_ne(runs[3].committed_hash, f.clean.committed_hash, label + " repeating flow guard, duplicated events")
		assert_eq(runs[3].committed.phase_commits.size(), 4 * WAVES, label + " every phase committed twice")
		for b in runs[3].committed.barriers:
			assert_eq(b.commits, 2, "%s %s seq %d" % [label, b.key, b.seq])
		var s = _faulted(fixture, [{"kind": FaultInjection.FAULT_STALE_REPLAY, "rate": 1.0, "types": [EventReplay.TYPE_ACTION]}])
		if s == null:
			continue
		var stale_clean = SwappedReplay.new(null, StaleFlowGuard.new()).run(fixture)
		var stale = SwappedReplay.new(null, StaleFlowGuard.new()).run(EventReplay.with_events(fixture, s.injected.events))
		assert_true(stale_clean.ok and stale.ok, label + " stale flow guard runs")
		if not (stale_clean.ok and stale.ok):
			continue
		assert_eq(stale_clean.committed_hash, s.clean.committed_hash, label + " stale flow guard, clean events")
		assert_ne(stale.committed_hash, s.clean.committed_hash, label + " stale flow guard, replayed events")
		assert_eq(stale.committed.actions.size(), s.clean.committed.actions.size(), label + " replays add no new action keys")
		var replayed := 0
		for a in stale.committed.actions:
			if a.executions > 1:
				replayed += 1
		assert_true(replayed >= n, label + " replays ran their original actions again: %d" % replayed)


# A reorder after late_ready leaves the delayed ready where it was, time
# included; moving it would hand its delay to another message, and the tag
# would point at a ready that arrived in time.
func test_reorder_after_late_ready_keeps_the_delay() -> void:
	for n in [5, 8]:
		var label: String = "%d players" % n
		var fixture := _generated(n)
		var clean = _run(fixture)
		if clean == null:
			continue
		var late_spec := {"kind": FaultInjection.FAULT_LATE_READY, "count": 2}
		var shuffle := {"kind": FaultInjection.FAULT_REORDER, "rate": 1.0, "window": 8, "keep_sender_order": false}
		var late = _inject(clean.events, [late_spec], FAULT_SEED)
		var both = _inject(clean.events, [late_spec, shuffle], FAULT_SEED)
		if late == null or both == null:
			continue
		assert_true(int(both.counts.get(FaultInjection.FAULT_REORDER, 0)) > n, label + " reorder moved messages")
		var delayed := 0
		for k in range(late.events.size()):
			if late.events[k].get("fault", "") == FaultInjection.FAULT_LATE_READY:
				delayed += 1
				assert_eq(var2str(both.events[k]), var2str(late.events[k]), "%s late ready at %d" % [label, k])
		assert_eq(delayed, 2, label)
		var run = _run(EventReplay.with_events(fixture, both.events))
		if run == null:
			continue
		var tagged := _tagged(run, FaultInjection.FAULT_LATE_READY)
		assert_eq(tagged.size(), 2, label)
		for e in tagged:
			assert_eq(e.status, EventReplay.STATUS_REJECTED, "%s late eid %d" % [label, e.eid])
		if not tagged.empty():
			assert_eq(tagged[0].reason, ReadyBarrier.REJECT_TIMED_OUT, label + " first late ready")


# F01/F09: an offline member is still expected, so the barrier waits until the
# host explicitly drops that slot at the hint. The drop is recorded, never
# takes the member off the roster, needs an open barrier and a seated slot (a
# ninth identity has none), and the last expected slot cannot be dropped.
func test_host_drop_completes_a_barrier_without_losing_the_member() -> void:
	var ninth := EventReplay.identity_for(CapacityPolicy.MAX_SUPPORTED_PLAYERS)
	var solo := _seated_run(1)
	solo.append({"type": EventReplay.TYPE_BARRIER, "key": EventReplay.KEY_START_WAVE})
	var last_slot := _push(solo, {"type": EventReplay.TYPE_DROP_EXPECTED, "identity": EventReplay.identity_for(0)})
	solo.append({"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(0)})
	var one = _run(_events_fixture(solo))
	if one != null:
		_expect_log(one, last_slot, EventReplay.STATUS_REJECTED, ReadyBarrier.REJECT_LAST_SLOT, "1 player")
		assert_eq(one.committed.phase_commits.size(), 1, "1 player: the ready still commits")
	for n in range(2, 9):
		var label: String = "%d players" % n
		var gone := EventReplay.identity_for(n - 1)
		var events := _seated_run(n)
		var early := _push(events, {"type": EventReplay.TYPE_DROP_EXPECTED, "identity": gone})
		events.append({"type": EventReplay.TYPE_DISCONNECT, "identity": gone})
		events.append({"type": EventReplay.TYPE_BARRIER, "key": EventReplay.KEY_START_WAVE, "t": 5000})
		for i in range(n - 1):
			events.append({"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(i), "t": 5100 + i})
		var offline_ready := _push(events, {"type": EventReplay.TYPE_READY, "from": gone})
		var blocked := _push(events, {"type": EventReplay.TYPE_ADVANCE, "wave": 2, "phase": EventReplay.PHASE_WAVE, "requires": EventReplay.KEY_START_WAVE})
		var stranger := _push(events, {"type": EventReplay.TYPE_DROP_EXPECTED, "identity": ninth, "t": 15000})
		var drop := _push(events, {"type": EventReplay.TYPE_DROP_EXPECTED, "identity": gone})
		var again := _push(events, {"type": EventReplay.TYPE_DROP_EXPECTED, "identity": gone})
		var moved_on := _push(events, {"type": EventReplay.TYPE_ADVANCE, "wave": 2, "phase": EventReplay.PHASE_WAVE, "requires": EventReplay.KEY_START_WAVE})
		var r = _run(_events_fixture(events))
		if r == null:
			continue
		_expect_log(r, early, EventReplay.STATUS_REJECTED, EventReplay.REASON_NO_BARRIER, label)
		_expect_log(r, offline_ready, EventReplay.STATUS_REJECTED, EventReplay.REASON_SENDER_OFFLINE, label)
		_expect_log(r, blocked, EventReplay.STATUS_REJECTED, EventReplay.REASON_PHASE_NOT_COMMITTED, label)
		_expect_log(r, stranger, EventReplay.STATUS_REJECTED, ReadyBarrier.REJECT_INVALID_SLOT, label)
		_expect_log(r, drop, EventReplay.STATUS_APPLIED, EventReplay.REASON_NONE, label)
		_expect_log(r, again, EventReplay.STATUS_REJECTED, ReadyBarrier.REJECT_COMPLETE, label)
		_expect_log(r, moved_on, EventReplay.STATUS_APPLIED, EventReplay.REASON_NONE, label)
		assert_eq(r.committed.roster.size(), n, label + " the dropped member keeps the seat")
		assert_eq(r.committed.roster[n - 1].identity, gone, label)
		assert_false(r.committed.roster[n - 1].online, label)
		assert_eq(r.committed.roster_generation, 0, label + " a drop is no remap")
		assert_eq(r.committed.barriers.size(), 1, label)
		if r.committed.barriers.size() == 1:
			var b: Dictionary = r.committed.barriers[0]
			assert_eq(b.state, ReadyBarrier.STATE_COMPLETE, label)
			assert_eq(b.removed, [n - 1], label)
			assert_eq(b.ready, range(n - 1), label)
			assert_eq(b.missing, [], label)
			assert_eq(b.commits, 1, label)
		assert_eq(r.committed.phase_commits.size(), 1, label)
		assert_eq(r.digest.commit_refusals.size(), 0, label)
		assert_eq(r.committed.flow.wave, 2, label)


# Host events inside a run: a member seated after begin_run (roster not yet
# frozen) can act at once; a local gamepad plugged and unplugged hands its id
# back, so a reconnecting remote gets it (no two players ever share one); a
# fixed reserved id cannot be unplugged; and a restarted run (begin_run again,
# as when continuing from a checkpoint) supersedes the waiting barrier, refuses
# the failed attempt's messages and opens a fresh ledger scope.
func test_mid_run_host_events_keep_the_rules_in_step() -> void:
	for n in range(2, 9):
		var label: String = "%d players" % n
		var first := EventReplay.identity_for(0)
		var second := EventReplay.identity_for(1)
		var last := EventReplay.identity_for(n - 1)
		var buy := {"shop_slot": 0, "item": "knife", "cost": 4}
		var events := []
		var applied := []
		for i in range(n - 1):
			applied.append(_push(events, {"type": EventReplay.TYPE_JOIN, "identity": EventReplay.identity_for(i), "local": i == 0}))
		applied.append(_push(events, {"type": EventReplay.TYPE_BEGIN_RUN, "run_id": "run-mid"}))
		applied.append(_push(events, {"type": EventReplay.TYPE_ADVANCE, "wave": 1, "phase": EventReplay.PHASE_SHOP, "label": "shop1"}))
		applied.append(_push(events, {"type": EventReplay.TYPE_ACTION, "from": first, "kind": EventReplay.KIND_BUY, "body": buy}))
		applied.append(_push(events, {"type": EventReplay.TYPE_JOIN, "identity": last}))
		applied.append(_push(events, {"type": EventReplay.TYPE_ACTION, "from": last, "kind": EventReplay.KIND_BUY, "body": buy}))
		applied.append(_push(events, {"type": EventReplay.TYPE_FREEZE}))
		applied.append(_push(events, {"type": EventReplay.TYPE_DEVICE_PLUG, "device_id": 1}))
		applied.append(_push(events, {"type": EventReplay.TYPE_DEVICE_UNPLUG, "device_id": 1}))
		var fixed := _push(events, {"type": EventReplay.TYPE_DEVICE_UNPLUG, "device_id": 6})
		applied.append(_push(events, {"type": EventReplay.TYPE_DISCONNECT, "identity": second}))
		applied.append(_push(events, {"type": EventReplay.TYPE_RECONNECT, "identity": second}))
		applied.append(_push(events, {"type": EventReplay.TYPE_BARRIER, "key": EventReplay.KEY_START_WAVE, "t": 1000}))
		for i in range(n - 1):
			applied.append(_push(events, {"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(i)}))
		applied.append(_push(events, {"type": EventReplay.TYPE_BEGIN_RUN, "run_id": "run-mid", "t": 2000}))
		var stale := _push(events, {"type": EventReplay.TYPE_READY, "from": last, "stamp": "@shop1"})
		applied.append(_push(events, {"type": EventReplay.TYPE_ACTION, "from": first, "kind": EventReplay.KIND_BUY, "action_id": 1, "body": buy}))
		applied.append(_push(events, {"type": EventReplay.TYPE_BARRIER, "key": EventReplay.KEY_START_WAVE}))
		for i in range(n):
			applied.append(_push(events, {"type": EventReplay.TYPE_READY, "from": EventReplay.identity_for(i)}))
		applied.append(_push(events, {"type": EventReplay.TYPE_ADVANCE, "wave": 1, "phase": EventReplay.PHASE_WAVE, "requires": EventReplay.KEY_START_WAVE}))
		var r = _run(_events_fixture(events))
		if r == null:
			continue
		for at in applied:
			_expect_log(r, at, EventReplay.STATUS_APPLIED, EventReplay.REASON_NONE, label)
		_expect_log(r, fixed, EventReplay.STATUS_REJECTED, VirtualDevicePool.REASON_FIXED_RESERVED, label)
		_expect_log(r, stale, EventReplay.STATUS_REJECTED, FlowGuard.REJECT_STALE, label)
		assert_eq(r.committed.roster.size(), n, label)
		assert_eq(r.committed.violations, [], label)
		if r.committed.roster.size() == n:
			assert_eq(r.committed.roster[1].device_id, 1, label + " the unplugged id went to the reconnecting player")
		assert_eq(r.committed.barriers.size(), 2, label)
		if r.committed.barriers.size() == 2:
			var waiting: Dictionary = r.committed.barriers[0]
			assert_true(waiting.superseded, label + " restart supersedes the waiting barrier")
			assert_eq(waiting.missing, [n - 1], label)
			assert_eq(waiting.commits, 0, label)
			assert_eq(r.committed.barriers[1].state, ReadyBarrier.STATE_COMPLETE, label)
		assert_eq(r.committed.phase_commits.size(), 1, label)
		# P1's two buys share action id 1 in two scopes; both count, once each.
		assert_eq(r.committed.actions.size(), 3, label)
		_assert_executed_once(r, label)
		_assert_matches_identity_model(r, label)


func test_fault_injection_is_pure_and_seeded() -> void:
	var fixture := _generated(8)
	var clean = _run(fixture)
	if clean == null:
		return
	var events: Array = clean.events
	var before := var2str(events)
	var faults := _all_faults()
	var faults_before := var2str(faults)
	var a = _inject(events, faults, 5)
	var b = _inject(events, faults, 5)
	if a == null or b == null:
		return
	assert_eq(var2str(events), before, "input events unchanged")
	assert_eq(var2str(faults), faults_before, "fault list unchanged")
	assert_eq(var2str(b.events), var2str(a.events), "same seed, same output")
	assert_ne(var2str(a.events), before, "faults changed something")
	var none = _inject(events, [{"kind": FaultInjection.FAULT_FORGE_INDEX, "count": 0}], 5)
	if none != null:
		assert_eq(var2str(none.events), before, "count 0 is a no-op")
	# Events without eid get their input position, so copies point back.
	var bare: Array = events.duplicate(true)
	for e in bare:
		e.erase("eid")
	var d = _inject(bare, [{"kind": FaultInjection.FAULT_DUPLICATE, "count": 3}], 1)
	if d == null:
		return
	assert_eq(d.events.size(), bare.size() + 3)
	var copies := 0
	for e in d.events:
		assert_true(e.has("eid"), "every output event has an eid")
		if e.has("fault"):
			copies += 1
			var source: Dictionary = bare[e.eid]
			assert_eq(e.from, source.from, "copy of eid %d" % e.eid)
			assert_eq(var2str(e.payload), var2str(source.payload), "copy of eid %d" % e.eid)
	assert_eq(copies, 3)


func test_copies_land_where_their_fault_puts_them() -> void:
	var clean = _run(_generated(8))
	if clean == null:
		return
	var events: Array = clean.events
	var specs := [
		{"kind": FaultInjection.FAULT_DUPLICATE, "rate": 0.5, "copies": 2, "window": 3},
		{"kind": FaultInjection.FAULT_STALE_REPLAY, "rate": 0.5},
		{"kind": FaultInjection.FAULT_FORGE_INDEX, "rate": 0.5},
		{"kind": FaultInjection.FAULT_OVERSIZE, "rate": 0.5},
	]
	for spec in specs:
		var kind: String = spec.kind
		var r = _inject(events, [spec], 7)
		if r == null:
			continue
		var seen := -1
		var copies := 0
		for e in r.events:
			if not e.has("fault"):
				seen += 1
				assert_eq(var2str(e), var2str(events[seen]), "%s keeps original %d in order" % [kind, seen])
				continue
			copies += 1
			var source: Dictionary = events[e.eid]
			var where: String = "%s copy of eid %d" % [kind, e.eid]
			assert_eq(e.fault, kind, where)
			assert_true(source.type in EventReplay.MESSAGE_TYPES, where)
			assert_false(e.has("t") or e.has("label"), where + " has no time or label of its own")
			var gap: int = seen - e.eid
			if kind == FaultInjection.FAULT_DUPLICATE:
				assert_true(gap >= 0 and gap < 3, "%s gap %d" % [where, gap])
				assert_eq(var2str(e.payload), var2str(source.payload), where)
			elif kind == FaultInjection.FAULT_STALE_REPLAY:
				var flows := 0
				for k in range(e.eid + 1, seen + 1):
					if events[k].type in EventReplay.FLOW_TYPES:
						flows += 1
				assert_eq(flows, 1, where + " lands one stamp change later")
				assert_eq(var2str(e.payload), var2str(source.payload), where)
			elif kind == FaultInjection.FAULT_FORGE_INDEX:
				assert_eq(gap, 0, where)
				var index = e.payload.player_index
				assert_true(typeof(index) == TYPE_INT and index >= 0 and index <= CapacityPolicy.MAX_SUPPORTED_PLAYERS, where)
				assert_ne(index, source.payload.player_index, where)
				var rest: Dictionary = e.payload.duplicate(true)
				rest["player_index"] = source.payload.player_index
				assert_eq(var2str(rest), var2str(source.payload), where + " changes only the index")
			else:
				assert_eq(gap, 0, where)
				assert_true(e.payload.has(FaultInjection.PADDING_KEY), where)
				var rest: Dictionary = e.payload.duplicate(true)
				rest.erase(FaultInjection.PADDING_KEY)
				assert_eq(var2str(rest), var2str(source.payload), where + " only adds padding")
		assert_eq(seen, events.size() - 1, kind + " keeps every original")
		assert_eq(copies, int(r.counts.get(kind, 0)), kind)
		assert_true(copies > 0, kind)
	var late = _inject(events, [{"kind": FaultInjection.FAULT_LATE_READY, "count": 3, "timeout_msec": 5000}], 3)
	if late == null:
		return
	assert_eq(late.events.size(), events.size(), "late_ready adds nothing")
	var clock := 0
	var delayed := 0
	for k in range(late.events.size()):
		var e: Dictionary = late.events[k]
		if e.get("fault", "") == FaultInjection.FAULT_LATE_READY:
			delayed += 1
			assert_eq(e.type, EventReplay.TYPE_READY)
			var base := int(max(clock, events[k].get("t", 0)))
			var extra: int = e.t - base - 5000
			assert_true(extra >= 1 and extra <= FaultInjection.MAX_LATE_EXTRA_MSEC, "late ready eid %d extra %d" % [e.eid, extra])
		else:
			assert_eq(var2str(e), var2str(events[k]), "event %d untouched" % k)
		if e.has("t") and e.t > clock:
			clock = e.t
	assert_eq(delayed, 3)


func test_fault_specs_and_events_are_checked() -> void:
	var clean = _run(_generated(5))
	if clean == null:
		return
	var events: Array = clean.events
	var dup := FaultInjection.FAULT_DUPLICATE
	var cases := [
		[[{"kind": "drop", "rate": 0.5}], FaultInjection.REASON_UNKNOWN_FAULT, "faults[0].kind"],
		[[{"kind": dup}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "rate": 0.5, "count": 2}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "rate": 1.5}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "rate": -0.1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "rate": NAN}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "rate": "0.5"}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].rate"],
		[[{"kind": dup, "count": -1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].count"],
		[[{"kind": dup, "count": 1.0}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].count"],
		[[{"kind": dup, "rate": 0.5, "windw": 3}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].windw"],
		[[{"kind": dup, "rate": 0.5, "window": 0}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].window"],
		[[{"kind": FaultInjection.FAULT_REORDER, "rate": 0.5, "window": 1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].window"],
		[[{"kind": dup, "rate": 0.5, "copies": FaultInjection.MAX_COPIES + 1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].copies"],
		[[{"kind": dup, "rate": 0.5, "types": ["join"]}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].types"],
		[[{"kind": dup, "rate": 0.5, "types": []}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].types"],
		[[{"kind": dup, "rate": 0.5, "types": ["ready", "ready"]}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].types"],
		[[{"kind": FaultInjection.FAULT_OVERSIZE, "rate": 0.5, "mode": "gigantic"}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].mode"],
		[[{"kind": FaultInjection.FAULT_REORDER, "rate": 0.5, "keep_sender_order": 1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].keep_sender_order"],
		[[{"kind": FaultInjection.FAULT_LATE_READY, "rate": 0.5, "timeout_msec": -1}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].timeout_msec"],
		[[{"kind": FaultInjection.FAULT_LATE_READY, "rate": 0.5, "mode": "deep"}], FaultInjection.REASON_BAD_PARAMETER, "faults[0].mode"],
		[[{"kind": FaultInjection.FAULT_LATE_READY, "count": 1000}], FaultInjection.REASON_TOO_FEW_CANDIDATES, "faults[0]"],
		[[{"kind": dup, "rate": 0.5}, {"kind": dup, "count": 1000}], FaultInjection.REASON_TOO_FEW_CANDIDATES, "faults[1]"],
		[["duplicate"], FaultInjection.REASON_INVALID_FAULTS, "faults[0]"],
		[{"kind": dup, "rate": 0.5}, FaultInjection.REASON_INVALID_FAULTS, "faults"],
	]
	for case in cases:
		var r = FaultInjection.new().apply(events, case[0], 1)
		var where: String = "%s -> %s" % [var2str(case[0]).replace("\n", " "), case[1]]
		assert_false(r.ok, where)
		assert_eq(r.reason, case[1], where)
		assert_eq(r.field, case[2], where)
		assert_eq(r.events, [], where + " no partial output")
		assert_eq(r.injected, [], where)
	var authored: Array = _generated(5).events
	var first_message := -1
	for k in range(authored.size()):
		if first_message < 0 and authored[k].type in EventReplay.MESSAGE_TYPES:
			first_message = k
	var event_cases := [
		[events, "1", FaultInjection.REASON_INVALID_SEED, "seed"],
		["events", 1, FaultInjection.REASON_INVALID_EVENTS, "events"],
		[[{"type": 5}], 1, FaultInjection.REASON_INVALID_EVENTS, "events[0]"],
		[[{"type": "ready", "payload": {}}], 1, FaultInjection.REASON_INVALID_EVENTS, "events[0].from"],
		[[{"type": "tick", "t": -5}], 1, FaultInjection.REASON_INVALID_EVENTS, "events[0].t"],
		[[{"type": "tick", "t": 1.5}], 1, FaultInjection.REASON_INVALID_EVENTS, "events[0].t"],
		[[{"type": "tick", "eid": "3"}], 1, FaultInjection.REASON_INVALID_EVENTS, "events[0].eid"],
		[authored, 1, FaultInjection.REASON_NOT_LITERAL, "events[%d]" % first_message],
	]
	for case in event_cases:
		var r = FaultInjection.new().apply(case[0], [{"kind": dup, "rate": 0.5}], case[1])
		assert_false(r.ok, case[3])
		assert_eq(r.reason, case[2], case[3])
		assert_eq(r.field, case[3], case[3])
		assert_eq(r.events, [], case[3])


func test_malformed_fixtures_are_refused() -> void:
	var good := EventReplay.generate_fixture(2, 1, 1)
	assert_true(EventReplay.check_fixture(good).ok, "generated fixture is well formed")
	var cases := [
		[[], EventReplay.REASON_NOT_A_FIXTURE, -1, ""],
		[_patched(good, "evnets", []), EventReplay.REASON_NOT_A_FIXTURE, -1, "evnets"],
		[_patched(good, "format", "other"), EventReplay.REASON_UNSUPPORTED_FORMAT, -1, "version"],
		[_patched(good, "version", 2), EventReplay.REASON_UNSUPPORTED_FORMAT, -1, "version"],
		[_patched(good, "version", 1.0), EventReplay.REASON_UNSUPPORTED_FORMAT, -1, "version"],
		[_patched(good, "seed", "7"), EventReplay.REASON_NOT_A_FIXTURE, -1, "seed"],
		[_patched(good, "session", {"capacty": 8}), EventReplay.REASON_BAD_SESSION, -1, "capacty"],
		[_patched(good, "session", {"capacity": "8"}), EventReplay.REASON_BAD_SESSION, -1, "capacity"],
		[_patched(good, "session", {"session_id": ""}), EventReplay.REASON_BAD_SESSION, -1, "session_id"],
		[_patched(good, "session", {"start_gold": -1}), EventReplay.REASON_BAD_SESSION, -1, "start_gold"],
		[_patched(good, "session", {"device_candidates": 5}), EventReplay.REASON_BAD_SESSION, -1, "device_candidates"],
		[_patched(good, "events", []), EventReplay.REASON_NOT_A_FIXTURE, -1, "events"],
		[_events_fixture([{"type": "kick", "identity": "x"}]), EventReplay.REASON_BAD_EVENT, 0, "type"],
		[_events_fixture([{"type": "join"}]), EventReplay.REASON_BAD_EVENT, 0, "identity"],
		[_events_fixture([{"type": "join", "identity": "x", "locl": true}]), EventReplay.REASON_BAD_EVENT, 0, "locl"],
		[_events_fixture([{"type": "tick", "t": -1}]), EventReplay.REASON_BAD_EVENT, 0, "t"],
		[_events_fixture([{"type": "tick", "t": 1.5}]), EventReplay.REASON_BAD_EVENT, 0, "t"],
		[_events_fixture([{"type": "tick"}, {"type": "advance", "wave": "1", "phase": "shop"}]), EventReplay.REASON_BAD_EVENT, 1, "wave"],
		[_events_fixture([{"type": "begin_run", "run_id": 5}]), EventReplay.REASON_BAD_EVENT, 0, "run_id"],
		[_events_fixture([{"type": "barrier", "key": ["start_wave"]}]), EventReplay.REASON_BAD_EVENT, 0, "key"],
		[_events_fixture([{"type": "ready", "from": 5}]), EventReplay.REASON_BAD_EVENT, 0, "from"],
		[_events_fixture([{"type": "action", "from": "x"}]), EventReplay.REASON_BAD_EVENT, 0, "kind"],
		[_events_fixture([{"type": "action", "from": "x", "payload": {}, "stamp": "current"}]), EventReplay.REASON_BAD_EVENT, 0, "payload"],
		[_events_fixture([{"type": "action", "from": "x", "kind": "buy", "body": {"player_index": 3}}]), EventReplay.REASON_BAD_EVENT, 0, "body"],
		[_events_fixture([{"type": "ready", "from": "x", "stamp": "previous"}]), EventReplay.REASON_BAD_EVENT, 0, "stamp"],
		[_events_fixture([{"type": "ready", "from": "x", "stamp": 3}]), EventReplay.REASON_BAD_EVENT, 0, "stamp"],
		[_events_fixture([{"type": "ready", "from": "x", "stamp": "@nowhere"}]), EventReplay.REASON_UNKNOWN_LABEL, 0, "stamp"],
		[_events_fixture([{"type": "ready", "from": "x", "stamp": "@shop", "label": "shop"}]), EventReplay.REASON_UNKNOWN_LABEL, 0, "stamp"],
	]
	for case in cases:
		var where: String = "%s: %s" % [case[1], case[3]]
		var r = EventReplay.new().run(case[0])
		assert_false(r.ok, where)
		assert_eq(r.reason, case[1], where)
		assert_eq(r.at, case[2], where)
		assert_eq(r.field, case[3], where)
		assert_eq(r.events, [], where)
		assert_true(r.digest.empty() and r.committed.empty(), where + " no digest")
		assert_eq(r.digest_hash, "", where)
	# A label defined earlier is fine, and a fixture with only host events runs.
	var labelled = EventReplay.new().run(_events_fixture([{"type": "tick", "label": "start"}, {"type": "ready", "from": "x", "stamp": "@start"}]))
	assert_true(labelled.ok, "label defined before use")
	if labelled.ok:
		assert_eq(labelled.digest.log[1].reason, EventReplay.REASON_SENDER_NOT_SEATED)


func test_json_numbers_are_normalized() -> void:
	var parsed = JSON.parse('{"a": 1, "b": [2.0, 2.5, {"$float": 3}], "c": {"d": -4}, "e": 9007199254740993, "f": "7"}')
	assert_eq(parsed.error, OK)
	var n = EventReplay.normalize_json(parsed.result)
	assert_eq(n.a, 1)
	assert_eq(n.b[0], 2)
	assert_eq(n.b[1], 2.5)
	assert_eq(n.b[2], 3.0)
	assert_eq(n.c.d, -4)
	assert_eq(typeof(n.e), TYPE_REAL, "beyond 2^53 stays a float")
	assert_eq(n.f, "7")
	var loaded = EventReplay.load_fixture(FIXTURE_DIR.plus_file("baseline_four_players.json"))
	assert_true(loaded.ok)
	if loaded.ok:
		assert_eq(typeof(loaded.fixture.version), TYPE_INT)
		assert_eq(typeof(loaded.fixture.events[0].t), TYPE_INT)
		assert_eq(typeof(loaded.fixture.events[8].body.choice), TYPE_INT)
	var missing = EventReplay.load_fixture(FIXTURE_DIR.plus_file("no_such_fixture.json"))
	assert_false(missing.ok)
	assert_eq(missing.reason, EventReplay.REASON_UNREADABLE)


func test_injector_and_replay_agree_on_the_format() -> void:
	assert_eq(FaultInjection.MESSAGE_TYPES, EventReplay.MESSAGE_TYPES)
	assert_eq(FaultInjection.FLOW_TYPES, EventReplay.FLOW_TYPES)
	assert_eq(FaultInjection.TYPE_READY, EventReplay.TYPE_READY)
	assert_eq(FaultInjection.TYPE_ACTION, EventReplay.TYPE_ACTION)
	var guard = PayloadGuard.new()
	for kind in EventReplay.ACTION_KINDS + [EventReplay.KIND_READY]:
		var schema := EventReplay.schema_for(kind)
		assert_true(guard.check_schema(schema).ok, kind + " schema")
		assert_false(schema.fields.has(FaultInjection.PADDING_KEY), kind + " never declares the padding key")
		for name in EventReplay.body_specs(kind):
			assert_false(name in EventReplay.ENVELOPE_KEYS, kind + " body field " + name)
	assert_true(EventReplay.schema_for("teleport").empty())
	assert_true(EventReplay.schema_for(3).empty())
	# The huge padding fits every per-value limit and still exceeds the size limit.
	assert_true(FaultInjection.HUGE_STRING_LENGTH < PayloadGuard.DEFAULT_MAX_STRING_LENGTH)
	assert_true(FaultInjection.HUGE_STRING_COUNT < PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE)
	assert_true(FaultInjection.HUGE_STRING_LENGTH * FaultInjection.HUGE_STRING_COUNT > PayloadGuard.DEFAULT_MAX_ENCODED_SIZE)


# AP-008: test switches never reach the release package.
func test_debug_switches_stay_out_of_the_package() -> void:
	var text := _read_text("res://project.lock.json")
	assert_ne(text, "", "lock file readable")
	var parsed = JSON.parse(text)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		fail("project.lock.json is not JSON")
		return
	var package: Dictionary = parsed.result.get("package", {})
	assert_has(package.get("excluded_dirs", []), "mods-unpacked/CoopPlus-OnlineExtendedCoop/debug")
	for glob in package.get("whitelist", []):
		assert_false("debug" in glob, "whitelist entry " + glob)
	var files := []
	for dir in ["scripts", "extensions", "ui"]:
		_collect_gd(MOD_DIR.plus_file(dir), files)
	files.append(MOD_DIR.plus_file("mod_main.gd"))
	assert_true(files.size() > 10, "packaged scripts found: %d" % files.size())
	for path in files:
		var source := _read_text(path)
		assert_ne(source, "", path)
		assert_false("fault_injection" in source, path + " names the fault injector")
		assert_false(("preload(\"%s/debug/" % MOD_DIR) in source, path + " preloads debug/")


# --- helpers ---------------------------------------------------------------

func _check_expect(r, expect: Dictionary, label: String) -> void:
	var digest: Dictionary = r.digest
	var committed: Dictionary = r.committed
	for key in expect:
		var want = expect[key]
		var where: String = "%s %s" % [label, key]
		if key == "rejection_count":
			assert_eq(digest.rejections.size(), want, where + ": " + _reasons_text(digest.rejections))
		elif key == "duplicate_count":
			assert_eq(digest.counts[EventReplay.STATUS_DUPLICATE], want, where)
		elif key == "commit_refusals":
			assert_eq(digest.commit_refusals.size(), want, where)
		elif key == "outcomes":
			for o in want:
				var entry = _log_entry(digest, o.eid)
				if entry == null:
					fail("%s eid %d missing" % [where, o.eid])
				else:
					_expect_fields(entry, o, "%s eid %d" % [where, o.eid])
		elif key == "roster" or key == "devices" or key == "online":
			var field := "identity"
			if key == "devices":
				field = "device_id"
			elif key == "online":
				field = "online"
			var got := []
			for e in committed.roster:
				got.append(e[field])
			assert_eq(var2str(got), var2str(want), where)
		elif key == "roster_generation":
			assert_eq(committed.roster_generation, want, where)
		elif key == "flow":
			_expect_fields(committed.flow, want, where)
		elif key == "players":
			assert_eq(committed.players.size(), want.size(), where)
			for p in want:
				var got = _player(committed, p.slot)
				if got == null:
					fail("%s slot %d missing" % [where, p.slot])
				else:
					_expect_fields(got, p, "%s slot %d" % [where, p.slot])
		elif key == "phase_commits":
			var keys := []
			for c in committed.phase_commits:
				keys.append(c.key)
			assert_eq(keys, want, where)
		elif key == "action_count":
			assert_eq(committed.actions.size(), want, where)
		elif key == "action_results":
			for a in want:
				var got = _action(committed, a.sender, a.action_id)
				if got == null:
					fail("%s %s#%d missing" % [where, a.sender, a.action_id])
				else:
					assert_eq(got.result.ok, a.ok, "%s %s#%d" % [where, a.sender, a.action_id])
					assert_eq(got.result.reason, a.reason, "%s %s#%d" % [where, a.sender, a.action_id])
		elif key == "barriers":
			assert_eq(committed.barriers.size(), want.size(), where)
			for i in range(int(min(committed.barriers.size(), want.size()))):
				_expect_fields(committed.barriers[i], want[i], "%s %d" % [where, i])
		elif key == "violations":
			assert_eq(committed.violations, want, where)
		else:
			fail("%s: unknown expectation" % where)


func _expect_fields(actual: Dictionary, expected: Dictionary, label: String) -> void:
	for key in expected:
		if not actual.has(key):
			fail("%s: no field %s" % [label, key])
		else:
			assert_eq(var2str(actual[key]), var2str(expected[key]), "%s.%s" % [label, key])


# Independent model of the toy economy keyed by identity instead of index,
# rebuilt from the applied actions of the literal events: catches any value
# that followed an index instead of its player.
func _assert_matches_identity_model(r, label: String) -> void:
	var model := {}
	for entry in r.digest.log:
		if entry.type != EventReplay.TYPE_ACTION or entry.status != EventReplay.STATUS_APPLIED:
			continue
		var p: Dictionary = r.events[entry.at].payload
		if not model.has(entry.from):
			model[entry.from] = _fresh_player()
		var m: Dictionary = model[entry.from]
		if p.kind == EventReplay.KIND_BUY and m.gold >= p.cost:
			m.gold -= p.cost
			m.items.append(p.item)
		elif p.kind == EventReplay.KIND_SELL and m.items.has(p.item):
			m.items.erase(p.item)
			m.gold += p.value
		elif p.kind == EventReplay.KIND_REROLL and m.gold >= p.cost:
			m.gold -= p.cost
			m.rerolls += 1
		elif p.kind == EventReplay.KIND_LOCK:
			if p.locked and not m.locks.has(p.shop_slot):
				m.locks.append(p.shop_slot)
				m.locks.sort()
			elif not p.locked:
				m.locks.erase(p.shop_slot)
		elif p.kind == EventReplay.KIND_UPGRADE:
			m.upgrades.append(p.stat)
		elif p.kind == EventReplay.KIND_CHEST:
			m.chests.append(p.item)
			if p.take:
				m.items.append(p.item)
			else:
				m.gold += EventReplay.CHEST_RECYCLE_GOLD
	for e in r.committed.roster:
		var got = _player(r.committed, e.slot)
		if got == null:
			fail("%s: no economy for slot %d" % [label, e.slot])
			continue
		var want: Dictionary = model.get(e.identity, _fresh_player())
		for field in want:
			assert_eq(var2str(got[field]), var2str(want[field]), "%s slot %d %s" % [label, e.slot, field])


func _fresh_player() -> Dictionary:
	return {"gold": EventReplay.DEFAULT_START_GOLD, "items": [], "upgrades": [], "chests": [], "rerolls": 0, "locks": []}


func _assert_executed_once(r, label: String) -> void:
	for a in r.committed.actions:
		assert_eq(a.executions, 1, "%s: %s#%d executions" % [label, a.sender, a.action_id])


# Stamps carry the registry's roster generation, also after a begin_run that
# follows a remove (FlowGuard.begin_run starts it over at 0).
func _assert_generations_agree(r, label: String) -> void:
	assert_true(r.committed.flow.seq > 0, label + " has a run")
	assert_eq(r.committed.flow.roster_generation, r.committed.roster_generation, label + " roster generations agree")


# Reorder keeps host events in place, keeps each run of messages as a set, and
# leaves the receive times on their positions; keep_sender_order also keeps
# every sender's own order.
func _assert_reorder_shape(before: Array, after: Array, keep_sender_order: bool, label: String) -> void:
	assert_eq(after.size(), before.size(), label)
	if after.size() != before.size():
		return
	var k := 0
	while k < before.size():
		if not (before[k].type in EventReplay.MESSAGE_TYPES):
			assert_eq(var2str(after[k]), var2str(before[k]), "%s host event %d stays" % [label, k])
			k += 1
			continue
		var end := k
		while end < before.size() and before[end].type in EventReplay.MESSAGE_TYPES:
			end += 1
		var was := []
		var now := []
		var was_by_sender := {}
		var now_by_sender := {}
		for j in range(k, end):
			assert_eq(after[j].get("t"), before[j].get("t"), "%s time stays at %d" % [label, j])
			was.append(before[j].eid)
			now.append(after[j].eid)
			if not was_by_sender.has(before[j].from):
				was_by_sender[before[j].from] = []
			was_by_sender[before[j].from].append(before[j].eid)
			if not now_by_sender.has(after[j].from):
				now_by_sender[after[j].from] = []
			now_by_sender[after[j].from].append(after[j].eid)
		was.sort()
		now.sort()
		assert_eq(now, was, "%s messages %d..%d stay in their run" % [label, k, end - 1])
		if keep_sender_order:
			for sender in was_by_sender:
				assert_eq(now_by_sender.get(sender, []), was_by_sender[sender], "%s sender order in %d..%d" % [label, k, end - 1])
		k = end


func _expect_log(r, at: int, status: String, reason: String, label: String) -> void:
	if at < 0 or at >= r.digest.log.size():
		fail("%s: no log entry %d" % [label, at])
		return
	var entry: Dictionary = r.digest.log[at]
	var where: String = "%s event %d (%s)" % [label, at, entry.type]
	assert_eq(entry.status, status, where)
	assert_eq(entry.reason, reason, where)


# What the generator's random numbers decide: order, senders, bodies and
# times. The run id and the name follow the seed even without them.
func _event_shape(events: Array) -> Array:
	var out := []
	for e in events:
		out.append([e.type, e.get("from", ""), e.get("kind", ""), e.get("body", {}), e.get("t", -1)])
	return out


# n seats (index 0 local), freeze, begin_run, wave 1 shop.
func _seated_run(n: int) -> Array:
	var events := []
	for i in range(n):
		events.append({"type": EventReplay.TYPE_JOIN, "identity": EventReplay.identity_for(i), "local": i == 0, "t": 10 * i})
	events.append({"type": EventReplay.TYPE_FREEZE, "t": 1000})
	events.append({"type": EventReplay.TYPE_BEGIN_RUN, "run_id": "run-host", "t": 2000})
	events.append({"type": EventReplay.TYPE_ADVANCE, "wave": 1, "phase": EventReplay.PHASE_SHOP, "t": 3000})
	return events


# Appends e and returns its position (= its log position and eid).
func _push(events: Array, e: Dictionary) -> int:
	events.append(e)
	return events.size() - 1


func _tagged(r, fault: String) -> Array:
	var out := []
	for entry in r.digest.log:
		if entry.fault == fault:
			out.append(entry)
	return out


func _count_kind(r, kind: String) -> int:
	var n := 0
	for a in r.committed.actions:
		if a.kind == kind:
			n += 1
	return n


func _slot_of(r, identity: String) -> int:
	for e in r.committed.roster:
		if e.identity == identity:
			return e.slot
	return SlotRegistry.NO_SLOT


func _player(committed: Dictionary, slot):
	for p in committed.players:
		if p.slot == slot:
			return p
	return null


func _action(committed: Dictionary, sender, action_id):
	for a in committed.actions:
		if a.sender == sender and a.action_id == action_id:
			return a
	return null


func _log_entry(digest: Dictionary, eid):
	for entry in digest.log:
		if entry.eid == eid:
			return entry
	return null


func _first_phase(events: Array, phase: String) -> int:
	for k in range(events.size()):
		if events[k].type == EventReplay.TYPE_ADVANCE and events[k].phase == phase:
			return k
	return -1


func _reasons_text(entries: Array) -> String:
	var parts := PoolStringArray()
	for e in entries:
		parts.append("%d:%s/%s" % [e.eid, e.layer, e.reason])
	return parts.join(", ")


func _patched(fixture: Dictionary, key: String, value) -> Dictionary:
	var copy: Dictionary = fixture.duplicate(true)
	copy[key] = value
	return copy


func _events_fixture(events: Array) -> Dictionary:
	return {"format": EventReplay.FORMAT, "version": EventReplay.FORMAT_VERSION, "events": events}


func _fixture_paths() -> Array:
	var out := []
	var dir := Directory.new()
	if dir.open(FIXTURE_DIR) != OK:
		return out
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".json"):
			out.append(FIXTURE_DIR.plus_file(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _collect_gd(path: String, out: Array) -> void:
	var dir := Directory.new()
	if dir.open(path) != OK:
		return
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		var full := path.plus_file(entry)
		if dir.current_is_dir():
			_collect_gd(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _read_text(path: String) -> String:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var text := f.get_as_text()
	f.close()
	return text
