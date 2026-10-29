extends "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/panel_view_controller.gd"
# The two display modes (D-012) on the character and weapon selection screens
# with more than four players and one local player. Each player has several
# nodes there (character: Panel + LockedPanel in one row; weapon: Panel in the
# panel row + inventory in the inventory row). The game shows and hides them
# itself on every focus change, and Brotato Online sets the remote players'
# panels visible whenever it applies the host's selection state
# (menu_sync_manager.gd _apply_item_to_panel), so this mode never touches
# `visible`: a player outside the view is taken out of the container layout
# instead (set_as_toplevel, moved off screen) and put back when shown. Their
# FocusEmulators keep a visible focus area, so remote input keeps working.
#   focus  the local player's nodes and a compact status strip
#          (ui/player_status_strip.gd modes "character"/"weapon")
#   pages  four players, sliding as on the panel screens
# The edge columns float just outside the shown panels instead of taking room
# in the row: the character row has the run options beside it and four panels
# plus two columns did not fit (EV-0031).
# Input handling, the switch key and the saved choice are the parent's.
# apply() builds it; teardown() restores the vanilla layout (players joining
# or leaving character selection rebuild it).

signal layout_changed()

const PlayerStatusStrip = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/player_status_strip.gd")
const OFFSCREEN := Vector2(-20000, -20000)
const STRIP_WIDTH := 640.0
const STRIP_MARGIN := 15
# Vanilla panels per screen (= the parent's PAGE_SIZE, which a GDScript 1 static
# function cannot see).
const VANILLA_PANELS := 4
const EDGE_GAP := 6.0

# player_index -> [Control, ...]
var _groups := []
var _suppressed := {}


# groups: every player's nodes in player order; row: the panel row (edge
# columns and the strip go there); mode: "character" or "weapon". Returns the
# controller, or null when the layout does not apply.
static func apply(screen: Node, groups: Array, row: Container, mode: String, local: int) -> Node:
	if groups.size() <= VANILLA_PANELS or row == null or local < 0 or local >= groups.size():
		return null
	var holder := PanelContainer.new()
	holder.name = "CoopPlusSelectionStripHolder"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.rect_min_size = Vector2(STRIP_WIDTH, 0)
	holder.size_flags_horizontal = Control.SIZE_FILL
	var style := StyleBoxEmpty.new()
	for margin in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
		style.set_default_margin(margin, STRIP_MARGIN)
	holder.add_stylebox_override("panel", style)
	row.add_child(holder)
	var others := []
	for i in groups.size():
		if i != local:
			others.append(i)
	var strip = PlayerStatusStrip.new()
	holder.add_child(strip)
	strip.setup(screen, mode, others)
	var controller = load("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/selection_view_controller.gd").new()
	screen.add_child(controller)
	controller.setup_selection(screen, row, groups, local, holder, strip)
	return controller


func setup_selection(screen: Node, row: Container, groups: Array, local: int, holder: Control, strip) -> void:
	_groups = groups
	_begin(screen, row, groups.size(), local, holder, strip)
	var _e = row.connect("item_rect_changed", self, "_position_edges")


# Back to the vanilla layout; frees the strip, the edge columns and itself.
func teardown() -> void:
	for control in _suppressed.keys():
		_set_suppressed(control, false)
	# Out of the row at once, so a rebuilt layout in the same frame does not
	# lay out next to them until the end-of-frame free.
	for node in _edges + [_holder]:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
	if is_instance_valid(_notice):
		_notice.queue_free()
	queue_free()


# Players currently laid out (for the weapon inventories' column count).
func shown_players() -> int:
	return 1 if _mode == MODE_FOCUS else int(min(PAGE_SIZE, _count))


func _apply_focus() -> void:
	for edge in _edges:
		edge.visible = false
	for i in _groups.size():
		_set_group_shown(i, i == _local)
	_holder.visible = true
	_place_holder()
	emit_signal("layout_changed")


func _apply_pages() -> void:
	_holder.visible = false
	for i in _groups.size():
		_set_group_shown(i, i >= _start and i < _start + PAGE_SIZE)
	_update_edges()
	call_deferred("_position_edges")
	emit_signal("layout_changed")


# The players' own order is already right (the clones follow P4).
func _order_row() -> void:
	pass


func _build_edges() -> void:
	._build_edges()
	for edge in _edges:
		edge.set_as_toplevel(true)


# After the row has been laid out: beside the outermost shown nodes of the row.
func _position_edges() -> void:
	if _mode != MODE_PAGES or not is_instance_valid(_row):
		return
	var left := INF
	var right := -INF
	var top := 0.0
	var height := 0.0
	for group in _groups:
		for control in group:
			if not is_instance_valid(control) or control.get_parent() != _row or _suppressed.has(control) or not control.visible:
				continue
			var rect: Rect2 = control.get_global_rect()
			left = min(left, rect.position.x)
			right = max(right, rect.end.x)
			top = rect.position.y
			height = max(height, rect.size.y)
	if left == INF:
		return
	# Kept on screen: the character row starts right at the screen margin, so
	# the left column may overlap the first panel's edge a little.
	var view_width := get_viewport().get_visible_rect().size.x
	_edges[0].rect_size = Vector2(EDGE_WIDTH, height)
	_edges[0].rect_global_position = Vector2(max(0.0, left - EDGE_GAP - EDGE_WIDTH), top)
	_edges[1].rect_size = Vector2(EDGE_WIDTH, height)
	_edges[1].rect_global_position = Vector2(min(view_width - EDGE_WIDTH, right + EDGE_GAP), top)


func _place_holder() -> void:
	var last := -1
	for control in _groups[_local]:
		if is_instance_valid(control) and control.get_parent() == _row:
			last = int(max(last, control.get_index()))
	if last >= 0:
		var to := last + 1
		if _holder.get_index() < last:
			to -= 1
		_row.move_child(_holder, to)


func _local_shown() -> bool:
	for control in _groups[_local]:
		if is_instance_valid(control) and _suppressed.has(control):
			return false
	return true


# The local cursor lives in an inventory, which this mode never hides.
func _rescue_local_focus() -> void:
	pass


func _set_group_shown(player_index: int, shown: bool) -> void:
	for control in _groups[player_index]:
		if is_instance_valid(control):
			_set_suppressed(control, not shown)


func _set_suppressed(control: Control, suppressed: bool) -> void:
	if suppressed == _suppressed.has(control):
		return
	if suppressed:
		_suppressed[control] = true
		control.set_as_toplevel(true)
		control.rect_global_position = OFFSCREEN
	else:
		_suppressed.erase(control)
		control.set_as_toplevel(false)
	var parent = control.get_parent()
	if parent is Container:
		parent.queue_sort()
