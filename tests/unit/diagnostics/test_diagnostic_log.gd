extends "res://tests/runner/test_case.gd"

const DiagnosticLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/diagnostics/diagnostic_log.gd")
const Redact = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/diagnostics/redact.gd")

const SALT := "log-salt-fedcba9876"
const STEAM_A := "76561198000000001"
const TOKEN := "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

var dlog


func before_each() -> void:
	dlog = DiagnosticLog.new(SALT)


func _steam(n: int) -> String:
	return str(76561198000000000 + n)


func _context(players: int) -> Dictionary:
	var slots := []
	for i in range(players):
		slots.append({"slot": i + 1, "identity": "steam:" + _steam(i + 1)})
	return {
		DiagnosticLog.CTX_RISK: "F09",
		DiagnosticLog.CTX_VERSIONS: {"upstream_fingerprint": "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819", "extension": "0.1.0"},
		DiagnosticLog.CTX_STAMP: {"run_id": "r-1", "wave": 4, "phase": "shop", "roster_generation": 1},
		DiagnosticLog.CTX_SLOTS: slots,
		DiagnosticLog.CTX_ACTION: "wait_for_player",
		DiagnosticLog.CTX_RESULT: "pending",
		"reconnect_token": TOKEN,
		"note": "peer %s dropped" % STEAM_A,
	}


func _raw_secrets() -> Array:
	return [STEAM_A, TOKEN, SALT]


# --- records -------------------------------------------------------------------

func test_record_is_redacted_before_storage() -> void:
	var r: Dictionary = dlog.record("disconnect", "peer %s lost" % STEAM_A, _context(8), 1000)
	assert_true(r.ok)
	assert_eq(r.reason, DiagnosticLog.REASON_NONE)
	assert_eq(r.seq, 1)
	var e: Dictionary = dlog.export_records()[0]
	assert_eq(e.kind, "disconnect")
	assert_eq(e.at_msec, 1000)
	assert_eq(e.reason, "peer %s lost" % dlog.redactor.redact_identity(STEAM_A, SALT))
	assert_eq(e.context.reconnect_token, Redact.MASK_SECRET)
	assert_eq(e.context.versions.upstream_fingerprint, "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819")
	assert_eq(e.context.stamp.wave, 4)
	assert_eq(e.problems, [])
	var dump := var2str(dlog.export_records())
	for raw in _raw_secrets():
		assert_eq(dump.find(raw), -1, "leaked %s" % raw)


func test_slot_summaries_keep_every_player_zero_to_nine() -> void:
	for players in range(0, 10):
		var l = DiagnosticLog.new(SALT)
		l.record("slot_check", "", _context(players), 0)
		var slots: Array = l.export_records()[0].context.slots
		assert_eq(slots.size(), players, "players %d" % players)
		var seen := {}
		for i in range(slots.size()):
			assert_eq(slots[i].slot, i + 1, "players %d" % players)
			assert_eq(slots[i].identity, l.redactor.redact_identity(_steam(i + 1), SALT))
			seen[slots[i].identity] = true
		assert_eq(seen.size(), players, "identities stay distinguishable, players %d" % players)


func test_stored_record_is_isolated_from_caller_and_export() -> void:
	var ctx := _context(5)
	var before := var2str(ctx)
	dlog.record("recovery", "resync", ctx, 5)
	assert_eq(var2str(ctx), before, "input not mutated")
	ctx.stamp.wave = 99
	ctx.slots.append({"slot": 6})
	var exported: Array = dlog.export_records()
	assert_eq(exported[0].context.stamp.wave, 4, "later caller change not seen")
	assert_eq(exported[0].context.slots.size(), 5)
	exported[0].context.stamp.wave = 77
	exported[0].kind = "changed"
	exported.clear()
	var again: Dictionary = dlog.export_records()[0]
	assert_eq(again.context.stamp.wave, 4, "export is a deep copy")
	assert_eq(again.kind, "recovery")


