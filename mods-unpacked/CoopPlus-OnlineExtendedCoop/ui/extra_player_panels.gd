extends Reference
# P5..P8 panels for the four-panel co-op screens (AP-015; R01; UI-09, UI-10,
# INP-08). The end-of-wave upgrade screen and the co-op shop share one layout:
#   <row>/<Prefix>1..4        one panel per player (exported player_index)
#   <popup parent>/StatPopup1..4
#   FocusEmulator1..4         per-player focus; its focus_base_data points at
#                             that player's panel
# clone() duplicates panel 4, popup 4 and focus emulator 4 for every player
# from 5 to `size`, renames them like vanilla (Prefix5, StatPopup5,
# FocusEmulator5, ...) and rebases the focus data onto the new panel, so
# Utils.get_focus_emulator(i) finds them. Called from the screens' _enter_tree,
# before any _ready of the screen runs. The new panels share the vanilla row
# (functional layout; the final 5..8 layout follows the OWNER-confirmed
# sample, AP-014).

const VANILLA_SLOTS := 4
const EMULATOR_PREFIX := "FocusEmulator"
const POPUP_PREFIX := "StatPopup"
const PATH_LIST_FIELDS := [
	"contain_horizontal_focus_exception_paths",
	"require_entry_from_control_paths",
	"focus_neighbour_top_paths",
	"focus_neighbour_bottom_paths",
	"focus_neighbour_left_paths",
	"focus_neighbour_right_paths",
]


# Returns {"ok", "reason", "containers": [], "popups": [], "emulators": [],
# "extra": {prefix: []}}; index 0 of each list belongs to player_index 4.
# extra_popup_prefixes clones further per-player popups found next to the stat
# popups (e.g. "ItemPopup" on the end-of-run screen).
static func clone(screen: Node, size: int, row_path: String, panel_prefix: String, popup_parent_path: String, extra_popup_prefixes: Array = []) -> Dictionary:
	var result := {"ok": false, "reason": "", "containers": [], "popups": [], "emulators": [], "extra": {}}
	if size <= VANILLA_SLOTS:
		result.ok = true
		return result
	var row = screen.get_node_or_null(row_path)
	var popup_parent = screen.get_node_or_null(popup_parent_path)
	var template_name := "%s%d" % [panel_prefix, VANILLA_SLOTS]
	var panel_template = screen.get_node_or_null("%s/%s" % [row_path, template_name])
	var popup_template = screen.get_node_or_null("%s/%s%d" % [popup_parent_path, POPUP_PREFIX, VANILLA_SLOTS])
	var emulator_template = screen.get_node_or_null("%s%d" % [EMULATOR_PREFIX, VANILLA_SLOTS])
	if row == null or popup_parent == null or panel_template == null or popup_template == null or emulator_template == null:
		result.reason = "screen_layout_changed"
		return result
	var extra_templates := {}
	for prefix in extra_popup_prefixes:
		var template = screen.get_node_or_null("%s/%s%d" % [popup_parent_path, prefix, VANILLA_SLOTS])
		if template == null:
			result.reason = "screen_layout_changed:" + prefix
			return result
		extra_templates[prefix] = template
		result.extra[prefix] = []
	for player_index in range(VANILLA_SLOTS, size):
		var number := player_index + 1
		var panel = panel_template.duplicate()
		panel.name = "%s%d" % [panel_prefix, number]
		panel.unique_name_in_owner = false
		if "player_index" in panel:
			panel.player_index = player_index
		row.add_child(panel)
		result.containers.append(panel)

		var popup = popup_template.duplicate()
		popup.name = "%s%d" % [POPUP_PREFIX, number]
		popup.unique_name_in_owner = false
		popup_parent.add_child(popup)
		result.popups.append(popup)

		for prefix in extra_templates:
			var extra = extra_templates[prefix].duplicate()
			extra.name = "%s%d" % [prefix, number]
			extra.unique_name_in_owner = false
			popup_parent.add_child(extra)
			result.extra[prefix].append(extra)

		var emulator = emulator_template.duplicate()
		emulator.name = "%s%d" % [EMULATOR_PREFIX, number]
		var rebased := []
		for data in emulator_template.focus_base_data:
			rebased.append(_rebase_focus_data(data, template_name, panel.name))
		emulator.focus_base_data = rebased
		screen.add_child(emulator)
		emulator.player_index = player_index
		result.emulators.append(emulator)
	result.ok = true
	return result


