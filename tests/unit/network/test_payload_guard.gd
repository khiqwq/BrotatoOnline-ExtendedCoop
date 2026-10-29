extends "res://tests/runner/test_case.gd"

const PayloadGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/payload_guard.gd")

const BUY_SCHEMA := {
	"type": "dict",
	"fields": {
		"action_id": {"type": "int", "min": 1, "max": 2147483647},
		"player_index": {"type": "player_index"},
		"shop_slot": {"type": "int", "min": 0, "max": 5},
		"item_id": {"type": "string", "min_len": 1, "max_len": 16},
		"kind": {"type": "string", "allowed": ["buy", "sell"]},
		"locked": {"type": "bool", "optional": true},
		"note": {"type": "string", "max_len": 8, "optional": true, "nullable": true},
		"slots": {"type": "array", "max_len": 4, "min_len": 0, "optional": true, "items": {"type": "int", "min": 0, "max": 7}},
		"offer": {"type": "dict", "optional": true, "fields": {
			"price": {"type": "number", "min": 0, "max": 9999},
			"weight": {"type": "float", "min": 0.0, "max": 1.0, "optional": true},
		}},
	},
}

# Any key may be added; only the structure pass looks at the extras.
const OPEN_SCHEMA := {"type": "dict", "allow_extra": true, "fields": {}}

const ALL_REASONS := [
	PayloadGuard.REASON_NONE, PayloadGuard.REASON_INVALID_CONFIG, PayloadGuard.REASON_BAD_SCHEMA,
	PayloadGuard.REASON_BAD_CONTEXT, PayloadGuard.REASON_WRONG_TYPE, PayloadGuard.REASON_FORBIDDEN_TYPE,
	PayloadGuard.REASON_BAD_KEY, PayloadGuard.REASON_MISSING_FIELD, PayloadGuard.REASON_UNKNOWN_FIELD,
	PayloadGuard.REASON_OUT_OF_RANGE, PayloadGuard.REASON_NOT_FINITE, PayloadGuard.REASON_NOT_ALLOWED,
	PayloadGuard.REASON_STRING_TOO_LONG, PayloadGuard.REASON_STRING_TOO_SHORT, PayloadGuard.REASON_TOO_MANY_ITEMS,
	PayloadGuard.REASON_TOO_FEW_ITEMS, PayloadGuard.REASON_TOO_DEEP, PayloadGuard.REASON_TOO_MANY_NODES,
	PayloadGuard.REASON_TOO_LARGE,
]

var guard


func before_each() -> void:
	guard = PayloadGuard.new()


func _buy(player_index = 0) -> Dictionary:
	return {"action_id": 7, "player_index": player_index, "shop_slot": 2, "item_id": "item_knife", "kind": "buy"}


func _with(field: String, value) -> Dictionary:
	var msg := _buy()
	msg[field] = value
	return msg


func _ctx(roster_count) -> Dictionary:
	return {"roster_count": roster_count}


func _expect(payload, reason: String, field: String, message: String, schema = BUY_SCHEMA, context = null) -> void:
	if typeof(context) == TYPE_NIL:
		context = _ctx(4)
	var r = guard.validate(payload, schema, context)
	assert_false(r.ok, message)
	assert_eq(r.reason, reason, message)
	assert_eq(r.field, field, message)


# Arrays nested `levels` deep: _nest(1) == [0], _nest(2) == [[0]].
func _nest(levels: int) -> Array:
	var value: Array = [0]
	for _i in range(levels - 1):
		value = [value]
	return value


func _string_of(length: int) -> String:
	var s := ""
	for _i in range(length):
		s += "a"
	return s


func test_example_schemas_are_well_formed() -> void:
	for schema in [BUY_SCHEMA, OPEN_SCHEMA]:
		var r = guard.check_schema(schema)
		assert_true(r.ok, "%s %s" % [r.reason, r.field])


func test_valid_purchase_passes_for_every_roster_size() -> void:
	for n in range(1, 9):
		for index in range(0, n):
			var r = guard.validate(_buy(index), BUY_SCHEMA, _ctx(n))
			assert_true(r.ok, "roster %d index %d: %s %s" % [n, index, r.reason, r.field])
			assert_eq(r.reason, PayloadGuard.REASON_NONE)
			assert_eq(r.field, "")