func test_ring_evicts_oldest_and_counts_drops() -> void:
	for cap in range(1, 9):
		var l = DiagnosticLog.new(SALT, cap)
		var total := cap + 3
		for i in range(total):
			var r: Dictionary = l.record("tick" if i % 2 == 0 else "tock", "", {"i": i}, i)
			assert_eq(r.seq, i + 1)
			assert_eq(r.evicted, 1 if i >= cap else 0, "cap %d i %d" % [cap, i])
		var records: Array = l.export_records()
		assert_eq(records.size(), cap, "cap %d" % cap)
		assert_eq(l.entry_count(), cap)
		assert_eq(l.dropped_count(), 3, "cap %d" % cap)
		assert_eq(l.total_recorded(), total)
		assert_eq(records[0].seq, 4, "oldest three evicted, cap %d" % cap)
		assert_eq(records[cap - 1].seq, total, "newest kept, cap %d" % cap)
		assert_eq(records[0].context.i, 3)
		var counts: Dictionary = l.counts_by_kind()
		assert_eq(int(counts.get("tick", 0)) + int(counts.get("tock", 0)), total, "counts survive eviction")
		assert_eq(counts.get("tick"), (total + 1) / 2)


func test_totals_always_add_up() -> void:
	# total = retained + dropped, and every stored record is counted by kind.
	for cap in [1, 3, 8]:
		var l = DiagnosticLog.new(SALT, cap)
		for i in range(20):
			l.record("k%d" % (i % 3) if i % 5 != 0 else "", "", {}, i)
			assert_eq(l.total_recorded(), l.entry_count() + l.dropped_count(), "cap %d after %d" % [cap, i + 1])
			var sum := 0
			for v in l.counts_by_kind().values():
				sum += v
			assert_eq(sum, l.total_recorded(), "cap %d after %d" % [cap, i + 1])
	var broken = DiagnosticLog.new(SALT, 0)
	for i in range(4):
		broken.record("x", "", {}, i)
	assert_eq(broken.total_recorded(), broken.entry_count() + broken.dropped_count())
	assert_eq(broken.counts_by_kind().size(), 0, "refused records are not counted as stored kinds")


func test_distinct_kinds_are_bounded_without_losing_counts() -> void:
	var extra := 5
	for i in range(DiagnosticLog.MAX_COUNTED_KINDS + extra):
		dlog.record("kind_%d" % i, "", {}, i)
	dlog.record("kind_0", "", {}, 0)
	dlog.record("kind_%d" % (DiagnosticLog.MAX_COUNTED_KINDS + 1), "", {}, 0)
	var counts: Dictionary = dlog.counts_by_kind()
	assert_eq(counts.size(), DiagnosticLog.MAX_COUNTED_KINDS + 1, "named kinds plus one bucket")
	assert_eq(counts[DiagnosticLog.KIND_OTHER], extra + 1)
	assert_eq(counts["kind_0"], 2, "known kinds keep counting after the table is full")
	assert_false(counts.has("kind_%d" % DiagnosticLog.MAX_COUNTED_KINDS))
	var sum := 0
	for v in counts.values():
		sum += v
	assert_eq(sum, dlog.total_recorded(), "nothing lost, only grouped")
	var records: Array = dlog.export_records()
	assert_eq(records[records.size() - 1].kind, "kind_%d" % (DiagnosticLog.MAX_COUNTED_KINDS + 1), "the record keeps its own kind")
	assert_false(dlog.record(DiagnosticLog.KIND_OTHER, "", {}, 0).ok, "the bucket name is not a legal kind")


func test_counts_by_kind_is_a_copy() -> void:
	dlog.record("a", "", {}, 0)
	var counts: Dictionary = dlog.counts_by_kind()
	counts["a"] = 50
	assert_eq(dlog.counts_by_kind()["a"], 1)


