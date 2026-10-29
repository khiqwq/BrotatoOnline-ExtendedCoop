extends Reference
# Validates incoming message Dictionaries before they reach game logic
# (AP-011; F08 forged, oversized or malformed payloads). Two bounded passes:
#   1. structure, over the whole payload including fields a schema lets
#      through with allow_extra: nesting depth, node count, collection sizes,
#      string lengths, String keys, finite floats, plain types only (no Object,
#      Vector2, Pool*Array, ...); then the var2bytes size of the payload.
#   2. schema: required keys, exact types, ranges, enums, per-field limits.
# Every value is type-checked before use, so null, nested arrays, huge numbers,
# NaN or self-referencing containers produce a reason, never a script error.
# Result: {"ok": bool, "reason": REASON_*, "field": path}. The path is "" for
# the payload itself, "offer.price" for nested keys, "slots[2]" for elements.
# Only names the schema declares (and that are plain identifiers) appear in
# it; any other key, unknown or let through by allow_extra, shows as "?". So
# payload text never reaches logs (R21), not even a Steam id used as a key.
#
# Schema format: a spec is a Dictionary with "type" plus keys for that type.
#   any type      "optional": bool (a dict field may be absent), "nullable": bool
#   bool          -
#   int           "min", "max" (both required, inclusive), "allowed": [ints]
#   float         "min", "max" (required); NaN and INF are always rejected
#   number        int or float, "min", "max" (required)
#   player_index  int in 0..context[count]-1; "count" names the context key
#                 (default "roster_count"), which must hold an int 1..8
#   string        "min_len" (default 0), "max_len" (default guard limit),
#                 "allowed": [Strings]; lengths are in characters
#   array         "items": spec (required), "min_len", "max_len"
#   dict          "fields": {name: spec}, "allow_extra": bool (default false)
# Unknown spec keys are schema errors, so a typo such as "maxlen" cannot
# silently remove a limit; check_schema() checks a whole schema once at load.
# Example, a shop purchase:
#   const BUY_SCHEMA := {"type": "dict", "fields": {
#       "action_id": {"type": "int", "min": 1, "max": 2147483647},
#       "player_index": {"type": "player_index"},
#       "shop_slot": {"type": "int", "min": 0, "max": 5},
#       "item_id": {"type": "string", "min_len": 1, "max_len": 64},
#       "tags": {"type": "array", "max_len": 4, "optional": true,
#               "items": {"type": "string", "max_len": 16}},
#   }}
#   var r = guard.validate(msg, BUY_SCHEMA, {"roster_count": 6})
#   if not r.ok: log r.reason and r.field, drop the message
# Numbers must arrive with their real types (var2bytes/bytes2var or
# File.get_var with allow_objects=false). parse_json() turns every number into
# a float, which "int" rejects; convert JSON input before validating it.
# Pure rules: no autoloads, no scene tree.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const REASON_NONE := ""
const REASON_INVALID_CONFIG := "invalid_config"
const REASON_BAD_SCHEMA := "bad_schema"
const REASON_BAD_CONTEXT := "bad_context"
const REASON_WRONG_TYPE := "wrong_type"
const REASON_FORBIDDEN_TYPE := "forbidden_type"
const REASON_BAD_KEY := "bad_key"
const REASON_MISSING_FIELD := "missing_field"
const REASON_UNKNOWN_FIELD := "unknown_field"
const REASON_OUT_OF_RANGE := "out_of_range"
const REASON_NOT_FINITE := "not_finite"
const REASON_NOT_ALLOWED := "value_not_allowed"
const REASON_STRING_TOO_LONG := "string_too_long"
const REASON_STRING_TOO_SHORT := "string_too_short"
const REASON_TOO_MANY_ITEMS := "too_many_items"
const REASON_TOO_FEW_ITEMS := "too_few_items"
const REASON_TOO_DEEP := "too_deep"
const REASON_TOO_MANY_NODES := "too_many_nodes"
const REASON_TOO_LARGE := "payload_too_large"

const TYPE_NAME_BOOL := "bool"
const TYPE_NAME_INT := "int"
const TYPE_NAME_FLOAT := "float"
const TYPE_NAME_NUMBER := "number"
const TYPE_NAME_PLAYER_INDEX := "player_index"
const TYPE_NAME_STRING := "string"
const TYPE_NAME_ARRAY := "array"
const TYPE_NAME_DICT := "dict"