func test_player_index_outside_roster_is_rejected() -> void:
	for n in range(1, 9):
		for index in [n, n + 1, -1, 8, 100, 9223372036854775807]:
			if index >= 0 and index < n:
				continue
			_expect(_buy(index), PayloadGuard.REASON_OUT_OF_RANGE, "player_index", "roster %d index %d" % [n, index], BUY_SCHEMA, _ctx(n))


func test_ninth_player_index_rejected_with_full_roster() -> void:
	_expect(_buy(8), PayloadGuard.REASON_OUT_OF_RANGE, "player_index", "P9 on a roster of 8", BUY_SCHEMA, _ctx(8))
	assert_true(guard.validate(_buy(7), BUY_SCHEMA, _ctx(8)).ok, "P8 is legal")


func test_bad_roster_context_is_rejected() -> void:
	for context in [{}, _ctx(0), _ctx(9), _ctx(-1), _ctx("5"), _ctx(5.0), _ctx(null), [], "roster", 5]:
		var r = guard.validate(_buy(0), BUY_SCHEMA, context)
		assert_false(r.ok, var2str(context))
		assert_eq(r.reason, PayloadGuard.REASON_BAD_CONTEXT, var2str(context))
		assert_eq(r.field, "player_index", var2str(context))
	# null context is only a problem once a player_index spec is reached
	var no_index := {"type": "dict", "fields": {"n": {"type": "int", "min": 0, "max": 1}}}
	assert_true(guard.validate({"n": 1}, no_index).ok)
	assert_eq(guard.validate(_buy(0), BUY_SCHEMA).reason, PayloadGuard.REASON_BAD_CONTEXT)


func test_player_index_can_use_another_count_key() -> void:
	var schema := {"type": "dict", "fields": {"target": {"type": "player_index", "count": "member_count"}}}
	var context := {"roster_count": 8, "member_count": 3}
	assert_true(guard.validate({"target": 2}, schema, context).ok)
	_expect({"target": 3}, PayloadGuard.REASON_OUT_OF_RANGE, "target", "member_count bound", schema, context)
	_expect({"target": 0}, PayloadGuard.REASON_BAD_CONTEXT, "target", "missing key", schema, {"roster_count": 8})


func test_non_dictionary_payload_is_rejected() -> void:
	for payload in [null, [], [_buy()], 5, 1.5, "buy", true]:
		_expect(payload, PayloadGuard.REASON_WRONG_TYPE, "", var2str(payload))


func test_wrong_field_types_are_rejected() -> void:
	var cases := [
		["player_index", "1"], ["player_index", 1.0], ["player_index", true], ["player_index", [0]],
		["player_index", {}], ["player_index", null],
		# parse_json() would deliver this float; "int" must not accept it
		["action_id", 7.0], ["action_id", "7"],
		["shop_slot", false], ["item_id", 5], ["item_id", ["item_knife"]], ["kind", null],
		["locked", 1], ["locked", "true"], ["slots", {}], ["slots", "0,1"], ["offer", []],
	]
	for c in cases:
		_expect(_with(c[0], c[1]), PayloadGuard.REASON_WRONG_TYPE, c[0], "%s = %s" % [c[0], var2str(c[1])])


func test_missing_and_optional_fields() -> void:
	for field in ["action_id", "player_index", "shop_slot", "item_id", "kind"]:
		var msg := _buy()
		msg.erase(field)
		_expect(msg, PayloadGuard.REASON_MISSING_FIELD, field, field)
	var full := _buy()
	full["locked"] = true
	full["note"] = null
	full["slots"] = [0, 7]
	full["offer"] = {"price": 15}
	var r = guard.validate(full, BUY_SCHEMA, _ctx(4))
	assert_true(r.ok, "%s %s" % [r.reason, r.field])
	_expect(_with("offer", {"weight": 0.5}), PayloadGuard.REASON_MISSING_FIELD, "offer.price", "nested required")
	_expect(_with("locked", null), PayloadGuard.REASON_WRONG_TYPE, "locked", "optional is not nullable")