func test_malformed_kind_is_still_stored() -> void:
	var too_long := ""
	for i in range(DiagnosticLog.MAX_KIND_LENGTH + 1):
		too_long += "k"
	var seq := 0
	for kind in ["", "   ", null, 7, too_long, "has space", "bad\nline"]:
		var r: Dictionary = dlog.record(kind, "why", {"slot": 5}, 10)
		seq += 1
		assert_false(r.ok, str(kind))
		assert_eq(r.reason, DiagnosticLog.REASON_INVALID_KIND, str(kind))
		assert_eq(r.seq, seq, "stored anyway")
	var records: Array = dlog.export_records()
	assert_eq(records.size(), seq)
	for e in records:
		assert_eq(e.kind, DiagnosticLog.KIND_MALFORMED)
		assert_eq(e.reason, "why")
		assert_eq(e.context.slot, 5)
		assert_has(e.problems, DiagnosticLog.REASON_INVALID_KIND)
	assert_eq(dlog.counts_by_kind()[DiagnosticLog.KIND_MALFORMED], seq)
	var max_kind := ""
	for i in range(DiagnosticLog.MAX_KIND_LENGTH):
		max_kind += "k"
	assert_true(dlog.record(max_kind, "", {}, 0).ok, "longest legal kind")
	assert_true(dlog.record("phase.timeout:F07", "", {}, 0).ok)


func test_kind_with_identity_is_redacted() -> void:
	var r: Dictionary = dlog.record("reject_" + STEAM_A, "", {}, 0)
	assert_true(r.ok)
	var kind: String = dlog.export_records()[0].kind
	assert_eq(kind.find(STEAM_A), -1)
	assert_true(dlog.counts_by_kind().has(kind))


func test_malformed_context_is_wrapped_not_lost() -> void:
	var r: Dictionary = dlog.record("x", "", [STEAM_A, 3], 0)
	assert_false(r.ok)
	assert_eq(r.reason, DiagnosticLog.REASON_INVALID_CONTEXT)
	var e: Dictionary = dlog.export_records()[0]
	assert_eq(e.context[DiagnosticLog.WRAPPED_VALUE_KEY], [dlog.redactor.redact_identity(STEAM_A, SALT), 3])
	var s: Dictionary = dlog.record("x", "", "free text " + TOKEN, 0)
	assert_false(s.ok)
	assert_eq(dlog.export_records()[1].context[DiagnosticLog.WRAPPED_VALUE_KEY], "free text " + Redact.MASK_TOKEN)
	var n: Dictionary = dlog.record("x", "", null, 0)
	assert_true(n.ok, "null context means none")
	assert_eq(dlog.export_records()[2].context.size(), 0)


func test_invalid_reason_and_time_are_reported() -> void:
	var r: Dictionary = dlog.record("x", 76561198000000001, {}, 0)
	assert_false(r.ok)
	assert_eq(r.reason, DiagnosticLog.REASON_INVALID_REASON)
	assert_eq(dlog.export_records()[0].reason, dlog.redactor.redact_identity(STEAM_A, SALT))
	assert_true(dlog.record("x", null, {}, 0).ok, "missing reason is allowed")
	for t in ["soon", -1, null, -0.5, INF, NAN]:
		var bad: Dictionary = dlog.record("x", "", {}, t)
		assert_false(bad.ok, str(t))
		assert_eq(bad.reason, DiagnosticLog.REASON_INVALID_TIME, str(t))
	var records: Array = dlog.export_records()
	assert_eq(records[records.size() - 1].at_msec, DiagnosticLog.NO_TIME)
	assert_true(dlog.record("x", "", {}, 1500.0).ok, "float time accepted")
	var last: Array = dlog.export_records()
	assert_eq(last[last.size() - 1].at_msec, 1500, "stored as int")


func test_non_string_reason_is_bounded() -> void:
	var big := []
	for i in range(100):
		big.append("reason part %d" % i)
	var r: Dictionary = dlog.record("x", big, {}, 0)
	assert_false(r.ok)
	var reason: String = dlog.export_records()[0].reason
	var limit: int = dlog.redactor.max_string_length
	assert_true(reason.length() <= limit + 32, "reason length %d" % reason.length())
	assert_true(reason.begins_with("[reason part 0, reason part 1"), reason.substr(0, 40))
	assert_true(reason.ends_with(" chars>"), "cut is marked")


func test_huge_or_cyclic_context_stays_bounded() -> void:
	# A malformed peer payload logged as context must not be kept in full
	# for every one of max_entries records.
	# Three self-references per level: 3^12 values without the node budget.
	var fan := {}
	for i in range(3):
		fan["c%d" % i] = fan
	var r: Dictionary = dlog.record("payload_rejected", "", {"payload": fan}, 0)
	fan.clear()
	assert_true(r.ok)
	var stored = dlog.export_records()[0].context
	assert_true(var2str(stored).length() < 200000, "size %d" % var2str(stored).length())
	assert_true(var2str(stored).find(Redact.TRUNCATED_KEY) != -1, "cut is marked")


