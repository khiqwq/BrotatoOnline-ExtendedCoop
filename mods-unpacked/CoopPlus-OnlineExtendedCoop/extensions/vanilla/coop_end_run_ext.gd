extends "res://ui/menus/run/coop_end_run.gd"
# Co-op end-of-run screen for P5..P8 (AP-015; R01, R08; UI-11). The scene
# (coop_end_run.tscn) has four player containers, item popups, stat popups and
# FocusEmulator1..4, and vanilla _ready builds four-entry onready arrays of
# them right before looping over every player and calling methods on the
# entries; with five players the release engine crashed on entering the screen
# (local simulation, EV-0021). There is no hook between the onready arrays and
# that loop, so:
#   _enter_tree  clones panels, popups and focus emulators 5..N
#                (ui/extra_player_panels.gd) and limits RunData.get_player_count()
#                to 4 for this frame, so vanilla _ready sets up exactly P1..P4
#   _ready       (after vanilla) lifts the limit and gives P5..N the same setup
#                vanilla gives each player: panel init, weapons and items lists,
#                item and stat popups registered with the PopupManager, focus
# Popup toggling for P5+ goes to the clones (vanilla indexes the four-entry
# array). Only while the gate is extended and the run has more than four
# players; otherwise everything is the parent's (R08). Callbacks never call
# their parent versions (ADR-001 rule 1).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")
const VanillaFields = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/vanilla_per_player_fields.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_ROW_PATH := "MarginContainer/VBoxContainer/HBoxContainer2/PanelContainer/VBoxContainer/HBoxContainer"

# Index 0 belongs to player_index 4.
var _coopplus_extra_containers := []
var _coopplus_extra_item_popups := []
var _coopplus_extra_stat_popups := []
var _coopplus_size := 0


func _enter_tree() -> void:
	if not RuntimeGate.is_extended() or not _coopplus_extra_containers.empty():
		return
	var size := PerPlayerArrays.target_size(RunData.players_data.size(), RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var cloned: Dictionary = ExtraPlayerPanels.clone(self, size, COOPPLUS_ROW_PATH, "PlayerContainer", ".", ["ItemPopup"])
	if not bool(cloned.ok):
		ModLoaderLog.error("end of run: no P5+ panels (%s)" % cloned.reason, COOPPLUS_MOD_ID)
		return
	_coopplus_size = size
	_coopplus_extra_containers = cloned.containers
	_coopplus_extra_stat_popups = cloned.popups
	_coopplus_extra_item_popups = cloned.extra["ItemPopup"]
	RunData.call("coopplus_limit_player_count_this_frame", PerPlayerArrays.VANILLA_SLOTS)


# Runs after vanilla _ready, still in the same frame.
func _ready() -> void:
	if _coopplus_extra_containers.empty():
		return
	RunData.call("coopplus_clear_player_count_limit")
	# PopupManager grew its arrays while the count was limited to 4.
	var _r = PerPlayerArrays.grow_fields(_popup_manager, VanillaFields.POPUP_MANAGER, _coopplus_size)
	for i in _coopplus_extra_containers.size():
		_coopplus_setup_player(PerPlayerArrays.VANILLA_SLOTS + i, i)
	var panels := []
	for i in PerPlayerArrays.VANILLA_SLOTS:
		panels.append(player_containers[i])
	panels.append_array(_coopplus_extra_containers)
	var _strip = LocalFocusLayout.apply(self, get_node(COOPPLUS_ROW_PATH), panels, "end_run")


func _coopplus_setup_player(player_index: int, extra: int) -> void:
	var container = _coopplus_extra_containers[extra]
	container.visible = true
	# The setter skipped its work while the count was limited; run it again.
	container.player_index = player_index

	var weapons = RunData.get_player_weapons(player_index)
	container.weapons_container.visible = not weapons.empty()
	container.weapons_container.set_data("WEAPONS", Category.WEAPON, weapons)
	container.items_container.set_data("ITEMS", Category.ITEM, RunData.get_player_items(player_index), true, true)

	var item_popup = _coopplus_extra_item_popups[extra]
	var _e = item_popup.connect("popup_toggled", self, "_on_popup_toggled")
	item_popup.player_index = player_index
	item_popup.parent_node_path = container.carousel.get_path()
	_popup_manager.add_item_popup(item_popup, player_index)
	_popup_manager.connect_inventory_container(container.weapons_container)
	_popup_manager.connect_inventory_container(container.items_container)

	var stat_popup = _coopplus_extra_stat_popups[extra]
	stat_popup.parent_node_path = container.carousel.get_path()
	_popup_manager.add_stat_popup(stat_popup, player_index)
	_popup_manager.connect_stats_container(container.primary_stats_container)
	_popup_manager.connect_stats_container(container.secondary_stats_container)

	container.focus()


# Parent: coop_end_run.gd (indexes the four-entry player_containers).
func _on_popup_toggled(hide_popup: bool, player_index: int) -> void:
	var extra := player_index - PerPlayerArrays.VANILLA_SLOTS
	if extra < 0 or extra >= _coopplus_extra_containers.size():
		._on_popup_toggled(hide_popup, player_index)
		return
	var hint = _coopplus_extra_containers[extra].toggle_popup_hint
	hint.set_text("COOP_POPUP_ENABLE_HINT" if hide_popup else "COOP_POPUP_DISABLE_HINT")
