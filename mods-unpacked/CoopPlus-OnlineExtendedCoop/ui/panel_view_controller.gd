extends Node
# Display modes of the 5..8 player panel screens (shop, upgrades, end of run)
# with one local player, chosen per PC (D-012):
#   focus  own panel large, the others in ui/player_status_strip.gd (D-010,
#          D-011); the default
#   pages  vanilla-style row of four panels; left/right slides the window one
#          player at a time (P5 comes in at the end, P1 leaves at the start)
# V or the gamepad's Back/View button switches modes on these screens; the
# choice is saved in PREFS_PATH. Both are unbound in the game's input map
# (project.binary) and in Brotato Online (Tab, F6, Ctrl, L3, LT).
# Sliding (pages): the right stick always; ui_left/ui_right (arrow keys, A/D,
# D-pad) only when the local cursor cannot move further that way, so they keep
# moving the cursor inside the panel (FocusEmulator's own neighbour search
# decides, focus_emulator.gd _get_focus_neighbour_for_event). On shop items
# vanilla locks left/right, so there they always slide. With the local panel
# outside the window its FocusEmulator ignores input (every focus base hidden)
# and left/right only slide.
# Added as the screen's last child so its _input runs before the
# FocusEmulators' (Godot calls _input in reverse tree order). Layout only: it
# never changes game state; hidden panels stay in the scene as in D-010.
# ui/selection_view_controller.gd reuses the input handling and the modes for
# the character and weapon selection screens; _begin, _apply_focus,
# _apply_pages, _order_row, _local_shown and _rescue_local_focus are its
# override points.

const PanelPopups = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/panel_popups.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const MODE_FOCUS := "focus"
const MODE_PAGES := "pages"
const PAGE_SIZE := 4
const PREFS_PATH := "user://coopplus_view.cfg"
const PREFS_SECTION := "view"
const PREFS_KEY := "mode"
const TOGGLE_KEY := KEY_V
const TOGGLE_JOY_BUTTON := JOY_SELECT
const STICK_AXIS := JOY_AXIS_2
const STICK_PRESS := 0.6
const STICK_RELEASE := 0.3
const SLIDE_COOLDOWN_SEC := 0.18
const EDGE_WIDTH := 40.0
const EDGE_FONT_SIZE := 26
const NOTICE_SEC := 4.0
const NOTICE_FADE_SEC := 0.5
const PAUSE_MENU_PATHS := ["UI/PauseMenu", "PauseMenu"]

const TEXT := {
	"zh": {
		"pages": "四人视图：←/→、十字键左右或右摇杆切换玩家；V / 手柄 Back 键切回本机放大",
		"focus": "本机放大视图；V / 手柄 Back 键切换四人视图",
	},
	"en": {
		"pages": "Four-panel view: ←/→, D-pad or right stick slides players; V / gamepad Back to switch back",
		"focus": "Own panel view; V / gamepad Back for the four-panel view",
	},
}

var _screen: Node = null
var _row: Container = null
var _panels := []
var _local := -1
var _holder: Control = null
var _strip = null
var _muted := {}
var _focus_stretch := 1.5
var _mode := MODE_FOCUS
var _count := 0
var _start := 0
var _cooldown := 0.0
var _stick_dir := 0
var _edges := []
var _edge_font: Font = null
var _notice: Control = null
var _notice_label: Label = null
var _notice_left := 0.0
# player index -> global rect of that player's focused control at the last redraw
var _frame_rects := {}


# panels: every player's panel in player order; holder/strip: the focus-mode
# status strip (local_focus_layout.gd); muted: PanelPopups.mute() record of the
# other players; focus_stretch: the local panel's ratio in focus mode.
func setup(screen: Node, row: Container, panels: Array, local: int, holder: Control, strip, muted: Dictionary, focus_stretch: float) -> void:
	_panels = panels
	_muted = muted
	_focus_stretch = focus_stretch
	_begin(screen, row, panels.size(), local, holder, strip)


