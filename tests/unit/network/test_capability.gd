extends "res://tests/runner/test_case.gd"
# AP-009 capability handshake rules; T13 (old/missing extension on an extended
# continue), T15 (DLC sets), T17 (unverified upstream/game/engine).

const Capability = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/capability.gd")
const COMPAT_PATH := "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/compatibility.json"

const FINGERPRINT := "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819"
const MOUSE_UI_FINGERPRINT := "811ebfa7aeeb9fb9c86d7aaf224fe314c3af7cec1abd870e7e650561ab1bee54"
const OTHER_FINGERPRINT := "00000000000000000000000000000000000000000000000000000000000000ff"
const MOUSE_UI := "CoopFix-OnlineMouseUI"

var rules


func before_each() -> void:
	rules = Capability.new()


func _record() -> Dictionary:
	return {
		"schema": 1,
		"extension_id": "CoopPlus-OnlineExtendedCoop",
		"extension_version": "0.1.0",
		"network_capability_version": 1,
		"save_schema_version": 1,
		"game_versions": ["1.1.15.4"],
		"engine_versions": ["3.7.dev.custom_build.74e86be54"],
		"mod_loader_versions": ["6.3.0"],
		"upstream": [
			{"id": "six666-BrotatoOnline", "version": "6.6.6", "normalized_fingerprint": FINGERPRINT, "role": "required"},
			{"id": MOUSE_UI, "version": "1.0.1", "normalized_fingerprint": MOUSE_UI_FINGERPRINT, "role": "compatibility-candidate"},
		],
	}


func _info() -> Dictionary:
	return {
		"extension_id": "CoopPlus-OnlineExtendedCoop",
		"extension_version": "0.1.0",
		"capability_version": 1,
		"game_version": "1.1.15.4",
		"engine_version": "3.7.dev.custom_build.74e86be54",
		"upstream_fingerprint": FINGERPRINT,
		"capacity": 8,
		"dlc": ["abyssal_terrors"],
		"mods": [{"id": "six666-BrotatoOnline", "version": "6.6.6"}, {"id": "CoopPlus-OnlineExtendedCoop", "version": "0.1.0"}],
		"incompatible_mods": [MOUSE_UI],
		"supported": _record(),
	}


func _hello(overrides := {}) -> Dictionary:
	var h = rules.build_hello(_info())
	for key in overrides:
		h[key] = overrides[key]
	return h


func _without(d: Dictionary, key: String) -> Dictionary:
	var copy = d.duplicate(true)
	copy.erase(key)
	return copy


func _pad(prefix: String, length: int) -> String:
	var s := prefix
	while s.length() < length:
		s += "a"
	return s


func _assert_rejected(d: Dictionary, reason: String, label: String) -> void:
	assert_false(d.accepted, label)
	assert_eq(d.reason, reason, label)
	assert_eq(d.mode, Capability.MODE_NONE, label)


func _assert_vanilla(d: Dictionary, note: String, label: String) -> void:
	assert_true(d.accepted, label)
	assert_eq(d.reason, Capability.REASON_NONE, label)
	assert_eq(d.mode, Capability.MODE_VANILLA_COMPAT, label)
	assert_eq(d.note, note, label)


# [hello overrides, reason] - each one breaks exactly one rule.
func _mismatch_cases() -> Array:
	var too_many_dlc := []
	for i in range(Capability.MAX_DLC + 1):
		too_many_dlc.append("dlc_%d" % i)
	return [
		[{"extension_id": "Other-Extension"}, Capability.REASON_EXTENSION_ID_MISMATCH],
		[{"capability_version": 2}, Capability.REASON_CAPABILITY_MISMATCH],
		[{"extension_version": "1.0.0"}, Capability.REASON_EXTENSION_VERSION_MISMATCH],
		[{"game_version": "1.1.15.3"}, Capability.REASON_GAME_VERSION_MISMATCH],
		[{"engine_version": "3.6.stable"}, Capability.REASON_ENGINE_VERSION_MISMATCH],
		[{"upstream_fingerprint": OTHER_FINGERPRINT}, Capability.REASON_UPSTREAM_MISMATCH],
		[{"dlc": []}, Capability.REASON_DLC_MISMATCH],
		[{"capacity": 4}, Capability.REASON_CAPACITY_UNSUPPORTED],
		[{"mods": [{"id": MOUSE_UI, "version": "1.0.1"}]}, Capability.REASON_INCOMPATIBLE_MOD],
		[{"msg_type": "coopplus_other"}, Capability.REASON_MALFORMED_HELLO],
		[{"dlc": too_many_dlc}, Capability.REASON_OVERSIZED_HELLO],
	]


func test_message_types_carry_the_extension_prefix() -> void:
	assert_eq(Capability.MSG_PREFIX, "coopplus_")
	assert_true(Capability.MSG_HELLO.begins_with(Capability.MSG_PREFIX))
	assert_true(Capability.MSG_RESULT.begins_with(Capability.MSG_PREFIX))
	assert_ne(Capability.MSG_HELLO, Capability.MSG_RESULT)


func test_build_hello_carries_every_field_and_nothing_local() -> void:
	var h = rules.build_hello(_info())
	assert_eq(h.msg_type, Capability.MSG_HELLO)
	for key in Capability.HELLO_FIELDS:
		assert_has(h, key)
	assert_eq(h.size(), Capability.HELLO_FIELDS.size())
	assert_not_has(h, "supported")
	assert_not_has(h, "incompatible_mods")
	assert_eq(h.capability_version, 1)
	assert_eq(h.capacity, 8)
	assert_eq(h.extension_version, "0.1.0")
	assert_eq(h.upstream_fingerprint, FINGERPRINT)
	var v = rules.validate_hello(h)
	assert_true(v.ok, "%s %s" % [v.reason, v.detail])


func test_build_hello_is_canonical_and_never_aliases_the_input() -> void:
	var a = _info()
	a.dlc = ["abyssal_terrors", "zz_dlc"]
	var b = _info()
	b.dlc = ["zz_dlc", "abyssal_terrors"]
	b.mods = [b.mods[1], b.mods[0]]
	b.upstream_fingerprint = FINGERPRINT.to_upper()
	b.capability_version = 1.0
	b.capacity = 8.0
	var ha = rules.build_hello(a)
	var hb = rules.build_hello(b)
	assert_eq(var2bytes(hb).hex_encode(), var2bytes(ha).hex_encode())
	assert_eq(typeof(hb.capability_version), TYPE_INT)
	assert_eq(hb.dlc, ["abyssal_terrors", "zz_dlc"])
	assert_eq(hb.mods[0].id, "CoopPlus-OnlineExtendedCoop")
	assert_eq(b.dlc, ["zz_dlc", "abyssal_terrors"], "input list untouched")
	hb.dlc.append("x")
	hb.mods[0]["id"] = "changed"
	assert_eq(b.dlc.size(), 2)
	assert_eq(b.mods[0].id, "CoopPlus-OnlineExtendedCoop", "input entries are copied, not shared")