func test_unknown_fields_rejected_unless_allowed() -> void:
	_expect(_with("player_indx", 0), PayloadGuard.REASON_UNKNOWN_FIELD, "?", "typo field")
	_expect(_with("offer", {"price": 1, "discount": 1}), PayloadGuard.REASON_UNKNOWN_FIELD, "offer.?", "nested extra")
	assert_true(guard.validate({"anything": [1, "two", {"three": 3.0}]}, OPEN_SCHEMA).ok)


# Undeclared keys never appear in paths, safe-looking or not.
func test_undeclared_keys_are_masked_in_field_paths() -> void:
	for key in ["bad key", "line\nbreak", "%s", "", _string_of(33), "名字", _string_of(32), "kind_"]:
		_expect(_with(key, 1), PayloadGuard.REASON_UNKNOWN_FIELD, "?", "key %s" % var2str(key))
	_expect(_with("offer", {"price": 1, "x.y": 1}), PayloadGuard.REASON_UNKNOWN_FIELD, "offer.?", "dot in key")
	# a declared name is shown only while it is a plain identifier
	var odd_names := {"type": "dict", "fields": {"x.y": {"type": "int", "min": 0, "max": 1}, _string_of(32): {"type": "bool"}}}
	assert_true(guard.check_schema(odd_names).ok)
	_expect({"x.y": 5, _string_of(32): true}, PayloadGuard.REASON_OUT_OF_RANGE, "?", "unsafe declared name", odd_names)
	_expect({"x.y": 1, _string_of(32): 1}, PayloadGuard.REASON_WRONG_TYPE, _string_of(32), "32 char declared name", odd_names)


# R21: a Steam id (or any other payload text) used as a key never shows up in a
# field path, wherever it sits and whichever pass refuses the message; declared
# names next to it still do.
func test_identity_keys_never_reach_field_paths() -> void:
	var steam_id := "76561198012345678"
	var open_offer := {"type": "dict", "allow_extra": true, "fields": {
		"offer": {"type": "dict", "allow_extra": true, "fields": {
			"price": {"type": "number", "min": 0, "max": 9},
			"tags": {"type": "array", "optional": true, "items": {"type": "dict", "allow_extra": true, "fields": {
				"label": {"type": "string", "max_len": 8},
			}}},
		}},
	}}
	assert_true(guard.check_schema(open_offer).ok)
	var cases := [
		[_with(steam_id, 1), BUY_SCHEMA, PayloadGuard.REASON_UNKNOWN_FIELD, "?"],
		[_with("offer", {"price": 1, steam_id: 1}), BUY_SCHEMA, PayloadGuard.REASON_UNKNOWN_FIELD, "offer.?"],
		[_with("offer", {"price": 1, steam_id: _string_of(300)}), BUY_SCHEMA, PayloadGuard.REASON_STRING_TOO_LONG, "offer.?"],
		[{steam_id: _string_of(300)}, OPEN_SCHEMA, PayloadGuard.REASON_STRING_TOO_LONG, "?"],
		[{steam_id: {"price": NAN}}, OPEN_SCHEMA, PayloadGuard.REASON_NOT_FINITE, "?.?"],
		[{steam_id: [1, Vector2()]}, OPEN_SCHEMA, PayloadGuard.REASON_FORBIDDEN_TYPE, "?[1]"],
		[{"offer": {steam_id: _string_of(300)}}, open_offer, PayloadGuard.REASON_STRING_TOO_LONG, "offer.?"],
		[{"offer": {"tags": [{}, {steam_id: INF}]}}, open_offer, PayloadGuard.REASON_NOT_FINITE, "offer.tags[1].?"],
		[{"offer": {"tags": [{steam_id: 1, "label": _string_of(300)}]}}, open_offer, PayloadGuard.REASON_STRING_TOO_LONG, "offer.tags[0].label"],
		[{"offer": {"price": INF, steam_id: 1}}, open_offer, PayloadGuard.REASON_NOT_FINITE, "offer.price"],
		[{"offer": {steam_id: 1, "price": 10}}, open_offer, PayloadGuard.REASON_OUT_OF_RANGE, "offer.price"],
	]
	for c in cases:
		var r = guard.validate(c[0], c[1], _ctx(4))
		assert_eq(r.reason, c[2], c[3])
		assert_eq(r.field, c[3], c[3])
		assert_eq(str(r.field).find(steam_id), -1, c[3])


