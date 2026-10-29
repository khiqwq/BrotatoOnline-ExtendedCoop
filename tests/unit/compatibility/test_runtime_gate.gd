extends "res://tests/runner/test_case.gd"

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const BO := "six666-BrotatoOnline"
const COOPFIX := "CoopFix-OnlineMouseUI"
const FP := "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819"
const OTHER_FP := "0000000000000000000000000000000000000000000000000000000000000000"
const COOPFIX_FP := "811ebfa7aeeb9fb9c86d7aaf224fe314c3af7cec1abd870e7e650561ab1bee54"


func before_each() -> void:
	RuntimeGate._reset()


func after_each() -> void:
	RuntimeGate._reset()


# Facts of the locked target with nothing against extended mode.
func _good_inputs() -> Dictionary:
	return {
		"cmdline_args": ["--enable-mods"],
		"compatibility_state": RuntimeGate.COMPAT_OK,
		"compatibility": {
			"schema": 1.0,
			"extension_id": "CoopPlus-OnlineExtendedCoop",
			"game_versions": ["1.1.15.4"],
			"engine_versions": ["3.7.dev.custom_build.74e86be54"],
			"mod_loader_versions": ["6.3.0"],
			"upstream": [
				{"id": BO, "version": "6.6.6", "normalized_fingerprint": FP, "role": "required"},
				{"id": COOPFIX, "version": "1.0.1", "normalized_fingerprint": COOPFIX_FP, "role": "optional"},
			],
		},
		"game_version": "1.1.15.4",
		"engine_version": "3.7.dev.custom_build.74e86be54",
		"mod_loader_version": "6.3.0",
		"fingerprints": {BO: {"ok": true, "reason": "", "fingerprint": FP, "file_count": 42}},
		"mods": {
			BO: {"loadable": true, "active": true},
			"CoopPlus-OnlineExtendedCoop": {"loadable": true, "active": true},
		},
		"mod_dirs": {COOPFIX: false},
	}


func _assert_vanilla(result: Dictionary, reasons: Array, message := "") -> void:
	assert_eq(result.capacity, 4, message)
	assert_false(result.extended, message)
	assert_eq(result.max_remote_players, 3, message)
	assert_eq(result.virtual_device_ids, [], message)
	assert_eq(result.reasons, reasons, message)


func test_locked_target_allows_eight_players() -> void:
	var r = RuntimeGate.decide(_good_inputs())
	assert_eq(r.capacity, 8)
	assert_true(r.extended)
	assert_eq(r.max_remote_players, 7)
	assert_eq(r.virtual_device_ids, [16, 17, 18, 19, 20, 21, 22])
	assert_eq(r.reasons, [])
	assert_true(r.install_extensions)
	assert_eq(r.details.upstream[BO].result, "match")
	assert_eq(r.details.upstream[BO].actual, "17443875")


func test_fingerprint_mismatch_keeps_vanilla() -> void:
	var inputs = _good_inputs()
	inputs.fingerprints[BO].fingerprint = OTHER_FP
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_FINGERPRINT_MISMATCH])
	assert_false(r.install_extensions, "overrides are unverified against a changed Brotato Online")
	assert_eq(r.details.upstream[BO].result, "mismatch")


func test_unreadable_or_missing_fingerprint_keeps_vanilla() -> void:
	var inputs = _good_inputs()
	inputs.fingerprints[BO] = {"ok": false, "reason": "mod_dir_missing", "fingerprint": "", "file_count": 0}
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_FINGERPRINT_UNAVAILABLE], "compute failed")
	assert_false(r.install_extensions, "compute failed")
	inputs.erase("fingerprints")
	_assert_vanilla(RuntimeGate.decide(inputs), [RuntimeGate.REASON_FINGERPRINT_UNAVAILABLE], "fact missing")


# Locked CoopFix running: its mouse input is how players click in co-op (D-011).
func _with_coopfix(fingerprint) -> Dictionary:
	var inputs = _good_inputs()
	inputs.mods[COOPFIX] = {"loadable": true, "active": true}
	if fingerprint != null:
		inputs.fingerprints[COOPFIX] = {"ok": true, "reason": "", "fingerprint": fingerprint, "file_count": 9}
	return inputs