func test_hello_from_incomplete_info_names_the_missing_field() -> void:
	for key in ["extension_id", "extension_version", "capability_version", "game_version", "engine_version", "upstream_fingerprint", "capacity", "dlc", "mods"]:
		var v = rules.validate_hello(rules.build_hello(_without(_info(), key)))
		assert_false(v.ok, key)
		assert_eq(v.reason, Capability.REASON_MALFORMED_HELLO, key)
		assert_eq(v.detail, key, key)


func test_matching_peer_is_extended_for_five_to_eight() -> void:
	for n in range(5, 9):
		var d = rules.evaluate(_info(), _hello(), n)
		assert_true(d.accepted, "capacity %d: %s %s" % [n, d.reason, d.detail])
		assert_eq(d.reason, Capability.REASON_NONE, "capacity %d" % n)
		assert_eq(d.mode, Capability.MODE_EXTENDED, "capacity %d" % n)
		assert_eq(d.note, Capability.REASON_NONE, "capacity %d" % n)
		assert_true(d.reply, "capacity %d" % n)
		assert_true(rules.requires_handshake(n), "capacity %d" % n)


func test_plain_client_keeps_one_to_four_sessions_open() -> void:
	for n in range(1, 5):
		var d = rules.evaluate(_info(), null, n)
		_assert_vanilla(d, Capability.REASON_EXTENSION_MISSING, "capacity %d" % n)
		assert_false(d.reply, "plain client gets no extension message, capacity %d" % n)
		assert_false(rules.requires_handshake(n), "no wait for plain clients, capacity %d" % n)


func test_extension_stays_dormant_in_one_to_four_sessions() -> void:
	for n in range(1, 5):
		var d = rules.evaluate(_info(), _hello(), n)
		_assert_vanilla(d, Capability.REASON_NONE, "capacity %d" % n)
		assert_true(d.reply, "capacity %d" % n)


func test_missing_extension_rejected_for_five_to_eight() -> void:
	for n in range(5, 9):
		var d = rules.evaluate(_info(), null, n)
		_assert_rejected(d, Capability.REASON_EXTENSION_MISSING, "capacity %d" % n)
		assert_false(d.reply, "capacity %d" % n)


func test_invalid_session_capacity_rejected_even_for_matching_peer() -> void:
	for n in [0, -1, 9, 16]:
		_assert_rejected(rules.evaluate(_info(), null, n), Capability.REASON_INVALID_CAPACITY, "null, capacity %d" % n)
		_assert_rejected(rules.evaluate(_info(), _hello(), n), Capability.REASON_INVALID_CAPACITY, "hello, capacity %d" % n)
		assert_true(rules.requires_handshake(n), "capacity %d" % n)


func test_every_mismatch_has_its_own_reason() -> void:
	var seen := []
	for item in _mismatch_cases():
		var reason: String = item[1]
		assert_not_has(seen, reason, "reasons must be distinct")
		seen.append(reason)
		for n in range(5, 9):
			var d = rules.evaluate(_info(), _hello(item[0]), n)
			_assert_rejected(d, reason, "%s capacity %d" % [reason, n])
			assert_true(d.reply, "%s capacity %d" % [reason, n])
		for n in range(1, 5):
			var note: String = reason
			if reason == Capability.REASON_CAPACITY_UNSUPPORTED:
				note = Capability.REASON_NONE
			_assert_vanilla(rules.evaluate(_info(), _hello(item[0]), n), note, "%s capacity %d" % [reason, n])
	assert_not_has(seen, Capability.REASON_EXTENSION_MISSING)
	assert_not_has(seen, Capability.REASON_HOST_UNVERIFIED)
	assert_not_has(seen, Capability.REASON_INVALID_CAPACITY)


func test_reason_constants_are_distinct_and_readable_on_the_wire() -> void:
	var values := []
	var constants: Dictionary = Capability.get_script_constant_map()
	for name in constants:
		if name.begins_with("REASON_") and name != "REASON_NONE":
			var value: String = constants[name]
			assert_not_has(values, value, name)
			values.append(value)
			var result = rules.read_result({"msg_type": Capability.MSG_RESULT, "accepted": false, "reason": value, "mode": Capability.MODE_NONE})
			assert_true(result.ok, "%s must survive read_result" % name)
	assert_true(values.size() >= 25, "found %d reasons" % values.size())


func test_incompatible_mod_names_the_mod() -> void:
	var mods = _info().mods
	mods.append({"id": MOUSE_UI, "version": "1.0.1"})
	var d = rules.evaluate(_info(), _hello({"mods": mods}), 8)
	_assert_rejected(d, Capability.REASON_INCOMPATIBLE_MOD, "peer runs OnlineMouseUI")
	assert_eq(d.detail, MOUSE_UI)
	var other = _info().mods
	other.append({"id": "Someone-ContentMod", "version": "2.0.0"})
	assert_true(rules.evaluate(_info(), _hello({"mods": other}), 8).accepted, "unlisted mods are not blocked here")


func test_peer_capacity_must_cover_session_capacity() -> void:
	for session in range(1, 9):
		for peer_capacity in range(1, 9):
			var d = rules.evaluate(_info(), _hello({"capacity": peer_capacity}), session)
			var label := "session %d peer %d" % [session, peer_capacity]
			if session <= 4:
				_assert_vanilla(d, Capability.REASON_CAPACITY_UNSUPPORTED if peer_capacity < session else Capability.REASON_NONE, label)
			elif peer_capacity >= session:
				assert_eq(d.mode, Capability.MODE_EXTENDED, label)
			else:
				_assert_rejected(d, Capability.REASON_CAPACITY_UNSUPPORTED, label)
				assert_eq(d.detail, "peer=%d session=%d" % [peer_capacity, session], label)


func test_host_capacity_below_session_capacity_is_rejected() -> void:
	var info = _info()
	info.capacity = 6
	assert_true(rules.evaluate(info, _hello(), 6).accepted)
	var d = rules.evaluate(info, _hello(), 7)
	_assert_rejected(d, Capability.REASON_CAPACITY_UNSUPPORTED, "host supports 6")
	assert_eq(d.detail, "host=6 session=7")