func test_non_string_keys_are_rejected() -> void:
	for key in [1, 1.5, null, true, [1], Vector2(1, 2)]:
		var msg := _buy()
		msg[key] = 1
		_expect(msg, PayloadGuard.REASON_BAD_KEY, "?", "key %s" % var2str(key))
	_expect(_with("offer", {"price": 1, 2: 3}), PayloadGuard.REASON_BAD_KEY, "offer.?", "nested int key")


func test_int_ranges_are_inclusive() -> void:
	for id in [1, 2, 2147483647]:
		assert_true(guard.validate(_with("action_id", id), BUY_SCHEMA, _ctx(4)).ok, "action_id %d" % id)
	for id in [0, -1, 2147483648, 9223372036854775807, -9223372036854775807 - 1]:
		_expect(_with("action_id", id), PayloadGuard.REASON_OUT_OF_RANGE, "action_id", "action_id %d" % id)
	assert_true(guard.validate(_with("shop_slot", 5), BUY_SCHEMA, _ctx(4)).ok)
	_expect(_with("shop_slot", 6), PayloadGuard.REASON_OUT_OF_RANGE, "shop_slot", "slot 6")


func test_int_allowed_list() -> void:
	var schema := {"type": "dict", "fields": {"choice": {"type": "int", "min": 0, "max": 9, "allowed": [1, 3]}}}
	assert_true(guard.validate({"choice": 3}, schema).ok)
	_expect({"choice": 2}, PayloadGuard.REASON_NOT_ALLOWED, "choice", "2 not allowed", schema)
	_expect({"choice": 3.0}, PayloadGuard.REASON_WRONG_TYPE, "choice", "float 3.0", schema)


func test_non_finite_numbers_are_rejected_everywhere() -> void:
	for v in [NAN, INF, -INF]:
		_expect(_with("offer", {"price": 1, "weight": v}), PayloadGuard.REASON_NOT_FINITE, "offer.weight", "float field %s" % str(v))
		_expect(_with("offer", {"price": v}), PayloadGuard.REASON_NOT_FINITE, "offer.price", "number field %s" % str(v))
		_expect({"extra": [1, v]}, PayloadGuard.REASON_NOT_FINITE, "?[1]", "extra field %s" % str(v), OPEN_SCHEMA)


func test_number_and_float_ranges() -> void:
	assert_true(guard.validate(_with("offer", {"price": 9999}), BUY_SCHEMA, _ctx(4)).ok, "int price")
	assert_true(guard.validate(_with("offer", {"price": 0.5, "weight": 1.0}), BUY_SCHEMA, _ctx(4)).ok, "float price")
	_expect(_with("offer", {"price": 10000}), PayloadGuard.REASON_OUT_OF_RANGE, "offer.price", "price above max")
	_expect(_with("offer", {"price": -0.01}), PayloadGuard.REASON_OUT_OF_RANGE, "offer.price", "price below min")
	_expect(_with("offer", {"price": 1e300}), PayloadGuard.REASON_OUT_OF_RANGE, "offer.price", "huge float")
	_expect(_with("offer", {"price": 1, "weight": 1}), PayloadGuard.REASON_WRONG_TYPE, "offer.weight", "int for float")
	_expect(_with("offer", {"price": 1, "weight": 1.5}), PayloadGuard.REASON_OUT_OF_RANGE, "offer.weight", "weight")


func test_string_limits() -> void:
	assert_true(guard.validate(_with("item_id", _string_of(16)), BUY_SCHEMA, _ctx(4)).ok, "16 chars")
	_expect(_with("item_id", _string_of(17)), PayloadGuard.REASON_STRING_TOO_LONG, "item_id", "17 chars")
	_expect(_with("item_id", ""), PayloadGuard.REASON_STRING_TOO_SHORT, "item_id", "empty")
	_expect(_with("kind", "steal"), PayloadGuard.REASON_NOT_ALLOWED, "kind", "enum")
	_expect(_with("kind", "BUY"), PayloadGuard.REASON_NOT_ALLOWED, "kind", "enum is case sensitive")
	# Length is in characters: 8 CJK characters fit a max_len of 8.
	assert_true(guard.validate(_with("note", "商店商店商店商店"), BUY_SCHEMA, _ctx(4)).ok, "8 CJK chars")
	_expect(_with("note", "商店商店商店商店商"), PayloadGuard.REASON_STRING_TOO_LONG, "note", "9 CJK chars")


