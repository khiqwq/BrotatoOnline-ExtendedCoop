extends "res://tests/runner/test_case.gd"

const ActionLedger = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/action_ledger.gd")
const PayloadGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/payload_guard.gd")

const SCOPE := "s1|run1|wave3|shop|r0"
const NEXT_SCOPE := "s1|run1|wave4|shop|r0"
const START_GOLD := 100

const BUY_SCHEMA := {"type": "dict", "fields": {
	"scope": {"type": "string", "min_len": 1, "max_len": 128},
	"action_id": {"type": "int", "min": 1, "max": 2147483647},
	"player_index": {"type": "player_index"},
	"item": {"type": "string", "min_len": 1, "max_len": 32},
	"cost": {"type": "int", "min": 0, "max": 999},
}}


func _senders(n: int) -> Array:
	var out := []
	for i in range(n):
		out.append("steam_%d" % (76561198000000000 + i))
	return out


func _ledger(n: int, max_entries: int = 512, per_sender: int = 64):
	var ledger = ActionLedger.new(max_entries, per_sender)
	var r = ledger.begin_scope(SCOPE, _senders(n))
	assert_true(r.ok, "begin_scope with %d senders: %s" % [n, r.reason])
	return ledger


# Host state for a fake shop: sender i owns slot i.
func _host(n: int) -> Dictionary:
	var host := {"slot_of": {}, "gold": {}, "executions": {}, "results": {}}
	var senders := _senders(n)
	for i in range(n):
		host.slot_of[senders[i]] = i
		host.gold[i] = START_GOLD
	return host


func _buy_msg(scope: String, sender: String, action_id: int, player_index: int, cost: int) -> Dictionary:
	return {"scope": scope, "sender": sender, "action_id": action_id, "player_index": player_index, "item": "item_%d" % action_id, "cost": cost}


func _key(sender, action_id) -> String:
	return "%s#%s" % [str(sender), str(action_id)]


# What the host adapter does: ownership from the slot map, execute only when new.
func _deliver(ledger, host: Dictionary, msg: Dictionary) -> Dictionary:
	var owns: bool = typeof(msg.player_index) == TYPE_INT and int(host.slot_of.get(msg.sender, -1)) == msg.player_index
	var fp: String = ActionLedger.make_fingerprint(["buy", msg.player_index, msg.item])
	var c = ledger.check(msg.scope, msg.sender, msg.action_id, msg.player_index, owns, fp)
	if c.status == ActionLedger.STATUS_NEW:
		var key := _key(msg.sender, msg.action_id)
		host.executions[key] = int(host.executions.get(key, 0)) + 1
		host.gold[msg.player_index] -= msg.cost
		var result := {"ok": true, "gold": host.gold[msg.player_index]}
		host.results[key] = result.duplicate()
		var committed = ledger.commit(msg.scope, msg.sender, msg.action_id, result)
		assert_true(committed.ok, "commit %s: %s" % [key, committed.reason])
	return c


# One field of a check() result, or null. Tests read results through this so a
# broken ledger fails assertions instead of dereferencing null: the engine copy
# is a release build, where that can crash the whole run.
func _field(check_result, name: String):
	if typeof(check_result) != TYPE_DICTIONARY or typeof(check_result.get("result")) != TYPE_DICTIONARY:
		return null
	return check_result.result.get(name)