# row: where the edge columns go; count: players on the screen.
func _begin(screen: Node, row: Container, count: int, local: int, holder: Control, strip) -> void:
	name = "CoopPlusPanelViewController"
	_screen = screen
	_row = row
	_count = count
	_local = local
	_holder = holder
	_strip = strip
	_start = int(clamp(local - (PAGE_SIZE - 1), 0, max(0, count - PAGE_SIZE)))
	_build_edges()
	_build_notice()
	_set_mode(load_mode(), false)
	if _mode == MODE_PAGES:
		_show_notice()


func display_mode() -> String:
	return _mode


func window_start() -> int:
	return _start


# Switches modes and remembers the choice on this PC.
func toggle_mode() -> void:
	_set_mode(MODE_PAGES if _mode == MODE_FOCUS else MODE_FOCUS, true)
	_show_notice()


# Pages mode: moves the window by dir (-1 left, 1 right). False at either end.
func slide(dir: int) -> bool:
	if _mode != MODE_PAGES:
		return false
	var start := int(clamp(_start + dir, 0, max(0, _count - PAGE_SIZE)))
	if start == _start:
		return false
	_start = start
	_apply_pages()
	return true


static func load_mode() -> String:
	var config := ConfigFile.new()
	if config.load(PREFS_PATH) != OK:
		return MODE_FOCUS
	var value := str(config.get_value(PREFS_SECTION, PREFS_KEY, MODE_FOCUS))
	return value if value in [MODE_FOCUS, MODE_PAGES] else MODE_FOCUS


static func save_mode(mode: String) -> void:
	var config := ConfigFile.new()
	var _r = config.load(PREFS_PATH)
	config.set_value(PREFS_SECTION, PREFS_KEY, mode)
	var _s = config.save(PREFS_PATH)


func _process(delta: float) -> void:
	_refresh_focus_frames()
	if _cooldown > 0.0:
		_cooldown -= delta
	if _notice_left > 0.0:
		_notice_left -= delta
		_notice.modulate.a = clamp(_notice_left / NOTICE_FADE_SEC, 0.0, 1.0)
		if _notice_left <= 0.0:
			_notice.visible = false


# FocusEmulator draws the stacked cursor frames of players sharing a control
# once, at the control's global rect at that moment, and redraws only when
# focus changes (focus_emulator.gd _draw). Players seated before the screen
# opens all focus the first cell before the layout settles, and this layout
# moves controls again (strip, hidden panels, edge columns), so the frames
# stayed half a cell above the cell (character selection, 8 players). Every
# emulator whose focused control moved redraws. The same happens with four
# players in the game itself, which this leaves alone (R08).
func _refresh_focus_frames() -> void:
	if not is_instance_valid(_screen):
		return
	for i in _count:
		var emulator = _screen.get_node_or_null("FocusEmulator%d" % (i + 1))
		if emulator == null:
			continue
		var control = emulator.get("focused_control")
		if control == null or not is_instance_valid(control) or not control is Control:
			continue
		var rect: Rect2 = control.get_global_rect()
		if not _frame_rects.has(i) or _frame_rects[i] != rect:
			_frame_rects[i] = rect
			emulator.update()


func _input(event: InputEvent) -> void:
	if _input_blocked():
		return
	if _is_toggle(event):
		toggle_mode()
		get_tree().set_input_as_handled()
		return
	if _mode != MODE_PAGES:
		return
	var dir := _stick_direction(event)
	if dir == 0:
		dir = _edge_direction(event)
	if dir == 0:
		return
	get_tree().set_input_as_handled()
	if _cooldown <= 0.0 and slide(dir):
		_cooldown = SLIDE_COOLDOWN_SEC


func _set_mode(mode: String, remember: bool) -> void:
	_mode = mode
	if remember:
		save_mode(mode)
	if mode == MODE_PAGES:
		_apply_pages()
	else:
		_apply_focus()


