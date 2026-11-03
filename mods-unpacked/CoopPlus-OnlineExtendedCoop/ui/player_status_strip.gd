extends VBoxContainer
# Compact rows for the other players on the 5..8 player panel screens
# (AP-014 layout "own panel large", D-010). One row per player: player-coloured
# panel (CoopService.change_stylebox_for_player, as the vanilla panels do),
# character icon, "P<n> <character>", a status line that depends on the screen
# and, right of it, the player's weapons on their tier colours (D-011):
#   shop     gold and whether the player pressed GO
#   upgrades whether the player is still choosing
#   end_run  level, weapon and item counts
#   character, weapon (selection screens, D-012) one compact line: the
#            character/weapon the player has picked or is pointing at, and
#            whether they have picked; no weapon list. On character selection
#            the row ends with the player's DLC icons in online extended rooms
#            (ui/dlc_badges.gd, D-014)
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
# With more than VISIBLE_ROWS rows (nine players or more) the strip shows
# VISIBLE_ROWS of them at a time (as many as an eight-player room has, which
# fit every screen; END_RUN_WINDOW_ROWS on the end-of-run screen) between two
# lines naming the players above and below. A row grows to two lines of
# weapons from seven weapons on; while the strip runs past the bottom of the
# screen it shows one row fewer (_fit_window, at least MIN_WINDOW_ROWS).
# scroll_rows moves the window: a whole page of new rows, or one row so the
# top one leaves as the next comes in, as chosen per PC (load_scroll_mode,
# the game's Gameplay options, ui/options_entry.gd). ui/panel_view_controller.gd
# calls it for the mouse wheel over the strip and the right stick, and
# step_focus when the local cursor moves past the first or last shown row.
# Fonts and panel styles come from the screen's theme. Layout only: it never
# changes game state.

const PanelPopups = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/panel_popups.gd")
const DlcBadges = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/dlc_badges.gd")
const ListWindow = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/list_window.gd")

const MODE_SHOP := "shop"
const MODE_UPGRADES := "upgrades"
const MODE_END_RUN := "end_run"
const MODE_CHARACTER := "character"
const MODE_WEAPON := "weapon"
const SELECTION_MODES := [MODE_CHARACTER, MODE_WEAPON]
const COMPACT_ICON_SIZE := Vector2(40, 40)
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
const VISIBLE_ROWS := 7
# End-of-run rows are taller (two lines of weapons from seven on) and the
# screen starts lower: with the two lines naming the other players and the
# scroll hint, seven rows ran past the bottom of a 1080 px screen.
const END_RUN_WINDOW_ROWS := 6
const MIN_WINDOW_ROWS := 3
const SCROLL_PAGE := ListWindow.MODE_PAGE
const SCROLL_ROW := ListWindow.MODE_ROW
const PREFS_PATH := "user://coopplus_view.cfg"
const PREFS_SECTION := "view"
const PREFS_SCROLL_KEY := "list_scroll"
const MORE_FONT_SIZE := 26
const MORE_HEIGHT := 34.0

const TEXT := {
	"zh": {"ready": "已准备", "shopping": "选购中", "choosing": "选择中", "done": "已完成", "level": "等级 %d", "weapons": "武器 %d", "items": "道具 %d", "hint": "选择玩家可展开或收起其面板", "toggle": "V / 手柄 Back 键：四人视图", "selected": "已选择", "scroll": "鼠标滚轮 / 右摇杆：翻看更多玩家"},
	"en": {"ready": "Ready", "shopping": "Shopping", "choosing": "Choosing", "done": "Done", "level": "LV.%d", "weapons": "Weapons %d", "items": "Items %d", "hint": "Select a player to show or hide their panel", "toggle": "V / gamepad Back: four-panel view", "selected": "Picked", "scroll": "Mouse wheel / right stick: more players"},
}

var _screen: Node = null
var _mode := MODE_SHOP
# player_index -> {panel, texts, title, status, weapons, weapons_key, style, selected_style, button}
var _rows := {}
var _refresh_left := 0.0
# Players in row order, and the index in it of the first shown row.
var _order := []
var _first := 0
var _window := VISIBLE_ROWS
# Lines above and below the rows naming the players out of view (windowed only).
var _more_above: HBoxContainer = null
var _more_below: HBoxContainer = null
var _more_font: Font = null
# Set by enable_view: {row, panels, local, stretch, popups}.
var _view := {}
var _viewed := -1
var _hint: Label = null