func _shuffle(items: Array, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = items[i]
		items[i] = items[j]
		items[j] = tmp


func _total_executions(host: Dictionary) -> int:
	var total := 0
	for key in host.executions:
		total += int(host.executions[key])
	return total


func _string_of(length: int) -> String:
	var s := ""
	for _i in range(length):
		s += "x"
	return s


# Arrays nested `levels` deep around a 0: _nest(1) == [0], _nest(2) == [[0]].
func _nest(levels: int) -> Array:
	var value: Array = [0]
	for _i in range(levels - 1):
		value = [value]
	return value


# T05: every purchase is sent three times in a random order; gold moves once.
func test_retried_purchases_spend_gold_once_for_every_roster_size() -> void:
	for n in range(1, 9):
		var ledger = _ledger(n)
		var host := _host(n)
		var senders := _senders(n)
		var messages := []
		for p in range(n):
			for id in range(1, 6):
				messages.append(_buy_msg(SCOPE, senders[p], id, p, 3 + id))
		var deliveries := []
		for m in messages:
			for _k in range(3):
				deliveries.append(m)
		_shuffle(deliveries, 1000 + n)
		var duplicates := 0
		for m in deliveries:
			var c = _deliver(ledger, host, m)
			if c.status == ActionLedger.STATUS_DUPLICATE:
				duplicates += 1
				var stored: Dictionary = host.results.get(_key(m.sender, m.action_id), {})
				assert_eq(_field(c, "gold"), stored.get("gold", -1), "n %d duplicate answers with the stored result" % n)
			else:
				assert_eq(c.status, ActionLedger.STATUS_NEW, "n %d: %s" % [n, c.reason])
		assert_eq(duplicates, 2 * messages.size(), "n %d" % n)
		assert_eq(host.executions.size(), messages.size(), "n %d" % n)
		assert_eq(_total_executions(host), messages.size(), "n %d" % n)
		for p in range(n):
			assert_eq(host.gold[p], START_GOLD - (4 + 5 + 6 + 7 + 8), "n %d player %d" % [n, p])
		assert_eq(ledger.size(), messages.size(), "n %d" % n)


func test_senders_have_separate_id_spaces() -> void:
	for n in range(2, 9):
		var ledger = _ledger(n)
		var senders := _senders(n)
		for p in range(n):
			var c = ledger.check(SCOPE, senders[p], 1, p, true)
			assert_eq(c.status, ActionLedger.STATUS_NEW, "n %d sender %d" % [n, p])
			ledger.commit(SCOPE, senders[p], 1, {"player": p})
		for p in range(n):
			var again = ledger.check(SCOPE, senders[p], 1, p, true)
			assert_eq(again.status, ActionLedger.STATUS_DUPLICATE, "n %d sender %d" % [n, p])
			assert_eq(_field(again, "player"), p, "each sender gets its own result")


# T08: after the phase changes, replays of the old phase change nothing.
func test_old_scope_messages_have_no_effect_after_phase_change() -> void:
	for n in range(1, 9):
		var ledger = _ledger(n)
		var host := _host(n)
		var senders := _senders(n)
		var old := []
		for p in range(n):
			for id in range(1, 4):
				old.append(_buy_msg(SCOPE, senders[p], id, p, 10))
				_deliver(ledger, host, old.back())
		var gold_before: Dictionary = host.gold.duplicate()
		var begun = ledger.begin_scope(NEXT_SCOPE, senders)
		assert_true(begun.ok, "n %d" % n)
		assert_eq(begun.dropped, 3 * n, "n %d" % n)
		assert_eq(ledger.size(), 0, "n %d" % n)
		assert_eq(ledger.highest_action_id(senders[0]), 0, "n %d" % n)
		for m in old:
			var c = _deliver(ledger, host, m)
			assert_eq(c.status, ActionLedger.STATUS_REJECTED, "n %d" % n)
			assert_eq(c.reason, ActionLedger.REASON_WRONG_SCOPE, "n %d" % n)
		assert_eq(var2str(host.gold), var2str(gold_before), "n %d gold untouched" % n)
		assert_eq(_total_executions(host), 3 * n, "n %d" % n)
		assert_eq(ledger.size(), 0, "n %d rejected messages leave no entry" % n)
		# ids start again in the new scope
		var fresh = _deliver(ledger, host, _buy_msg(NEXT_SCOPE, senders[0], 1, 0, 1))
		assert_eq(fresh.status, ActionLedger.STATUS_NEW, "n %d" % n)


func test_retired_scope_cannot_be_reopened() -> void:
	var ledger = _ledger(2)
	var senders := _senders(2)
	assert_true(ledger.begin_scope(NEXT_SCOPE, senders).ok)
	var back = ledger.begin_scope(SCOPE, senders)
	assert_false(back.ok)
	assert_eq(back.reason, ActionLedger.REASON_SCOPE_RETIRED)
	# failing closed: the scope that was open is closed as well
	assert_eq(ledger.current_scope(), "")
	assert_eq(ledger.check(NEXT_SCOPE, senders[0], 1, 0, true).reason, ActionLedger.REASON_NO_SCOPE)
	assert_eq(ledger.check(SCOPE, senders[0], 1, 0, true).reason, ActionLedger.REASON_NO_SCOPE)
	assert_eq(ledger.begin_scope(NEXT_SCOPE, senders).reason, ActionLedger.REASON_SCOPE_RETIRED)
	assert_true(ledger.begin_scope("s1|run1|wave5|shop|r0", senders).ok)


# Documented fail-closed cost: a bad identity list for the open key closes it
# for good. Reopening it would be worse: its entries are gone, so id 1 could run
# a second time.
func test_failed_refresh_of_open_scope_closes_and_retires_it() -> void:
	var ledger = _ledger(3)
	var host := _host(3)
	var senders := _senders(3)
	_deliver(ledger, host, _buy_msg(SCOPE, senders[0], 1, 0, 5))
	var r = ledger.begin_scope(SCOPE, [senders[0], senders[1], ""])
	assert_false(r.ok)
	assert_eq(r.reason, ActionLedger.REASON_INVALID_SENDER)
	assert_eq(r.dropped, 1)
	assert_eq(ledger.current_scope(), "")
	assert_eq(ledger.begin_scope(SCOPE, senders).reason, ActionLedger.REASON_SCOPE_RETIRED)
	assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, senders[0], 1, 0, 5)).reason, ActionLedger.REASON_NO_SCOPE)
	assert_eq(_total_executions(host), 1)
	assert_eq(host.gold[0], START_GOLD - 5)


func test_retired_scope_memory_is_bounded() -> void:
	var ledger = ActionLedger.new()
	var senders := _senders(1)
	var total: int = ActionLedger.MAX_RETIRED_SCOPES + 6
	for i in range(total):
		assert_true(ledger.begin_scope("scope%d" % i, senders).ok, "scope %d" % i)
	assert_true(ledger.begin_scope("scope%d" % (total - 1), senders).ok, "the open scope can be repeated")
	assert_eq(ledger.begin_scope("scope%d" % (total - 10), senders).reason, ActionLedger.REASON_SCOPE_RETIRED)
	# Only the last MAX_RETIRED_SCOPES keys are remembered; older stamps must
	# never come back, which the phase guard's generation counters ensure.
	assert_true(ledger.begin_scope("scope0", senders).ok)


func test_begin_scope_accepts_one_to_eight_senders() -> void:
	for n in range(1, 9):
		var ledger = ActionLedger.new()
		var r = ledger.begin_scope(SCOPE, _senders(n))
		assert_true(r.ok, "n %d" % n)
		assert_eq(r.dropped, 0, "n %d" % n)
		assert_eq(ledger.current_scope(), SCOPE)
		for s in _senders(n):
			assert_eq(ledger.check(SCOPE, s, 1, 0, true).status, ActionLedger.STATUS_NEW, "n %d" % n)


