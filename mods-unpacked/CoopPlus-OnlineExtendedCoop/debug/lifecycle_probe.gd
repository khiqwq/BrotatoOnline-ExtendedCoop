extends Node
# AP-005 lifecycle probe (debug/ only, never packaged). Started by mod_main when
# the game runs with --coopplus-probe. After the main menu has settled it writes
# user://coopplus_probe/lifecycle.json: event order, callback counters, script
# chains of Brotato Online managers and patched autoloads, Mod Loader data and
# the runtime fingerprint of Brotato Online. --coopplus-probe-quit exits after.

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")
const UpstreamFingerprint = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/upstream_fingerprint.gd")

const REPORT_DIR := "user://coopplus_probe"
const BO_ID := "six666-BrotatoOnline"
const SETTLE_SEC := 12.0

var _quit_after := false


func _ready() -> void:
	_quit_after = "--coopplus-probe-quit" in OS.get_cmdline_args()
	ProbeLog.event("lifecycle_probe._ready")
	var timer := get_tree().create_timer(SETTLE_SEC)
	var _err = timer.connect("timeout", self, "_on_settled")


func _on_settled() -> void:
	ProbeLog.event("lifecycle_probe.settled")
	var report := {
		"probe": ProbeLog.snapshot(),
		"mod_loader_version": ModLoaderStore.MODLOADER_VERSION,
		"engine": Engine.get_version_info(),
		"mod_loader_children": _describe_children(get_node_or_null("/root/ModLoader"), 2),
		"autoload_chains": {
			"CoopService": ProbeLog.script_chain(get_node_or_null("/root/CoopService")),
			"RunData": ProbeLog.script_chain(get_node_or_null("/root/RunData")),
			"InputService": ProbeLog.script_chain(get_node_or_null("/root/InputService")),
			"ProgressData": ProbeLog.script_chain(get_node_or_null("/root/ProgressData")),
		},
		"stacked_chains": {
			"res://global/entity_spawner.gd": _identify_chain(load("res://global/entity_spawner.gd")),
			"res://singletons/coop_service.gd": _identify_chain(load("res://singletons/coop_service.gd")),
			"res://mods-unpacked/six666-BrotatoOnline/scripts/session_manager.gd": _identify_chain(load("res://mods-unpacked/six666-BrotatoOnline/scripts/session_manager.gd")),
			"res://mods-unpacked/six666-BrotatoOnline/scripts/online_player_slot_manager.gd": _identify_chain(load("res://mods-unpacked/six666-BrotatoOnline/scripts/online_player_slot_manager.gd")),
		},
		"coop_service_max_players": CoopService.get_max_players(),
		"upstream_fingerprint": UpstreamFingerprint.compute(BO_ID),
		"current_scene": get_tree().current_scene.filename if get_tree().current_scene != null else "",
	}
	var dir := Directory.new()
	var _mk = dir.make_dir_recursive(REPORT_DIR)
	var f := File.new()
	if f.open(REPORT_DIR.plus_file("lifecycle.json"), File.WRITE) == OK:
		f.store_string(JSON.print(report, "\t"))
		f.close()
		print("COOPPLUS_PROBE report written")
	else:
		printerr("COOPPLUS_PROBE could not write report")
	if _quit_after:
		get_tree().quit()


func _describe_children(node: Node, depth: int) -> Array:
	var out := []
	if node == null:
		return out
	for child in node.get_children():
		var entry := {"name": child.name, "chain": ProbeLog.script_chain(child)}
		if depth > 1:
			entry["children"] = _describe_children(child, depth - 1)
		out.append(entry)
	return out


# Every level of an extended script shares the taken-over resource_path, so levels
# are identified by matching their source text against the files of both mods.
func _identify_chain(script) -> Array:
	var known := {}
	for mod_id in ["six666-BrotatoOnline", "CoopPlus-OnlineExtendedCoop"]:
		_index_sources("res://mods-unpacked".plus_file(mod_id), known)
	var out := []
	while script != null:
		var src: String = script.source_code
		var key := src.sha256_text() if src != "" else ""
		out.append(known.get(key, "<vanilla bytecode>" if src == "" else "<unknown source>"))
		script = script.get_base_script()
	return out


func _index_sources(dir_path: String, known: Dictionary) -> void:
	var dir := Directory.new()
	if dir.open(dir_path) != OK:
		return
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.plus_file(entry)
		if dir.current_is_dir():
			_index_sources(full, known)
		elif entry.ends_with(".gd"):
			var f := File.new()
			if f.open(full, File.READ) == OK:
				known[f.get_as_text().sha256_text()] = full
				f.close()
		entry = dir.get_next()
	dir.list_dir_end()