func test_extension_versions_mix_within_major_but_not_across_zero_minor() -> void:
	for v in ["0.1.0", "0.1.9"]:
		assert_true(rules.evaluate(_info(), _hello({"extension_version": v}), 8).accepted, v)
	for v in ["0.2.0", "0.0.9", "1.1.0"]:
		var d = rules.evaluate(_info(), _hello({"extension_version": v}), 8)
		_assert_rejected(d, Capability.REASON_EXTENSION_VERSION_MISMATCH, v)
		assert_eq(d.detail, "host=0.1.0 peer=%s" % v)
	var info = _info()
	info.extension_version = "1.2.0"
	info.supported.extension_version = "1.2.0"
	for v in ["1.0.0", "1.9.3"]:
		assert_true(rules.evaluate(info, _hello({"extension_version": v}), 8).accepted, "1.2.0 vs %s" % v)
	for v in ["2.0.0", "0.2.0"]:
		_assert_rejected(rules.evaluate(info, _hello({"extension_version": v}), 8), Capability.REASON_EXTENSION_VERSION_MISMATCH, "1.2.0 vs %s" % v)


func test_capability_mismatch_is_reported_even_when_the_body_changed() -> void:
	var h = _without(_hello({"capability_version": 2}), "dlc")
	h["future_field"] = {"anything": [1, 2, 3]}
	var d = rules.evaluate(_info(), h, 8)
	_assert_rejected(d, Capability.REASON_CAPABILITY_MISMATCH, "frozen envelope")
	assert_eq(d.detail, "host=1 peer=2")
	var same_version = _hello()
	same_version["future_field"] = 1
	var m = rules.evaluate(_info(), same_version, 8)
	_assert_rejected(m, Capability.REASON_MALFORMED_HELLO, "unknown field, same capability")
	assert_eq(m.detail, "unknown_field")


func test_reason_precedence_is_fixed() -> void:
	_assert_rejected(rules.evaluate(_info(), _hello({"capability_version": 2, "game_version": "1.0.0.0"}), 8), Capability.REASON_CAPABILITY_MISMATCH, "capability before game")
	_assert_rejected(rules.evaluate(_info(), _hello({"extension_id": "Other-Ext", "capability_version": 2}), 8), Capability.REASON_EXTENSION_ID_MISMATCH, "id before capability")
	_assert_rejected(rules.evaluate(_info(), _hello({"game_version": "1.1.15.3", "dlc": []}), 8), Capability.REASON_GAME_VERSION_MISMATCH, "game before dlc")
	_assert_rejected(rules.evaluate(_info(), _hello({"upstream_fingerprint": OTHER_FINGERPRINT, "mods": [{"id": MOUSE_UI, "version": "1.0.1"}]}), 8), Capability.REASON_UPSTREAM_MISMATCH, "upstream before mods")
	var info = _info()
	info.erase("supported")
	_assert_rejected(rules.evaluate(info, null, 8), Capability.REASON_HOST_UNVERIFIED, "host before peer")


func test_malformed_hellos_are_rejected_without_crashing() -> void:
	var with_int_key = _hello()
	with_int_key[5] = "x"
	var bodies := [
		"hello", 42, [], {}, Reference.new(), with_int_key,
		_hello({"msg_type": 5}),
		_without(_hello(), "msg_type"),
		_hello({"extension_id": ""}),
		_hello({"extension_id": "bad id"}),
		_hello({"extension_version": "1.0"}),
		_hello({"extension_version": 1}),
		_hello({"extension_version": "01.0.0"}),
		_hello({"capability_version": "1"}),
		_hello({"capability_version": 1.5}),
		_hello({"capability_version": 0}),
		_hello({"game_version": null}),
		_hello({"game_version": "1.1.15.4[b]"}),
		_hello({"engine_version": ""}),
		_hello({"upstream_fingerprint": FINGERPRINT.to_upper()}),
		_hello({"upstream_fingerprint": "abc"}),
		_hello({"capacity": 0}),
		_hello({"capacity": 2.5}),
		_hello({"capacity": "8"}),
		_hello({"dlc": "abyssal_terrors"}),
		_hello({"dlc": ["abyssal_terrors", "abyssal_terrors"]}),
		_hello({"dlc": [7]}),
		_hello({"mods": {}}),
		_hello({"mods": ["six666-BrotatoOnline"]}),
		_hello({"mods": [Reference.new()]}),
		_hello({"mods": [{"id": 5, "version": "1.0.0"}]}),
		_hello({"mods": [{"id": "A-B", "version": "1.0.0", "extra": 1}]}),
		_hello({"mods": [{"id": "A-B", "version": "1.0.0"}, {"id": "A-B", "version": "2.0.0"}]}),
	]
	for i in range(bodies.size()):
		var d8 = rules.evaluate(_info(), bodies[i], 8)
		_assert_rejected(d8, Capability.REASON_MALFORMED_HELLO, "case %d" % i)
		assert_true(d8.reply, "case %d" % i)
		_assert_vanilla(rules.evaluate(_info(), bodies[i], 4), Capability.REASON_MALFORMED_HELLO, "case %d at capacity 4" % i)
		assert_false(rules.validate_hello(bodies[i]).ok, "case %d" % i)


func test_oversized_hellos_are_rejected() -> void:
	var many_mods := []
	for i in range(Capability.MAX_MODS + 1):
		many_mods.append({"id": "Mod-%d" % i, "version": "1.0.0"})
	var many_keys = _hello()
	for i in range(Capability.MAX_HELLO_KEYS - many_keys.size() + 1):
		many_keys["x%d" % i] = 1
	var huge = _hello({"capability_version": 2})
	huge["padding"] = _pad("p", Capability.MAX_HELLO_BYTES + 1)
	var cases := [
		[_hello({"mods": many_mods}), "mods"],
		[many_keys, "keys"],
		[huge, "bytes"],
	]
	for item in cases:
		var d = rules.evaluate(_info(), item[0], 8)
		_assert_rejected(d, Capability.REASON_OVERSIZED_HELLO, item[1])
		assert_eq(d.detail, item[1])
		_assert_vanilla(rules.evaluate(_info(), item[0], 3), Capability.REASON_OVERSIZED_HELLO, item[1])


func test_hello_key_and_byte_limits_are_exact() -> void:
	var at_keys = _hello()
	var i := 0
	while at_keys.size() < Capability.MAX_HELLO_KEYS:
		at_keys["x%d" % i] = 1
		i += 1
	var d = rules.evaluate(_info(), at_keys, 8)
	_assert_rejected(d, Capability.REASON_MALFORMED_HELLO, "%d keys are not oversized" % Capability.MAX_HELLO_KEYS)
	assert_eq(d.detail, "unknown_field")
	at_keys["capability_version"] = 2
	_assert_rejected(rules.evaluate(_info(), at_keys, 8), Capability.REASON_CAPABILITY_MISMATCH, "newer peer at the key limit")
	# A newer peer whose hello is exactly MAX_HELLO_BYTES long is still read.
	var at_bytes = _hello({"capability_version": 2, "padding": ""})
	at_bytes["padding"] = _pad("p", Capability.MAX_HELLO_BYTES - var2bytes(at_bytes).size())
	assert_eq(var2bytes(at_bytes).size(), Capability.MAX_HELLO_BYTES)
	_assert_rejected(rules.evaluate(_info(), at_bytes, 8), Capability.REASON_CAPABILITY_MISMATCH, "exactly at the byte limit")
	at_bytes["padding"] += "p"
	var over = rules.evaluate(_info(), at_bytes, 8)
	_assert_rejected(over, Capability.REASON_OVERSIZED_HELLO, "one byte over")
	assert_eq(over.detail, "bytes")