func test_guard_string_limit_applies_without_schema_limit() -> void:
	var g = PayloadGuard.new(PayloadGuard.DEFAULT_MAX_ENCODED_SIZE, PayloadGuard.DEFAULT_MAX_DEPTH, PayloadGuard.DEFAULT_MAX_NODES, 10)
	assert_true(g.validate({"s": _string_of(10)}, OPEN_SCHEMA).ok)
	var r = g.validate({"s": _string_of(11)}, OPEN_SCHEMA)
	assert_eq(r.reason, PayloadGuard.REASON_STRING_TOO_LONG)
	assert_eq(r.field, "?")
	var declared := {"type": "dict", "fields": {"s": {"type": "string"}}}
	assert_eq(g.validate({"s": _string_of(11)}, declared).field, "s", "declared name")
	# Keys count as strings too.
	assert_eq(g.validate({_string_of(11): 1}, OPEN_SCHEMA).reason, PayloadGuard.REASON_STRING_TOO_LONG)


func test_array_limits_and_element_paths() -> void:
	assert_true(guard.validate(_with("slots", []), BUY_SCHEMA, _ctx(4)).ok, "empty")
	assert_true(guard.validate(_with("slots", [0, 1, 2, 7]), BUY_SCHEMA, _ctx(4)).ok, "4 items")
	_expect(_with("slots", [0, 1, 2, 3, 4]), PayloadGuard.REASON_TOO_MANY_ITEMS, "slots", "5 items")
	_expect(_with("slots", [0, 1, "2"]), PayloadGuard.REASON_WRONG_TYPE, "slots[2]", "string element")
	_expect(_with("slots", [0, [1]]), PayloadGuard.REASON_WRONG_TYPE, "slots[1]", "nested array element")
	_expect(_with("slots", [0, 8]), PayloadGuard.REASON_OUT_OF_RANGE, "slots[1]", "element range")
	_expect(_with("slots", [null]), PayloadGuard.REASON_WRONG_TYPE, "slots[0]", "null element")
	var schema := {"type": "dict", "fields": {"pick": {"type": "array", "min_len": 2, "max_len": 3, "items": {"type": "bool"}}}}
	_expect({"pick": [true]}, PayloadGuard.REASON_TOO_FEW_ITEMS, "pick", "below min_len", schema)


func test_nesting_depth_limit() -> void:
	# The payload dictionary is depth 1, so `levels` arrays inside make 1 + levels.
	var ok_payload := {"extra": _nest(PayloadGuard.DEFAULT_MAX_DEPTH - 1)}
	assert_true(guard.validate(ok_payload, OPEN_SCHEMA).ok, "depth 8")
	var r = guard.validate({"extra": _nest(PayloadGuard.DEFAULT_MAX_DEPTH)}, OPEN_SCHEMA)
	assert_eq(r.reason, PayloadGuard.REASON_TOO_DEEP, "depth 9")
	var expected_path := "?"
	for _i in range(PayloadGuard.DEFAULT_MAX_DEPTH - 1):
		expected_path += "[0]"
	assert_eq(r.field, expected_path)
	var deep = guard.validate({"extra": _nest(500)}, OPEN_SCHEMA)
	assert_eq(deep.reason, PayloadGuard.REASON_TOO_DEEP, "depth 501")


func test_self_referencing_payload_does_not_hang_or_crash() -> void:
	var loop := []
	loop.append(loop)
	var r = guard.validate({"extra": loop}, OPEN_SCHEMA)
	assert_eq(r.reason, PayloadGuard.REASON_TOO_DEEP)
	loop.clear()
	var dict_loop := {}
	dict_loop["self"] = dict_loop
	assert_eq(guard.validate(dict_loop, OPEN_SCHEMA).reason, PayloadGuard.REASON_TOO_DEEP)
	dict_loop.clear()


func test_collection_size_limit_covers_extras() -> void:
	var ints := []
	for i in range(PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE):
		ints.append(i)
	assert_true(guard.validate({"extra": ints}, OPEN_SCHEMA).ok, "64 items")
	ints.append(64)
	_expect({"extra": ints}, PayloadGuard.REASON_TOO_MANY_ITEMS, "?", "65 items", OPEN_SCHEMA)
	var keys := {}
	for i in range(PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE + 1):
		keys["k%d" % i] = i
	_expect(keys, PayloadGuard.REASON_TOO_MANY_ITEMS, "", "65 keys", OPEN_SCHEMA)