func test_ninth_sender_is_refused_not_dropped() -> void:
	var ledger = _ledger(8)
	var nine := _senders(9)
	assert_eq(ledger.check(SCOPE, nine[8], 1, 0, true).reason, ActionLedger.REASON_UNKNOWN_SENDER)
	var r = ledger.begin_scope(NEXT_SCOPE, nine)
	assert_false(r.ok)
	assert_eq(r.reason, ActionLedger.REASON_TOO_MANY_SENDERS)
	# nobody is silently cut: the whole scope stays closed instead
	assert_eq(ledger.current_scope(), "")
	for s in nine:
		assert_eq(ledger.check(NEXT_SCOPE, s, 1, 0, true).reason, ActionLedger.REASON_NO_SCOPE)


func test_begin_scope_rejects_malformed_input() -> void:
	var cases := [
		[null, _senders(2), ActionLedger.REASON_INVALID_SCOPE],
		[5, _senders(2), ActionLedger.REASON_INVALID_SCOPE],
		["", _senders(2), ActionLedger.REASON_INVALID_SCOPE],
		[_string_of(ActionLedger.MAX_SCOPE_KEY_LENGTH + 1), _senders(2), ActionLedger.REASON_INVALID_SCOPE],
		[NEXT_SCOPE, null, ActionLedger.REASON_INVALID_SENDERS],
		[NEXT_SCOPE, "steam_1", ActionLedger.REASON_INVALID_SENDERS],
		[NEXT_SCOPE, {"steam_1": true}, ActionLedger.REASON_INVALID_SENDERS],
		[NEXT_SCOPE, [], ActionLedger.REASON_NO_SENDERS],
		[NEXT_SCOPE, ["a", "a"], ActionLedger.REASON_DUPLICATE_SENDER],
		[NEXT_SCOPE, ["a", 5], ActionLedger.REASON_INVALID_SENDER],
		[NEXT_SCOPE, ["a", ""], ActionLedger.REASON_INVALID_SENDER],
		[NEXT_SCOPE, ["a", null], ActionLedger.REASON_INVALID_SENDER],
		[NEXT_SCOPE, ["a", _string_of(ActionLedger.MAX_SENDER_LENGTH + 1)], ActionLedger.REASON_INVALID_SENDER],
	]
	for c in cases:
		var ledger = _ledger(2)
		ledger.check(SCOPE, _senders(2)[0], 1, 0, true)
		var r = ledger.begin_scope(c[0], c[1])
		assert_false(r.ok, var2str(c))
		assert_eq(r.reason, c[2], var2str(c))
		assert_eq(r.dropped, 1, var2str(c))
		assert_eq(ledger.size(), 0, var2str(c))
		assert_eq(ledger.current_scope(), "", "fails closed: %s" % var2str(c))
	var exact = ActionLedger.new()
	assert_true(exact.begin_scope(_string_of(ActionLedger.MAX_SCOPE_KEY_LENGTH), [_string_of(ActionLedger.MAX_SENDER_LENGTH)]).ok, "limits are inclusive")


func test_check_rejects_malformed_input_without_reserving() -> void:
	var senders := _senders(8)
	var me: String = senders[0]
	var cases := [
		[null, me, 1, 0, true, "", ActionLedger.REASON_INVALID_SCOPE],
		[7, me, 1, 0, true, "", ActionLedger.REASON_INVALID_SCOPE],
		["", me, 1, 0, true, "", ActionLedger.REASON_INVALID_SCOPE],
		[[SCOPE], me, 1, 0, true, "", ActionLedger.REASON_INVALID_SCOPE],
		[_string_of(ActionLedger.MAX_SCOPE_KEY_LENGTH + 1), me, 1, 0, true, "", ActionLedger.REASON_INVALID_SCOPE],
		["s0|old-session", me, 1, 0, true, "", ActionLedger.REASON_WRONG_SCOPE],
		[NEXT_SCOPE, me, 1, 0, true, "", ActionLedger.REASON_WRONG_SCOPE],
		[SCOPE, null, 1, 0, true, "", ActionLedger.REASON_INVALID_SENDER],
		[SCOPE, 76561198000000000, 1, 0, true, "", ActionLedger.REASON_INVALID_SENDER],
		[SCOPE, "", 1, 0, true, "", ActionLedger.REASON_INVALID_SENDER],
		[SCOPE, [me], 1, 0, true, "", ActionLedger.REASON_INVALID_SENDER],
		[SCOPE, "intruder", 1, 0, true, "", ActionLedger.REASON_UNKNOWN_SENDER],
		[SCOPE, me, null, 0, true, "", ActionLedger.REASON_MISSING_ACTION_ID],
		[SCOPE, me, "1", 0, true, "", ActionLedger.REASON_INVALID_ACTION_ID],
		[SCOPE, me, 1.0, 0, true, "", ActionLedger.REASON_INVALID_ACTION_ID],
		[SCOPE, me, true, 0, true, "", ActionLedger.REASON_INVALID_ACTION_ID],
		[SCOPE, me, [1], 0, true, "", ActionLedger.REASON_INVALID_ACTION_ID],
		[SCOPE, me, NAN, 0, true, "", ActionLedger.REASON_INVALID_ACTION_ID],
		[SCOPE, me, 0, 0, true, "", ActionLedger.REASON_ACTION_ID_OUT_OF_RANGE],
		[SCOPE, me, -1, 0, true, "", ActionLedger.REASON_ACTION_ID_OUT_OF_RANGE],
		[SCOPE, me, ActionLedger.MAX_ACTION_ID + 1, 0, true, "", ActionLedger.REASON_ACTION_ID_OUT_OF_RANGE],
		[SCOPE, me, 9223372036854775807, 0, true, "", ActionLedger.REASON_ACTION_ID_OUT_OF_RANGE],
		[SCOPE, me, 1, -1, true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, 8, true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, 100, true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, "0", true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, 0.0, true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, null, true, "", ActionLedger.REASON_INVALID_TARGET],
		[SCOPE, me, 1, 0, false, "", ActionLedger.REASON_NOT_OWNER],
		[SCOPE, me, 1, 0, null, "", ActionLedger.REASON_NOT_OWNER],
		[SCOPE, me, 1, 0, 1, "", ActionLedger.REASON_NOT_OWNER],
		[SCOPE, me, 1, 0, "true", "", ActionLedger.REASON_NOT_OWNER],
		[SCOPE, me, 1, 0, [true], "", ActionLedger.REASON_NOT_OWNER],
		[SCOPE, me, 1, 0, true, null, ActionLedger.REASON_INVALID_FINGERPRINT],
		[SCOPE, me, 1, 0, true, 5, ActionLedger.REASON_INVALID_FINGERPRINT],
		[SCOPE, me, 1, 0, true, _string_of(ActionLedger.MAX_FINGERPRINT_LENGTH + 1), ActionLedger.REASON_INVALID_FINGERPRINT],
	]
	var ledger = _ledger(8)
	for c in cases:
		var r = ledger.check(c[0], c[1], c[2], c[3], c[4], c[5])
		assert_eq(r.status, ActionLedger.STATUS_REJECTED, var2str(c))
		assert_eq(r.reason, c[6], var2str(c))
		assert_null(r.result, var2str(c))
	assert_eq(ledger.size(), 0, "no rejected message reserved an entry")
	assert_eq(ledger.highest_action_id(me), 0)
	# the same id is still free for the genuine action
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).status, ActionLedger.STATUS_NEW)
	assert_eq(ledger.check(SCOPE, me, ActionLedger.MAX_ACTION_ID, 7, true, _string_of(64)).status, ActionLedger.STATUS_NEW, "upper limits inclusive")


