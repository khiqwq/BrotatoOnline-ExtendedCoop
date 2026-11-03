extends "res://ui/menus/run/item_set_bar.gd"
# DLC toggles in online extended rooms where some player lacks the DLC
# (D-014, scripts/bo/dlc_roster.gd). The bar (character and weapon selection)
# shows one button per installed DLC and update; for a blocked DLC the button
# is off and disabled on every machine of the room, the way vanilla disables
# a set that a picked character requires (set_required_item_sets), and its
# hover/focus banner names the players: "P3、P5 没有安装此 DLC，无法启用".
# Whether the set really is off is decided by progress_data_ext.gd
# (coopplus_blocked_dlcs); this only shows it. Outside such rooms the roster
# blocks nothing and the bar is vanilla (R08). Callbacks never call their
# parent versions (ADR-001 rule 1).

const DlcRoster = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/dlc_roster.gd")
const COOPPLUS_REFRESH_SEC := 0.5

var _coopplus_blocked := {}
var _coopplus_refresh := 0.0


func _process(delta: float) -> void:
	_coopplus_refresh -= delta
	if _coopplus_refresh > 0.0:
		return
	_coopplus_refresh = COOPPLUS_REFRESH_SEC
	var roster = DlcRoster.find(get_tree())
	var blocked: Dictionary = roster.blocked() if roster != null else {}
	if var2str(blocked) == var2str(_coopplus_blocked):
		return
	_coopplus_blocked = blocked
	_coopplus_apply()
	var focused := _get_focused_button_index()
	if focused >= 0:
		_show_logo(_buttons[focused], _updates[focused])


func set_required_item_sets(required_by: Dictionary) -> void:
	.set_required_item_sets(required_by)
	_coopplus_apply()


func _on_item_sets_changed() -> void:
	._on_item_sets_changed()
	_coopplus_apply()


func _coopplus_apply() -> void:
	for i in _buttons.size():
		var id: String = _updates[i].id
		var blocked := _coopplus_blocked.has(id)
		_buttons[i].disabled = _required_by.has(id) or blocked
		if blocked and _buttons[i].pressed:
			_buttons[i].set_pressed_no_signal(false)
		_update_icon(_buttons[i], _updates[i])


func _show_logo(button: Button, update: UpdateData) -> void:
	._show_logo(button, update)
	if not _coopplus_blocked.has(update.id):
		return
	_required_label.text = DlcRoster.texts().blocked % DlcRoster.players_text(_coopplus_blocked[update.id])
	_required_label.visible = true
	# Same placement as the parent, for the longer label.
	_logo.rect_size = Vector2.ZERO
	var logo_size := _logo.get_combined_minimum_size()
	var button_position := button.rect_global_position - rect_global_position
	if _horizontal:
		_logo.rect_position = Vector2(
			max(-rect_position.x, button_position.x + (button.rect_size.x - logo_size.x) / 2.0),
			_panel.rect_position.y + _panel.rect_size.y + LOGO_GAP
		)
	else:
		_logo.rect_position = Vector2(
			_panel.rect_position.x + _panel.rect_size.x + LOGO_GAP,
			button_position.y + (button.rect_size.y - logo_size.y) / 2.0
		)