static func load_scroll_mode() -> String:
	var config := ConfigFile.new()
	if config.load(PREFS_PATH) != OK:
		return SCROLL_PAGE
	var value := str(config.get_value(PREFS_SECTION, PREFS_SCROLL_KEY, SCROLL_PAGE))
	return value if value in [SCROLL_PAGE, SCROLL_ROW] else SCROLL_PAGE


# Same file as the display mode (panel_view_controller.gd PREFS_PATH).
static func save_scroll_mode(mode: String) -> void:
	var config := ConfigFile.new()
	var _r = config.load(PREFS_PATH)
	config.set_value(PREFS_SECTION, PREFS_SCROLL_KEY, mode)
	var _s = config.save(PREFS_PATH)


func setup(screen: Node, mode: String, player_indices: Array) -> void:
	_screen = screen
	_mode = mode
	name = "CoopPlusPlayerStatusStrip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_FILL
	alignment = BoxContainer.ALIGN_CENTER
	add_constant_override("separation", 8 if _compact() else 12)
	_order = player_indices.duplicate()
	_window = END_RUN_WINDOW_ROWS if _mode == MODE_END_RUN else VISIBLE_ROWS
	if is_windowed():
		_more_above = _build_more_line("MoreAbove")
	for player_index in player_indices:
		_rows[player_index] = _build_row(player_index)
	if is_windowed():
		_more_below = _build_more_line("MoreBelow")
		_apply_window()
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


func is_windowed() -> bool:
	return _order.size() > VISIBLE_ROWS


# Moves the shown rows by one page or one row (load_scroll_mode) towards the
# end (dir 1) or the start (-1). False when already at that end.
func scroll_rows(dir: int) -> bool:
	if not is_windowed() or dir == 0:
		return false
	var first: int = ListWindow.scrolled(_first, _order.size(), _window_rows(), dir, load_scroll_mode())
	if first == _first:
		return false
	var focused_slot := _local_focused_slot()
	_first = first
	_apply_window()
	if focused_slot >= 0:
		# The local cursor stays on the same place in the list.
		_focus_row(int(min(_first + focused_slot, _last_shown())))
	return true


# Local cursor on the first shown row moving up, or on the last one moving
# down, with more rows that way: scrolls and puts the cursor on the next row.
func step_focus(dir: int) -> bool:
	var slot := _local_focused_slot()
	if slot < 0 or not is_windowed():
		return false
	var to := _first + slot + dir
	if to < 0 or to >= _order.size() or (to >= _first and to <= _last_shown()):
		return false
	_first = ListWindow.revealing(_first, _order.size(), _window_rows(), to, load_scroll_mode())
	_apply_window()
	_focus_row(to)
	return true


func _last_shown() -> int:
	return ListWindow.last_shown(_first, _order.size(), _window_rows())


# Rows shown at once once the list is windowed.
func _window_rows() -> int:
	return _window


# One row fewer while the strip's bottom is below the screen's (taller rows
# than the window was sized for). Never grows back on the same screen, so it
# cannot flip between two sizes.
func _fit_window() -> void:
	if not is_windowed() or _window <= MIN_WINDOW_ROWS or not is_visible_in_tree():
		return
	if get_global_rect().end.y <= get_viewport_rect().size.y + 0.5:
		return
	_window -= 1
	_apply_window()


func _apply_window() -> void:
	for k in _order.size():
		_rows[_order[k]].panel.visible = k >= _first and k <= _last_shown()
	_fill_more_line(_more_above, _order.slice(0, _first - 1) if _first > 0 else [], "▲")
	_fill_more_line(_more_below, _order.slice(_last_shown() + 1, _order.size() - 1) if _last_shown() + 1 < _order.size() else [], "▼")
	_link_shop_items()


# Same height with or without players named, so the rows do not move.
func _build_more_line(line_name: String) -> HBoxContainer:
	if _more_font == null:
		var base_font = get_font("font", "Label")
		if base_font is DynamicFont:
			_more_font = base_font.duplicate()
			_more_font.size = MORE_FONT_SIZE
	var line := HBoxContainer.new()
	line.name = line_name
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.alignment = BoxContainer.ALIGN_CENTER
	line.rect_min_size = Vector2(0, MORE_HEIGHT)
	line.add_constant_override("separation", 10)
	add_child(line)
	return line


func _fill_more_line(line: HBoxContainer, players: Array, arrow: String) -> void:
	if line == null:
		return
	for child in line.get_children():
		line.remove_child(child)
		child.queue_free()
	if players.empty():
		return
	line.add_child(_more_label(arrow, Color.white))
	for player_index in players:
		line.add_child(_more_label(str(player_index + 1), CoopService.get_player_color(player_index)))