func _apply_focus() -> void:
	for edge in _edges:
		edge.visible = false
	for i in _panels.size():
		if i == _local or not is_instance_valid(_panels[i]):
			continue
		_panels[i].visible = false
		PanelPopups.set_registered(_screen, _muted, i, false)
	var local_panel: Control = _panels[_local]
	local_panel.visible = true
	local_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	local_panel.size_flags_stretch_ratio = _focus_stretch
	_holder.visible = true
	if _strip != null and _strip.has_method("enter_focus_mode"):
		_strip.enter_focus_mode()


func _apply_pages() -> void:
	if _strip != null and _strip.has_method("leave_focus_mode"):
		_strip.leave_focus_mode()
	_holder.visible = false
	_order_row()
	for i in _panels.size():
		var panel = _panels[i]
		if not is_instance_valid(panel):
			continue
		var shown: bool = i >= _start and i < _start + PAGE_SIZE
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_stretch_ratio = 1.0
		panel.visible = shown
		if i != _local:
			PanelPopups.set_registered(_screen, _muted, i, shown)
	_update_edges()
	_rescue_local_focus()


# The local cursor left on a (now hidden) strip row goes back to the local
# panel: the screen's own default control (base_shop.gd
# _get_default_focus_control), else the panel's first focusable control. Only
# while the local panel is inside the window; Utils.focus_player_control
# ignores hidden controls.
func _rescue_local_focus() -> void:
	var emulator = _local_emulator()
	var panel = _panels[_local]
	if emulator == null or not _local_shown():
		return
	var focused = emulator.focused_control
	if is_instance_valid(focused) and focused.is_visible_in_tree():
		return
	var target = null
	if _screen.has_method("_get_default_focus_control"):
		target = _screen._get_default_focus_control(_local)
	if not target is Control or not target.is_visible_in_tree():
		target = _first_focusable(panel)
	if target != null:
		Utils.focus_player_control(target, _local, emulator)


func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if not child is Control or not child.is_visible_in_tree():
			continue
		if child.focus_mode == Control.FOCUS_ALL and not (child is BaseButton and child.disabled):
			return child
		var inner := _first_focusable(child)
		if inner != null:
			return inner
	return null


# Panels back in player order (the strip moves a shown panel next to the
# local one), between the two edge columns and before the strip holder.
func _order_row() -> void:
	var order := [_edges[0]]
	for panel in _panels:
		if is_instance_valid(panel) and panel.get_parent() == _row:
			order.append(panel)
	order.append(_holder)
	order.append(_edges[1])
	for k in order.size():
		_row.move_child(order[k], k)


# Narrow columns at both ends of the row: an arrow and the numbers of the
# players beyond that end, in their colours. Always present in pages mode so
# the panel widths do not change while sliding.
func _build_edges() -> void:
	var probe := Label.new()
	_row.add_child(probe)
	var base_font = probe.get_font("font")
	_row.remove_child(probe)
	probe.free()
	if base_font is DynamicFont:
		_edge_font = base_font.duplicate()
		_edge_font.size = EDGE_FONT_SIZE
	for side in ["Left", "Right"]:
		var column := VBoxContainer.new()
		column.name = "CoopPlusPagesEdge" + side
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.rect_min_size = Vector2(EDGE_WIDTH, 0)
		column.alignment = BoxContainer.ALIGN_CENTER
		column.visible = false
		_row.add_child(column)
		_edges.append(column)


func _update_edges() -> void:
	var hidden_left := range(0, _start)
	var hidden_right := range(_start + PAGE_SIZE, _count)
	_fill_edge(_edges[0], hidden_left, "◀", true)
	_fill_edge(_edges[1], hidden_right, "▶", false)


func _fill_edge(column: Control, players: Array, arrow: String, arrow_first: bool) -> void:
	column.visible = true
	for child in column.get_children():
		column.remove_child(child)
		child.queue_free()
	if players.empty():
		return
	if arrow_first:
		column.add_child(_edge_label(arrow, Color.white))
	for i in players:
		column.add_child(_edge_label(str(i + 1), CoopService.get_player_color(i)))
	if not arrow_first:
		column.add_child(_edge_label(arrow, Color.white))


func _edge_label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.align = Label.ALIGN_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_color_override("font_color", color)
	if _edge_font != null:
		label.add_font_override("font", _edge_font)
	return label