func test_locked_coopfix_allows_eight_players() -> void:
	var r = RuntimeGate.decide(_with_coopfix(COOPFIX_FP))
	assert_true(r.extended)
	assert_eq(r.capacity, 8)
	assert_eq(r.reasons, [])
	assert_eq(var2str(r.details.optional_running), var2str({COOPFIX: "match"}))
	assert_eq(r.details.unsupported_running, [])


func test_other_coopfix_version_blocks_extended_mode() -> void:
	var r = RuntimeGate.decide(_with_coopfix(OTHER_FP))
	_assert_vanilla(r, ["unsupported_mod:CoopFix-OnlineMouseUI"], "changed files")
	assert_true(r.install_extensions, "1-4 player sessions keep working (R07)")
	assert_eq(var2str(r.details.optional_running), var2str({COOPFIX: "mismatch"}))
	assert_eq(r.details.unsupported_running, [COOPFIX])
	r = RuntimeGate.decide(_with_coopfix(null))
	_assert_vanilla(r, ["unsupported_mod:CoopFix-OnlineMouseUI"], "fingerprint unavailable")
	assert_eq(var2str(r.details.optional_running), var2str({COOPFIX: "unavailable"}))


func test_coopfix_directory_counts_when_mod_loader_view_lacks_it() -> void:
	var inputs = _good_inputs()
	inputs.mod_dirs[COOPFIX] = true
	_assert_vanilla(RuntimeGate.decide(inputs), ["unsupported_mod:CoopFix-OnlineMouseUI"], "listed nowhere, directory present, no fingerprint")
	inputs.fingerprints[COOPFIX] = {"ok": true, "reason": "", "fingerprint": COOPFIX_FP, "file_count": 9}
	assert_true(RuntimeGate.decide(inputs).extended, "directory present, locked version")
	inputs.erase("mods")
	assert_true(RuntimeGate.decide(inputs).extended, "no Mod Loader view at all, locked version")


func test_deactivated_or_unloadable_coopfix_does_not_block() -> void:
	for state in [{"loadable": true, "active": false}, {"loadable": false, "active": true}]:
		var inputs = _good_inputs()
		inputs.mods[COOPFIX] = state
		inputs.mod_dirs[COOPFIX] = true
		var r = RuntimeGate.decide(inputs)
		assert_true(r.extended, "Mod Loader view wins over the mounted directory: %s" % str(state))


func test_coopfix_blocks_if_compatibility_does_not_list_it_as_optional() -> void:
	var inputs = _with_coopfix(COOPFIX_FP)
	inputs.compatibility.upstream.remove(1)
	_assert_vanilla(RuntimeGate.decide(inputs), ["unsupported_mod:CoopFix-OnlineMouseUI"], "omitted")
	inputs = _with_coopfix(COOPFIX_FP)
	inputs.compatibility.upstream[1].role = "not-supported"
	_assert_vanilla(RuntimeGate.decide(inputs), ["unsupported_mod:CoopFix-OnlineMouseUI"], "listed as not supported")


func test_other_not_supported_mod_from_compatibility_blocks() -> void:
	var inputs = _good_inputs()
	inputs.compatibility.upstream.append({"id": "Someone-OtherCoopUI", "role": "not-supported"})
	inputs.mods["Someone-OtherCoopUI"] = {"loadable": true, "active": true}
	_assert_vanilla(RuntimeGate.decide(inputs), ["unsupported_mod:Someone-OtherCoopUI"])


func test_command_line_opt_out() -> void:
	var inputs = _good_inputs()
	inputs.cmdline_args = ["--enable-mods", "--coopplus-vanilla"]
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_DISABLED])
	assert_true(r.install_extensions)
	inputs.cmdline_args = PoolStringArray(["--coopplus-vanilla"])
	_assert_vanilla(RuntimeGate.decide(inputs), [RuntimeGate.REASON_DISABLED], "PoolStringArray from OS")
	inputs.cmdline_args = ["--coopplus-vanilla=0", "--coopplus-probe"]
	assert_true(RuntimeGate.decide(inputs).extended, "only the exact flag disables")


func test_missing_compatibility_json_keeps_vanilla() -> void:
	var inputs = _good_inputs()
	inputs.compatibility_state = RuntimeGate.COMPAT_MISSING
	inputs.compatibility = {}
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_COMPAT_MISSING])
	assert_eq(r.details.upstream[BO].result, "not_checked")
	assert_false(r.install_extensions, "nothing to verify the target against")