func test_node_budget_stops_wide_payloads() -> void:
	var g = PayloadGuard.new(1 << 20, 8, 20)
	var flat := []
	for i in range(18):
		flat.append(i)
	# dictionary + array + 18 ints = 20 nodes
	assert_true(g.validate({"extra": flat}, OPEN_SCHEMA).ok, "20 nodes")
	flat.append(18)
	_expect_with(g, {"extra": flat}, PayloadGuard.REASON_TOO_MANY_NODES, "?[18]", "21 nodes")
	# 8 x 8 x 8 small arrays stay within depth and width limits but not the budget
	var wide := []
	for _i in range(8):
		var mid := []
		for _j in range(8):
			mid.append([1, 2, 3, 4, 5, 6, 7, 8])
		wide.append(mid)
	assert_eq(guard.validate({"extra": wide}, OPEN_SCHEMA).reason, PayloadGuard.REASON_TOO_MANY_NODES)


func _expect_with(g, payload, reason: String, field: String, message: String) -> void:
	var r = g.validate(payload, OPEN_SCHEMA)
	assert_eq(r.reason, reason, message)
	assert_eq(r.field, field, message)


func test_encoded_size_limit_is_exact() -> void:
	var payload := {"a": _string_of(200), "b": _string_of(200), "c": _string_of(200)}
	var size := var2bytes(payload).size()
	var at_limit = PayloadGuard.new(size)
	assert_true(at_limit.validate(payload, OPEN_SCHEMA).ok, "exactly at the limit")
	var below = PayloadGuard.new(size - 1)
	var r = below.validate(payload, OPEN_SCHEMA)
	assert_eq(r.reason, PayloadGuard.REASON_TOO_LARGE)
	assert_eq(r.field, "")
	# Each string is within the 256 character limit; only the total is too big.
	var many := {}
	for i in range(40):
		many["s%d" % i] = _string_of(250)
	assert_eq(guard.validate(many, OPEN_SCHEMA).reason, PayloadGuard.REASON_TOO_LARGE)


func test_forbidden_types_are_rejected() -> void:
	var values := [Vector2(1, 2), Color(1, 0, 0), PoolByteArray([1, 2]), PoolIntArray([1]), NodePath("a"), Reference.new(), Transform2D()]
	for v in values:
		_expect({"extra": v}, PayloadGuard.REASON_FORBIDDEN_TYPE, "?", "type %d" % typeof(v), OPEN_SCHEMA)
	_expect(_with("player_index", Vector2(0, 0)), PayloadGuard.REASON_FORBIDDEN_TYPE, "player_index", "vector as index")


func test_bad_schemas_are_reported_not_crashing() -> void:
	var bad := [
		null, [], "dict", {}, {"type": "integer"}, {"type": 5},
		{"type": "int"}, {"type": "int", "min": 0}, {"type": "int", "min": 5, "max": 1},
		{"type": "int", "min": 0.5, "max": 1}, {"type": "float", "min": NAN, "max": 1.0},
		{"type": "float", "min": 0.0, "max": INF}, {"type": "number", "min": "0", "max": 1},
		{"type": "string", "maxlen": 5}, {"type": "string", "max_len": -1}, {"type": "string", "max_len": 1.5},
		{"type": "string", "min_len": 3, "max_len": 2}, {"type": "string", "allowed": [1]},
		{"type": "string", "allowed": []}, {"type": "int", "min": 0, "max": 9, "allowed": ["1"]},
		{"type": "int", "min": 0, "max": 1, "optional": "yes"}, {"type": "bool", "nullable": 1},
		{"type": "array"}, {"type": "array", "items": "int"}, {"type": "dict", "fields": []},
		{"type": "dict", "fields": {"a": 5}}, {"type": "dict", "fields": {1: {"type": "bool"}}},
		{"type": "dict", "allow_extra": "true"}, {"type": "player_index", "count": ""},
		{"type": "player_index", "count": 5}, {"type": "bool", "min": 0, "max": 1},
	]
	for schema in bad:
		var r = guard.check_schema(schema)
		assert_false(r.ok, var2str(schema))
		assert_eq(r.reason, PayloadGuard.REASON_BAD_SCHEMA, var2str(schema))
		var v = guard.validate({"x": 1}, schema, _ctx(4))
		assert_false(v.ok, var2str(schema))