const DEFAULT_COUNT_KEY := "roster_count"
const COMMON_SPEC_KEYS := ["type", "optional", "nullable"]
const SPEC_KEYS := {
	TYPE_NAME_BOOL: [],
	TYPE_NAME_INT: ["min", "max", "allowed"],
	TYPE_NAME_FLOAT: ["min", "max"],
	TYPE_NAME_NUMBER: ["min", "max"],
	TYPE_NAME_PLAYER_INDEX: ["count"],
	TYPE_NAME_STRING: ["min_len", "max_len", "allowed"],
	TYPE_NAME_ARRAY: ["items", "min_len", "max_len"],
	TYPE_NAME_DICT: ["fields", "allow_extra"],
}

# Menu messages are a few hundred bytes; bigger messages pass their own limit.
const DEFAULT_MAX_ENCODED_SIZE := 8192
const DEFAULT_MAX_DEPTH := 8
const DEFAULT_MAX_NODES := 512
const DEFAULT_MAX_STRING_LENGTH := 256
const DEFAULT_MAX_COLLECTION_SIZE := 64
const MAX_SCHEMA_DEPTH := 32
# Specs check_schema() visits; stops a schema built at run time that shares or
# repeats sub-specs from taking exponential time.
const MAX_SCHEMA_NODES := 1024
const MAX_PATH_KEY_LENGTH := 32

var max_encoded_size: int = DEFAULT_MAX_ENCODED_SIZE
# Containers nested inside each other; {"a": [1]} has depth 2.
var max_depth: int = DEFAULT_MAX_DEPTH
# Every value counts once: containers, their elements and dictionary values.
var max_nodes: int = DEFAULT_MAX_NODES
var max_string_length: int = DEFAULT_MAX_STRING_LENGTH
# Elements of one Array or keys of one Dictionary.
var max_collection_size: int = DEFAULT_MAX_COLLECTION_SIZE

var _node_count := 0
var _spec_count := 0


func _init(p_max_encoded_size: int = DEFAULT_MAX_ENCODED_SIZE, p_max_depth: int = DEFAULT_MAX_DEPTH, p_max_nodes: int = DEFAULT_MAX_NODES, p_max_string_length: int = DEFAULT_MAX_STRING_LENGTH, p_max_collection_size: int = DEFAULT_MAX_COLLECTION_SIZE) -> void:
	max_encoded_size = p_max_encoded_size
	max_depth = p_max_depth
	max_nodes = p_max_nodes
	max_string_length = p_max_string_length
	max_collection_size = p_max_collection_size


func is_valid() -> bool:
	return max_encoded_size >= 1 and max_depth >= 1 and max_nodes >= 1 and max_string_length >= 1 and max_collection_size >= 1


# context carries runtime limits such as {"roster_count": 5}; it is only read
# when the schema contains a player_index spec.
func validate(payload, schema, context = null) -> Dictionary:
	if not is_valid():
		return _fail(REASON_INVALID_CONFIG, "")
	_node_count = 0
	var r := _scan(payload, schema, 0, "")
	if not r.ok:
		return r
	# Safe only after _scan: it rejected Objects and anything cyclic or deep.
	if var2bytes(payload).size() > max_encoded_size:
		return _fail(REASON_TOO_LARGE, "")
	return _check(payload, schema, context, "")


# Checks every spec in a schema, including optional fields a message may never
# carry. field is the payload path of the bad spec ("[]" marks array items).
func check_schema(schema) -> Dictionary:
	_spec_count = 0
	return _check_spec_tree(schema, "", 0)


# spec is the schema node expected at this position (or anything else, the
# schema is not checked yet); it only decides which key names may be shown.
func _scan(value, spec, depth: int, path: String) -> Dictionary:
	_node_count += 1
	if _node_count > max_nodes:
		return _fail(REASON_TOO_MANY_NODES, path)
	var t := typeof(value)
	if t == TYPE_NIL or t == TYPE_BOOL or t == TYPE_INT:
		return _ok()
	if t == TYPE_REAL:
		if is_nan(value) or is_inf(value):
			return _fail(REASON_NOT_FINITE, path)
		return _ok()
	if t == TYPE_STRING:
		if value.length() > max_string_length:
			return _fail(REASON_STRING_TOO_LONG, path)
		return _ok()
	if t != TYPE_ARRAY and t != TYPE_DICTIONARY:
		return _fail(REASON_FORBIDDEN_TYPE, path)
	if depth + 1 > max_depth:
		return _fail(REASON_TOO_DEEP, path)
	if value.size() > max_collection_size:
		return _fail(REASON_TOO_MANY_ITEMS, path)
	if t == TYPE_ARRAY:
		var item_spec = _declared_items(spec)
		for i in range(value.size()):
			var item_result := _scan(value[i], item_spec, depth + 1, _index_path(path, i))
			if not item_result.ok:
				return item_result
		return _ok()
	var fields := _declared_fields(spec)
	for key in value:
		if typeof(key) != TYPE_STRING:
			return _fail(REASON_BAD_KEY, _join(path, null))
		var key_path := _join(path, key if fields.has(key) else null)
		if key.length() > max_string_length:
			return _fail(REASON_STRING_TOO_LONG, key_path)
		var field_result := _scan(value[key], fields.get(key), depth + 1, key_path)
		if not field_result.ok:
			return field_result
	return _ok()


