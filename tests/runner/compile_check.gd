extends SceneTree
# Compiles every .gd file below the given res:// roots and reports each one.
#   --roots=res://a,res://b   --exclude=substring,substring
# Exit code 1 when any script fails to load or compile.


func _initialize() -> void:
	var roots := []
	var excludes := []
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--roots="):
			roots = arg.substr("--roots=".length()).split(",", false)
		elif arg.begins_with("--exclude="):
			excludes = arg.substr("--exclude=".length()).split(",", false)
	var files := []
	for r in roots:
		_collect(r, files)
	files.sort()
	var failed := 0
	for path in files:
		var skip := false
		for ex in excludes:
			if ex in path:
				skip = true
		if skip:
			continue
		var script = load(path)
		if script != null and script.can_instance():
			print("COMPILE_OK %s" % path)
		else:
			failed += 1
			print("COMPILE_FAIL %s" % path)
	print("COMPILE_SUMMARY files=%d failed=%d" % [files.size(), failed])
	quit(1 if failed > 0 or files.empty() else 0)


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
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
