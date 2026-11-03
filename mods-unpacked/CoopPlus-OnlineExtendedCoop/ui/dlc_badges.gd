extends HBoxContainer
# One player's DLC icons in an online extended room (D-014): for every DLC
# that some player in the room has installed, its item set bar icon
# (UpdateData.icon) in the DLC's colour when this player has it, greyed when
# not (or not reported yet), so the players who keep a DLC off are visible at
# a glance. Hidden when the room rule does not apply
# (scripts/bo/dlc_roster.gd is_active). Refreshes itself; layout only.

const DlcRoster = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/dlc_roster.gd")
const SCRIPT_PATH := "res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/dlc_badges.gd"
const NODE_NAME := "CoopPlusDlcBadges"
const ICON_SIZE := Vector2(32, 32)
const MISSING_MODULATE := Color(0.5, 0.5, 0.5, 0.35)
const CORNER_MARGIN := 10.0
const REFRESH_SEC := 0.5

var player_index := -1
var _key := ""
var _refresh_left := 0.0


# In the top-right corner of a panel. Containers size their children to fill
# them, so the badges sit in a full-size holder that ignores the mouse.
static func overlay(panel: Control, index: int) -> HBoxContainer:
	var holder = panel.get_node_or_null(NODE_NAME + "Holder")
	if holder == null:
		holder = Control.new()
		holder.name = NODE_NAME + "Holder"
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.anchor_right = 1.0
		holder.anchor_bottom = 1.0
		panel.add_child(holder)
		var badges = load(SCRIPT_PATH).new()
		badges.anchor_left = 1.0
		badges.anchor_right = 1.0
		badges.margin_left = -CORNER_MARGIN
		badges.margin_right = -CORNER_MARGIN
		badges.margin_top = CORNER_MARGIN
		badges.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		holder.add_child(badges)
	var badges = holder.get_child(0)
	badges.player_index = index
	return badges


# As the last item of a box (a player status strip row).
static func inline(box: BoxContainer, index: int) -> HBoxContainer:
	var badges = load(SCRIPT_PATH).new()
	badges.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badges.player_index = index
	box.add_child(badges)
	return badges


func _init() -> void:
	name = NODE_NAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_constant_override("separation", 4)
	visible = false


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_SEC
	refresh()


func refresh() -> void:
	var roster = DlcRoster.find(get_tree())
	var active: bool = roster != null and roster.is_active() and player_index >= 0
	var owners: Dictionary = roster.current_owners() if active else {}
	var shown := []
	if active:
		for update in DlcRoster.dlc_updates():
			for i in range(RunData.get_player_count()):
				if update.id in owners.get(i, []):
					shown.append(update)
					break
	var mine: Array = owners.get(player_index, [])
	var ids := []
	for update in shown:
		ids.append([update.id, update.id in mine])
	var key := var2str(ids)
	if key == _key:
		return
	_key = key
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for update in shown:
		var icon := TextureRect.new()
		icon.texture = update.icon
		icon.expand = true
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.rect_min_size = ICON_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.modulate = update.color if update.id in mine else MISSING_MODULATE
		add_child(icon)
	visible = not shown.empty()
