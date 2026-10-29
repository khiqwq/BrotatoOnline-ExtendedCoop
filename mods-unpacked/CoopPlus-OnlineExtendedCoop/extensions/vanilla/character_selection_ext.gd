extends "res://ui/menus/run/character_selection.gd"
# Character selection for P5..P8 (AP-015; UI-05, UI-07, UI-M02, MENU-04,
# MENU-M03). All players share Inventory1; each has a Panel, a LockedPanel and
# a FocusEmulator, and the scene has them for P1..P4 only. With a fifth
# player the screen never completed (local simulation baseline EV-0031: stuck
# in character selection): base_selection.gd _ready and
# _on_connected_players_updated focus the new player's element through
# Utils.focus_player_control, which calls a method on the missing
# FocusEmulator5 (a runtime error that aborts the call), so P5 had no cursor
# and could not pick; _set_selected_element / _on_element_focused also index
# the four-entry panel lists. Brotato Online applies remote choices through the
# same paths (menu_sync_manager.gd _apply_focus_element, _select_character_
# element, which also bounds-checks _player_characters).
# In _enter_tree, before any _ready of the screen, the per-player arrays grow
# to the session capacity (players can join while the screen is open) and
# Panel, LockedPanel and FocusEmulator 5..capacity are cloned
# (ui/extra_player_panels.gd); the accessors return them. Only while the gate
# is extended; otherwise every override is the parent's (R08). Callbacks never
# call their parent versions (ADR-001 rule 1). With more than four players and
# one local player the panel row uses the two display modes of D-012
# (ui/selection_view_controller.gd), rebuilt whenever the player set changes.
# The run options get a room-type dropdown (D-008, scripts/core/room_policy.gd):
# standard (4, vanilla compatible) or extended (5..8). It is shown whenever
# extended mode is verified on this PC, saves the choice per PC and is locked
# while an online room is open (the type is fixed per room).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")
const SelectionView = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/selection_view_controller.gd")
const RoomPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/room_policy.gd")
const COOPPLUS_ROOM_REFRESH_SEC := 0.5
const COOPPLUS_ROOM_TEXT := {
	"zh": {"standard": "标准房间（4 人，原版兼容）", "extended": "扩展房间（%d 人）"},
	"en": {"standard": "Standard room (4, vanilla compatible)", "extended": "Extended room (%d players)"},
}
# Dropdown order: standard, then extended 5..8.
const COOPPLUS_ROOM_CHOICES := [["standard", 4], ["extended", 5], ["extended", 6], ["extended", 7], ["extended", 8]]

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_ROW_PATH := "MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer"
const COOPPLUS_FIELDS := [
	["displayed_elements", PerPlayerArrays.KIND_ARRAY],
	["_has_player_selected", PerPlayerArrays.KIND_VALUE, false],
	["_displayed_panel_data_element", PerPlayerArrays.KIND_VALUE, null],
	["_latest_focused_element", PerPlayerArrays.KIND_VALUE, null],
	["_player_characters", PerPlayerArrays.KIND_VALUE, null],
]

# Index 0 belongs to player_index 4.
var _coopplus_extra_panels := []
var _coopplus_extra_locked_panels := []
var _coopplus_view = null
var _coopplus_view_key := ""
var _coopplus_room_button: OptionButton = null
var _coopplus_room_refresh := 0.0


func _enter_tree() -> void:
	if not RuntimeGate.is_extended() or not _coopplus_extra_panels.empty():
		return
	var size := RuntimeGate.capacity()
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var grown: Dictionary = PerPlayerArrays.grow_fields(self, COOPPLUS_FIELDS, size)
	if not grown.skipped.empty():
		ModLoaderLog.warning("character selection: per-player arrays missing (%s)" % ",".join(PoolStringArray(grown.skipped)), COOPPLUS_MOD_ID)
	var cloned: Dictionary = ExtraPlayerPanels.clone_named(self, size, [[COOPPLUS_ROW_PATH, "Panel"], [COOPPLUS_ROW_PATH, "LockedPanel"]])
	if not bool(cloned.ok):
		ModLoaderLog.error("character selection: no P5+ panels (%s)" % cloned.reason, COOPPLUS_MOD_ID)
		return
	_coopplus_extra_panels = cloned.nodes["Panel"]
	_coopplus_extra_locked_panels = cloned.nodes["LockedPanel"]


