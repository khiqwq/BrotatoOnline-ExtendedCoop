extends "res://ui/menus/run/difficulty_selection/difficulty_selection.gd"
# Difficulty selection for P5..P8 (AP-015; UI-05). Only P1 chooses (the scene
# has FocusEmulator1 alone; Brotato Online ignores remote focus and selection
# on this screen, menu_sync_manager.gd apply_remote_*_by_item_id), but
# base_selection.gd _ready focuses an element for every player:
# inventories[player_index % 4] is the visible Inventory1 again for P5, and
# Utils.focus_player_control then calls a method on the missing
# FocusEmulator5 (a runtime error on every visit). P2..P4 are skipped there
# only because their inventories are hidden. As on the co-op end-of-run
# screen, _enter_tree limits RunData.get_player_count() to 4 for this frame so
# the vanilla _ready treats P5..P8 like the hidden P2..P4, and _ready (after
# vanilla) lifts the limit; the per-player arrays still grow to the player
# count for the later per-event loops (base_selection.gd _input). Only while
# the gate is extended and the run has more than four players (R08). Callbacks
# never call their parent versions (ADR-001 rule 1).
# Starting the run in an online extended room (D-014, scripts/bo/dlc_roster.gd):
# the parent sets RunData.enabled_dlcs to every installed DLC
# (difficulty_selection.gd:103), which turns on DLC mechanics such as the shop
# curses and the DLC consumables; a DLC some player lacks is taken out of it
# right after (active_update_data_ids already leaves it out,
# progress_data_ext.gd), before Brotato Online sends the run configuration to
# the clients, and a zone of such a DLC becomes the base zone.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const DlcRoster = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/dlc_roster.gd")

const COOPPLUS_FIELDS := [
	["displayed_elements", PerPlayerArrays.KIND_ARRAY],
	["_has_player_selected", PerPlayerArrays.KIND_VALUE, false],
	["_displayed_panel_data_element", PerPlayerArrays.KIND_VALUE, null],
	["_latest_focused_element", PerPlayerArrays.KIND_VALUE, null],
]

var _coopplus_limited := false


func _enter_tree() -> void:
	if not RuntimeGate.is_extended() or _coopplus_limited:
		return
	var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var _grown = PerPlayerArrays.grow_fields(self, COOPPLUS_FIELDS, size)
	_coopplus_limited = true
	RunData.call("coopplus_limit_player_count_this_frame", PerPlayerArrays.VANILLA_SLOTS)


# Runs after vanilla _ready, still in the same frame.
func _ready() -> void:
	if _coopplus_limited:
		RunData.call("coopplus_clear_player_count_limit")


func _on_element_pressed(element: InventoryElement, inventory_player_index: int) -> void:
	var roster = DlcRoster.find(get_tree())
	var blocked: Dictionary = roster.blocked(true) if roster != null and roster.is_host() else {}
	if blocked.empty():
		._on_element_pressed(element, inventory_player_index)
		return
	var zone = ZoneService.get_zone_data(RunData.current_zone)
	if zone != null and blocked.has(zone.dlc_id):
		RunData.current_zone = ZoneService.zones[0].my_id
		ProgressData.settings.zone_selected = 0
	._on_element_pressed(element, inventory_player_index)
	var enabled := []
	for id in RunData.enabled_dlcs:
		if not blocked.has(id):
			enabled.append(id)
	RunData.enabled_dlcs = enabled
	for id in blocked:
		RunData.active_update_data_ids.erase(id)
