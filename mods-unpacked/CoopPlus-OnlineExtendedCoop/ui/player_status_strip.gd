extends VBoxContainer
# Compact rows for the other players on the 5..8 player panel screens
# (AP-014 layout "own panel large", D-010). One row per player: player-coloured
# panel (CoopService.change_stylebox_for_player, as the vanilla panels do),
# character icon, "P<n> <character>", a status line that depends on the screen
# and, right of it, the player's weapons on their tier colours (D-011):
#   shop     gold and whether the player pressed GO
#   upgrades whether the player is still choosing
#   end_run  level, weapon and item counts
# On the shop and end-run screens the rows can be selected (D-011, enable_view):
# each row holds a button inside the local player's FocusEmulator area
# (local_focus_layout.gd), so the gamepad/keyboard reaches it by moving right
# from the local panel (from a shop item too, _link_shop_items), and
# CoopFix-OnlineMouseUI's click routing finds it
# (vanilla FocusEmulator consumes native mouse events in co-op,
# focus_emulator.gd:52). Selecting a row shows that player's own vanilla panel
# next to the local one, the two splitting the left side evenly; selecting it
# again hides it. The shown panel is view-only here: it is outside the local
# player's focus area and Brotato Online keeps driving it from its owner.
# The strip is the focus mode of ui/panel_view_controller.gd (D-012), which
# calls leave_focus_mode/enter_focus_mode around the four-panel mode; the hint
# under the rows names the key that switches.
# Fonts and panel styles come from the screen's theme. Layout only: it never
# changes game state.

const PanelPopups = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/panel_popups.gd")

const MODE_SHOP := "shop"
const MODE_UPGRADES := "upgrades"
const MODE_END_RUN := "end_run"
const REFRESH_SEC := 0.25
const ICON_SIZE := Vector2(56, 56)
const WEAPON_SIZE := Vector2(52, 52)
const WEAPON_COLUMNS := 6
const WEAPON_BG_ALPHA := 0.35
const FOCUS_BORDER := 4
const SELECTED_BORDER := 6
# The theme's panel background is translucent; over the battle scene the
# upgrade screen would show the HUD blocks of P2..P8 through the rows
# (EV-0025), so rows are made close to opaque.
const ROW_MIN_BG_ALPHA := 0.95

const TEXT := {
	"zh": {"ready": "已准备", "shopping": "选购中", "choosing": "选择中", "done": "已完成", "level": "等级 %d", "weapons": "武器 %d", "items": "道具 %d", "hint": "选择玩家可展开或收起其面板", "toggle": "V / 手柄 Back 键：四人视图"},
	"en": {"ready": "Ready", "shopping": "Shopping", "choosing": "Choosing", "done": "Done", "level": "LV.%d", "weapons": "Weapons %d", "items": "Items %d", "hint": "Select a player to show or hide their panel", "toggle": "V / gamepad Back: four-panel view"},
}

var _screen: Node = null
var _mode := MODE_SHOP
# player_index -> {panel, texts, title, status, weapons, weapons_key, style, selected_style, button}
var _rows := {}
var _refresh_left := 0.0
# Set by enable_view: {row, panels, local, stretch, popups}.
var _view := {}
var _viewed := -1
var _hint: Label = null


func setup(screen: Node, mode: String, player_indices: Array) -> void:
	_screen = screen
	_mode = mode
	name = "CoopPlusPlayerStatusStrip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_FILL
	alignment = BoxContainer.ALIGN_CENTER
	add_constant_override("separation", 12)
	for player_index in player_indices:
		_rows[player_index] = _build_row(player_index)
	_hint = Label.new()
	_hint.name = "Hint"
	_hint.align = Label.ALIGN_CENTER
	_hint.autowrap = true
	_hint.modulate.a = 0.7
	add_child(_hint)
	_update_hint()
	_refresh()


# row: the screen's panel row; panels: every player's panel in player order;
# local: the local player's index; stretch: the local panel's stretch ratio
# with nothing shown beside it; popups: {PopupManager field: {player_index:
# popup}} un-registered by PanelPopups.mute().
func enable_view(row: Container, panels: Array, local: int, stretch: float, popups: Dictionary) -> void:
	_view = {"row": row, "panels": panels, "local": local, "stretch": stretch, "popups": popups}
	for player_index in _rows:
		_add_select_button(player_index)
	_update_hint()
	_link_shop_items()


func viewed_player() -> int:
	return _viewed


func select_button(player_index: int) -> Button:
	return _rows[player_index].button if _rows.has(player_index) else null