# Fields a spec declares, or {}. Runs before the schema is checked, so only the
# shapes are tested; a spec that declares fields or items it may not have is
# refused by the schema pass, and its names come from the trusted schema anyway.
func _declared_fields(spec) -> Dictionary:
	if typeof(spec) != TYPE_DICTIONARY or typeof(spec.get("fields")) != TYPE_DICTIONARY:
		return {}
	return spec.fields


func _declared_items(spec):
	if typeof(spec) != TYPE_DICTIONARY:
		return null
	return spec.get("items")


func _check(value, spec, context, path: String) -> Dictionary:
	if _spec_problem(spec):
		return _fail(REASON_BAD_SCHEMA, path)
	var type_name: String = spec.type
	if typeof(value) == TYPE_NIL:
		if spec.get("nullable", false):
			return _ok()
		return _fail(REASON_WRONG_TYPE, path)
	if type_name == TYPE_NAME_BOOL:
		if typeof(value) != TYPE_BOOL:
			return _fail(REASON_WRONG_TYPE, path)
		return _ok()
	if type_name == TYPE_NAME_INT or type_name == TYPE_NAME_FLOAT or type_name == TYPE_NAME_NUMBER:
		return _check_number(value, spec, type_name, path)
	if type_name == TYPE_NAME_PLAYER_INDEX:
		return _check_player_index(value, spec, context, path)
	if type_name == TYPE_NAME_STRING:
		if typeof(value) != TYPE_STRING:
			return _fail(REASON_WRONG_TYPE, path)
		if value.length() > int(spec.get("max_len", max_string_length)):
			return _fail(REASON_STRING_TOO_LONG, path)
		if value.length() < int(spec.get("min_len", 0)):
			return _fail(REASON_STRING_TOO_SHORT, path)
		if spec.has("allowed") and not spec.allowed.has(value):
			return _fail(REASON_NOT_ALLOWED, path)
		return _ok()
	if type_name == TYPE_NAME_ARRAY:
		if typeof(value) != TYPE_ARRAY:
			return _fail(REASON_WRONG_TYPE, path)
		if value.size() > int(spec.get("max_len", max_collection_size)):
			return _fail(REASON_TOO_MANY_ITEMS, path)
		if value.size() < int(spec.get("min_len", 0)):
			return _fail(REASON_TOO_FEW_ITEMS, path)
		for i in range(value.size()):
			var item_result := _check(value[i], spec.items, context, _index_path(path, i))
			if not item_result.ok:
				return item_result
		return _ok()
	return _check_dict(value, spec, context, path)


func _check_number(value, spec: Dictionary, type_name: String, path: String) -> Dictionary:
	var t := typeof(value)
	var type_ok := t == TYPE_INT
	if type_name == TYPE_NAME_FLOAT:
		type_ok = t == TYPE_REAL
	elif type_name == TYPE_NAME_NUMBER:
		type_ok = t == TYPE_INT or t == TYPE_REAL
	if not type_ok:
		return _fail(REASON_WRONG_TYPE, path)
	# _scan already refused NaN/INF; kept because NaN passes both range tests.
	if t == TYPE_REAL and (is_nan(value) or is_inf(value)):
		return _fail(REASON_NOT_FINITE, path)
	if value < spec["min"] or value > spec["max"]:
		return _fail(REASON_OUT_OF_RANGE, path)
	if spec.has("allowed") and not spec.allowed.has(value):
		return _fail(REASON_NOT_ALLOWED, path)
	return _ok()


# The legal range comes from the live roster, so a forged index for a ninth
# player, or one beyond a smaller roster, never reaches per-player arrays.
func _check_player_index(value, spec: Dictionary, context, path: String) -> Dictionary:
	if typeof(value) != TYPE_INT:
		return _fail(REASON_WRONG_TYPE, path)
	if typeof(context) != TYPE_DICTIONARY:
		return _fail(REASON_BAD_CONTEXT, path)
	var count = context.get(spec.get("count", DEFAULT_COUNT_KEY))
	if typeof(count) != TYPE_INT or count < 1 or count > CapacityPolicy.MAX_SUPPORTED_PLAYERS:
		return _fail(REASON_BAD_CONTEXT, path)
	if value < 0 or value >= count:
		return _fail(REASON_OUT_OF_RANGE, path)
	return _ok()


