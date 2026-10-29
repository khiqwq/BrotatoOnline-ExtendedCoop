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
# Placement: P5..P8 HUD blocks sit in a second margin layer just inside the
# P1..P4 corners (ui/extra_hud_layer.gd). Their pending-icon containers sit in
# a copy of the vanilla icon layer inside that same layer, so each lines up
# with its own block the way P1..P4's do (top edge for the top corners,
# bottom edge for the bottom ones); they used to be extra rows of the vanilla
# icon layer, spread over the screen height and away from their blocks. The
# team bag of leftover materials leaves P1's block for P5's
# (attach_team_widgets), since P5's block covers the place below P1's.
# build() is called from main_ext.gd _enter_tree, before any _ready of the
# scene runs.

const VANILLA_SLOTS := 4
const HUD_PATH := "UI/HUD"
const WORLD_UI_PATH := "WorldUI"
const THINGS_LAYER_PATH := "UI/HUD/ThingsToProcessMarginContainer"
const THINGS_PREFIX := "UIThingsToProcessPlayerContainer"
const EXTRA_HUD_NAME := "CoopPlusHUDP5ToP8"
const EXTRA_THINGS_NAME := "CoopPlusThingsToProcessP5ToP8"
const ExtraHudLayer = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_hud_layer.gd")
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
	var things_layer = main.get_node_or_null(THINGS_LAYER_PATH)
	if hud == null or world_ui == null or things_layer == null:
		result.reason = "battle_scene_layout_changed"
		return result
	for t in range(1, VANILLA_SLOTS + 1):
		for path in ["%%PlayerLifeBarContainerP%d" % t, "%%LifeContainerP%d" % t, "%%%s%d" % [THINGS_PREFIX, t]]:
			if main.get_node_or_null(path) == null:
				result.reason = "missing_template:" + path
				return result

	# Copy of the icon layer, taken before anything is added to the scene: its
	# P1..P4 containers become P5..P8 (P5 from P1, ...), unused ones go.
	var extra_things = things_layer.duplicate()
	extra_things.name = EXTRA_THINGS_NAME
	for t in range(1, VANILLA_SLOTS + 1):
		var container = _find_named(extra_things, "%s%d" % [THINGS_PREFIX, t])
		if container == null:
			extra_things.free()
			result.reason = "missing_template:%s%d" % [THINGS_PREFIX, t]
			return result
		if t + VANILLA_SLOTS <= player_count:
			container.name = "%s%d" % [THINGS_PREFIX, t + VANILLA_SLOTS]
			container.hide()
			result.things.append(container)
		else:
			container.get_parent().remove_child(container)
			container.free()
	_drop_unique_names(extra_things)

	var extra_hud = ExtraHudLayer.new()
	extra_hud.name = EXTRA_HUD_NAME
	extra_hud.anchor_right = 1.0
	extra_hud.anchor_bottom = 1.0
	extra_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ui_layer = hud.get_parent()
	ui_layer.add_child(extra_hud)
	ui_layer.move_child(extra_hud, hud.get_index() + 1)
	extra_hud.owner = main
	extra_hud.add_child(extra_things)
	_adopt(extra_things, main)

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

	extra_hud.setup(hud,
			[main.get_node("%LifeContainerP1"), main.get_node("%LifeContainerP2")],
			[main.get_node("%LifeContainerP3"), main.get_node("%LifeContainerP4")])
	result.ok = true
	return result


# The team-wide children of P1's block, the bag of leftover materials
# (UIBonusGold: wave-end materials fly to it, main.gd get_gold_bag_pos) and
# the FPS label, sit below P1's own rows, where P5's block now starts: the
# bag and the flying materials were drawn inside P5's bars. They move to the
# end of P5's block, still the bottom of the top-left HUD stack as in
# vanilla. Called after Main._ready: its onready references to them follow
# the nodes.
static func attach_team_widgets(main: Node) -> bool:
	var source = main.get_node_or_null("%LifeContainerP1")
	var target = main.get_node_or_null("%%LifeContainerP%d" % (VANILLA_SLOTS + 1))
	if source == null or target == null:
		return false
	for child in source.get_children():
		if _is_block_child(child):
			continue
		source.remove_child(child)
		target.add_child(child)
		_adopt(child, main)
	return true


# Vanilla set_hud_position only knows corners 0..3; P5..P8 reuse P1..P4's.
static func place_player_huds(players_ui: Array) -> void:
	for i in range(VANILLA_SLOTS, players_ui.size()):
		if players_ui[i] != null:
			players_ui[i].set_hud_position((i - VANILLA_SLOTS) % VANILLA_SLOTS)


static func _strip_shared_children(block: Node) -> void:
	for child in block.get_children():
		if not _is_block_child(child):
			block.remove_child(child)
			child.free()


static func _is_block_child(child: Node) -> bool:
	for prefix in BLOCK_CHILD_PREFIXES:
		if child.name.begins_with(prefix):
			return true
	return false


# find_node only searches owned nodes, and a fresh duplicate has no owner.
static func _find_named(node: Node, wanted: String) -> Node:
	for child in node.get_children():
		if child.name == wanted:
			return child
		var found := _find_named(child, wanted)
		if found != null:
			return found
	return null


# The copied layer keeps the unique-name flags of its template nodes
# (ThingsToProcessMarginContainer itself, ...); only the renamed P5..P8
# containers are looked up by unique name.
static func _drop_unique_names(node: Node) -> void:
	if node.unique_name_in_owner and not node.name.begins_with(THINGS_PREFIX):
		node.unique_name_in_owner = false
	for child in node.get_children():
		if child.owner == null:
			_drop_unique_names(child)


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
