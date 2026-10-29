extends "res://ui/menus/ingame/upgrades_ui.gd"
# End-of-wave upgrade/crate screen for P5..P8 (AP-015; R01, R08; UI-10,
# BAT-M03, INP-08). The co-op scene (coop_upgrades_ui.tscn) has exactly four
# player containers, four stat popups and FocusEmulator1..4; vanilla _ready
# loops over every player and calls methods on _get_player_container(i), which
# returns null for i >= 4 and crashed the release engine when the battle scene
# loaded with five players (EV-0015). Godot 3 runs the parent _ready
# regardless of this script, so the missing pieces are created in _enter_tree,
# before any _ready (ui/extra_player_panels.gd), together with the screen's own
# four-entry per-player arrays. Vanilla registers its stat popups from a local
# four-entry array, so for P5+ it registers null; _ready registers the clones.
# Only for the co-op screen while the gate is extended and the run has more
# than four players; otherwise every override is the parent's (R08). Callbacks
# never call their parent versions (ADR-001 rule 1). Verified with five and
# eight simulated players choosing upgrades (EV-0019).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_ARRAY_FIELDS := [
	["_showing_option", PerPlayerArrays.KIND_VALUE, null],
	["_player_is_choosing", PerPlayerArrays.KIND_VALUE, false],
	["_extra_items_to_process", PerPlayerArrays.KIND_ARRAY],
]

# Index 0 belongs to player_index 4.
var _coopplus_extra_containers := []
var _coopplus_extra_stat_popups := []


func _enter_tree() -> void:
	if not is_coop_ui or not RunData.is_coop_run or not RuntimeGate.is_extended():
		return
	if not _coopplus_extra_containers.empty():
		return
	var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var _r = PerPlayerArrays.grow_fields(self, COOPPLUS_ARRAY_FIELDS, size)
	var cloned: Dictionary = ExtraPlayerPanels.clone(self, size, "Content/HBoxContainer2", "UpgradesUIPlayerContainer", "Content")
	if not bool(cloned.ok):
		ModLoaderLog.error("upgrades UI: no P5+ panels (%s)" % cloned.reason, COOPPLUS_MOD_ID)
		return
	_coopplus_extra_containers = cloned.containers
	_coopplus_extra_stat_popups = cloned.popups


# Runs after the parent _ready, which registered null stat popups for P5+.
func _ready() -> void:
	for i in _coopplus_extra_stat_popups.size():
		var player_index: int = PerPlayerArrays.VANILLA_SLOTS + i
		var popup = _coopplus_extra_stat_popups[i]
		popup.parent_node_path = _coopplus_extra_containers[i].carousel.get_path()
		_popup_manager.add_stat_popup(popup, player_index)
	if not _coopplus_extra_containers.empty():
		var panels := []
		for i in RunData.get_player_count():
			panels.append(_get_player_container(i))
		var _strip = LocalFocusLayout.apply(self, get_node("Content/HBoxContainer2"), panels, "upgrades")


# Parent: upgrades_ui.gd:239 (a four-entry literal indexed by player).
func _get_player_container(player_index: int) -> UpgradesUIPlayerContainer:
	var extra := player_index - PerPlayerArrays.VANILLA_SLOTS
	if extra >= 0 and extra < _coopplus_extra_containers.size():
		return _coopplus_extra_containers[extra]
	return ._get_player_container(player_index)
