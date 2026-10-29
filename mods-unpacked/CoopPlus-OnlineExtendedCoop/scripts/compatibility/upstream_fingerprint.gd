extends Reference
# Runtime version of the normalized mod fingerprint in tools/lib/Common.psm1
# (R03, F17): lines "relative/path<TAB>sha256(content)\n" for every file under
# res://mods-unpacked/<mod_id>/, sorted, hashed with SHA-256. Independent of zip
# timestamps and compression, so it matches project.lock.json for an unmodified
# workshop download.

const UNPACKED_ROOT := "res://mods-unpacked"


static func compute(mod_id: String) -> Dictionary:
	var root := UNPACKED_ROOT.plus_file(mod_id)
	var files := []
	if not _collect(root, "", files):
		return {"ok": false, "reason": "mod_dir_missing", "fingerprint": "", "file_count": 0}
	files.sort()
	var file := File.new()
	var text := ""
	for rel in files:
		var sha := file.get_sha256(root.plus_file(rel))
		if sha == "":
			return {"ok": false, "reason": "unreadable:" + rel, "fingerprint": "", "file_count": files.size()}
		text += "%s\t%s\n" % [rel, sha]
	return {"ok": true, "reason": "", "fingerprint": text.sha256_text(), "file_count": files.size()}


static func _collect(dir_path: String, rel_prefix: String, out: Array) -> bool:
	var dir := Directory.new()
	if dir.open(dir_path) != OK:
		return false
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		var rel := entry if rel_prefix == "" else rel_prefix + "/" + entry
		if dir.current_is_dir():
			if not _collect(dir_path.plus_file(entry), rel, out):
				dir.list_dir_end()
				return false
		else:
			out.append(rel)
		entry = dir.get_next()
	dir.list_dir_end()
	return true