# [hello overrides, reason, detail]; each limit is probed at and just past it.
func _field_limit_cases() -> Array:
	var none: String = Capability.REASON_NONE
	var malformed: String = Capability.REASON_MALFORMED_HELLO
	var mods_at = _info().mods
	mods_at.append({"id": _pad("M-", Capability.MAX_ID_LENGTH), "version": _pad("1.", Capability.MAX_VERSION_LENGTH)})
	var cases := [
		[{"extension_id": _pad("X-", Capability.MAX_ID_LENGTH)}, Capability.REASON_EXTENSION_ID_MISMATCH, ""],
		[{"extension_id": _pad("X-", Capability.MAX_ID_LENGTH + 1)}, malformed, "extension_id"],
		[{"capability_version": Capability.MAX_CAPABILITY_VERSION}, Capability.REASON_CAPABILITY_MISMATCH, ""],
		[{"capability_version": Capability.MAX_CAPABILITY_VERSION + 1}, malformed, "capability_version"],
		[{"capability_version": -1}, malformed, "capability_version"],
		[{"game_version": _pad("1.", Capability.MAX_TEXT_LENGTH)}, Capability.REASON_GAME_VERSION_MISMATCH, ""],
		[{"game_version": _pad("1.", Capability.MAX_TEXT_LENGTH + 1)}, malformed, "game_version"],
		[{"engine_version": _pad("3.", Capability.MAX_TEXT_LENGTH)}, Capability.REASON_ENGINE_VERSION_MISMATCH, ""],
		[{"engine_version": _pad("3.", Capability.MAX_TEXT_LENGTH + 1)}, malformed, "engine_version"],
		[{"upstream_fingerprint": FINGERPRINT.substr(0, 63) + "g"}, malformed, "upstream_fingerprint"],
		[{"upstream_fingerprint": FINGERPRINT.substr(0, 63)}, malformed, "upstream_fingerprint"],
		[{"upstream_fingerprint": FINGERPRINT + "0"}, malformed, "upstream_fingerprint"],
		[{"capacity": Capability.MAX_PEER_CAPACITY}, none, ""],
		[{"capacity": Capability.MAX_PEER_CAPACITY + 1}, malformed, "capacity"],
		[{"capacity": -1}, malformed, "capacity"],
		[{"dlc": [_pad("d_", Capability.MAX_ID_LENGTH)]}, Capability.REASON_DLC_MISMATCH, ""],
		[{"dlc": [_pad("d_", Capability.MAX_ID_LENGTH + 1)]}, malformed, "dlc"],
		[{"dlc": [""]}, malformed, "dlc"],
		[{"mods": mods_at}, none, ""],
		[{"mods": [{"id": _pad("M-", Capability.MAX_ID_LENGTH + 1), "version": "1.0.0"}]}, malformed, "mods"],
		[{"mods": [{"id": "A-B", "version": _pad("1.", Capability.MAX_VERSION_LENGTH + 1)}]}, malformed, "mods"],
		[{"mods": [{"id": "A-B", "version": 5}]}, malformed, "mods"],
		[{"mods": [{"id": "A-B", "version": ""}]}, malformed, "mods"],
		[{"mods": [{"id": "A-B", "version": "1.0 beta"}]}, malformed, "mods"],
		[{"mods": [{"id": "A-B", "name": "1.0.0"}]}, malformed, "mods"],
	]
	return cases


func test_field_limits_are_exact() -> void:
	for item in _field_limit_cases():
		var label := "%s -> %s" % [str(item[0].keys()), item[1]]
		var d = rules.evaluate(_info(), _hello(item[0]), 8)
		if item[1] == Capability.REASON_NONE:
			assert_eq(d.mode, Capability.MODE_EXTENDED, "%s: %s %s" % [label, d.reason, d.detail])
		else:
			_assert_rejected(d, item[1], label)
			if not item[2].empty():
				assert_eq(d.detail, item[2], label)
		assert_eq(rules.validate_hello(_hello(item[0])).ok, item[1] != Capability.REASON_MALFORMED_HELLO, label)


func test_hello_at_every_limit_still_fits() -> void:
	var info = _info()
	var dlc := []
	for i in range(Capability.MAX_DLC):
		dlc.append(_pad("dlc_%d_" % i, Capability.MAX_ID_LENGTH))
	var mods := []
	for i in range(Capability.MAX_MODS):
		mods.append({"id": _pad("Mod%d-" % i, Capability.MAX_ID_LENGTH), "version": _pad("1.0.%d-" % i, Capability.MAX_VERSION_LENGTH)})
	info.dlc = dlc
	info.mods = mods
	var h = rules.build_hello(info)
	assert_true(rules.validate_hello(h).ok, rules.validate_hello(h).detail)
	assert_true(var2bytes(h).size() <= Capability.MAX_HELLO_BYTES, "var2bytes %d" % var2bytes(h).size())
	assert_true(to_json(h).length() <= Capability.MAX_HELLO_BYTES, "json %d" % to_json(h).length())
	var d = rules.evaluate(info, h, 8)
	assert_eq(d.mode, Capability.MODE_EXTENDED, "%s %s" % [d.reason, d.detail])
	var from_json = rules.evaluate(info, parse_json(to_json(h)), 8)
	assert_eq(from_json.mode, Capability.MODE_EXTENDED, "json at the limits: %s %s" % [from_json.reason, from_json.detail])


func test_json_and_binary_round_trips_are_accepted() -> void:
	var parsed = parse_json(to_json(_hello()))
	assert_eq(typeof(parsed.capability_version), TYPE_REAL, "JSON turns ints into floats")
	var host_from_json = parse_json(to_json(_info()))
	for n in range(5, 9):
		assert_eq(rules.evaluate(_info(), parsed, n).mode, Capability.MODE_EXTENDED, "json hello, capacity %d" % n)
		assert_eq(rules.evaluate(host_from_json, parsed, n).mode, Capability.MODE_EXTENDED, "json host info, capacity %d" % n)
		var binary = bytes2var(var2bytes(_hello()), false)
		assert_eq(rules.evaluate(_info(), binary, n).mode, Capability.MODE_EXTENDED, "var2bytes hello, capacity %d" % n)


