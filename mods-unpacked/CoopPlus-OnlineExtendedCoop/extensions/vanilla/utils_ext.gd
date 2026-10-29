extends "res://singletons/utils.gd"
# Manual-aim cache for players 5..8 (AP-006; R08; INP-10, DATA-06).
# Utils keeps a four-entry _manual_aim_cache that vanilla is_manual_aim
# indexes without a bounds check (utils.gd:814, :827), and its _process puts a
# fresh four-entry array back at the end of every frame (utils.gd:126,
# set_deferred). An override of _process cannot stop that (Godot 3 calls
# _process on every script level), so the cache is grown on demand right
# before the parent reads it; the parent then fills the new entry as usual
# and the end of the frame shrinks the cache back to four.
# Brotato Online's extension of this script (utils_online_manual_aim.gd)
# sits between this one and vanilla and skips the cache while an online
# session runs; this fix covers its fallbacks to vanilla (no session, input
# manager missing) and any caller without Brotato Online in between.
# Only indices below the gate capacity are grown, so with a vanilla gate
# (capacity 4) the parent sees exactly the calls it saw before (R08).
# The other four-entry Utils arrays, _stat_caches (DATA-05) and
# last_elt_selected (DATA-07), are grown by run_data_ext.gd whenever RunData's
# player count is set; the two Utils resets that rebuild them with four entries
# are followed by the same growth here (AP-013).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


# Parent chain: Brotato Online extensions/utils_online_manual_aim.gd:6, then
# res://singletons/utils.gd:813.
func is_manual_aim(player_index: int) -> bool:
	if player_index >= _manual_aim_cache.size() and player_index < RuntimeGate.capacity():
		_manual_aim_cache.resize(player_index + 1)
	return .is_manual_aim(player_index)


# Parent: res://singletons/utils.gd:453 (rebuilds _stat_caches with 4 entries).
func reset_stat_caches() -> void:
	.reset_stat_caches()
	_coopplus_regrow_per_player_arrays()


# Parent: res://singletons/utils.gd:652 (rebuilds last_elt_selected with 4 entries).
func reset_last_elt_selected() -> void:
	.reset_last_elt_selected()
	_coopplus_regrow_per_player_arrays()


func _coopplus_regrow_per_player_arrays() -> void:
	if RuntimeGate.is_extended() and is_instance_valid(RunData) and RunData.has_method("coopplus_fit_per_player_arrays"):
		# Through call(): the parser only knows vanilla RunData members.
		RunData.call("coopplus_fit_per_player_arrays")
