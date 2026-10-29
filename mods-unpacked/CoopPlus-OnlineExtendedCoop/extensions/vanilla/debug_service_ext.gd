extends "res://singletons/debug_service.gd"
# Run log for P5..P8 (AP-013; R01, R08; BAT-10). Main calls log_run_info()
# without arguments at the start of every wave (main.gd players_spawned
# handler); the defaults are four-entry arrays (debug_service.gd:175) that the
# per-player loop indexes, which crashed the release engine on P5 right after
# the battle HUD was set up (local simulation trail, EV-0019). The arrays are
# copied and grown to the player count before the parent runs; the caller's
# arrays are never modified. With 1..4 players, or a vanilla gate, the parent
# gets exactly its arguments (R08).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")


# Parent: debug_service.gd:175.
func log_run_info(upgrades: Array = [[], [], [], []], consumables: Array = [[], [], [], []]) -> void:
	if RuntimeGate.is_extended():
		var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
		if upgrades.size() < size:
			upgrades = upgrades.duplicate()
			var _a := PerPlayerArrays.grow(upgrades, size, PerPlayerArrays.KIND_ARRAY)
		if consumables.size() < size:
			consumables = consumables.duplicate()
			var _b := PerPlayerArrays.grow(consumables, size, PerPlayerArrays.KIND_ARRAY)
	.log_run_info(upgrades, consumables)