# Runs after vanilla _ready, which connected its own connected_players_updated
# handler first: ours sees the updated player count.
func _ready() -> void:
	if _coopplus_extra_panels.empty():
		return
	_coopplus_add_room_button()
	var _e = CoopService.connect("connected_players_updated", self, "_coopplus_on_players_updated")
	_coopplus_update_view()


func _process(delta: float) -> void:
	if _coopplus_room_button == null:
		return
	_coopplus_room_refresh -= delta
	if _coopplus_room_refresh <= 0.0:
		_coopplus_room_refresh = COOPPLUS_ROOM_REFRESH_SEC
		_coopplus_room_button.disabled = RuntimeGate.room_capacity() > 0


func _coopplus_add_room_button() -> void:
	if _run_options_panel_content == null:
		return
	var texts: Dictionary = COOPPLUS_ROOM_TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else COOPPLUS_ROOM_TEXT["en"]
	var button := OptionButton.new()
	button.name = "CoopPlusRoomType"
	button.focus_mode = Control.FOCUS_ALL
	for choice in COOPPLUS_ROOM_CHOICES:
		button.add_item(texts.standard if choice[0] == RoomPolicy.TYPE_STANDARD else texts.extended % choice[1])
	var pref: Dictionary = RoomPolicy.load_preference()
	for i in COOPPLUS_ROOM_CHOICES.size():
		if COOPPLUS_ROOM_CHOICES[i][0] == pref.type and COOPPLUS_ROOM_CHOICES[i][1] == pref.capacity:
			button.select(i)
	var _e = button.connect("item_selected", self, "_coopplus_on_room_selected")
	_run_options_panel_content.add_child(button)
	_coopplus_room_button = button
	_coopplus_room_button.disabled = RuntimeGate.room_capacity() > 0


func _coopplus_on_room_selected(index: int) -> void:
	if index < 0 or index >= COOPPLUS_ROOM_CHOICES.size() or RuntimeGate.room_capacity() > 0:
		return
	RoomPolicy.save_preference({"type": COOPPLUS_ROOM_CHOICES[index][0], "capacity": COOPPLUS_ROOM_CHOICES[index][1]})


func _coopplus_on_players_updated(_players: Array) -> void:
	_coopplus_update_view()


func _coopplus_update_view() -> void:
	var count: int = RunData.get_player_count()
	var local: int = LocalFocusLayout.local_player_index()
	var key := "%d:%d:%s" % [count, local, RunData.is_coop_run]
	if key == _coopplus_view_key:
		return
	_coopplus_view_key = key
	if is_instance_valid(_coopplus_view):
		_coopplus_view.teardown()
	_coopplus_view = null
	if not RunData.is_coop_run or count <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var panels: Array = _get_panels()
	var locked: Array = _get_locked_panels()
	var groups := []
	for i in int(min(count, panels.size())):
		groups.append([panels[i], locked[i]])
	_coopplus_view = SelectionView.apply(self, groups, get_node(COOPPLUS_ROW_PATH), "character", local)


# Parent: base_selection.gd:276 (four-entry literal indexed by player).
func _get_panels() -> Array:
	var panels: Array = ._get_panels()
	panels.append_array(_coopplus_extra_panels)
	return panels


# Parent: character_selection.gd:385 (four entries, resized to
# CoopService.get_max_players(), which stays 4, UI-13).
func _get_locked_panels() -> Array:
	var panels: Array = ._get_locked_panels()
	if _coopplus_extra_locked_panels.empty():
		return panels
	panels.resize(PerPlayerArrays.VANILLA_SLOTS)
	panels.append_array(_coopplus_extra_locked_panels)
	return panels


# Parent: character_selection.gd:525/539 refresh the background of Panel1..4.
func _setup_zone(index: int) -> void:
	._setup_zone(index)
	_coopplus_update_extra_backgrounds()


func _on_ZoneSelectionButton_item_selected(index: int) -> void:
	._on_ZoneSelectionButton_item_selected(index)
	_coopplus_update_extra_backgrounds()


func _coopplus_update_extra_backgrounds() -> void:
	for panel in _coopplus_extra_panels:
		if is_instance_valid(panel) and panel.has_method("_update_bg"):
			panel._update_bg()