func test_forged_player_index_never_executes_for_any_roster() -> void:
	for n in range(2, 9):
		var ledger = _ledger(n)
		var host := _host(n)
		var senders := _senders(n)
		for attacker in range(n):
			for victim in range(n):
				if victim == attacker:
					continue
				var c = _deliver(ledger, host, _buy_msg(SCOPE, senders[attacker], 1, victim, 50))
				assert_eq(c.reason, ActionLedger.REASON_NOT_OWNER, "n %d %d->%d" % [n, attacker, victim])
		assert_eq(_total_executions(host), 0, "n %d" % n)
		for p in range(n):
			assert_eq(host.gold[p], START_GOLD, "n %d player %d" % [n, p])
			# the id a forged message used is still free for the real action
			assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, senders[p], 1, p, 1)).status, ActionLedger.STATUS_NEW)


func test_second_copy_before_commit_is_pending() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).status, ActionLedger.STATUS_NEW)
	var second = ledger.check(SCOPE, me, 1, 0, true)
	assert_eq(second.status, ActionLedger.STATUS_PENDING)
	assert_null(second.result)
	assert_true(ledger.commit(SCOPE, me, 1, {"ok": true}).ok)
	var third = ledger.check(SCOPE, me, 1, 0, true)
	assert_eq(third.status, ActionLedger.STATUS_DUPLICATE)
	assert_eq(_field(third, "ok"), true)


func test_commit_only_counts_once() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	assert_eq(ledger.commit(SCOPE, me, 1, {"ok": true}).reason, ActionLedger.REASON_NOT_RESERVED, "commit without check")
	ledger.check(SCOPE, me, 1, 0, true)
	assert_true(ledger.commit(SCOPE, me, 1, {"gold": 10}).ok)
	var again = ledger.commit(SCOPE, me, 1, {"gold": 99})
	assert_false(again.ok)
	assert_eq(again.reason, ActionLedger.REASON_ALREADY_COMMITTED)
	assert_eq(_field(ledger.check(SCOPE, me, 1, 0, true), "gold"), 10, "first result kept")
	assert_eq(ledger.size(), 1)


func test_commit_rejects_bad_input_and_keeps_reservation() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	ledger.check(SCOPE, me, 1, 0, true)
	var bad_results := [null, Reference.new(), {"item": Reference.new()}, [Vector2(1, 1)], {"nested": [[Vector3()]]}]
	for result in bad_results:
		var r = ledger.commit(SCOPE, me, 1, result)
		assert_false(r.ok, "type %d" % typeof(result))
		assert_eq(r.reason, ActionLedger.REASON_INVALID_RESULT, "type %d" % typeof(result))
	assert_eq(ledger.commit(NEXT_SCOPE, me, 1, true).reason, ActionLedger.REASON_WRONG_SCOPE)
	assert_eq(ledger.commit(SCOPE, 5, 1, true).reason, ActionLedger.REASON_INVALID_SENDER)
	assert_eq(ledger.commit(SCOPE, me, 1.0, true).reason, ActionLedger.REASON_INVALID_ACTION_ID)
	assert_eq(ledger.commit(SCOPE, me, 2, true).reason, ActionLedger.REASON_NOT_RESERVED)
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).status, ActionLedger.STATUS_PENDING, "still reserved")
	assert_true(ledger.commit(SCOPE, me, 1, {"ok": false, "reason": "not_enough_gold"}).ok, "refusals are committed too")
	assert_eq(_field(ledger.check(SCOPE, me, 1, 0, true), "reason"), "not_enough_gold")


