extends "res://singletons/debug_service.gd"
# Run log for P5..P8 (AP-013; R01, R08; BAT-10). Main calls log_run_info()
# without arguments at the start of every wave (main.gd players_spawned
# handler); the defaults are four-entry arrays (debug_service.gd:175) that the
# per-player loop indexes, which crashed the release engine on P5 right after
# the battle HUD was set up (local simulation trail, EV-0019). The arrays are
# copied and grown to the player count before the parent runs; the caller's
# arrays are never modified. With 1..4 players, or a vanilla gate, the parent
# gets exactly its arguments (R08).
# Also: --coopplus-no-fullscreen (passed with the engine's --no-window by
# tools/instance.ps1 for the isolated test instances) keeps the hidden window
# hidden. Otherwise the boot scene switched to fullscreen from the saved
# settings (pause.gd -> ProgressData.apply_settings; a fresh profile defaults
# to fullscreen) and the window covered the user's screen; the game's own
# no_fullscreen_on_launch option skips that switch. The engine consumes
# --no-window itself, so OS.get_cmdline_args() never contains it. Normal starts
# do not pass the flag and are unchanged.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")


# DebugService is a scene (debug_service.tscn): exported values are applied
# after _init, so the flag is set here, before the boot scene's _ready.
func _ready() -> void:
	if "--coopplus-no-fullscreen" in OS.get_cmdline_args():
		no_fullscreen_on_launch = true


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