# Short note at the top of the screen after a switch (and when a screen opens
# in pages mode). Its parent is this Node, so it is laid out against the
# viewport and drawn above the screen.
func _build_notice() -> void:
	_notice = PanelContainer.new()
	_notice.name = "CoopPlusViewNotice"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.04, 0.88)
	style.set_corner_radius_all(8)
	for margin in [MARGIN_LEFT, MARGIN_RIGHT]:
		style.set_default_margin(margin, 18)
	for margin in [MARGIN_TOP, MARGIN_BOTTOM]:
		style.set_default_margin(margin, 8)
	_notice.add_stylebox_override("panel", style)
	_notice_label = Label.new()
	_notice_label.align = Label.ALIGN_CENTER
	if _edge_font != null:
		_notice_label.add_font_override("font", _edge_font)
	_notice.add_child(_notice_label)
	_notice.visible = false
	add_child(_notice)


func _show_notice() -> void:
	var texts: Dictionary = TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else TEXT["en"]
	_notice_label.text = texts[_mode]
	_notice.visible = true
	_notice.modulate.a = 1.0
	_notice_left = NOTICE_SEC
	_notice.rect_size = Vector2.ZERO
	var size := _notice.get_combined_minimum_size()
	var view := get_viewport().get_visible_rect().size
	_notice.rect_position = Vector2((view.x - size.x) * 0.5, 12)


# Not while the screen is hidden (the upgrade screen outside its turn), under
# the pause menu, or while Brotato Online has suspended the local
# FocusEmulator for one of its overlays (player list, quick chat).
func _input_blocked() -> bool:
	if not is_instance_valid(_screen) or not _screen is CanvasItem or not _screen.is_visible_in_tree():
		return true
	var scene = get_tree().current_scene
	if scene != null:
		for path in PAUSE_MENU_PATHS:
			var menu = scene.get_node_or_null(path)
			if menu != null and menu is CanvasItem and menu.is_visible_in_tree():
				return true
	var emulator = _local_emulator()
	return emulator != null and not emulator.is_processing_input()


func _is_toggle(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and (event.scancode == TOGGLE_KEY or event.physical_scancode == TOGGLE_KEY)
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == TOGGLE_JOY_BUTTON and not RuntimeGate.is_virtual_device(event.device)
	return false


# Right stick: one slide per push; it has to come back to the centre first.
func _stick_direction(event: InputEvent) -> int:
	if not event is InputEventJoypadMotion or event.axis != STICK_AXIS or RuntimeGate.is_virtual_device(event.device):
		return 0
	var value: float = event.axis_value
	if _stick_dir == 0 and abs(value) >= STICK_PRESS:
		_stick_dir = 1 if value > 0.0 else -1
		return _stick_dir
	if _stick_dir != 0 and abs(value) <= STICK_RELEASE:
		_stick_dir = 0
	return 0


func _edge_direction(event: InputEvent) -> int:
	if _local < 0 or _local >= CoopService.connected_players.size():
		return 0
	var device := int(CoopService.connected_players[_local][0])
	var dir := 0
	for pair in [["ui_left", -1], ["ui_right", 1]]:
		var action := "%s_%d" % [pair[0], device]
		if InputMap.has_action(action) and event.is_action_pressed(action):
			dir = pair[1]
	if dir == 0:
		return 0
	var emulator = _local_emulator()
	if emulator == null or not _local_shown():
		return dir
	var focused = emulator.focused_control
	if not is_instance_valid(focused) or not focused.is_visible_in_tree() or not emulator.has_method("_get_focus_neighbour_for_event"):
		return dir
	var result = emulator._get_focus_neighbour_for_event(event, focused)
	if result.control == null or result.control == focused:
		return dir
	return 0


# Whether the local player's panel is on screen.
func _local_shown() -> bool:
	return is_instance_valid(_panels[_local]) and _panels[_local].is_visible_in_tree()


func _local_emulator():
	return _screen.get_node_or_null("FocusEmulator%d" % (_local + 1)) if is_instance_valid(_screen) else null
