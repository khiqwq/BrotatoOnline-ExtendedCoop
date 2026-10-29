extends Reference
# AP-005 probe bookkeeping. Lives in debug/ (excluded from release packages).
# State is kept as Engine metadata so script extensions can record events even
# before the probe node exists (autoload instances are created early).

const META_KEY := "coopplus_lifecycle_probe"
const EVENTS_DIR := "user://coopplus_probe"


static func _state() -> Dictionary:
	if not Engine.has_meta(META_KEY):
		Engine.set_meta(META_KEY, {"events": [], "counters": {}})
	return Engine.get_meta(META_KEY)


static func event(name: String, detail := {}) -> void:
	var s := _state()
	var e := {"t": OS.get_ticks_msec(), "frame": Engine.get_idle_frames(), "event": name, "detail": detail}
	s.events.append(e)
	_append_line(to_json(e))


# Written and closed per event so the trail survives a hard crash.
static func _append_line(line: String) -> void:
	var dir := Directory.new()
	var _mk = dir.make_dir_recursive(EVENTS_DIR)
	var f := File.new()
	var path := EVENTS_DIR.plus_file("events.log")
	var mode := File.READ_WRITE if f.file_exists(path) else File.WRITE
	if f.open(path, mode) != OK:
		return
	f.seek_end()
	f.store_line(line)
	f.close()


static func count(name: String) -> void:
	var s := _state()
	s.counters[name] = int(s.counters.get(name, 0)) + 1


static func snapshot() -> Dictionary:
	return _state().duplicate(true)


static func script_chain(obj: Object) -> Array:
	var chain := []
	if obj == null:
		return chain
	var script = obj.get_script()
	while script != null:
		chain.append(script.resource_path)
		script = script.get_base_script()
	return chain
