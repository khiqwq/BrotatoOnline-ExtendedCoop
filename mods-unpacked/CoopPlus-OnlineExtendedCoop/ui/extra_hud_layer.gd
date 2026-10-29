extends MarginContainer
# Second battle HUD layer for P5..P8 (ui/extra_player_hud.gd). It keeps the
# HUD's margins, pushed in vertically by the height of the P1..P4 blocks, so
# P5/P6 start just below P1/P2 and P7/P8 end just above P3/P4. The blocks
# only reach their real height once their labels have text (and P1's block
# hands the team bag to P5, extra_player_hud.gd attach_team_widgets), so the
# margins follow the blocks' sizes instead of being fixed when the scene is
# built: a fixed estimate left P5 overlapping P1 by 12 px at 1920x1080.

const BLOCK_GAP := 16.0
const MIN_BLOCK_HEIGHT := 140.0

var _hud: Control = null
var _top_blocks := []
var _bottom_blocks := []


func setup(hud: Control, top_blocks: Array, bottom_blocks: Array) -> void:
	_hud = hud
	_top_blocks = top_blocks
	_bottom_blocks = bottom_blocks
	for block in top_blocks + bottom_blocks:
		if not block.is_connected("resized", self, "_update_margins"):
			var _e = block.connect("resized", self, "_update_margins")
	_update_margins()


func _update_margins() -> void:
	if _hud == null or not is_instance_valid(_hud):
		return
	var top := _half_offset(_top_blocks)
	var bottom := _half_offset(_bottom_blocks)
	for side in ["left", "right", "top", "bottom"]:
		var value := int(_hud.get("custom_constants/margin_" + side))
		if side == "top":
			value += int(top)
		elif side == "bottom":
			value += int(bottom)
		if int(get("custom_constants/margin_" + side)) != value:
			add_constant_override("margin_" + side, value)


func _half_offset(blocks: Array) -> float:
	var height := MIN_BLOCK_HEIGHT
	for block in blocks:
		if is_instance_valid(block) and block.visible:
			height = max(height, max(block.rect_size.y, block.get_combined_minimum_size().y))
	return height + BLOCK_GAP
