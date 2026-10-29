extends SceneTree
# Minimal rule-test runner for the target Godot 3 engine.
#   --suite=<dir under res://tests/>   (default: unit)
#   --filter=<substring of file or test name>
# Prints one TEST_RESULT line per test and writes user://test_results.json.
# tools/test.ps1 also fails the run on any SCRIPT ERROR in the engine output,
# because GDScript runtime errors cannot be caught here.

const TestCase = preload("res://tests/runner/test_case.gd")


func _initialize() -> void:
	var suite := "unit"
	var filter := ""
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--suite="):
			suite = arg.substr("--suite=".length())
		elif arg.begins_with("--filter="):
			filter = arg.substr("--filter=".length())
	var files := []
	_collect("res://tests/%s" % suite, files)
	files.sort()
	var results := []
	var passed := 0
	var failed := 0
	for path in files:
		var script = load(path)
		if script == null or not script.can_instance():
			results.append({"file": path, "test": "<load>", "status": "FAIL", "failures": ["script failed to load"]})
			failed += 1
			print("TEST_RESULT FAIL %s <load>" % path)
			continue
		var names := []
		for m in script.get_script_method_list():
			if m.name.begins_with("test_") and not names.has(m.name):
				names.append(m.name)
		names.sort()
		for name in names:
			if filter != "" and not (filter in path) and not (filter in name):
				continue
			var case = script.new()
			if not case is TestCase:
				results.append({"file": path, "test": name, "status": "FAIL", "failures": ["test script must extend test_case.gd"]})
				failed += 1
				break
			case._reset()
			print("TEST_BEGIN %s %s" % [path, name])
			if case.has_method("before_each"):
				case.before_each()
			case.call(name)
			if case.has_method("after_each"):
				case.after_each()
			print("TEST_END %s %s" % [path, name])
			var failures: Array = case.get_failures()
			var status := "PASS"
			if failures.size() > 0:
				status = "FAIL"
			elif case.get_check_count() == 0:
				status = "FAIL"
				failures = ["test made no assertions"]
			if status == "PASS":
				passed += 1
			else:
				failed += 1
			results.append({"file": path, "test": name, "status": status, "checks": case.get_check_count(), "failures": failures})
			print("TEST_RESULT %s %s %s" % [status, path, name])
			for f in failures:
				print("  - %s" % f)
	var out := File.new()
	if out.open("user://test_results.json", File.WRITE) == OK:
		out.store_string(to_json({"suite": suite, "passed": passed, "failed": failed, "results": results}))
		out.close()
	print("TEST_SUMMARY suite=%s passed=%d failed=%d" % [suite, passed, failed])
	quit(1 if failed > 0 or passed == 0 else 0)


func _collect(dir_path: String, out: Array) -> void:
	var dir := Directory.new()
	if dir.open(dir_path) != OK:
		return
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.plus_file(entry)
		if dir.current_is_dir():
			_collect(full, out)
		elif entry.begins_with("test_") and entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