func test_schema_error_paths_point_at_the_bad_spec() -> void:
	var schema := {"type": "dict", "fields": {
		"ok": {"type": "bool"},
		"list": {"type": "array", "items": {"type": "dict", "fields": {"n": {"type": "int", "min": 0}}}},
	}}
	var r = guard.check_schema(schema)
	assert_eq(r.reason, PayloadGuard.REASON_BAD_SCHEMA)
	assert_eq(r.field, "list[].n")
	# validate() finds it lazily, at the element that uses it
	var v = guard.validate({"ok": true, "list": [{"n": 1}]}, schema)
	assert_eq(v.reason, PayloadGuard.REASON_BAD_SCHEMA)
	assert_eq(v.field, "list[0].n")
	# a broken optional spec is caught even when the field is absent
	var opt := {"type": "dict", "fields": {"o": {"type": "int", "optional": true}}}
	assert_eq(guard.validate({}, opt).reason, PayloadGuard.REASON_BAD_SCHEMA)


# Schemas built at run time can repeat or share a sub-spec; check_schema() must
# still finish quickly with a reason, and validate() stays bounded by the payload.
func test_cyclic_or_shared_schemas_are_bounded() -> void:
	var cyclic := {"type": "dict", "fields": {}}
	cyclic.fields["next"] = {"type": "dict", "optional": true, "fields": cyclic.fields}
	assert_eq(guard.check_schema(cyclic).reason, PayloadGuard.REASON_BAD_SCHEMA, "cyclic")
	assert_true(guard.validate({}, cyclic).ok, "cyclic spec, absent field")
	assert_eq(guard.validate({"next": {"next": {}}}, cyclic).reason, PayloadGuard.REASON_NONE, "two levels")
	# each level names the next twice: 2^31 paths without a visit budget, but
	# within MAX_SCHEMA_DEPTH, so only the budget can stop it
	var shared := {"type": "bool"}
	for _i in range(31):
		shared = {"type": "dict", "fields": {"a": shared, "b": shared}}
	assert_eq(guard.check_schema(shared).reason, PayloadGuard.REASON_BAD_SCHEMA, "shared")
	assert_eq(guard.validate({"a": {"b": {}}}, shared).reason, PayloadGuard.REASON_MISSING_FIELD, "validate follows the payload")
	# a wide but finite schema stays well inside the budget
	var wide := {"type": "dict", "fields": {}}
	for i in range(PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE):
		wide.fields["f%d" % i] = {"type": "array", "items": {"type": "dict", "fields": {"x": {"type": "bool"}, "y": {"type": "bool"}}}}
	assert_true(guard.check_schema(wide).ok, "64 x 4 specs")
	cyclic.fields.clear()


func test_invalid_guard_config_rejects_everything() -> void:
	var configs := [[0, 8, 512, 256, 64], [8192, 0, 512, 256, 64], [8192, 8, 0, 256, 64], [8192, 8, 512, 0, 64], [8192, 8, 512, 256, -1]]
	for c in configs:
		var g = PayloadGuard.new(c[0], c[1], c[2], c[3], c[4])
		assert_false(g.is_valid(), var2str(c))
		var r = g.validate(_buy(), BUY_SCHEMA, _ctx(4))
		assert_eq(r.reason, PayloadGuard.REASON_INVALID_CONFIG, var2str(c))
	assert_true(PayloadGuard.new().is_valid())


func test_validation_does_not_modify_payload() -> void:
	var msg := _buy(3)
	msg["slots"] = [1, 2]
	msg["offer"] = {"price": 3.5}
	var before := var2str(msg)
	guard.validate(msg, BUY_SCHEMA, _ctx(4))
	guard.validate(msg, BUY_SCHEMA, _ctx(2))
	assert_eq(var2str(msg), before)


