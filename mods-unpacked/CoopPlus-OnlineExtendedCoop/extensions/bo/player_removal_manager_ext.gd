extends "res://mods-unpacked/six666-BrotatoOnline/scripts/player_removal_manager.gd"
# Removing a player with five or more players left (AP-017; GAP1-02, SAVE-13,
# DATA-15). When the host removes a player, every client rebuilds its roster
# in _apply_client_roster (player_removal_manager.gd:400-441), which sets
# RunData.locked_shop_items to four empty lists (:432) right before the
# scene change; with five or more players left the rebuilt shop indexes P5's
# entry past the end of that list (the release engine aborts the shop's
# setup). The per-player arrays are fitted to the new player count right
# after the parent returns: change_scene_to switches scenes at the end of the
# frame, so the new scene's _ready sees the fitted arrays.
# The host's side (_commit_host_removal) needs nothing: it keeps every
# array's length while compacting, and RunData.reset_run_caches is followed
# by run_data_ext.gd. 1..4 players: unchanged (R08).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")


# Parent: player_removal_manager.gd:400.
func _apply_client_roster(message: Dictionary, generation: int) -> void:
	._apply_client_roster(message, generation)
	if RuntimeGate.is_extended() and RunData.has_method("coopplus_fit_per_player_arrays"):
		RunData.call("coopplus_fit_per_player_arrays")