func _check_dict(value, spec: Dictionary, context, path: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _fail(REASON_WRONG_TYPE, path)
	var fields: Dictionary = spec.get("fields", {})
	var allow_extra: bool = spec.get("allow_extra", false)
	for key in value:
		if typeof(key) != TYPE_STRING:
			return _fail(REASON_BAD_KEY, _join(path, null))
		if not allow_extra and not fields.has(key):
			return _fail(REASON_UNKNOWN_FIELD, _join(path, null))
	for name in fields:
		var field_spec = fields[name]
		if not value.has(name):
			if _spec_problem(field_spec):
				return _fail(REASON_BAD_SCHEMA, _join(path, name))
			if field_spec.get("optional", false):
				continue
			return _fail(REASON_MISSING_FIELD, _join(path, name))
		var field_result := _check(value[name], field_spec, context, _join(path, name))
		if not field_result.ok:
			return field_result
	return _ok()


func _check_spec_tree(spec, path: String, depth: int) -> Dictionary:
	_spec_count += 1
	if depth > MAX_SCHEMA_DEPTH or _spec_count > MAX_SCHEMA_NODES or _spec_problem(spec):
		return _fail(REASON_BAD_SCHEMA, path)
	if spec.type == TYPE_NAME_ARRAY:
		return _check_spec_tree(spec.items, path + "[]", depth + 1)
	if spec.type == TYPE_NAME_DICT:
		var fields: Dictionary = spec.get("fields", {})
		for name in fields:
			var r := _check_spec_tree(fields[name], _join(path, name), depth + 1)
			if not r.ok:
				return r
	return _ok()


# Shallow check of one spec node; child specs are checked when visited.
func _spec_problem(spec) -> bool:
	if typeof(spec) != TYPE_DICTIONARY:
		return true
	var type_name = spec.get("type")
	if typeof(type_name) != TYPE_STRING or not SPEC_KEYS.has(type_name):
		return true
	var own_keys: Array = SPEC_KEYS[type_name]
	for key in spec:
		if typeof(key) != TYPE_STRING or not (key in COMMON_SPEC_KEYS or key in own_keys):
			return true
	for flag in ["optional", "nullable", "allow_extra"]:
		if spec.has(flag) and typeof(spec[flag]) != TYPE_BOOL:
			return true
	if type_name == TYPE_NAME_INT or type_name == TYPE_NAME_FLOAT or type_name == TYPE_NAME_NUMBER:
		if not spec.has("min") or not spec.has("max"):
			return true
		if not _is_bound(spec["min"], type_name) or not _is_bound(spec["max"], type_name):
			return true
		if spec["min"] > spec["max"]:
			return true
	if spec.has("min_len") or spec.has("max_len"):
		var min_len = spec.get("min_len", 0)
		var max_len = spec.get("max_len", min_len)
		if typeof(min_len) != TYPE_INT or typeof(max_len) != TYPE_INT or min_len < 0 or min_len > max_len:
			return true
	if spec.has("allowed"):
		var element_type := TYPE_INT if type_name == TYPE_NAME_INT else TYPE_STRING
		if typeof(spec.allowed) != TYPE_ARRAY or spec.allowed.empty():
			return true
		for v in spec.allowed:
			if typeof(v) != element_type:
				return true
	if spec.has("count") and (typeof(spec.count) != TYPE_STRING or spec.count.empty()):
		return true
	if type_name == TYPE_NAME_ARRAY and (not spec.has("items") or typeof(spec.items) != TYPE_DICTIONARY):
		return true
	if spec.has("fields"):
		if typeof(spec.fields) != TYPE_DICTIONARY:
			return true
		for name in spec.fields:
			if typeof(name) != TYPE_STRING or typeof(spec.fields[name]) != TYPE_DICTIONARY:
				return true
	return false


func _is_bound(value, type_name: String) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	return type_name != TYPE_NAME_INT and typeof(value) == TYPE_REAL and not is_nan(value) and not is_inf(value)


func _join(path: String, key) -> String:
	var name := "?"
	if typeof(key) == TYPE_STRING and _is_safe_key(key):
		name = key
	if path == "":
		return name
	return "%s.%s" % [path, name]


func _index_path(path: String, index: int) -> String:
	return "%s[%d]" % [path, index]


func _is_safe_key(key: String) -> bool:
	if key.empty() or key.length() > MAX_PATH_KEY_LENGTH:
		return false
	for i in range(key.length()):
		var c := key.ord_at(i)
		var is_letter := (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		var is_digit := c >= 48 and c <= 57
		if not is_letter and not is_digit and c != 95:
			return false
	return true


func _ok() -> Dictionary:
	return {"ok": true, "reason": REASON_NONE, "field": ""}


func _fail(reason: String, field: String) -> Dictionary:
	return {"ok": false, "reason": reason, "field": field}
