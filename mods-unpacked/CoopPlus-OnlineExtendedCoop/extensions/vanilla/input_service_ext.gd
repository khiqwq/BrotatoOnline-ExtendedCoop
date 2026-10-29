extends "res://singletons/input_service.gd"
# Per-device actions for the virtual remote devices (AP-006; R02; INP-04,
# INP-05; F02 F03). The parent copies every action to base + "_" + id for the
# remapped ids 0..CoopService.REMAP_END - 1 only (input_service.gd:235, :243,
# :251), and REMAP_END is a const a child cannot change. A remote player on a
# virtual id (16 and up, see the slot manager extension) would therefore read
# actions that do not exist: player_movement_behavior.gd:31,
# utils.gd:737, focus_emulator.gd:210 and main.gd:425 build such names, and
# Godot reports every query of a missing action.
# After the parent has run, each base action that got per-device copies also
# gets one copy per virtual id with the base action's deadzone and no events
# at all. Brotato Online presses them on the host with Input.action_press
# (online_input_manager.gd:163); as they hold no key, button or axis event, no
# local keyboard or controller can press them, unlike the shared id 0 (INP-04).
# _copy_device_actions is the only reader of REMAP_END and runs right after
# each InputMap.load_from_globals (input_service.gd:64-65, :79-80), so the
# virtual copies are rebuilt whenever the parent rebuilds its own. The
# gamepad-movement switch afterwards only erases events (:67-75), which the
# virtual copies do not have.
# Without extended mode nothing is added (R08).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


# Parent: res://singletons/input_service.gd:222 (declares no return type, so
# neither does this override).
func _copy_device_actions():
	# Both callers reload the map from the project settings just before, so
	# this is the list of base actions the parent is about to copy.
	var base_actions = InputMap.get_actions()
	._copy_device_actions()
	if not RuntimeGate.is_extended():
		return
	var ids = RuntimeGate.virtual_device_ids()
	if ids.empty():
		return
	for action_value in base_actions:
		var action_name = str(action_value)
		# The parent copies an action for every remapped id, 0 included, as
		# soon as it holds a key, button or axis event; "<name>_0" marks the
		# actions it copied. Actions it left alone stay without copies here too.
		if not InputMap.has_action(action_name + "_0"):
			continue
		var deadzone = InputMap.action_get_deadzone(action_name)
		for id in ids:
			var device_action = action_name + "_" + str(int(id))
			if not InputMap.has_action(device_action):
				InputMap.add_action(device_action, deadzone)