func test_evaluate_leaves_inputs_untouched_and_repeats_its_answer() -> void:
	var info = _info()
	info.dlc = ["zz_dlc", "abyssal_terrors"]
	var h = rules.build_hello(info)
	h.dlc = ["zz_dlc", "abyssal_terrors"]
	h.mods = [h.mods[1], h.mods[0]]
	var info_before := var2str(info)
	var hello_before := var2str(h)
	var first = rules.evaluate(info, h, 8)
	var second = rules.evaluate(info, h, 8)
	assert_eq(first.mode, Capability.MODE_EXTENDED, "%s %s" % [first.reason, first.detail])
	assert_eq(var2str(second), var2str(first))
	assert_eq(var2str(info), info_before)
	assert_eq(var2str(h), hello_before)


func test_t17_unverified_upstream_closes_extended_sessions() -> void:
	var info = _info()
	info.upstream_fingerprint = OTHER_FINGERPRINT
	var peer = rules.build_hello(info)
	for n in range(5, 9):
		var d = rules.evaluate(info, peer, n)
		_assert_rejected(d, Capability.REASON_HOST_UNVERIFIED, "both sides on the same unknown upstream, capacity %d" % n)
		assert_eq(d.detail, "%s:%s" % [Capability.REASON_UPSTREAM_UNVERIFIED, OTHER_FINGERPRINT.substr(0, 12)])
	for n in range(1, 5):
		_assert_vanilla(rules.evaluate(info, peer, n), Capability.REASON_HOST_UNVERIFIED, "capacity %d stays open" % n)
	var candidate = _info()
	candidate.upstream_fingerprint = MOUSE_UI_FINGERPRINT
	assert_eq(rules.check_local_support(candidate).reason, Capability.REASON_UPSTREAM_UNVERIFIED, "only role=required entries verify the upstream")


func test_t17_unverified_game_or_engine_closes_extended_sessions() -> void:
	var game = _info()
	game.game_version = "1.1.16.0"
	var d = rules.evaluate(game, rules.build_hello(game), 8)
	_assert_rejected(d, Capability.REASON_HOST_UNVERIFIED, "game")
	assert_eq(d.detail, "game_version_unverified:1.1.16.0")
	var engine = _info()
	engine.engine_version = "3.6.stable"
	d = rules.evaluate(engine, rules.build_hello(engine), 8)
	_assert_rejected(d, Capability.REASON_HOST_UNVERIFIED, "engine")
	assert_eq(d.detail, "engine_version_unverified:3.6.stable")


func test_host_environment_problems_fail_closed() -> void:
	var no_record = _info()
	no_record.erase("supported")
	var no_list = _info()
	no_list.erase("incompatible_mods")
	var own_mouse_ui = _info()
	own_mouse_ui.mods.append({"id": MOUSE_UI, "version": "1.0.1"})
	var cases := [
		[{}, "info_invalid:extension_id"],
		[no_record, "support_record_invalid:supported"],
		[no_list, "info_invalid:incompatible_mods"],
		[own_mouse_ui, "local_incompatible_mod:%s" % MOUSE_UI],
	]
	for item in cases:
		for n in range(5, 9):
			var d = rules.evaluate(item[0], _hello(), n)
			_assert_rejected(d, Capability.REASON_HOST_UNVERIFIED, "%s capacity %d" % [item[1], n])
			assert_eq(d.detail, item[1])
		_assert_vanilla(rules.evaluate(item[0], null, 4), Capability.REASON_HOST_UNVERIFIED, item[1])


func test_check_local_support_reasons() -> void:
	assert_eq(rules.check_local_support(_info()).ok, true)
	var cases := []
	var info = _info()
	info.supported = "x"
	cases.append([info, Capability.REASON_RECORD_INVALID, "supported"])
	info = _info()
	info.supported.game_versions = "1.1.15.4"
	cases.append([info, Capability.REASON_RECORD_INVALID, "game_versions"])
	info = _info()
	info.supported.engine_versions = [5]
	cases.append([info, Capability.REASON_RECORD_INVALID, "engine_versions"])
	info = _info()
	info.supported.upstream = [{"id": "six666-BrotatoOnline"}]
	cases.append([info, Capability.REASON_RECORD_INVALID, "upstream"])
	info = _info()
	info.supported.network_capability_version = "1"
	cases.append([info, Capability.REASON_RECORD_INVALID, "network_capability_version"])
	info = _info()
	info.supported.extension_id = "Other-Extension"
	cases.append([info, Capability.REASON_RECORD_MISMATCH, "extension_id"])
	info = _info()
	info.supported.extension_version = "0.1.1"
	cases.append([info, Capability.REASON_RECORD_MISMATCH, "extension_version"])
	info = _info()
	info.supported.network_capability_version = 2
	cases.append([info, Capability.REASON_RECORD_MISMATCH, "capability_version"])
	info = _info()
	info.supported.game_versions = []
	cases.append([info, Capability.REASON_GAME_UNVERIFIED, "1.1.15.4"])
	info = _info()
	info.supported.engine_versions = ["3.6.stable"]
	cases.append([info, Capability.REASON_ENGINE_UNVERIFIED, "3.7.dev.custom_build.74e86be54"])
	info = _info()
	info.supported.upstream = []
	cases.append([info, Capability.REASON_UPSTREAM_UNVERIFIED, FINGERPRINT.substr(0, 12)])
	info = _info()
	info.mods.append({"id": MOUSE_UI, "version": "1.0.1"})
	cases.append([info, Capability.REASON_LOCAL_INCOMPATIBLE_MOD, MOUSE_UI])
	info = _info()
	info.capacity = 0
	cases.append([info, Capability.REASON_INFO_INVALID, "capacity"])
	info = _info()
	info.incompatible_mods = MOUSE_UI
	cases.append([info, Capability.REASON_INFO_INVALID, "incompatible_mods"])
	info = _info()
	info.supported.extension_id = 5
	cases.append([info, Capability.REASON_RECORD_INVALID, "extension_id"])
	info = _info()
	info.supported.erase("extension_version")
	cases.append([info, Capability.REASON_RECORD_INVALID, "extension_version"])
	info = _info()
	info.supported.upstream = "six666-BrotatoOnline"
	cases.append([info, Capability.REASON_RECORD_INVALID, "upstream"])
	info = _info()
	info.supported.upstream = [5]
	cases.append([info, Capability.REASON_RECORD_INVALID, "upstream"])
	info = _info()
	info.supported.upstream[0].id = "Someone-OtherUpstream"
	cases.append([info, Capability.REASON_UPSTREAM_UNVERIFIED, FINGERPRINT.substr(0, 12)])
	for item in cases:
		var r = rules.check_local_support(item[0])
		assert_false(r.ok, "%s %s" % [item[1], item[2]])
		assert_eq(r.reason, item[1], item[2])
		assert_eq(r.detail, item[2], item[1])