func test_unparsable_compatibility_json_keeps_vanilla() -> void:
	var inputs = _good_inputs()
	inputs.compatibility_state = RuntimeGate.COMPAT_INVALID
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_COMPAT_INVALID])
	assert_false(r.install_extensions)


func test_malformed_compatibility_content_keeps_vanilla() -> void:
	var cases := {
		"schema": {"schema": 2},
		"extension_id": {"extension_id": "Other-Mod"},
		"game_versions": {"game_versions": "1.1.15.4"},
		"upstream": {"upstream": {}},
		"upstream[0].normalized_fingerprint": {"upstream": [{"id": BO, "role": "required", "normalized_fingerprint": "short"}]},
		"upstream:six666-BrotatoOnline": {"upstream": [{"id": COOPFIX, "role": "not-supported"}]},
		"upstream[0]": {"upstream": [{"role": "required"}]},
		"upstream[1].normalized_fingerprint": {"upstream": [{"id": BO, "role": "required", "normalized_fingerprint": FP}, {"id": COOPFIX, "role": "optional"}]},
	}
	for problem in cases:
		var inputs = _good_inputs()
		var patch: Dictionary = cases[problem]
		for key in patch:
			inputs.compatibility[key] = patch[key]
		var r = RuntimeGate.decide(inputs)
		_assert_vanilla(r, [RuntimeGate.REASON_COMPAT_INVALID], problem)
		assert_eq(r.details.get("compatibility_problem", ""), problem, problem)
	var not_object = _good_inputs()
	not_object.compatibility = []
	_assert_vanilla(RuntimeGate.decide(not_object), [RuntimeGate.REASON_COMPAT_INVALID], "not an object")


func test_unverified_versions_keep_vanilla() -> void:
	var expected := {
		"game_version": RuntimeGate.REASON_GAME_VERSION,
		"engine_version": RuntimeGate.REASON_ENGINE_VERSION,
		"mod_loader_version": RuntimeGate.REASON_MOD_LOADER_VERSION,
	}
	for fact in expected:
		var inputs = _good_inputs()
		inputs[fact] = "9.9.9"
		var r = RuntimeGate.decide(inputs)
		_assert_vanilla(r, [expected[fact]], fact)
		assert_false(r.install_extensions, "%s: parents differ from the verified ones" % fact)
		inputs[fact] = ""
		_assert_vanilla(RuntimeGate.decide(inputs), [expected[fact]], "%s empty is unverified (R04)" % fact)
		inputs.erase(fact)
		r = RuntimeGate.decide(inputs)
		_assert_vanilla(r, [expected[fact]], "%s not supplied is unverified (R04)" % fact)
		assert_eq(r.details[fact], "missing", fact)


func test_stopped_brotato_online_skips_extensions() -> void:
	var inputs = _good_inputs()
	inputs.mods[BO] = {"loadable": true, "active": false}
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_UPSTREAM_INACTIVE])
	assert_false(r.install_extensions, "LIFE-20: BO layers were never installed")
	inputs.mods.erase(BO)
	assert_true(RuntimeGate.decide(inputs).install_extensions, "unknown view is not 'stopped'")


# Capacity 4 on the verified target still installs the extensions: they fall
# back to the parent themselves (R07: 1-4 players keep working with an
# unverified CoopFix; here its fingerprint is unavailable).
func test_opt_out_and_unsupported_mod_keep_extensions_installed() -> void:
	var inputs = _good_inputs()
	inputs.cmdline_args = ["--coopplus-vanilla"]
	inputs.mods[COOPFIX] = {"loadable": true, "active": true}
	var r = RuntimeGate.decide(inputs)
	_assert_vanilla(r, [RuntimeGate.REASON_DISABLED, "unsupported_mod:CoopFix-OnlineMouseUI"])
	assert_true(r.install_extensions)
	inputs.fingerprints[BO].fingerprint = OTHER_FP
	assert_false(RuntimeGate.decide(inputs).install_extensions, "any unverified-target reason wins")


