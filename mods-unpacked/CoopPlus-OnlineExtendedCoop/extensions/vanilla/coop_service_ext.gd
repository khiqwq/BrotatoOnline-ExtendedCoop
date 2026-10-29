extends "res://singletons/coop_service.gd"
# CoopService data for 5..8 players (AP-006; R01, R02, R08, R14; INP-02,
# INP-06, INP-09).
#   - player_colors gets four more colours in _ready when extended mode is on
#     (INP-09). It is an exported var holding four colours
#     (coop_service.tscn:66) and is indexed without bounds checks by
#     get_player_color (coop_service.gd:203) and directly (for example
#     character_panel_ui.gd:159-160), in battle, HUD and menus alike, so one
#     data patch covers every reader. The first four stay as they are (R08).
#   - _on_Input_joy_connection_changed ignores the virtual remote device ids
#     (INP-06). Godot 3 reports physical joypads 0..15 only, so this is a
#     safeguard: an unplug signal can never remove a remote player's slot.
# Deliberately not overridden:
#   - get_max_players(): main.gd:215-219 and character_selection.gd:399-418
#     reach exactly four containers and panels through it (CAP-10, INP-02);
#     the UI work (AP-014/015) decides when it may grow.
#   - _can_add_new_device(): its vanilla limit (fewer than get_max_players()
#     players) only gates local hold-to-join in _process (coop_service.gd:111).
#     Remote seats go through _add_player (coop_service.gd:317-322), which has
#     no count check, so the limit never blocks them; with four or more
#     players seated it keeps local joining closed, which matches one player
#     per machine (R02).
# Godot 3 runs _ready on every script level, parent first, so _ready here
# must not call ._ready() (ADR-001 rule 1).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_VANILLA_COLOR_COUNT := 4
# Colours of P5..P8. Same pastel band as the vanilla four (saturation about
# 0.32, value 0.97; get_player_color later adds 0.5 saturation), on the hues
# the vanilla set leaves open: blue 215, indigo 255, magenta 305, rose 345
# (vanilla: orange 21, yellow 53, lime 86, aqua 166). They keep 14 degrees
# or more from the blue CHARM/DAMAGE_INC (about 200) and violet CURSE (279)
# effect colours of utils.gd:4-6. Final colours and numbering come with the
# UI samples (AP-014, R14).
const COOPPLUS_EXTRA_PLAYER_COLORS := [
	Color("a8c9f7"),
	Color("bca8f7"),
	Color("f7a8f1"),
	Color("f7a8bc"),
]


func _ready() -> void:
	if not RuntimeGate.is_extended():
		return
	var capacity := RuntimeGate.capacity()
	var colors: Array = player_colors.duplicate()
	if colors.size() < COOPPLUS_VANILLA_COLOR_COUNT:
		# Something else replaced the vanilla colours; do not guess the order.
		ModLoaderLog.warning("player colours left unchanged: %d instead of %d vanilla entries" % [colors.size(), COOPPLUS_VANILLA_COLOR_COUNT], COOPPLUS_MOD_ID)
		return
	# Only the missing entries are added, so colours another mod appended stay.
	var appended := 0
	while colors.size() < capacity and colors.size() < COOPPLUS_VANILLA_COLOR_COUNT + COOPPLUS_EXTRA_PLAYER_COLORS.size():
		colors.append(COOPPLUS_EXTRA_PLAYER_COLORS[colors.size() - COOPPLUS_VANILLA_COLOR_COUNT])
		appended += 1
	if appended == 0:
		return
	# A new array: the old one may be shared with the scene's stored state.
	player_colors = colors
	ModLoaderLog.info("player colours extended to %d" % colors.size(), COOPPLUS_MOD_ID)


# Parent: res://singletons/coop_service.gd:367 (connected by name in the
# parent's _ready, coop_service.gd:76, so this override receives the signal).
func _on_Input_joy_connection_changed(device: int, connected: bool) -> void:
	if RuntimeGate.is_virtual_device(device):
		return
	._on_Input_joy_connection_changed(device, connected)
