extends "res://ui/menus/global/focus_emulator.gd"
# Remote players' cursors no longer scroll the local player's lists (AP-015;
# reported from online 5-player play, 2026-11-02). Brotato Online moves every
# remote player's FocusEmulator on each machine, and an emulator scrolls its
# control into view on every focus change (focus_emulator.gd:249, 429-432).
# Character selection has one ScrollContainer that every player's cursor
# moves in, so the local view jumped up and down with the other players.
# In extended rooms, a remote player's emulator (a virtual device id) leaves
# a ScrollContainer alone when it shares one of the local player's focus
# bases (holds it or lies in it), i.e. a list the local player uses too;
# lists only that player uses (their shop panel in the four-panel view)
# still follow their cursor.
# Brotato Online's own extension of this script (focus_emulator_safe_disconnect.gd)
# stays below this one in the chain.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


# Parent: focus_emulator.gd:429.
func _ensure_control_visible(control: Control) -> void:
	if RuntimeGate.is_extended() and RuntimeGate.is_virtual_device(_device) and _coopplus_in_local_player_base(control):
		return
	._ensure_control_visible(control)


func _coopplus_in_local_player_base(control: Control) -> bool:
	var scroll = _find_parent_scroll_container(control)
	var parent = get_parent()
	if scroll == null or parent == null:
		return false
	for sibling in parent.get_children():
		if sibling == self or not sibling is FocusEmulator or RuntimeGate.is_virtual_device(int(sibling.get("_device"))):
			continue
		for base in sibling.get("_focus_base_nodes"):
			# The base can hold the list or sit inside it (the character grid).
			if base is Node and is_instance_valid(base) and (base == scroll or base.is_a_parent_of(scroll) or scroll.is_a_parent_of(base)):
				return true
	return false
