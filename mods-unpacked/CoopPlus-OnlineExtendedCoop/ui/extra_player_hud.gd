extends Reference
# Battle HUD pieces for P5..P8 (AP-015; R01; BAT-07, UI-12, GAP2-02). The
# battle scene (main.tscn) only has P1..P4 copies of:
#   WorldUI/PlayerLifeBarContainerPn (+ PlayerLifeBarPn)  life bar above the player
#   UI/HUD/LifeContainerPn (UILifeBarPn, UIXPBarPn, UIGoldPn, UIHitProtection)
#   UIThingsToProcessPlayerContainerN  pending upgrades/crates icons
# and Main._on_EntitySpawner_players_spawned looks them up by unique name for
# every player, so the release engine crashed on P5 (EV-0017). build() clones
# the P1..P4 nodes for P5..P8 (P5 from P1, P6 from P2, ...) and registers the
# clones as unique names of the battle scene, so vanilla finds them unchanged.
# Placement (functional; the final 5..8 layout follows the OWNER-confirmed
# sample, AP-014): P5..P8 HUD blocks sit in a second margin layer just inside
# the P1..P4 corners, and their pending-icon rows sit between the vanilla rows.
# Called from main_ext.gd _enter_tree, before any _ready of the scene runs.

const VANILLA_SLOTS := 4
const HUD_PATH := "UI/HUD"
const WORLD_UI_PATH := "WorldUI"
const THINGS_VBOX_PATH := "UI/HUD/ThingsToProcessMarginContainer/VBoxContainer"
const EXTRA_HUD_NAME := "CoopPlusHUDP5ToP8"
const MIN_BLOCK_HEIGHT := 140.0
const BLOCK_GAP := 16.0
# Per-player children of a HUD block. P1's block also holds the team-wide
# UIBonusGold and FPSLabel, which must not be cloned.
const BLOCK_CHILD_PREFIXES := ["UILifeBarP", "UIXPBarP", "UIGoldP", "UIHitProtection"]


# Returns {"ok", "reason", "things": [UIThingsToProcessPlayerContainer for P5..]}.
static func build(main: Node, player_count: int) -> Dictionary:
	var result := {"ok": false, "reason": "", "things": []}
	if player_count <= VANILLA_SLOTS:
		result.ok = true
		return result
	var hud = main.get_node_or_null(HUD_PATH)
	var world_ui = main.get_node_or_null(WORLD_UI_PATH)
	var things_vbox = main.get_node_or_null(THINGS_VBOX_PATH)
	if hud == null or world_ui == null or things_vbox == null or things_vbox.get_child_count() < 2:
		result.reason = "battle_scene_layout_changed"
		return result
	for t in range(1, VANILLA_SLOTS + 1):
		for path in ["%%PlayerLifeBarContainerP%d" % t, "%%LifeContainerP%d" % t, "%%UIThingsToProcessPlayerContainer%d" % t]:
			if main.get_node_or_null(path) == null:
				result.reason = "missing_template:" + path
				return result

	var extra_hud := MarginContainer.new()
	extra_hud.name = EXTRA_HUD_NAME
	extra_hud.anchor_right = 1.0
	extra_hud.anchor_bottom = 1.0
	extra_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var offset := _block_height(main.get_node("%LifeContainerP1")) + BLOCK_GAP
	for side in ["left", "right", "top", "bottom"]:
		var base := int(hud.get("custom_constants/margin_" + side))
		var extra := int(offset) if side == "top" or side == "bottom" else 0
		extra_hud.add_constant_override("margin_" + side, base + extra)
	var ui_layer = hud.get_parent()
	ui_layer.add_child(extra_hud)
	ui_layer.move_child(extra_hud, hud.get_index() + 1)
	extra_hud.owner = main

	# Pending-icon rows: P5/P6 under the P1/P2 row, P7/P8 above the P3/P4 row.
	var row_top = things_vbox.get_child(0)
	var rows := {}

	for player_index in range(VANILLA_SLOTS, player_count):
		var n := player_index + 1
		var t := (player_index - VANILLA_SLOTS) % VANILLA_SLOTS + 1

		var bar = main.get_node("%%PlayerLifeBarContainerP%d" % t).duplicate()
		_rename_player_suffix(bar, t, n)
		world_ui.add_child(bar)
		_adopt(bar, main)

		var block = main.get_node("%%LifeContainerP%d" % t).duplicate()
		_strip_shared_children(block)
		_rename_player_suffix(block, t, n)
		extra_hud.add_child(block)
		_adopt(block, main)

		var row_key := 0 if t <= 2 else 1
		if not rows.has(row_key):
			var row := HBoxContainer.new()
			row.name = "CoopPlusThingsRow%d" % (row_key + 1)
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.size_flags_vertical = row_top.size_flags_vertical
			things_vbox.add_child(row)
			# Order: vanilla top row, P5/P6, P7/P8, vanilla bottom row.
			things_vbox.move_child(row, 1 + row_key)
			row.owner = main
			rows[row_key] = row
		var things = main.get_node("%%UIThingsToProcessPlayerContainer%d" % t).duplicate()
		things.name = "UIThingsToProcessPlayerContainer%d" % n
		rows[row_key].add_child(things)
		_adopt(things, main)
		things.hide()
		result.things.append(things)

	result.ok = true
	return result


# Vanilla set_hud_position only knows corners 0..3; P5..P8 reuse P1..P4's.
static func place_player_huds(players_ui: Array) -> void:
	for i in range(VANILLA_SLOTS, players_ui.size()):
		if players_ui[i] != null:
			players_ui[i].set_hud_position((i - VANILLA_SLOTS) % VANILLA_SLOTS)


static func _block_height(block: Control) -> float:
	if block == null:
		return MIN_BLOCK_HEIGHT
	return max(MIN_BLOCK_HEIGHT, block.get_combined_minimum_size().y)


static func _strip_shared_children(block: Node) -> void:
	for child in block.get_children():
		var keep := false
		for prefix in BLOCK_CHILD_PREFIXES:
			if child.name.begins_with(prefix):
				keep = true
		if not keep:
			block.remove_child(child)
			child.free()


# Scene-level nodes of a duplicate have no owner yet (the nodes inside
# instanced sub-scenes keep their instance root as owner); rename the
# P<t>-suffixed ones to P<n>.
static func _rename_player_suffix(node: Node, t: int, n: int) -> void:
	var suffix := "P%d" % t
	if node.owner == null and node.name.ends_with(suffix):
		node.name = node.name.substr(0, node.name.length() - suffix.length()) + "P%d" % n
	for child in node.get_children():
		_rename_player_suffix(child, t, n)


# Gives the scene-level nodes the battle scene as owner and re-registers the
# unique names they carry over from the template, now under their new names.
static func _adopt(node: Node, scene_owner: Node) -> void:
	if node.owner == null and node != scene_owner:
		node.owner = scene_owner
		if node.unique_name_in_owner:
			node.unique_name_in_owner = false
			node.unique_name_in_owner = true
	for child in node.get_children():
		_adopt(child, scene_owner)