func test_cyclic_or_too_deep_results_are_refused() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	ledger.check(SCOPE, me, 1, 0, true)
	var loop := []
	loop.append(loop)
	assert_eq(ledger.commit(SCOPE, me, 1, loop).reason, ActionLedger.REASON_INVALID_RESULT, "cyclic")
	loop.clear()
	var dict_loop := {}
	dict_loop["self"] = dict_loop
	assert_eq(ledger.commit(SCOPE, me, 1, dict_loop).reason, ActionLedger.REASON_INVALID_RESULT, "cyclic dictionary")
	dict_loop.clear()
	assert_eq(ledger.commit(SCOPE, me, 1, _nest(ActionLedger.MAX_RESULT_DEPTH + 1)).reason, ActionLedger.REASON_INVALID_RESULT, "too deep")
	assert_true(ledger.commit(SCOPE, me, 1, _nest(ActionLedger.MAX_RESULT_DEPTH)).ok, "deepest allowed")
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).result, _nest(ActionLedger.MAX_RESULT_DEPTH))


func test_commit_still_works_after_sender_left_the_roster() -> void:
	var ledger = _ledger(3)
	var senders := _senders(3)
	ledger.check(SCOPE, senders[2], 1, 2, true)
	assert_true(ledger.begin_scope(SCOPE, [senders[0], senders[1]]).ok)
	assert_true(ledger.commit(SCOPE, senders[2], 1, {"ok": true}).ok)


func test_reused_action_id_with_other_content_is_refused() -> void:
	var ledger = _ledger(2)
	var me: String = _senders(2)[0]
	var fp_a: String = ActionLedger.make_fingerprint(["buy", 0, "item_knife"])
	var fp_b: String = ActionLedger.make_fingerprint(["buy", 0, "item_gun"])
	assert_eq(ledger.check(SCOPE, me, 1, 0, true, fp_a).status, ActionLedger.STATUS_NEW)
	assert_eq(ledger.check(SCOPE, me, 1, 0, true, fp_b).reason, ActionLedger.REASON_ACTION_ID_REUSED, "pending, other body")
	ledger.commit(SCOPE, me, 1, {"bought": "item_knife"})
	assert_eq(ledger.check(SCOPE, me, 1, 0, true, fp_b).reason, ActionLedger.REASON_ACTION_ID_REUSED, "committed, other body")
	assert_eq(ledger.check(SCOPE, me, 1, 1, true, fp_a).reason, ActionLedger.REASON_ACTION_ID_REUSED, "other target")
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).reason, ActionLedger.REASON_ACTION_ID_REUSED, "fingerprint dropped")
	var same = ledger.check(SCOPE, me, 1, 0, true, fp_a)
	assert_eq(same.status, ActionLedger.STATUS_DUPLICATE)
	assert_eq(_field(same, "bought"), "item_knife")


func test_make_fingerprint_is_stable_and_type_sensitive() -> void:
	var a: String = ActionLedger.make_fingerprint(["buy", 3, "item_knife"])
	assert_eq(a, ActionLedger.make_fingerprint(["buy", 3, "item_knife"]))
	assert_eq(a.length(), 64)
	assert_true(a.is_valid_hex_number(), a)
	assert_ne(a, ActionLedger.make_fingerprint(["buy", 4, "item_knife"]))
	assert_ne(a, ActionLedger.make_fingerprint(["sell", 3, "item_knife"]))
	assert_ne(ActionLedger.make_fingerprint([1]), ActionLedger.make_fingerprint([1.0]))
	assert_ne(ActionLedger.make_fingerprint(["ab", "c"]), ActionLedger.make_fingerprint(["a", "bc"]))
	# Not an Array: still a well-formed digest, distinct from the empty Array's.
	for odd in [null, "buy", 3]:
		var f: String = ActionLedger.make_fingerprint(odd)
		assert_eq(f.length(), 64, var2str(odd))
		assert_ne(f, ActionLedger.make_fingerprint([]), var2str(odd))


func test_stored_results_are_isolated_from_callers() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	ledger.check(SCOPE, me, 1, 0, true)
	var result := {"gold": 10, "items": ["knife"]}
	ledger.commit(SCOPE, me, 1, result)
	result.gold = 999
	result.items.append("gun")
	var first = ledger.check(SCOPE, me, 1, 0, true)
	assert_eq(_field(first, "gold"), 10)
	assert_eq(_field(first, "items"), ["knife"])
	if typeof(_field(first, "items")) == TYPE_ARRAY:
		first.result.gold = 555
		first.result.items.clear()
	var second = ledger.check(SCOPE, me, 1, 0, true)
	assert_eq(_field(second, "gold"), 10)
	assert_eq(_field(second, "items"), ["knife"])


func test_repeating_open_scope_keeps_entries_and_updates_senders() -> void:
	var ledger = _ledger(3)
	var senders := _senders(3)
	for p in range(3):
		ledger.check(SCOPE, senders[p], 1, p, true)
		ledger.commit(SCOPE, senders[p], 1, {"p": p})
	var r = ledger.begin_scope(SCOPE, [senders[0], senders[1]])
	assert_true(r.ok)
	assert_eq(r.dropped, 0)
	assert_eq(ledger.size(), 3)
	assert_eq(ledger.check(SCOPE, senders[2], 2, 2, true).reason, ActionLedger.REASON_UNKNOWN_SENDER)
	assert_eq(ledger.check(SCOPE, senders[2], 1, 2, true).reason, ActionLedger.REASON_UNKNOWN_SENDER)
	assert_true(ledger.begin_scope(SCOPE, senders).ok)
	var back = ledger.check(SCOPE, senders[2], 1, 2, true)
	assert_eq(back.status, ActionLedger.STATUS_DUPLICATE, "returning sender keeps its results")
	assert_eq(_field(back, "p"), 2)


