extends MarginContainer
# Battle HUD layer for one group of four players beyond P4 (P5..P8,
# P9..P12, ...; ui/extra_player_hud.gd). It keeps the HUD's margins, pushed in
# vertically by the rows of blocks before it (P1/P2 and every earlier group's
# top pair above, P3/P4 and their bottom pairs below), so P5/P6 start just
# below P1/P2, P9/P10 just below P5/P6, and P7/P8 end just above P3/P4. The blocks
# only reach their real height once their labels have text (and P1's block
# hands the team bag to P5, extra_player_hud.gd attach_team_widgets), so the
# margins follow the blocks' sizes instead of being fixed when the scene is
# built: a fixed estimate left P5 overlapping P1 by 12 px at 1920x1080.

const BLOCK_GAP := 16.0
const MIN_BLOCK_HEIGHT := 140.0

var _hud: Control = null
var _min_block_height := MIN_BLOCK_HEIGHT
var _block_gap := BLOCK_GAP
# Rows of blocks before this layer: [[P1, P2], [P5, P6], ...] / [[P3, P4], ...].
var _top_rows := []
var _bottom_rows := []


func setup(hud: Control, top_rows: Array, bottom_rows: Array) -> void:
	_hud = hud
	_top_rows = top_rows
	_bottom_rows = bottom_rows
	for row in top_rows + bottom_rows:
		for block in row:
			if not block.is_connected("resized", self, "_update_margins"):
				var _e = block.connect("resized", self, "_update_margins")
	_update_margins()


# Compact blocks (ui/compact_hud.gd) are much lower than the 140 px floor.
func set_spacing(min_block_height: float, block_gap: float) -> void:
	_min_block_height = min_block_height
	_block_gap = block_gap
	_update_margins()


func _update_margins() -> void:
	if _hud == null or not is_instance_valid(_hud):
		return
	var top := 0.0
	for row in _top_rows:
		top += _half_offset(row)
	var bottom := 0.0
	for row in _bottom_rows:
		bottom += _half_offset(row)
	for side in ["left", "right", "top", "bottom"]:
		var value := int(_hud.get("custom_constants/margin_" + side))
		if side == "top":
			value += int(top)
		elif side == "bottom":
			value += int(bottom)
		if int(get("custom_constants/margin_" + side)) != value:
			add_constant_override("margin_" + side, value)


func _half_offset(blocks: Array) -> float:
	var height := _min_block_height
	for block in blocks:
		if is_instance_valid(block) and block.visible:
			height = max(height, max(block.rect_size.y, block.get_combined_minimum_size().y))
	return height + _block_gap
