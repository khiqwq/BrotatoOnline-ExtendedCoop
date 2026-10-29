extends Reference
# Per-player popups of the four-panel screens while some panels are hidden
# (D-010..D-012). The screens register one item popup and one stat popup per
# player with their PopupManager, which shows them when that player focuses an
# element (popup_manager.gd); coop_end_run.gd _ready focuses every player's
# first item, so hidden players' popups appeared over the shown panels
# (EV-0025). PopupManager null-checks every entry before use and nothing else
# reads its lists, so un-registering a player's popups keeps them hidden,
# including focus mirrored from remote players later; registering them again
# restores the vanilla behaviour. The popup nodes stay in the scene.

const FIELDS := ["_item_popups", "_stat_popups"]


# Un-registers the players' popups. Returns {field: {player_index: popup}}, the
# record register() needs.
static func mute(screen: Node, player_indices: Array) -> Dictionary:
	var muted := {}
	var manager = screen.get("_popup_manager")
	if manager == null:
		return muted
	for field in FIELDS:
		var popups = manager.get(field)
		if not popups is Array:
			continue
		muted[field] = {}
		for i in player_indices:
			if i < popups.size() and popups[i] != null:
				muted[field][i] = popups[i]
				popups[i].hide()
				popups[i] = null
	return muted


# Registers (shown panel) or un-registers (hidden panel) one player's popups
# recorded by mute().
static func set_registered(screen: Node, muted: Dictionary, player_index: int, registered: bool) -> void:
	var manager = screen.get("_popup_manager") if is_instance_valid(screen) else null
	if manager == null:
		return
	for field in muted:
		var saved: Dictionary = muted[field]
		var list = manager.get(field)
		if not list is Array or not saved.has(player_index) or player_index >= list.size():
			continue
		var popup = saved[player_index]
		if not is_instance_valid(popup):
			continue
		if registered:
			list[player_index] = popup
		else:
			popup.hide()
			list[player_index] = null