func test_every_unverified_target_reason_skips_extensions() -> void:
	var cases := {
		RuntimeGate.REASON_COMPAT_MISSING: {"compatibility_state": RuntimeGate.COMPAT_MISSING},
		RuntimeGate.REASON_COMPAT_INVALID: {"compatibility_state": RuntimeGate.COMPAT_INVALID},
		RuntimeGate.REASON_GAME_VERSION: {"game_version": "1.1.16.0"},
		RuntimeGate.REASON_ENGINE_VERSION: {"engine_version": "3.6.stable.official.de2f0f147"},
		RuntimeGate.REASON_MOD_LOADER_VERSION: {"mod_loader_version": "6.2.0"},
		RuntimeGate.REASON_UPSTREAM_INACTIVE: {"mods": {BO: {"loadable": true, "active": false}}},
		RuntimeGate.REASON_FINGERPRINT_UNAVAILABLE: {"fingerprints": {}},
		RuntimeGate.REASON_FINGERPRINT_MISMATCH: {"fingerprints": {BO: {"ok": true, "fingerprint": OTHER_FP, "file_count": 42}}},
	}
	assert_eq(cases.size(), RuntimeGate.UNVERIFIED_TARGET_REASONS.size(), "every listed reason has a case")
	for reason in cases:
		var inputs = _good_inputs()
		var patch: Dictionary = cases[reason]
		for key in patch:
			inputs[key] = patch[key]
		var r = RuntimeGate.decide(inputs)
		assert_has(r.reasons, reason, reason)
		assert_false(r.install_extensions, reason)
		assert_false(r.extended, reason)


func test_reasons_accumulate_in_check_order() -> void:
	var inputs = _good_inputs()
	inputs.cmdline_args = ["--coopplus-vanilla"]
	inputs.game_version = "1.1.15.3"
	inputs.fingerprints[BO].fingerprint = OTHER_FP
	inputs.mods[COOPFIX] = {"loadable": true, "active": true}
	_assert_vanilla(RuntimeGate.decide(inputs), [
		RuntimeGate.REASON_DISABLED,
		RuntimeGate.REASON_GAME_VERSION,
		RuntimeGate.REASON_FINGERPRINT_MISMATCH,
		"unsupported_mod:CoopFix-OnlineMouseUI",
	])


func test_empty_inputs_are_vanilla() -> void:
	var r = RuntimeGate.decide({})
	assert_false(r.extended)
	assert_eq(r.capacity, 4)
	assert_has(r.reasons, RuntimeGate.REASON_COMPAT_MISSING)


func test_decide_does_not_change_its_inputs() -> void:
	var inputs = _good_inputs()
	inputs.mods[COOPFIX] = {"loadable": true, "active": true}
	var before := var2str(inputs)
	var _r = RuntimeGate.decide(inputs)
	assert_eq(var2str(inputs), before)


func test_getters_are_vanilla_before_initialize() -> void:
	assert_false(RuntimeGate.is_initialized())
	assert_eq(RuntimeGate.capacity(), 4)
	assert_false(RuntimeGate.is_extended())
	assert_eq(RuntimeGate.max_remote_players(), 3)
	assert_eq(RuntimeGate.virtual_device_ids(), [])
	assert_eq(RuntimeGate.block_reasons(), [RuntimeGate.REASON_NOT_INITIALIZED])
	for device in [0, 6, 7, 15, 16, 22]:
		assert_false(RuntimeGate.is_virtual_device(device), "device %d" % device)
	assert_eq(RuntimeGate.decision().capacity, 4)


func test_getters_follow_an_extended_decision() -> void:
	RuntimeGate._store(RuntimeGate.decide(_good_inputs()))
	assert_true(RuntimeGate.is_initialized())
	assert_eq(RuntimeGate.capacity(), 8)
	assert_true(RuntimeGate.is_extended())
	assert_eq(RuntimeGate.max_remote_players(), 7)
	assert_eq(RuntimeGate.block_reasons(), [])
	assert_eq(RuntimeGate.virtual_device_ids(), [16, 17, 18, 19, 20, 21, 22])
	for device in range(0, 30):
		assert_eq(RuntimeGate.is_virtual_device(device), device >= 16 and device <= 22, "device %d" % device)


