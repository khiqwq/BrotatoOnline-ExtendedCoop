extends Node
# Mouse wheel for item descriptions in the co-op shop (reported 2026-11-14:
# the wheel did not scroll a long description). While
# CoopService.listening_for_inputs is false every FocusEmulator marks each
# input that is not a co-op UI action as handled (focus_emulator.gd:84-85),
# and the emulators are the shop scene's last children, so their _input runs
# before the descriptions' (Brotato Online's long_description_input.gd
# scrolls them). Brotato Online sets that flag per machine
# (session_manager.gd:525, online_player_slot_manager.gd), so the wheel
# worked on some machines and not on others. Overriding the emulator's
# _input cannot help: Godot 3 calls _input on every level of a script chain.
# This node is added after the emulators, so it sees the wheel first and
# hands it to each visible description; the description decides itself
# (hovered card, local player) and marks the event handled when it scrolls.
# Other input passes through untouched.

const WHEEL_BUTTONS := [BUTTON_WHEEL_UP, BUTTON_WHEEL_DOWN]


static func attach(screen: Node) -> Node:
	var node = load("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/description_wheel.gd").new()
	node.name = "CoopPlusDescriptionWheel"
	screen.add_child(node)
	return node


func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed or not event.button_index in WHEEL_BUTTONS:
		return
	var screen = get_parent()
	if screen == null:
		return
	for description in _descriptions(screen, []):
		description._input(event)
		if get_tree().is_input_handled():
			return


# Item descriptions (item_description.gd) that are on screen.
func _descriptions(node: Node, out: Array) -> Array:
	for child in node.get_children():
		if child is CanvasItem and not child.visible:
			continue
		if child.has_method("get_scroll_container") and child.has_method("reduce_scroll_min_height"):
			out.append(child)
		else:
			var _r = _descriptions(child, out)
	return out
