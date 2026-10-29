extends "res://tests/runner/test_case.gd"
# Contract with the upstream scripts the adapters override (F17). Reads source
# text, so it works even where the recovered game root cannot fully compile a
# script (autoload stubs). Runs only in the integration root from setup.ps1.

const CONTRACT_PATH := "res://tests/fixtures/upstream_contract.json"

var _contract := {}


func before_each() -> void:
	var f := File.new()
	if f.open(CONTRACT_PATH, File.READ) != OK:
		_contract = {}
		return
	var parsed = parse_json(f.get_as_text())
	f.close()
	_contract = parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func test_contract_fixture_is_readable() -> void:
	assert_true(_contract.has("scripts"), "fixture %s" % CONTRACT_PATH)


func test_upstream_methods_keep_their_parameter_counts() -> void:
	for path in _contract.get("scripts", {}):
		var source := _read(path)
		if source == "":
			fail("cannot read %s" % path)
			continue
		var methods: Dictionary = _contract.scripts[path].get("methods", {})
		for name in methods:
			var count := _param_count(source, name)
			assert_eq(count, int(methods[name]), "%s %s()" % [path, name])


func test_upstream_constants_keep_their_values() -> void:
	for path in _contract.get("scripts", {}):
		var source := _read(path)
		var constants: Dictionary = _contract.scripts[path].get("constants", {})
		for name in constants:
			assert_eq(_const_value(source, name), str(constants[name]), "%s const %s" % [path, name])


func _read(path: String) -> String:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


# -1 when the method is missing; otherwise the number of declared parameters.
func _param_count(source: String, method: String) -> int:
	var re := RegEx.new()
	var _err = re.compile("(?m)^(static\\s+)?func\\s+" + method + "\\s*\\(([^)]*)\\)")
	var m := re.search(source)
	if m == null:
		return -1
	var params := m.get_string(2).strip_edges()
	if params == "":
		return 0
	var depth := 0
	var count := 1
	for i in params.length():
		var c := params[i]
		if c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		elif c == "," and depth == 0:
			count += 1
	return count


func _const_value(source: String, name: String) -> String:
	var re := RegEx.new()
	var _err = re.compile("(?m)^const\\s+" + name + "\\s*(:\\s*\\w+)?\\s*:?=\\s*(.+?)\\s*$")
	var m := re.search(source)
	if m == null:
		return "<missing>"
	return m.get_string(2)