func test_out_of_order_ids_inside_the_window_are_accepted() -> void:
	var ledger = _ledger(1)
	var me: String = _senders(1)[0]
	for id in [5, 3, 4, 1, 2]:
		assert_eq(ledger.check(SCOPE, me, id, 0, true).status, ActionLedger.STATUS_NEW, "id %d" % id)
		ledger.commit(SCOPE, me, id, id)
	for id in [1, 2, 3, 4, 5]:
		var c = ledger.check(SCOPE, me, id, 0, true)
		assert_eq(c.status, ActionLedger.STATUS_DUPLICATE, "id %d" % id)
		assert_eq(c.result, id)
	assert_eq(ledger.highest_action_id(me), 5)
	assert_eq(ledger.watermark(me), 0)


# The bound: a flood of actions never grows the ledger past its cap, and no
# evicted action is executed a second time when it is replayed later.
func test_evicted_actions_are_never_executed_twice() -> void:
	var cap := 8
	var ledger = _ledger(1, 512, cap)
	var host := _host(1)
	var me: String = _senders(1)[0]
	host.gold[0] = 1000
	var sent := []
	for id in range(1, 101):
		sent.append(_buy_msg(SCOPE, me, id, 0, 1))
		_deliver(ledger, host, sent.back())
		assert_true(ledger.size() <= cap, "size after id %d" % id)
	assert_eq(ledger.size(), cap)
	assert_eq(ledger.evicted_count(), 100 - cap)
	assert_eq(ledger.watermark(me), 100 - cap)
	for m in sent:
		var c = _deliver(ledger, host, m)
		if m.action_id > 100 - cap:
			assert_eq(c.status, ActionLedger.STATUS_DUPLICATE, "id %d" % m.action_id)
		else:
			assert_eq(c.reason, ActionLedger.REASON_STALE_ACTION_ID, "id %d" % m.action_id)
	assert_eq(_total_executions(host), 100)
	assert_eq(host.gold[0], 900)
	assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, 101, 0, 1)).status, ActionLedger.STATUS_NEW)


func test_flooding_sender_cannot_evict_other_senders() -> void:
	var ledger = _ledger(2, 512, 8)
	var senders := _senders(2)
	for id in range(1, 4):
		ledger.check(SCOPE, senders[1], id, 1, true)
		ledger.commit(SCOPE, senders[1], id, {"id": id})
	for id in range(1, 201):
		ledger.check(SCOPE, senders[0], id, 0, true)
		ledger.commit(SCOPE, senders[0], id, {"id": id})
	assert_eq(ledger.size(), 8 + 3)
	assert_eq(ledger.watermark(senders[1]), 0)
	for id in range(1, 4):
		assert_eq(ledger.check(SCOPE, senders[1], id, 1, true).status, ActionLedger.STATUS_DUPLICATE, "id %d" % id)


func test_total_cap_evicts_oldest_across_senders() -> void:
	var ledger = _ledger(8, 16, 64)
	var senders := _senders(8)
	for id in range(1, 5):
		for p in range(8):
			assert_eq(ledger.check(SCOPE, senders[p], id, p, true).status, ActionLedger.STATUS_NEW)
			ledger.commit(SCOPE, senders[p], id, id)
			assert_true(ledger.size() <= 16)
	assert_eq(ledger.size(), 16)
	assert_eq(ledger.evicted_count(), 16)
	for p in range(8):
		for id in [1, 2]:
			assert_eq(ledger.check(SCOPE, senders[p], id, p, true).reason, ActionLedger.REASON_STALE_ACTION_ID, "p %d id %d" % [p, id])
		for id in [3, 4]:
			assert_eq(ledger.check(SCOPE, senders[p], id, p, true).status, ActionLedger.STATUS_DUPLICATE, "p %d id %d" % [p, id])


# Documented cost of the watermark: a never-seen id below an evicted one is
# refused (safe, never executed), while later ids keep working.
func test_late_id_below_watermark_is_refused() -> void:
	var ledger = _ledger(1, 512, 2)
	var me: String = _senders(1)[0]
	for id in [10, 11, 12]:
		ledger.check(SCOPE, me, id, 0, true)
		ledger.commit(SCOPE, me, id, id)
	assert_eq(ledger.watermark(me), 10)
	assert_eq(ledger.check(SCOPE, me, 5, 0, true).reason, ActionLedger.REASON_STALE_ACTION_ID)
	assert_eq(ledger.check(SCOPE, me, 10, 0, true).reason, ActionLedger.REASON_STALE_ACTION_ID)
	assert_eq(ledger.check(SCOPE, me, 13, 0, true).status, ActionLedger.STATUS_NEW)
	assert_eq(ledger.watermark(me), 11)


# Eviction follows arrival order, not id order: with a cap of 2, ids arriving
# 5, 1, 2, 6 evict 5 and then 1. The watermark must stay at 5, or a replay of
# the evicted 5 would run a second time.
func test_watermark_keeps_highest_evicted_id_when_ids_arrive_out_of_order() -> void:
	var ledger = _ledger(1, 512, 2)
	var host := _host(1)
	var me: String = _senders(1)[0]
	for id in [5, 1, 2, 6]:
		assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, id, 0, 1)).status, ActionLedger.STATUS_NEW, "id %d" % id)
	assert_eq(ledger.evicted_count(), 2)
	assert_eq(ledger.watermark(me), 5)
	# 2 is below the watermark but still stored: its retry gets the stored result
	var kept = _deliver(ledger, host, _buy_msg(SCOPE, me, 2, 0, 1))
	assert_eq(kept.status, ActionLedger.STATUS_DUPLICATE)
	var stored: Dictionary = host.results.get(_key(me, 2), {})
	assert_eq(_field(kept, "gold"), stored.get("gold", -1))
	for id in [5, 1]:
		assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, id, 0, 1)).reason, ActionLedger.REASON_STALE_ACTION_ID, "evicted id %d" % id)
	assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, 3, 0, 1)).reason, ActionLedger.REASON_STALE_ACTION_ID, "never-seen id below the watermark")
	assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, 6, 0, 1)).status, ActionLedger.STATUS_DUPLICATE)
	assert_eq(_total_executions(host), 4)
	assert_eq(host.gold[0], START_GOLD - 4)
	assert_eq(_deliver(ledger, host, _buy_msg(SCOPE, me, 7, 0, 1)).status, ActionLedger.STATUS_NEW)
	assert_eq(ledger.watermark(me), 5, "evicting 2 later does not lower it")


