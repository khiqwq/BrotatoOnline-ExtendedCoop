extends Reference
# Compact battle HUD for more than eight players. A full block (a 320x50 life
# bar with its numbers, a 320x50 experience bar with the level, a 64 px
# materials icon with size-50 digits) is about 170 px tall, so only three fit
# above each other in a screen corner; from the ninth player on every block,
# P1's included, becomes a thin life bar, a thinner experience bar and a
# small materials icon and number. The numbers on the bars are hidden (there
# is no room for them); the materials count stays. The pending-icon layers
# (level-up potatoes, crates) move in to sit next to the narrower blocks, and
# the block layers stack with smaller gaps (ui/extra_hud_layer.gd).
# Layout only: vanilla keeps updating the values (player_ui_elements.gd).

const ABOVE_PLAYERS := 8
const LIFE_BAR_SIZE := Vector2(150, 12)
const XP_BAR_SIZE := Vector2(150, 6)
const BAR_STRETCH_MARGIN := 3
const GOLD_ICON_SIZE := Vector2(26, 26)
const GOLD_FONT_SIZE := 24
const GOLD_OUTLINE_SIZE := 2
const BLOCK_SEPARATION := 2
# Vanilla puts the pending icons 348 px in from the HUD edge: a 320 px block
# and 28 px of space (main.tscn ThingsToProcessMarginContainer).
const THINGS_MARGIN := 150 + 28
const LAYER_MIN_BLOCK_HEIGHT := 0.0
const LAYER_BLOCK_GAP := 8.0
const THINGS_LAYER_PATH := "%ThingsToProcessMarginContainer"


static func applies(player_count: int) -> bool:
	return player_count > ABOVE_PLAYERS


# players_ui: Main._players_ui (PlayerUIElements of every spawned player).
# extra_layers: the block layers of ui/extra_player_hud.gd.
static func apply(main: Node, players_ui: Array, extra_layers: Array) -> void:
	for ui in players_ui:
		if ui == null:
			continue
		_bar(ui.life_bar, ui.life_label, LIFE_BAR_SIZE)
		_bar(ui.xp_bar, ui.level_label, XP_BAR_SIZE)
		_gold(ui.gold)
		if is_instance_valid(ui.hud_container):
			ui.hud_container.add_constant_override("separation", BLOCK_SEPARATION)
	var things_layers := [main.get_node_or_null(THINGS_LAYER_PATH)]
	for layer in extra_layers:
		if is_instance_valid(layer):
			layer.set_spacing(LAYER_MIN_BLOCK_HEIGHT, LAYER_BLOCK_GAP)
			for child in layer.get_children():
				if child is MarginContainer:
					things_layers.append(child)
	for things in things_layers:
		if is_instance_valid(things):
			things.add_constant_override("margin_left", THINGS_MARGIN)
			things.add_constant_override("margin_right", THINGS_MARGIN)


# A TextureProgress shows its textures at their own size unless it stretches
# them as nine-patches; the frame keeps a thin border.
static func _bar(bar, label, size: Vector2) -> void:
	if not is_instance_valid(bar):
		return
	bar.nine_patch_stretch = true
	bar.stretch_margin_left = BAR_STRETCH_MARGIN
	bar.stretch_margin_right = BAR_STRETCH_MARGIN
	bar.stretch_margin_top = BAR_STRETCH_MARGIN
	bar.stretch_margin_bottom = BAR_STRETCH_MARGIN
	bar.rect_min_size = size
	bar.rect_size = size
	# The label sits in a MarginContainer of the bar (main.tscn); vanilla only
	# ever shows or hides the label itself, so hiding its holder sticks.
	if is_instance_valid(label) and label.get_parent() is Control and label.get_parent() != bar:
		label.get_parent().hide()
	elif is_instance_valid(label):
		label.self_modulate.a = 0.0


static func _gold(gold) -> void:
	if not is_instance_valid(gold):
		return
	var icon = gold.get("icon")
	if icon is TextureRect:
		icon.expand = true
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.rect_min_size = GOLD_ICON_SIZE
		icon.rect_size = GOLD_ICON_SIZE
	var label = gold.get("gold_label")
	if label is Label:
		var font = label.get_font("font")
		if font is DynamicFont:
			font = font.duplicate()
			font.size = GOLD_FONT_SIZE
			font.outline_size = GOLD_OUTLINE_SIZE
			font.extra_spacing_top = 0
			label.add_font_override("font", font)