func test_several_problems_are_all_listed() -> void:
	var r: Dictionary = dlog.record("", 5, "ctx", "t")
	assert_false(r.ok)
	assert_eq(r.reason, DiagnosticLog.REASON_INVALID_KIND, "first problem")
	var e: Dictionary = dlog.export_records()[0]
	assert_eq(e.problems, [DiagnosticLog.REASON_INVALID_KIND, DiagnosticLog.REASON_INVALID_REASON, DiagnosticLog.REASON_INVALID_CONTEXT, DiagnosticLog.REASON_INVALID_TIME])


func test_invalid_configuration_refuses_and_counts() -> void:
	for cfg in [[0, 3], [-1, 3], [DiagnosticLog.MAX_ENTRIES_LIMIT + 1, 3], [10, 0], [10, DiagnosticLog.MAX_RECOVERY_ATTEMPTS_LIMIT + 1]]:
		var l = DiagnosticLog.new(SALT, cfg[0], cfg[1])
		assert_false(l.is_valid(), str(cfg))
		var r: Dictionary = l.record("x", "", {}, 0)
		assert_false(r.ok, str(cfg))
		assert_eq(r.reason, DiagnosticLog.REASON_INVALID_CONFIG, str(cfg))
		assert_eq(r.seq, 0)
		assert_eq(l.entry_count(), 0)
		assert_eq(l.dropped_count(), 1, "refused record is counted, " + str(cfg))
		assert_false(l.allow_recovery("k"), str(cfg))
		assert_eq(l.request_recovery("k").reason, DiagnosticLog.REASON_INVALID_CONFIG)
		assert_eq(l.request_recovery("k").remaining, 0)
		var report: Dictionary = l.to_report({})
		assert_eq(report.problems, [DiagnosticLog.REASON_INVALID_CONFIG], "an empty report says why, " + str(cfg))
		assert_eq(report.dropped, 1)
	assert_true(DiagnosticLog.new(SALT, DiagnosticLog.MAX_ENTRIES_LIMIT, DiagnosticLog.MAX_RECOVERY_ATTEMPTS_LIMIT).is_valid())
	assert_true(DiagnosticLog.new(SALT, 1, 1).is_valid())


func test_default_configuration() -> void:
	var l = DiagnosticLog.new()
	assert_true(l.is_valid())
	assert_eq(l.max_entries, DiagnosticLog.DEFAULT_MAX_ENTRIES)
	assert_eq(l.max_recovery_attempts, 3, "requirements section 5")
	assert_false(l.has_salt())
	assert_true(dlog.has_salt())
	assert_false(DiagnosticLog.new(12345).has_salt(), "non-string salt ignored")
	assert_false(DiagnosticLog.new("1234567").has_salt(), "salt below Redact.MIN_SALT_LENGTH ignored")
	assert_true(DiagnosticLog.new("12345678").has_salt())
	var weak = DiagnosticLog.new("run1")
	weak.record("x", "peer " + STEAM_A, {}, 0)
	assert_eq(weak.export_records()[0].reason, "peer steam:#" + Redact.HASH_NO_SALT, "weak salt hides instead of hashing")
	assert_false(weak.to_report({}).salted)


func test_without_salt_identities_are_hidden_not_hashed() -> void:
	var l = DiagnosticLog.new("")
	l.record("x", "peer " + STEAM_A, {"identity": "steam:" + STEAM_A}, 0)
	var e: Dictionary = l.export_records()[0]
	assert_eq(e.reason, "peer steam:#" + Redact.HASH_NO_SALT)
	assert_eq(e.context.identity, "steam:#" + Redact.HASH_NO_SALT)
	assert_false(l.to_report({}).salted)