# Seeded: every sender sends ids 1..8, three copies each, in a shuffled order,
# against caps small enough that the per-sender cap (n 1) and the total cap
# (n 2..8) evict out of id order. Whatever the order, no action runs twice, the
# ledger stays within its caps and every duplicate gets the stored result.
func test_shuffled_retries_under_small_caps_never_execute_twice() -> void:
	for n in range(1, 9):
		var total := 2 * n + 1
		var ledger = _ledger(n, total, 3)
		var host := _host(n)
		var senders := _senders(n)
		var deliveries := []
		for p in range(n):
			for id in range(1, 9):
				for _k in range(3):
					deliveries.append(_buy_msg(SCOPE, senders[p], id, p, 1))
		_shuffle(deliveries, 500 + n)
		var counts := {}
		for m in deliveries:
			var c = _deliver(ledger, host, m)
			var outcome = c.status
			if c.status == ActionLedger.STATUS_REJECTED:
				assert_eq(c.reason, ActionLedger.REASON_STALE_ACTION_ID, "n %d" % n)
				outcome = c.reason
			elif c.status == ActionLedger.STATUS_DUPLICATE:
				var stored: Dictionary = host.results.get(_key(m.sender, m.action_id), {})
				assert_eq(_field(c, "gold"), stored.get("gold", -1), "n %d duplicate answers with the stored result" % n)
			counts[outcome] = int(counts.get(outcome, 0)) + 1
			assert_true(ledger.size() <= total, "n %d size %d" % [n, ledger.size()])
		for key in host.executions:
			assert_eq(host.executions[key], 1, "n %d %s ran more than once" % [n, key])
		var spent := 0
		for p in range(n):
			spent += START_GOLD - int(host.gold[p])
		assert_eq(spent, _total_executions(host), "n %d" % n)
		assert_eq(int(counts.get(ActionLedger.STATUS_NEW, 0)), _total_executions(host), "n %d" % n)
		# a sender's first message can never be stale, so everyone ran something
		assert_true(_total_executions(host) >= n, "n %d" % n)
		# the case must really exercise eviction, staleness and duplicates
		assert_true(ledger.evicted_count() > 0, "n %d evicted" % n)
		assert_true(int(counts.get(ActionLedger.REASON_STALE_ACTION_ID, 0)) > 0, "n %d stale" % n)
		assert_true(int(counts.get(ActionLedger.STATUS_DUPLICATE, 0)) > 0, "n %d duplicates" % n)


func test_pending_entry_evicted_before_commit_is_not_executed_again() -> void:
	var ledger = _ledger(1, 512, 2)
	var me: String = _senders(1)[0]
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).status, ActionLedger.STATUS_NEW)
	ledger.check(SCOPE, me, 2, 0, true)
	ledger.check(SCOPE, me, 3, 0, true)
	assert_eq(ledger.commit(SCOPE, me, 1, true).reason, ActionLedger.REASON_NOT_RESERVED)
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).reason, ActionLedger.REASON_STALE_ACTION_ID)


func test_invalid_config_rejects_everything() -> void:
	for config in [[0, 64], [512, 0], [-1, -1]]:
		var ledger = ActionLedger.new(config[0], config[1])
		assert_false(ledger.is_valid(), var2str(config))
		assert_eq(ledger.begin_scope(SCOPE, _senders(2)).reason, ActionLedger.REASON_INVALID_CONFIG, var2str(config))
		assert_eq(ledger.check(SCOPE, _senders(2)[0], 1, 0, true).reason, ActionLedger.REASON_INVALID_CONFIG, var2str(config))
		assert_eq(ledger.commit(SCOPE, _senders(2)[0], 1, true).reason, ActionLedger.REASON_INVALID_CONFIG, var2str(config))
	assert_true(ActionLedger.new().is_valid())
	assert_true(ActionLedger.new(1, 1).is_valid())


func test_check_before_any_scope() -> void:
	var ledger = ActionLedger.new()
	var r = ledger.check(SCOPE, "steam_1", 1, 0, true)
	assert_eq(r.status, ActionLedger.STATUS_REJECTED)
	assert_eq(r.reason, ActionLedger.REASON_NO_SCOPE)
	assert_eq(ledger.current_scope(), "")
	assert_eq(ledger.size(), 0)


func test_clear_drops_everything_and_retires_scope() -> void:
	var ledger = _ledger(2, 512, 1)
	var me: String = _senders(2)[0]
	ledger.check(SCOPE, me, 1, 0, true)
	ledger.check(SCOPE, me, 2, 0, true)
	assert_eq(ledger.evicted_count(), 1)
	ledger.clear()
	assert_eq(ledger.size(), 0)
	assert_eq(ledger.evicted_count(), 0)
	assert_eq(ledger.current_scope(), "")
	assert_eq(ledger.watermark(me), 0)
	assert_eq(ledger.highest_action_id(me), 0)
	assert_eq(ledger.check(SCOPE, me, 1, 0, true).reason, ActionLedger.REASON_NO_SCOPE)
	assert_eq(ledger.begin_scope(SCOPE, _senders(2)).reason, ActionLedger.REASON_SCOPE_RETIRED)