# Every single-field corruption of a valid message must be refused, and the
# reported field must be the one that was corrupted.
func test_each_corrupted_field_is_named() -> void:
	var corruptions := [null, "x", 1.5, -1, [], {}, true, 9223372036854775807]
	for field in ["action_id", "player_index", "shop_slot", "item_id", "kind"]:
		for bad in corruptions:
			if field == "item_id" and typeof(bad) == TYPE_STRING:
				continue
			var r = guard.validate(_with(field, bad), BUY_SCHEMA, _ctx(4))
			assert_false(r.ok, "%s = %s" % [field, var2str(bad)])
			assert_eq(r.field, field, "%s = %s" % [field, var2str(bad)])


# Seeded random garbage: never a script error, always a declared reason, and
# anything accepted really is a valid purchase.
func test_random_garbage_is_handled() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261028
	var accepted := 0
	for i in range(400):
		var payload = _random_message(rng)
		var n := rng.randi_range(1, 8)
		var r = guard.validate(payload, BUY_SCHEMA, _ctx(n))
		assert_eq(typeof(r.ok), TYPE_BOOL, "case %d" % i)
		assert_has(ALL_REASONS, r.reason, "case %d" % i)
		if r.ok:
			accepted += 1
			assert_true(_is_valid_buy(payload, n), "case %d accepted an invalid message" % i)
	# the generator mostly builds near-valid messages, so both paths are covered
	assert_true(accepted > 0, "some random messages are valid")
	assert_true(accepted < 400, "some random messages are invalid")


func _random_message(rng: RandomNumberGenerator):
	if rng.randi_range(0, 9) == 0:
		return _random_value(rng, 0)
	var msg := _buy(rng.randi_range(0, 7))
	for _i in range(rng.randi_range(0, 2)):
		var keys := ["action_id", "player_index", "shop_slot", "item_id", "kind", "locked", "junk"]
		var key: String = keys[rng.randi_range(0, keys.size() - 1)]
		if rng.randi_range(0, 3) == 0:
			msg.erase(key)
		else:
			msg[key] = _random_value(rng, 0)
	return msg


# Containers only near the top and short below it, so a case stays small.
func _random_value(rng: RandomNumberGenerator, depth: int):
	var kind := rng.randi_range(0, 9 if depth < 3 else 6)
	match kind:
		0:
			return null
		1:
			return rng.randi_range(0, 1) == 1
		2:
			return rng.randi_range(-3, 10)
		3:
			var big := [9223372036854775807, -9223372036854775807 - 1, 2147483648, 0]
			return big[rng.randi_range(0, big.size() - 1)]
		4:
			var floats := [NAN, INF, -INF, 0.5, 3.0, 1e300]
			return floats[rng.randi_range(0, floats.size() - 1)]
		5:
			return _string_of(rng.randi_range(0, 300))
		6:
			var words := ["buy", "sell", "item_knife", ""]
			return words[rng.randi_range(0, words.size() - 1)]
		7:
			var a := []
			for _i in range(rng.randi_range(0, 70 if depth == 0 else 4)):
				a.append(_random_value(rng, depth + 1))
			return a
		_:
			var d := {}
			for _i in range(rng.randi_range(0, 4)):
				d["k%d" % rng.randi_range(0, 9)] = _random_value(rng, depth + 1)
			return d


# Independent oracle for BUY_SCHEMA with only the required fields plus locked.
func _is_valid_buy(msg, roster_count: int) -> bool:
	if typeof(msg) != TYPE_DICTIONARY:
		return false
	for key in msg:
		if not (key in ["action_id", "player_index", "shop_slot", "item_id", "kind", "locked"]):
			return false
	for key in ["action_id", "player_index", "shop_slot", "item_id", "kind"]:
		if not msg.has(key):
			return false
	if typeof(msg.action_id) != TYPE_INT or msg.action_id < 1 or msg.action_id > 2147483647:
		return false
	if typeof(msg.player_index) != TYPE_INT or msg.player_index < 0 or msg.player_index >= roster_count:
		return false
	if typeof(msg.shop_slot) != TYPE_INT or msg.shop_slot < 0 or msg.shop_slot > 5:
		return false
	if typeof(msg.item_id) != TYPE_STRING or msg.item_id.length() < 1 or msg.item_id.length() > 16:
		return false
	if typeof(msg.kind) != TYPE_STRING or not (msg.kind in ["buy", "sell"]):
		return false
	if msg.has("locked") and typeof(msg.locked) != TYPE_BOOL:
		return false
	return true