func test_shipped_compatibility_record_verifies_the_locked_environment() -> void:
	var f := File.new()
	assert_eq(f.open(COMPAT_PATH, File.READ), OK, COMPAT_PATH)
	if not f.is_open():
		return
	var record = parse_json(f.get_as_text())
	f.close()
	assert_eq(typeof(record), TYPE_DICTIONARY)
	if typeof(record) != TYPE_DICTIONARY:
		return
	var info = _info()
	info.supported = record
	info.extension_version = record.extension_version
	info.capability_version = record.network_capability_version
	var local = rules.check_local_support(info)
	assert_true(local.ok, "%s %s" % [local.reason, local.detail])
	assert_eq(rules.evaluate(info, rules.build_hello(info), 8).mode, Capability.MODE_EXTENDED)


func test_t13_extended_continue_needs_a_matching_extension() -> void:
	var info = _info()
	info.capability_version = 2
	info.supported.network_capability_version = 2
	for n in [6, 8]:
		_assert_rejected(rules.evaluate(info, null, n), Capability.REASON_EXTENSION_MISSING, "uninstalled, capacity %d" % n)
		_assert_rejected(rules.evaluate(info, _hello({"capability_version": 1}), n), Capability.REASON_CAPABILITY_MISMATCH, "older protocol, capacity %d" % n)
		_assert_rejected(rules.evaluate(info, _hello({"capability_version": 2, "extension_version": "0.0.5"}), n), Capability.REASON_EXTENSION_VERSION_MISMATCH, "older release, capacity %d" % n)
		assert_eq(rules.evaluate(info, _hello({"capability_version": 2}), n).mode, Capability.MODE_EXTENDED, "capacity %d" % n)
	_assert_vanilla(rules.evaluate(info, null, 4), Capability.REASON_EXTENSION_MISSING, "four-player continue stays open")


func test_t15_dlc_sets_must_match_exactly() -> void:
	var cases := [
		[[], [], true],
		[["abyssal_terrors"], [], false],
		[[], ["abyssal_terrors"], false],
		[["a_dlc", "b_dlc"], ["b_dlc", "a_dlc"], true],
		[["a_dlc", "b_dlc"], ["a_dlc", "c_dlc"], false],
		[["a_dlc"], ["a_dlc", "b_dlc"], false],
	]
	for item in cases:
		var info = _info()
		info.dlc = item[0]
		var label := "host %s peer %s" % [str(item[0]), str(item[1])]
		for n in range(5, 9):
			var d = rules.evaluate(info, _hello({"dlc": item[1]}), n)
			if item[2]:
				assert_eq(d.mode, Capability.MODE_EXTENDED, label)
			else:
				_assert_rejected(d, Capability.REASON_DLC_MISMATCH, label)
		var vanilla = rules.evaluate(info, _hello({"dlc": item[1]}), 2)
		_assert_vanilla(vanilla, Capability.REASON_NONE if item[2] else Capability.REASON_DLC_MISMATCH, label)
	var missing = rules.evaluate(_info(), _hello({"dlc": []}), 8)
	assert_eq(missing.detail, "host=abyssal_terrors peer=none")


func test_result_round_trip_keeps_the_decision() -> void:
	var decisions := [
		rules.evaluate(_info(), _hello(), 8),
		rules.evaluate(_info(), null, 3),
		rules.evaluate(_info(), _hello({"capability_version": 2}), 3),
		rules.evaluate(_info(), _hello({"capability_version": 2}), 7),
		rules.evaluate(_info(), _hello({"mods": [{"id": MOUSE_UI, "version": "1.0.1"}]}), 5),
		rules.evaluate(_info(), _hello({"upstream_fingerprint": OTHER_FINGERPRINT}), 6),
		rules.evaluate(_info(), null, 8),
		rules.evaluate(_info(), null, 9),
	]
	for d in decisions:
		var msg = rules.build_result(d)
		var label := "%s/%s" % [d.reason, d.note]
		assert_eq(msg.msg_type, Capability.MSG_RESULT, label)
		var back = rules.read_result(parse_json(to_json(msg)))
		assert_true(back.ok, label)
		for key in ["accepted", "reason", "mode", "note", "detail"]:
			assert_eq(back[key], d[key], "%s %s" % [label, key])


func test_build_result_turns_inconsistent_decisions_into_rejections() -> void:
	var bad := [
		{},
		{"accepted": true, "reason": "capability_mismatch", "mode": Capability.MODE_EXTENDED},
		{"accepted": true, "reason": "", "mode": Capability.MODE_NONE},
		{"accepted": false, "reason": "", "mode": Capability.MODE_NONE},
		{"accepted": false, "reason": "capability_mismatch", "mode": Capability.MODE_EXTENDED},
		{"accepted": "true", "reason": "", "mode": Capability.MODE_EXTENDED},
		{"accepted": 1, "reason": "", "mode": Capability.MODE_EXTENDED},
		{"accepted": true, "reason": "", "mode": "turbo"},
		{"accepted": false, "reason": "Bad Reason", "mode": Capability.MODE_NONE},
		{"accepted": true, "reason": "", "mode": Capability.MODE_EXTENDED, "detail": 5},
	]
	for i in range(bad.size()):
		var msg = rules.build_result(bad[i])
		assert_eq(msg.accepted, false, "case %d" % i)
		assert_eq(msg.reason, Capability.REASON_INVALID_DECISION, "case %d" % i)
		assert_eq(msg.mode, Capability.MODE_NONE, "case %d" % i)
		var back = rules.read_result(msg)
		assert_true(back.ok, "fallback result is readable, case %d" % i)
		assert_false(back.accepted, "case %d" % i)


func test_read_result_rejects_malformed_messages() -> void:
	var good = rules.build_result(rules.evaluate(_info(), _hello(), 8))
	var cases := [null, "x", [], {}]
	var variants := [
		{"msg_type": Capability.MSG_HELLO},
		{"accepted": "true"},
		{"mode": Capability.MODE_NONE},
		{"reason": "capability_mismatch"},
		{"mode": "turbo"},
		{"detail": "[color=red]x[/color]"},
		{"detail": _pad("d", Capability.MAX_DETAIL_LENGTH + 1)},
		{"note": _pad("n", Capability.MAX_REASON_LENGTH + 1)},
		{"padding": _pad("p", Capability.MAX_RESULT_BYTES)},
	]
	for v in variants:
		var msg = good.duplicate()
		for key in v:
			msg[key] = v[key]
		cases.append(msg)
	var many = good.duplicate()
	for i in range(Capability.MAX_RESULT_KEYS):
		many["x%d" % i] = 1
	cases.append(many)
	var int_key = good.duplicate()
	int_key[3] = "x"
	cases.append(int_key)
	for i in range(cases.size()):
		var r = rules.read_result(cases[i])
		assert_false(r.ok, "case %d" % i)
		assert_false(r.accepted, "case %d" % i)
		assert_eq(r.reason, Capability.REASON_MALFORMED_RESULT, "case %d" % i)
		assert_eq(r.mode, Capability.MODE_NONE, "case %d" % i)