func test_end_scope_reports_dropped_entries() -> void:
	for n in range(1, 9):
		var ledger = _ledger(n)
		for s in _senders(n):
			ledger.check(SCOPE, s, 1, 0, true)
			ledger.check(SCOPE, s, 2, 0, true)
		assert_eq(ledger.end_scope(), 2 * n, "n %d" % n)
		assert_eq(ledger.size(), 0)
		assert_eq(ledger.end_scope(), 0, "closing twice is harmless")


# Seeded mixed traffic per roster size: retries, forged slots, intruders and
# old-scope replays. Every genuine action runs exactly once; nothing else runs.
func test_random_mixed_traffic_executes_each_genuine_action_once() -> void:
	for n in range(1, 9):
		var rng := RandomNumberGenerator.new()
		rng.seed = 77 + n
		var ledger = _ledger(n)
		var host := _host(n)
		host.gold = {}
		for p in range(n):
			host.gold[p] = 100000
		var senders := _senders(n)
		var next_id := {}
		for s in senders:
			next_id[s] = 1
		var genuine := []
		var resend_new := 0
		for _step in range(300):
			var roll := rng.randi_range(0, 99)
			var slot := rng.randi_range(0, n - 1)
			var sender: String = senders[slot]
			if roll < 45 or genuine.empty():
				genuine.append(_buy_msg(SCOPE, sender, next_id[sender], slot, 1))
				next_id[sender] += 1
				assert_eq(_deliver(ledger, host, genuine.back()).status, ActionLedger.STATUS_NEW, "n %d first copy" % n)
			elif roll < 75:
				var again = _deliver(ledger, host, genuine[rng.randi_range(0, genuine.size() - 1)])
				if again.status == ActionLedger.STATUS_NEW:
					resend_new += 1
			elif roll < 85:
				# forged slot (or a slot outside the roster) using the sender's next id
				var target := rng.randi_range(0, 7)
				if target == slot:
					target = (slot + 1) % 8
				var forged = _deliver(ledger, host, _buy_msg(SCOPE, sender, next_id[sender], target, 1))
				assert_eq(forged.status, ActionLedger.STATUS_REJECTED, "n %d forged" % n)
			elif roll < 93:
				var intruder = _deliver(ledger, host, _buy_msg(SCOPE, "steam_intruder", rng.randi_range(1, 50), 0, 1))
				assert_eq(intruder.reason, ActionLedger.REASON_UNKNOWN_SENDER, "n %d intruder" % n)
			else:
				var old = _deliver(ledger, host, _buy_msg("s0|run0|wave1|shop|r0", sender, rng.randi_range(1, 50), slot, 1))
				assert_eq(old.reason, ActionLedger.REASON_WRONG_SCOPE, "n %d old scope" % n)
		assert_eq(resend_new, 0, "n %d: a resend was executed again" % n)
		assert_eq(host.executions.size(), genuine.size(), "n %d" % n)
		assert_eq(_total_executions(host), genuine.size(), "n %d" % n)
		var spent := 0
		for p in range(n):
			spent += 100000 - int(host.gold[p])
		assert_eq(spent, genuine.size(), "n %d gold matches genuine actions" % n)


# How an adapter combines the two modules: shape first, then idempotency.
func test_guard_then_ledger_pipeline() -> void:
	var n := 5
	var guard = PayloadGuard.new()
	assert_true(guard.check_schema(BUY_SCHEMA).ok)
	var ledger = _ledger(n)
	var host := _host(n)
	var senders := _senders(n)
	var context := {"roster_count": n}
	var outcomes := []
	var wire := [
		[senders[4], {"scope": SCOPE, "action_id": 1, "player_index": 4, "item": "knife", "cost": 5}],
		[senders[4], {"scope": SCOPE, "action_id": 1, "player_index": 4, "item": "knife", "cost": 5}],
		[senders[4], {"scope": SCOPE, "action_id": 2, "player_index": 5, "item": "knife", "cost": 5}],
		[senders[4], {"scope": SCOPE, "action_id": 2, "player_index": 0, "item": "knife", "cost": 5}],
		[senders[4], {"scope": SCOPE, "action_id": 2.0, "player_index": 4, "item": "knife", "cost": 5}],
		[senders[4], {"scope": SCOPE, "action_id": 2, "player_index": 4, "item": "knife", "cost": 5, "admin": true}],
		[senders[4], {"scope": NEXT_SCOPE, "action_id": 2, "player_index": 4, "item": "knife", "cost": 5}],
	]
	for w in wire:
		var msg: Dictionary = w[1]
		var shape = guard.validate(msg, BUY_SCHEMA, context)
		if not shape.ok:
			outcomes.append("guard:" + shape.reason)
			continue
		var full := msg.duplicate()
		full["sender"] = w[0]
		var c = _deliver(ledger, host, full)
		outcomes.append(c.status if c.reason == "" else c.reason)
	assert_eq(outcomes, [
		ActionLedger.STATUS_NEW,
		ActionLedger.STATUS_DUPLICATE,
		"guard:" + PayloadGuard.REASON_OUT_OF_RANGE,
		ActionLedger.REASON_NOT_OWNER,
		"guard:" + PayloadGuard.REASON_WRONG_TYPE,
		"guard:" + PayloadGuard.REASON_UNKNOWN_FIELD,
		ActionLedger.REASON_WRONG_SCOPE,
	])
	assert_eq(host.gold[4], START_GOLD - 5)
	assert_eq(host.gold[0], START_GOLD)
