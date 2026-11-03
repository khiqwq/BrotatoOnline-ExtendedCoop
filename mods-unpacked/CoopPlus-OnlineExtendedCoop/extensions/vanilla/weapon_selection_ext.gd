extends "res://ui/menus/run/weapon_selection.gd"
# Weapon selection for P5..P8 (AP-015; UI-05, UI-08, UI-M05, MENU-04,
# MENU-M03). Every player has a Panel, an inventory (scroll_inventory.tscn)
# and a FocusEmulator, and the scene has them for P1..P4 only; with a fifth
# player base_selection.gd _ready cannot focus P5's element (the missing
# FocusEmulator5, as on the character screen), so P5 has nothing to pick
# from, and _input, _set_selected_element and the players-without-weapon-slots
# loop of _ready index the four-entry panel and inventory lists. CoopFix-OnlineMouseUI reads
# _has_player_selected up to _player_weapons.size() (UI-M05), and Brotato
# Online maps players to inventories with player_index % inventories.size()
# (MENU-04), so both lists must have an entry per player.
# In _enter_tree, before any _ready of the screen, the per-player arrays grow
# to the player count and Panel, inventory and FocusEmulator 5..N are cloned
# (ui/extra_player_panels.gd, focus data rebased onto the cloned inventory);
# the accessors return them. A duplicated scene instance loses its children's
# overrides, so the clones get Panel4's ItemDescription.expand_indefinitely =
# false again. Only while the gate is extended and the run has more than four
# players; otherwise every override is the parent's (R08). Callbacks never call
# their parent versions (ADR-001 rule 1). This script may chain with
# CoopFix-OnlineMouseUI's extension of the same path (ADR-001 rule 3).
# With one local player the panel and inventory rows use the two display modes
# of D-012 (ui/selection_view_controller.gd); the inventories' column count
# follows the players shown (vanilla: 16 / player count).
# 1.2.0.0 gave this screen a LockedPanel per player beside each Panel, as on
# the character screen (weapon_selection.gd:11-14, 242-243): focusing an
# element calls _update_locked_panel, which indexed the four locked panels by
# player, so the screen stopped once P5..P8 picked a weapon. LockedPanel 5..N
# are cloned with the others and belong to their player's display group.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")
const SelectionView = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/selection_view_controller.gd")
const DlcRoster = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/dlc_roster.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_PANELS_PATH := "MarginContainer/VBoxContainer/DescriptionContainer/Panels"
const COOPPLUS_INVENTORIES_PATH := "MarginContainer/VBoxContainer/Inventories"
const COOPPLUS_DESCRIPTION_PATH := "MarginContainer/VBoxContainer/ItemDescription"
const COOPPLUS_TOTAL_COLUMNS := 16
const COOPPLUS_FIELDS := [
	["displayed_elements", PerPlayerArrays.KIND_ARRAY],
	["_has_player_selected", PerPlayerArrays.KIND_VALUE, false],
	["_displayed_panel_data_element", PerPlayerArrays.KIND_VALUE, null],
	["_latest_focused_element", PerPlayerArrays.KIND_VALUE, null],
]

# Index 0 belongs to player_index 4.
var _coopplus_extra_panels := []
var _coopplus_extra_inventories := []
var _coopplus_extra_locked_panels := []
var _coopplus_view = null


func _enter_tree() -> void:
	if not RuntimeGate.is_extended() or not _coopplus_extra_panels.empty():
		return
	var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var grown: Dictionary = PerPlayerArrays.grow_fields(self, COOPPLUS_FIELDS, size)
	if not grown.skipped.empty():
		ModLoaderLog.warning("weapon selection: per-player arrays missing (%s)" % ",".join(PoolStringArray(grown.skipped)), COOPPLUS_MOD_ID)
	var cloned: Dictionary = ExtraPlayerPanels.clone_named(self, size, [[COOPPLUS_PANELS_PATH, "Panel"], [COOPPLUS_PANELS_PATH, "LockedPanel"], [COOPPLUS_INVENTORIES_PATH, "Inventory"]])
	if not bool(cloned.ok):
		ModLoaderLog.error("weapon selection: no P5+ panels (%s)" % cloned.reason, COOPPLUS_MOD_ID)
		return
	_coopplus_extra_panels = cloned.nodes["Panel"]
	_coopplus_extra_inventories = cloned.nodes["Inventory"]
	_coopplus_extra_locked_panels = cloned.nodes["LockedPanel"]
	for panel in _coopplus_extra_panels:
		var description = panel.get_node_or_null(COOPPLUS_DESCRIPTION_PATH)
		if description != null and "expand_indefinitely" in description:
			description.expand_indefinitely = false


# Runs after vanilla _ready (columns and the players without weapon slots are
# set up by then).
func _ready() -> void:
	if _coopplus_extra_panels.empty() or not RunData.is_coop_run:
		return
	var panels: Array = _get_panels()
	var containers: Array = _get_inventory_containers()
	var locked: Array = _get_locked_panels()
	var groups := []
	for i in int(min(RunData.get_player_count(), min(panels.size(), min(containers.size(), locked.size())))):
		groups.append([panels[i], locked[i], containers[i]])
	_coopplus_view = SelectionView.apply(self, groups, get_node(COOPPLUS_PANELS_PATH), "weapon", LocalFocusLayout.local_player_index())
	if _coopplus_view != null:
		var _e = _coopplus_view.connect("layout_changed", self, "_coopplus_on_layout_changed")
		_coopplus_on_layout_changed()


func _coopplus_on_layout_changed() -> void:
	var columns: int = int(COOPPLUS_TOTAL_COLUMNS / max(2, _coopplus_view.shown_players()))
	for inventory in _get_inventories():
		inventory.columns = columns
		inventory.queue_set_focus_neighbours()


# Parent: base_selection.gd:276 (four-entry literal indexed by player).
func _get_panels() -> Array:
	var panels: Array = ._get_panels()
	panels.append_array(_coopplus_extra_panels)
	return panels


# Parent: base_selection.gd:264 (Inventory1..4).
func _get_inventory_containers() -> Array:
	var containers: Array = ._get_inventory_containers()
	containers.append_array(_coopplus_extra_inventories)
	return containers


# Parent: weapon_selection.gd:242 (1.2.0.0; LockedPanel1..4).
# Weapons of a DLC some player lacks (D-014) are disabled as for a switched-off
# set (ProgressData.has_item_set, progress_data_ext.gd); the locked panel
# names the players lacking it.
func _update_locked_panel(element: InventoryElement, player_index: int) -> void:
	._update_locked_panel(element, player_index)
	var locked_panels: Array = _get_locked_panels()
	if player_index < 0 or player_index >= locked_panels.size() or not locked_panels[player_index].visible:
		return
	var roster = DlcRoster.find(get_tree())
	var text: String = roster.locked_text(_get_element_disabled_update(element)) if roster != null else ""
	if text != "":
		locked_panels[player_index].set_description(text)


func _get_locked_panels() -> Array:
	var panels: Array = ._get_locked_panels()
	if _coopplus_extra_locked_panels.empty():
		return panels
	panels.resize(PerPlayerArrays.VANILLA_SLOTS)
	panels.append_array(_coopplus_extra_locked_panels)
	return panels