func test_read_result_tolerates_newer_hosts() -> void:
	var msg = rules.build_result(rules.evaluate(_info(), _hello(), 8))
	msg["host_hint"] = "added later"
	msg.erase("note")
	msg.erase("detail")
	var r = rules.read_result(msg)
	assert_true(r.ok)
	assert_eq(r.mode, Capability.MODE_EXTENDED)
	assert_eq(r.note, "")
	assert_eq(r.detail, "")


func test_result_key_and_byte_limits_are_exact() -> void:
	var at_keys = rules.build_result(rules.evaluate(_info(), _hello(), 8))
	var i := 0
	while at_keys.size() < Capability.MAX_RESULT_KEYS:
		at_keys["x%d" % i] = 1
		i += 1
	assert_true(rules.read_result(at_keys).ok, "%d keys" % Capability.MAX_RESULT_KEYS)
	at_keys["one_more"] = 1
	assert_false(rules.read_result(at_keys).ok, "%d keys" % (Capability.MAX_RESULT_KEYS + 1))
	var at_bytes = rules.build_result(rules.evaluate(_info(), _hello(), 8))
	at_bytes["padding"] = ""
	at_bytes["padding"] = _pad("p", Capability.MAX_RESULT_BYTES - var2bytes(at_bytes).size())
	assert_eq(var2bytes(at_bytes).size(), Capability.MAX_RESULT_BYTES)
	assert_true(rules.read_result(at_bytes).ok, "exactly at the byte limit")
	at_bytes["padding"] += "p"
	assert_false(rules.read_result(at_bytes).ok, "one byte over")


func test_mode_for_capacity_follows_the_capacity_policy() -> void:
	for n in [-1, 0, 9, 16]:
		assert_eq(rules.mode_for_capacity(n), Capability.MODE_NONE, "capacity %d" % n)
	for n in range(1, 9):
		var expected: String = Capability.MODE_VANILLA_COMPAT if n <= 4 else Capability.MODE_EXTENDED
		assert_eq(rules.mode_for_capacity(n), expected, "capacity %d" % n)
		var d = rules.evaluate(_info(), _hello(), n)
		assert_eq(d.mode, expected, "evaluate agrees, capacity %d" % n)


func test_record_candidates_block_extended_sessions_without_a_list() -> void:
	# compatibility.json lists OnlineMouseUI as a compatibility-candidate, so it
	# blocks 5..8 player sessions even if the adapter passes an empty list (R07).
	var host = _info()
	host.incompatible_mods = []
	var own = host.duplicate(true)
	own.mods.append({"id": MOUSE_UI, "version": "1.0.1"})
	var local = rules.check_local_support(own)
	assert_eq(local.reason, Capability.REASON_LOCAL_INCOMPATIBLE_MOD)
	assert_eq(local.detail, MOUSE_UI)
	var peer_mods = _info().mods
	peer_mods.append({"id": MOUSE_UI, "version": "1.0.1"})
	for n in range(5, 9):
		var d = rules.evaluate(own, _hello(), n)
		_assert_rejected(d, Capability.REASON_HOST_UNVERIFIED, "host runs the candidate, capacity %d" % n)
		assert_eq(d.detail, "%s:%s" % [Capability.REASON_LOCAL_INCOMPATIBLE_MOD, MOUSE_UI])
		var p = rules.evaluate(host, _hello({"mods": peer_mods}), n)
		_assert_rejected(p, Capability.REASON_INCOMPATIBLE_MOD, "peer runs the candidate, capacity %d" % n)
		assert_eq(p.detail, MOUSE_UI)
	for n in range(1, 5):
		_assert_vanilla(rules.evaluate(own, _hello(), n), Capability.REASON_HOST_UNVERIFIED, "capacity %d stays open" % n)
		_assert_vanilla(rules.evaluate(host, _hello({"mods": peer_mods}), n), Capability.REASON_INCOMPATIBLE_MOD, "capacity %d stays open" % n)
	assert_eq(host.incompatible_mods, [], "the caller's list is not extended in place")
	# Once the record no longer calls it a candidate, only the list decides.
	var verified = host.duplicate(true)
	verified.supported.upstream[1].role = "verified"
	assert_eq(rules.evaluate(verified, _hello({"mods": peer_mods}), 8).mode, Capability.MODE_EXTENDED)
	verified.incompatible_mods = [MOUSE_UI]
	_assert_rejected(rules.evaluate(verified, _hello({"mods": peer_mods}), 8), Capability.REASON_INCOMPATIBLE_MOD, "explicit list")
	# Upper-case fingerprints in the record still verify.
	var upper = _info()
	upper.supported.upstream[0].normalized_fingerprint = FINGERPRINT.to_upper()
	assert_true(rules.check_local_support(upper).ok, "upper-case record fingerprint")


func test_client_decision_follows_the_host_result() -> void:
	var peers := [
		["matching", _hello()],
		["capability", _hello({"capability_version": 2})],
		["dlc", _hello({"dlc": []})],
		["mouse_ui", _hello({"mods": [{"id": MOUSE_UI, "version": "1.0.1"}]})],
		["malformed", _hello({"capacity": "8"})],
	]
	for n in range(1, 9):
		for item in peers:
			var host = rules.evaluate(_info(), item[1], n)
			var label := "%s capacity %d" % [item[0], n]
			assert_true(host.reply, label)
			var wire = parse_json(to_json(rules.build_result(host)))
			var client = rules.client_decision(wire, n)
			for key in ["accepted", "reason", "mode", "note", "detail"]:
				assert_eq(client[key], host[key], "%s %s" % [label, key])
			assert_not_has(client, "reply", label)


func test_client_without_a_result() -> void:
	for n in range(1, 9):
		for item in [[null, Capability.REASON_HANDSHAKE_TIMEOUT], ["garbage", Capability.REASON_MALFORMED_RESULT], [{}, Capability.REASON_MALFORMED_RESULT]]:
			var d = rules.client_decision(item[0], n)
			var label := "%s capacity %d" % [item[1], n]
			if n <= 4:
				_assert_vanilla(d, item[1], label)
			else:
				_assert_rejected(d, item[1], label)
				assert_eq(d.note, Capability.REASON_NONE, label)
	for n in [0, -1, 9, 16]:
		var r = rules.client_decision(rules.build_result(rules.evaluate(_info(), _hello(), 8)), n)
		_assert_rejected(r, Capability.REASON_INVALID_CAPACITY, "capacity %d" % n)
		_assert_rejected(rules.client_decision(null, n), Capability.REASON_INVALID_CAPACITY, "null, capacity %d" % n)