func test_custom_redactor_is_used() -> void:
	var custom = Redact.new(["pin"], null, null)
	var l = DiagnosticLog.new(SALT, 8, 3, custom)
	assert_eq(l.redactor, custom)
	l.record("x", "", {"pin": "1234", "token": "kept-by-custom-list"}, 0)
	var ctx: Dictionary = l.export_records()[0].context
	assert_eq(ctx.pin, Redact.MASK_SECRET)
	assert_eq(ctx.token, "kept-by-custom-list")
	var fallback = DiagnosticLog.new(SALT, 8, 3, "not a redactor")
	assert_true(fallback.redactor is Redact)


# --- report --------------------------------------------------------------------

func test_report_is_sanitized_and_complete() -> void:
	var l = DiagnosticLog.new(SALT, 2)
	for i in range(3):
		l.record("recovery", "attempt %d" % i, _context(8), 100 * i)
	l.allow_recovery("F09:" + STEAM_A)
	var header := {
		"versions": {"game": "1.1.15.4", "upstream_fingerprint": "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819"},
		"players": 8,
		"backend": "steam",
		"host_identity": "steam:" + STEAM_A,
		"auth_ticket": TOKEN,
	}
	var report: Dictionary = l.to_report(header)
	assert_eq(report.schema, DiagnosticLog.REPORT_SCHEMA)
	assert_eq(report.problems, [])
	assert_true(report.salted)
	assert_eq(report.max_entries, 2)
	assert_eq(report.total_recorded, 3)
	assert_eq(report.retained, 2)
	assert_eq(report.dropped, 1)
	assert_eq(report.counts_by_kind.recovery, 3)
	assert_eq(report.records.size(), 2)
	assert_eq(report.records[0].reason, "attempt 1")
	assert_eq(report.header.players, 8)
	assert_eq(report.header.versions.upstream_fingerprint, "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819")
	assert_eq(report.header.auth_ticket, Redact.MASK_SECRET)
	var host: String = report.header.host_identity
	assert_eq(host, report.records[0].context.slots[0].identity, "same player, same hash in header and records")
	assert_eq(report.max_recovery_attempts, 3)
	assert_eq(report.recovery.size(), 1)
	assert_eq(report.recovery[0].key, "F09:" + host)
	var dump := var2str(report)
	for raw in _raw_secrets():
		assert_eq(dump.find(raw), -1, "leaked %s" % raw)
	assert_eq(var2str(header).find(STEAM_A) != -1, true, "header input untouched")


func test_report_survives_json_round_trip() -> void:
	dlog.record("recovery", "", _context(8), 1)
	var text := to_json(dlog.to_report({"players": 8}))
	var parsed = parse_json(text)
	assert_eq(typeof(parsed), TYPE_DICTIONARY)
	assert_eq(parsed.records.size(), 1)
	assert_eq(parsed.records[0].context.slots.size(), 8)
	assert_eq(text.find(STEAM_A), -1)
	# A non-finite float anywhere must not make the whole report unreadable.
	dlog.record("fps", "", {"ratio": NAN, "budget_ms": INF}, 2)
	var with_nan = parse_json(to_json(dlog.to_report({"cpu_ratio": -INF})))
	assert_eq(typeof(with_nan), TYPE_DICTIONARY, "report with NaN/INF still parses")
	assert_eq(with_nan.records[1].context.ratio, Redact.MASK_NAN)
	assert_eq(with_nan.header.cpu_ratio, Redact.MASK_NEG_INF)


func test_report_with_malformed_header() -> void:
	var r: Dictionary = dlog.to_report(["host", STEAM_A])
	assert_eq(r.problems, [DiagnosticLog.REASON_INVALID_HEADER])
	assert_eq(r.header[DiagnosticLog.WRAPPED_VALUE_KEY][1], dlog.redactor.redact_identity(STEAM_A, SALT))
	var n: Dictionary = dlog.to_report(null)
	assert_eq(n.problems, [])
	assert_eq(n.header.size(), 0)


# --- recovery limiter ------------------------------------------------------------