# The selection screens (character, weapon) have no stat popups and several
# per-player nodes per parent. specs: [[parent_path, prefix], ...]; clones
# "<prefix>4" under each parent for players 5..size, placing each clone right
# after the previous player's node of the same parent, and (with_emulators)
# FocusEmulator4 with its focus data rebased from every template name to the
# clone's ("Inventory4" -> "Inventory5"; paths to shared nodes stay). Returns
# {"ok", "reason", "nodes": {prefix: []}, "emulators": []}; index 0 belongs to
# player_index 4.
static func clone_named(screen: Node, size: int, specs: Array, with_emulators: bool = true) -> Dictionary:
	var result := {"ok": false, "reason": "", "nodes": {}, "emulators": []}
	if size <= VANILLA_SLOTS:
		result.ok = true
		return result
	var templates := []
	var anchors := {}
	for spec in specs:
		var parent = screen.get_node_or_null(spec[0])
		var template = parent.get_node_or_null("%s%d" % [spec[1], VANILLA_SLOTS]) if parent != null else null
		if template == null:
			result.reason = "screen_layout_changed:" + str(spec[1])
			return result
		templates.append({"parent": parent, "template": template, "prefix": spec[1]})
		result.nodes[spec[1]] = []
		if not anchors.has(parent) or template.get_index() > anchors[parent].get_index():
			anchors[parent] = template
	var emulator_template = screen.get_node_or_null("%s%d" % [EMULATOR_PREFIX, VANILLA_SLOTS])
	if with_emulators and emulator_template == null:
		result.reason = "screen_layout_changed:" + EMULATOR_PREFIX
		return result
	for player_index in range(VANILLA_SLOTS, size):
		var number := player_index + 1
		for t in templates:
			var node = t.template.duplicate()
			node.name = "%s%d" % [t.prefix, number]
			node.unique_name_in_owner = false
			if "player_index" in node:
				node.player_index = player_index
			t.parent.add_child(node)
			t.parent.move_child(node, anchors[t.parent].get_index() + 1)
			anchors[t.parent] = node
			result.nodes[t.prefix].append(node)
		if not with_emulators:
			continue
		var emulator = emulator_template.duplicate()
		emulator.name = "%s%d" % [EMULATOR_PREFIX, number]
		var rebased := []
		for data in emulator_template.focus_base_data:
			var copy = data
			for t in templates:
				copy = _rebase_focus_data(copy, t.template.name, "%s%d" % [t.prefix, number])
			rebased.append(copy)
		emulator.focus_base_data = rebased
		screen.add_child(emulator)
		emulator.player_index = player_index
		result.emulators.append(emulator)
	result.ok = true
	return result


static func _rebase_focus_data(data: Resource, old_name: String, new_name: String) -> Resource:
	var copy = data.duplicate()
	copy.path = _rebase_path(copy.path, old_name, new_name)
	for field in PATH_LIST_FIELDS:
		if not field in copy:
			continue
		var paths := []
		for p in copy.get(field):
			paths.append(_rebase_path(p, old_name, new_name))
		copy.set(field, paths)
	return copy


# Replaces whole path segments only ("Panel4" -> "Panel5", never "Panel44").
static func _rebase_path(path: NodePath, old_name: String, new_name: String) -> NodePath:
	var parts := str(path).split("/")
	for i in parts.size():
		if parts[i] == old_name:
			parts[i] = new_name
	return NodePath(parts.join("/"))