func _more_label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_color_override("font_color", color)
	if _more_font != null:
		label.add_font_override("font", _more_font)
	return label


# Shown-row position (0 = first shown) of the row whose button holds the local
# cursor, or -1.
func _local_focused_slot() -> int:
	var emulator = _local_emulator()
	if emulator == null:
		return -1
	var focused = emulator.get("focused_control")
	for k in range(_first, _last_shown() + 1):
		var button = _rows[_order[k]].button
		if button != null and focused == button:
			return k - _first
	return -1


func _focus_row(k: int) -> void:
	var emulator = _local_emulator()
	var button = _rows[_order[k]].button if k >= 0 and k < _order.size() else null
	if emulator != null and button != null and button.is_visible_in_tree():
		Utils.focus_player_control(button, _view.local, emulator)


func _local_emulator():
	if _view.empty() or not is_instance_valid(_screen):
		return null
	return _screen.get_node_or_null("FocusEmulator%d" % (_view.local + 1))


func _update_hint() -> void:
	var t := _texts()
	_hint.text = (t.hint + "\n" if not _view.empty() else "") + (t.scroll + "\n" if is_windowed() else "") + t.toggle


func _process(delta: float) -> void:
	_fit_window()
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
	icon.rect_min_size = COMPACT_ICON_SIZE if _compact() else ICON_SIZE
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var character = null if _compact() else RunData.get_player_character(player_index)
	if character != null:
		icon.texture = character.icon
	row.add_child(icon)

	var texts: BoxContainer = HBoxContainer.new() if _compact() else VBoxContainer.new()
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _compact():
		texts.alignment = BoxContainer.ALIGN_BEGIN
		texts.add_constant_override("separation", 24)
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
	if _mode == MODE_CHARACTER:
		var badges = DlcBadges.inline(row, player_index)
		badges.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_SHRINK_END
	return {"panel": panel, "icon": icon, "texts": texts, "title": title, "status": status, "weapons": weapons, "weapons_key": null,
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
# the shown player's row while it is in view, else the first row in view
# (restore: vanilla's self link).
# The four item nodes live as long as the shop (shop_items_container.gd _ready).
func _link_shop_items(restore: bool = false) -> void:
	if _mode != MODE_SHOP or _view.empty() or _rows.empty() or not is_instance_valid(_screen) or not _screen.has_method("_get_shop_items_container"):
		return
	var container = _screen._get_shop_items_container(_view.local)
	if container == null or not "_shop_items" in container:
		return
	var first: int = _order[_first]
	var shown: bool = _viewed >= 0 and _rows.has(_viewed) and _rows[_viewed].panel.visible
	var target = select_button(_viewed if shown else first)
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
	if _compact():
		for player_index in _rows:
			_refresh_selection_row(_rows[player_index], player_index)
		return
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


func _compact() -> bool:
	return _mode in SELECTION_MODES


# Picked item if the player has picked, else the element they point at
# (base_selection.gd _latest_focused_element; the random element shows its
# own icon).
func _refresh_selection_row(entry: Dictionary, player_index: int) -> void:
	var t := _texts()
	var picked := false
	var item = null
	var icon: Texture = null
	var item_name := ""
	if is_instance_valid(_screen):
		var flags = _screen.get("_has_player_selected")
		picked = flags is Array and player_index < flags.size() and bool(flags[player_index])
		var chosen = _screen.get("_player_characters" if _mode == MODE_CHARACTER else "_player_weapons")
		if picked and chosen is Array and player_index < chosen.size():
			item = chosen[player_index]
			# 1.2.0.0 keeps a list of picks per player on the weapon screen
			# (weapon_selection.gd:5, 167): show the latest one.
			if item is Array:
				item = item.back() if not item.empty() else null
		if item != null and not item is Object:
			item = null
		if item == null:
			var focused = _screen.get("_latest_focused_element")
			var element = focused[player_index] if focused is Array and player_index < focused.size() else null
			if is_instance_valid(element):
				if bool(element.get("is_random")) and element.has_method("get_inventory_icon"):
					icon = element.get_inventory_icon()
					item_name = tr("RANDOM")
				else:
					item = element.get("item")
	if item != null:
		icon = item.get_icon() if item.has_method("get_icon") else item.get("icon")
		item_name = tr(str(item.get("name")))
	entry.icon.texture = icon
	entry.title.text = "P%d  %s" % [player_index + 1, item_name]
	entry.status.text = t.selected if picked else t.choosing


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