func test_client_refuses_a_mode_that_does_not_fit_the_lobby() -> void:
	var vanilla = rules.build_result(rules.evaluate(_info(), _hello(), 4))
	var extended = rules.build_result(rules.evaluate(_info(), _hello(), 8))
	assert_eq(vanilla.mode, Capability.MODE_VANILLA_COMPAT)
	assert_eq(extended.mode, Capability.MODE_EXTENDED)
	for n in range(5, 9):
		var d = rules.client_decision(vanilla, n)
		_assert_rejected(d, Capability.REASON_MODE_MISMATCH, "dormant in an extended lobby, capacity %d" % n)
		assert_eq(d.detail, "host=vanilla_compat session=%d" % n)
	for n in range(1, 5):
		var d = rules.client_decision(extended, n)
		_assert_rejected(d, Capability.REASON_MODE_MISMATCH, "extended in a vanilla lobby, capacity %d" % n)
		assert_eq(d.detail, "host=extended session=%d" % n)
	# A host's rejection stands, also in 1..4 lobbies.
	var rejected = rules.build_result(rules.evaluate(_info(), null, 9))
	for n in range(1, 9):
		_assert_rejected(rules.client_decision(rejected, n), Capability.REASON_INVALID_CAPACITY, "capacity %d" % n)


func test_result_detail_is_display_safe() -> void:
	var d = {"accepted": false, "reason": Capability.REASON_INCOMPATIBLE_MOD, "mode": Capability.MODE_NONE, "detail": "[b]x[/b]" + _pad("y", 400)}
	var msg = rules.build_result(d)
	assert_eq(msg.reason, Capability.REASON_INCOMPATIBLE_MOD)
	assert_true(msg.detail.length() <= Capability.MAX_DETAIL_LENGTH, "length %d" % msg.detail.length())
	assert_eq(msg.detail.find("["), -1)
	assert_true(msg.detail.begins_with("_b_x_/b_y"), msg.detail)
	assert_true(rules.read_result(msg).ok)


func test_timeout_boundaries_follow_the_ten_second_budget() -> void:
	assert_eq(Capability.HANDSHAKE_TIMEOUT_MSEC, 10000)
	var t = rules.check_timeout(1000, 1000)
	assert_false(t.expired)
	assert_eq(t.remaining_msec, 10000)
	t = rules.check_timeout(10999, 1000)
	assert_false(t.expired)
	assert_eq(t.remaining_msec, 1)
	t = rules.check_timeout(11000, 1000)
	assert_true(t.expired, "expires exactly at the budget")
	assert_eq(t.reason, Capability.REASON_NONE)
	assert_true(rules.check_timeout(90000, 1000).expired)
	assert_eq(rules.check_timeout(2999, 1000, 2000).remaining_msec, 1)
	assert_true(rules.check_timeout(3000, 1000, 2000).expired)
	assert_true(rules.check_timeout(0, 0, 1).remaining_msec == 1)


func test_invalid_timers_expire_instead_of_waiting_forever() -> void:
	var cases := [[5000, 1000, 0], [5000, 1000, -1], [5000, 1000, 10001], [999, 1000, 10000], [5000, -1, 10000]]
	for c in cases:
		var t = rules.check_timeout(c[0], c[1], c[2])
		assert_true(t.expired, str(c))
		assert_eq(t.reason, Capability.REASON_INVALID_TIMER, str(c))
		assert_eq(t.remaining_msec, 0, str(c))


func test_waiting_out_the_timeout_then_deciding_for_every_capacity() -> void:
	for n in range(1, 9):
		var started := 500
		var now := started
		var polls := 0
		while not rules.check_timeout(now, started).expired and polls < 100:
			now += 250
			polls += 1
		assert_eq(now - started, Capability.HANDSHAKE_TIMEOUT_MSEC, "capacity %d" % n)
		var d = rules.evaluate(_info(), null, n)
		var c = rules.client_decision(null, n)
		if n <= 4:
			_assert_vanilla(d, Capability.REASON_EXTENSION_MISSING, "capacity %d" % n)
			_assert_vanilla(c, Capability.REASON_HANDSHAKE_TIMEOUT, "client, capacity %d" % n)
		else:
			_assert_rejected(d, Capability.REASON_EXTENSION_MISSING, "capacity %d" % n)
			_assert_rejected(c, Capability.REASON_HANDSHAKE_TIMEOUT, "client, capacity %d" % n)


func test_parse_semver() -> void:
	var ok = rules.parse_semver("10.20.30")
	assert_true(ok.ok)
	assert_eq([ok.major, ok.minor, ok.patch], [10, 20, 30])
	assert_true(rules.parse_semver("0.1.0").ok)
	assert_true(rules.parse_semver("999999999.0.0").ok)
	for bad in ["", "1", "1.0", "1.0.0.0", "v1.0.0", "01.0.0", "1.00.0", "1.0.0-beta", "1.0.0+build", "1..0", " 1.0.0", "-1.0.0", "+1.0.0", "1.0.-1", "1000000000.0.0", 1, null, 1.0]:
		var r = rules.parse_semver(bad)
		assert_false(r.ok, str(bad))
		assert_eq(r.reason, Capability.REASON_INVALID_SEMVER, str(bad))


func test_compare_semver_is_numeric() -> void:
	var cases := [["1.2.3", "1.2.4", -1], ["1.10.0", "1.9.0", 1], ["2.0.0", "10.0.0", -1], ["0.1.0", "0.1.0", 0], ["3.0.0", "2.99.99", 1], ["1.0.10", "1.0.9", 1]]
	for c in cases:
		var r = rules.compare_semver(c[0], c[1])
		assert_true(r.ok, str(c))
		assert_eq(r.order, c[2], str(c))
	assert_false(rules.compare_semver("1.0", "1.0.0").ok)
	assert_false(rules.compare_semver("1.0.0", null).ok)


func test_semver_compatible_matrix() -> void:
	var cases := [
		["1.0.0", "1.9.9", true], ["1.2.0", "1.0.5", true], ["2.0.0", "1.9.9", false],
		["0.1.0", "0.1.5", true], ["0.1.0", "0.2.0", false], ["0.0.1", "0.0.2", true],
		["1.0.0", "1.0", false], ["bad", "bad", false],
	]
	for c in cases:
		assert_eq(rules.semver_compatible(c[0], c[1]), c[2], str(c))
		assert_eq(rules.semver_compatible(c[1], c[0]), c[2], "symmetric %s" % str(c))