# Row pressed: show that player's panel, or hide it when it is already shown.
func toggle_player(player_index: int) -> void:
	_set_viewed(-1 if player_index == _viewed else player_index)
	_link_shop_items()


# Four-panel mode takes over the row: nothing shown beside the local panel,
# and the shop items' right neighbour back to vanilla.
func leave_focus_mode() -> void:
	_set_viewed(-1)
	_link_shop_items(true)


func enter_focus_mode() -> void:
	_link_shop_items()


func _update_hint() -> void:
	var t := _texts()
	_hint.text = (t.hint + "\n" if not _view.empty() else "") + t.toggle


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = REFRESH_SEC
		_refresh()


func _build_row(player_index: int) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "RowP%d" % (player_index + 1)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style = get_stylebox("panel", "PanelContainer")
	var selected_style = null
	if style != null:
		style = style.duplicate()
		CoopService.change_stylebox_for_player(style, player_index)
		if style is StyleBoxFlat:
			style.bg_color.a = max(style.bg_color.a, ROW_MIN_BG_ALPHA)
			selected_style = style.duplicate()
			selected_style.set_border_width_all(SELECTED_BORDER)
			selected_style.bg_color = style.bg_color.lightened(0.15)
		panel.add_stylebox_override("panel", style)
	add_child(panel)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_constant_override("separation", 16)
	panel.add_child(row)

	var icon := TextureRect.new()
	icon.rect_min_size = ICON_SIZE
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var character = RunData.get_player_character(player_index)
	if character != null:
		icon.texture = character.icon
	row.add_child(icon)

	var texts := VBoxContainer.new()
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(texts)
	var title := Label.new()
	title.text = "P%d  %s" % [player_index + 1, tr(character.name) if character != null else ""]
	title.add_color_override("font_color", CoopService.get_player_color(player_index))
	texts.add_child(title)
	var status := Label.new()
	texts.add_child(status)

	var weapons := GridContainer.new()
	weapons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	weapons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	weapons.add_constant_override("hseparation", 6)
	weapons.add_constant_override("vseparation", 6)
	row.add_child(weapons)
	return {"panel": panel, "texts": texts, "title": title, "status": status, "weapons": weapons, "weapons_key": null,
			"style": style, "selected_style": selected_style, "button": null}


# Behind the row content, filling the row; focus is drawn as a border over the
# row's own one.
func _add_select_button(player_index: int) -> void:
	var entry: Dictionary = _rows[player_index]
	var panel: PanelContainer = entry.panel
	var button := Button.new()
	button.name = "Select"
	button.focus_mode = Control.FOCUS_ALL
	button.flat = false
	var empty := StyleBoxEmpty.new()
	for style_name in ["normal", "hover", "pressed", "disabled"]:
		button.add_stylebox_override(style_name, empty)
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.border_color = Color.white
	focus.set_border_width_all(FOCUS_BORDER)
	var row_style = entry.style
	if row_style is StyleBoxFlat:
		focus.set_corner_radius_all(row_style.corner_radius_top_left)
	if row_style != null:
		focus.expand_margin_left = row_style.get_margin(MARGIN_LEFT)
		focus.expand_margin_top = row_style.get_margin(MARGIN_TOP)
		focus.expand_margin_right = row_style.get_margin(MARGIN_RIGHT)
		focus.expand_margin_bottom = row_style.get_margin(MARGIN_BOTTOM)
	button.add_stylebox_override("focus", focus)
	var _e = button.connect("pressed", self, "toggle_player", [player_index])
	panel.add_child(button)
	panel.move_child(button, 0)
	entry.button = button


func _set_viewed(player_index: int) -> void:
	if _view.empty() or player_index == _viewed:
		return
	var panels: Array = _view.panels
	var local_panel: Control = panels[_view.local]
	if _viewed >= 0:
		if is_instance_valid(panels[_viewed]):
			panels[_viewed].visible = false
		PanelPopups.set_registered(_screen, _view.popups, _viewed, false)
		_set_row_selected(_viewed, false)
		_viewed = -1
	local_panel.size_flags_stretch_ratio = _view.stretch
	if player_index < 0 or player_index >= panels.size() or not is_instance_valid(panels[player_index]) or not _rows.has(player_index):
		return
	var panel: Control = panels[player_index]
	var row: Container = _view.row
	if panel.get_parent() == row:
		# move_child removes before inserting: a panel left of the local one
		# shifts it by one.
		var to := local_panel.get_index() + 1
		if panel.get_index() < local_panel.get_index():
			to -= 1
		row.move_child(panel, to)
	var half: float = _view.stretch * 0.5
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = half
	local_panel.size_flags_stretch_ratio = half
	panel.visible = true
	PanelPopups.set_registered(_screen, _view.popups, player_index, true)
	_set_row_selected(player_index, true)
	_viewed = player_index