func test_default_limit_allows_three_attempts_per_key() -> void:
	for i in range(3):
		var r: Dictionary = dlog.request_recovery("F07:wave3:shop")
		assert_true(r.allowed, "attempt %d" % (i + 1))
		assert_eq(r.attempt, i + 1)
		assert_eq(r.remaining, 2 - i)
	var denied: Dictionary = dlog.request_recovery("F07:wave3:shop")
	assert_false(denied.allowed)
	assert_eq(denied.reason, DiagnosticLog.REASON_RECOVERY_EXHAUSTED)
	assert_eq(denied.remaining, 0)
	assert_false(dlog.allow_recovery("F07:wave3:shop"), "stays denied")
	assert_eq(dlog.recovery_attempts("F07:wave3:shop"), 3, "denials do not count as attempts")
	var row: Dictionary = dlog.recovery_summary()[0]
	assert_eq(row.attempts, 3)
	assert_eq(row.denied, 2)
	assert_true(row.exhausted)


func test_limit_is_configurable_and_keys_are_independent() -> void:
	for limit in range(1, 6):
		var l = DiagnosticLog.new(SALT, 16, limit)
		for i in range(limit):
			assert_true(l.allow_recovery("a"), "limit %d attempt %d" % [limit, i + 1])
		assert_false(l.allow_recovery("a"), "limit %d" % limit)
		assert_true(l.allow_recovery("b"), "other key unaffected, limit %d" % limit)
		assert_eq(l.recovery_attempts("a"), limit)
		assert_eq(l.recovery_attempts("b"), 1)


func test_reset_restores_attempts() -> void:
	for i in range(3):
		dlog.allow_recovery("k")
	dlog.allow_recovery("other")
	assert_false(dlog.allow_recovery("k"))
	assert_true(dlog.reset("k"))
	assert_false(dlog.reset("k"), "already reset")
	assert_false(dlog.reset("never-seen"))
	assert_eq(dlog.recovery_attempts("k"), 0)
	assert_true(dlog.allow_recovery("k"))
	assert_eq(dlog.recovery_attempts("other"), 1, "reset touches one key only")
	dlog.reset_all_recoveries()
	assert_eq(dlog.recovery_attempts("other"), 0)
	assert_eq(dlog.recovery_summary().size(), 0)


func test_int_keys_and_invalid_keys() -> void:
	assert_true(dlog.allow_recovery(7))
	assert_eq(dlog.recovery_attempts(7), 1)
	assert_eq(dlog.recovery_attempts("7"), 1, "int key is its decimal text")
	var too_long := ""
	for i in range(DiagnosticLog.MAX_RECOVERY_KEY_LENGTH + 1):
		too_long += "k"
	for key in ["", "   ", null, 1.5, [], {}, too_long]:
		var r: Dictionary = dlog.request_recovery(key)
		assert_false(r.allowed, str(key))
		assert_eq(r.reason, DiagnosticLog.REASON_INVALID_KEY, str(key))
		assert_eq(r.remaining, 0, "a denial never advertises retries, " + str(key))
		assert_false(dlog.reset(key))
		assert_eq(dlog.recovery_attempts(key), 0)


func test_full_key_table_denies_new_keys_but_keeps_old_ones() -> void:
	for i in range(DiagnosticLog.MAX_RECOVERY_KEYS):
		assert_true(dlog.allow_recovery("key%d" % i))
	var r: Dictionary = dlog.request_recovery("one-too-many")
	assert_false(r.allowed)
	assert_eq(r.reason, DiagnosticLog.REASON_RECOVERY_TABLE_FULL)
	assert_eq(r.remaining, 0)
	assert_eq(dlog.recovery_attempts("one-too-many"), 0)
	assert_true(dlog.allow_recovery("key0"), "known key still limited normally")
	assert_true(dlog.allow_recovery("key0"))
	assert_false(dlog.allow_recovery("key0"))
	assert_true(dlog.reset("key1"))
	assert_true(dlog.allow_recovery("one-too-many"), "room again after reset")


func test_summary_rows_do_not_merge_keys_that_redact_alike() -> void:
	dlog.allow_recovery("reconnect:" + TOKEN)
	dlog.allow_recovery("reconnect:" + TOKEN.substr(1) + "0")
	var rows: Array = dlog.recovery_summary()
	assert_eq(rows.size(), 2)
	assert_eq(rows[0].key, "reconnect:" + Redact.MASK_TOKEN)
	assert_eq(rows[1].key, rows[0].key)
	assert_eq(var2str(rows).find(TOKEN.substr(0, 20)), -1)