func test_virtual_ids_avoid_every_vanilla_and_physical_id() -> void:
	RuntimeGate._store(RuntimeGate.decide(_good_inputs()))
	var ids = RuntimeGate.virtual_device_ids()
	assert_eq(ids.size(), 7, "one per remote player")
	for id in ids:
		assert_true(id >= 16, "above Godot's 16 physical joypads, vanilla remaps 0..7 and debug 8..11: %d" % id)


func test_getter_results_are_copies() -> void:
	RuntimeGate._store(RuntimeGate.decide(_good_inputs()))
	RuntimeGate.virtual_device_ids().append(99)
	RuntimeGate.block_reasons().append("x")
	RuntimeGate.decision().reasons.append("x")
	assert_eq(RuntimeGate.virtual_device_ids().size(), 7)
	assert_eq(RuntimeGate.block_reasons(), [])
	assert_true(RuntimeGate.is_extended())


func test_vanilla_decision_getters() -> void:
	var inputs = _good_inputs()
	inputs.cmdline_args = ["--coopplus-vanilla"]
	RuntimeGate._store(RuntimeGate.decide(inputs))
	assert_eq(RuntimeGate.capacity(), 4)
	assert_eq(RuntimeGate.block_reasons(), [RuntimeGate.REASON_DISABLED])
	assert_eq(RuntimeGate.virtual_device_ids(), [])
	assert_false(RuntimeGate.is_virtual_device(16))


func test_inconsistent_stored_state_reads_as_vanilla() -> void:
	for bad in [{"capacity": 99, "reasons": []}, {"capacity": 8, "reasons": ["x"]}, {"capacity": 8.0, "reasons": []}, "garbage"]:
		Engine.set_meta(RuntimeGate.META_KEY, bad)
		assert_eq(RuntimeGate.capacity(), 4, var2str(bad))
		assert_false(RuntimeGate.is_initialized(), var2str(bad))
		assert_eq(RuntimeGate.block_reasons(), [RuntimeGate.REASON_INVALID_STATE], var2str(bad))


func test_initialize_reads_real_files_and_runs_once() -> void:
	# The rule-test project has this mod's compatibility.json but no Brotato
	# Online directory, so the real gather path must end in vanilla.
	var first = RuntimeGate.initialize({"game_version": "1.1.15.4", "mod_loader_version": "6.3.0"})
	assert_true(RuntimeGate.is_initialized())
	assert_eq(first.details.compatibility, RuntimeGate.COMPAT_OK, "compatibility.json parsed")
	assert_eq(first.details.engine_version, RuntimeGate.engine_version_string())
	if not Directory.new().dir_exists("res://mods-unpacked/six666-BrotatoOnline"):
		assert_eq(first.reasons, [RuntimeGate.REASON_FINGERPRINT_UNAVAILABLE])
		assert_false(first.install_extensions)
	assert_eq(RuntimeGate.capacity(), first.capacity)
	assert_eq(RuntimeGate.block_reasons(), first.reasons)
	var second = RuntimeGate.initialize({"mods": {COOPFIX: {"loadable": true, "active": true}}})
	assert_eq(var2str(second), var2str(first), "second call returns the stored decision")


func test_describe_is_one_line_without_full_fingerprints() -> void:
	var good = RuntimeGate.describe(RuntimeGate.decide(_good_inputs()))
	assert_true(good.begins_with("runtime gate: extended capacity=8 virtual_devices=16..22"), good)
	assert_false("\n" in good)
	assert_false(FP in good, "short fingerprints only")
	var inputs = _good_inputs()
	inputs.mods[COOPFIX] = {"loadable": true, "active": true}
	var blocked = RuntimeGate.describe(RuntimeGate.decide(inputs))
	assert_true(blocked.begins_with("runtime gate: vanilla capacity=4 reasons=unsupported_mod:CoopFix-OnlineMouseUI"), blocked)
	assert_false("extensions=skipped" in blocked, blocked)
	inputs.fingerprints[BO].fingerprint = OTHER_FP
	var skipped = RuntimeGate.describe(RuntimeGate.decide(inputs))
	assert_true("extensions=skipped" in skipped, skipped)


func test_engine_version_string_matches_lock_format() -> void:
	var text := RuntimeGate.engine_version_string()
	var v := Engine.get_version_info()
	assert_true(text.begins_with("%d.%d" % [v.major, v.minor]), text)
	assert_true(text.ends_with(str(v.hash).substr(0, 9)), text)