# Vanilla locks left/right on the shop items (coop_shop_item.tscn: BuyButton
# focus_neighbour_left/right = "."), so moving right from an item went
# nowhere. The local player's item buttons point right at the strip instead:
# the shown player's row, else the first row (restore: vanilla's self link).
# The four item nodes live as long as the shop (shop_items_container.gd _ready).
func _link_shop_items(restore: bool = false) -> void:
	if _mode != MODE_SHOP or _view.empty() or _rows.empty() or not is_instance_valid(_screen) or not _screen.has_method("_get_shop_items_container"):
		return
	var container = _screen._get_shop_items_container(_view.local)
	if container == null or not "_shop_items" in container:
		return
	var rows: Array = _rows.keys()
	rows.sort()
	var target = select_button(_viewed if _viewed >= 0 else rows[0])
	if target == null:
		return
	for shop_item in container._shop_items:
		var button = shop_item.get("_button") if is_instance_valid(shop_item) else null
		if button is Control:
			button.focus_neighbour_right = NodePath(".") if restore else button.get_path_to(target)


func _set_row_selected(player_index: int, selected: bool) -> void:
	var entry: Dictionary = _rows[player_index]
	var style = entry.selected_style if selected and entry.selected_style != null else entry.style
	if style != null:
		entry.panel.add_stylebox_override("panel", style)


func _refresh() -> void:
	var text_width := 0.0
	for player_index in _rows:
		var entry: Dictionary = _rows[player_index]
		entry.status.text = _status_text(player_index)
		_refresh_weapons(entry, player_index)
		text_width = max(text_width, max(entry.title.get_minimum_size().x, entry.status.get_minimum_size().x))
	# Same text column width in every row, so the weapon lists line up.
	for player_index in _rows:
		var texts: Control = _rows[player_index].texts
		if texts.rect_min_size.x != text_width:
			texts.rect_min_size.x = text_width


func _refresh_weapons(entry: Dictionary, player_index: int) -> void:
	var weapons: Array = RunData.get_player_weapons(player_index)
	var key := []
	for weapon in weapons:
		key.append("%s:%d" % [weapon.my_id, weapon.tier])
	var joined := ",".join(PoolStringArray(key))
	if entry.weapons_key == joined:
		return
	entry.weapons_key = joined
	var grid: GridContainer = entry.weapons
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	grid.columns = int(max(WEAPON_COLUMNS, ceil(weapons.size() / 2.0)))
	for weapon in weapons:
		grid.add_child(_weapon_cell(weapon))


# Tier background and frame as on the vanilla inventory elements
# (inventory_element.gd update_background_color).
func _weapon_cell(weapon: Resource) -> Control:
	var cell := PanelContainer.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.rect_min_size = WEAPON_SIZE
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(6)
	for margin in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
		style.set_default_margin(margin, 4)
	ItemService.change_inventory_element_stylebox_from_tier(style, weapon.tier, WEAPON_BG_ALPHA)
	var tier_color: Color = ItemService.get_color_from_tier(weapon.tier)
	if tier_color != Color.white:
		style.border_color = tier_color
		style.set_border_width_all(2)
	cell.add_stylebox_override("panel", style)
	var icon := TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = weapon.get_icon()
	cell.add_child(icon)
	return cell


func _texts() -> Dictionary:
	return TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else TEXT["en"]


func _status_text(player_index: int) -> String:
	var t := _texts()
	match _mode:
		MODE_SHOP:
			var is_ready := false
			if is_instance_valid(_screen) and "_player_pressed_go_button" in _screen:
				var pressed: Array = _screen._player_pressed_go_button
				is_ready = player_index < pressed.size() and bool(pressed[player_index])
			return "%d  ·  %s" % [RunData.get_player_gold(player_index), t.ready if is_ready else t.shopping]
		MODE_UPGRADES:
			var choosing := false
			if is_instance_valid(_screen) and "_player_is_choosing" in _screen:
				var flags: Array = _screen._player_is_choosing
				choosing = player_index < flags.size() and bool(flags[player_index])
			return t.choosing if choosing else t.done
		_:
			return "%s  ·  %s  ·  %s" % [t.level % RunData.get_player_level(player_index),
					t.weapons % RunData.get_player_weapons(player_index).size(),
					t.items % RunData.get_player_items(player_index).size()]
