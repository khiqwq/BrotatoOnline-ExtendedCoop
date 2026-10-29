extends SceneTree
# Loads every script listed in res://__validation__/list.txt and writes a structural
# summary to user://<tag>.json. Run once against recovered sources and once against
# the original bytecode; recovery/compare_dumps.py diffs the two summaries.

var _frames := 0


func _idle(_delta):
	_frames += 1
	if _frames != 2:
		return
	var tag := "dump"
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--dump-tag="):
			tag = arg.substr("--dump-tag=".length())
	var f := File.new()
	if f.open("res://__validation__/list.txt", File.READ) != OK:
		printerr("VALIDATION_ERROR missing list")
		quit(2)
		return
	var paths := f.get_as_text().split("\n", false)
	f.close()
	var out := {}
	for path in paths:
		path = path.strip_edges()
		if path == "":
			continue
		var script = load(path)
		var entry := {"loaded": script != null}
		if script != null:
			entry["valid"] = script.can_instance()
			var methods := []
			for m in script.get_script_method_list():
				methods.append("%s/%d/%d" % [m.name, m.args.size(), m.default_args.size()])
			methods.sort()
			entry["methods"] = methods
			var props := []
			for p in script.get_script_property_list():
				props.append("%s:%d" % [p.name, p.type])
			props.sort()
			entry["props"] = props
			var consts := {}
			var cmap = script.get_script_constant_map()
			for k in cmap:
				var v = cmap[k]
				if typeof(v) == TYPE_OBJECT:
					consts[k] = "<obj %s>" % (v.resource_path if v is Resource else str(v))
				else:
					consts[k] = var2str(v)
			entry["consts"] = consts
			var sigs := []
			for s in script.get_script_signal_list():
				sigs.append("%s/%d" % [s.name, s.args.size()])
			sigs.sort()
			entry["signals"] = sigs
		out[path] = entry
	var o := File.new()
	o.open("user://%s.json" % tag, File.WRITE)
	o.store_string(to_json(out))
	o.close()
	print("VALIDATION_DONE ", tag, " ", out.size())
	quit(0)
