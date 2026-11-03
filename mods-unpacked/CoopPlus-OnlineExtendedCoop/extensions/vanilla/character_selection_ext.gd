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
# DLCs in online extended rooms (D-014, scripts/bo/dlc_roster.gd): a zone of a
# DLC that some player lacks is disabled in the zone list, its name followed by
# the players lacking it; on the host a selected one falls back to the first
# allowed zone, and the random zone never draws one (_setup_zone). Every
# player's panel shows their DLC icons (ui/dlc_badges.gd). The DLC's own
# toggle is item_set_bar_ext.gd. Its characters are disabled too: vanilla ties
# only characters with a required_item_set to the bar, but a client without
# the DLC could not load them (Brotato Online registers DLC content from the
# host's enabled DLCs only, session_content_catalog.gd apply), so
# _get_item_disabled_update also returns the blocked DLC for them (vanilla
# then greys them out, leaves them out of the random pick and clears such a
# selection, base_selection.gd _on_item_sets_changed), and the locked panel
# names the players lacking it.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")
const SelectionView = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/selection_view_controller.gd")
const RoomPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/room_policy.gd")
const DlcRoster = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/dlc_roster.gd")
const DlcBadges = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/dlc_badges.gd")
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
# Zone list item index -> its own text, before a "not installed by" suffix.
var _coopplus_zone_names := {}
var _coopplus_zone_key := ""


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
	var panels: Array = _get_panels()
	for i in panels.size():
		var _badges = DlcBadges.overlay(panels[i], i)


func _process(delta: float) -> void:
	if _coopplus_extra_panels.empty():
		return
	_coopplus_room_refresh -= delta
	if _coopplus_room_refresh <= 0.0:
		_coopplus_room_refresh = COOPPLUS_ROOM_REFRESH_SEC
		if _coopplus_room_button != null:
			_coopplus_room_button.disabled = RuntimeGate.room_capacity() > 0
		_coopplus_apply_zone_rule()


func _coopplus_apply_zone_rule() -> void:
	if _zone_selection_button == null:
		return
	var roster = DlcRoster.find(get_tree())
	var blocked: Dictionary = roster.blocked() if roster != null else {}
	var key := var2str(blocked)
	if key == _coopplus_zone_key:
		return
	_coopplus_zone_key = key
	var button := _zone_selection_button
	for i in button.get_item_count():
		if not _coopplus_zone_names.has(i):
			_coopplus_zone_names[i] = button.get_item_text(i)
		var missing: Array = blocked.get(_coopplus_zone_dlc(button.get_item_id(i)), [])
		button.set_item_disabled(i, not missing.empty())
		var text: String = _coopplus_zone_names[i]
		if not missing.empty():
			text = DlcRoster.texts().zone % [text, DlcRoster.players_text(missing)]
		button.set_item_text(i, text)
	var selected := button.selected
	if roster != null and roster.is_host() and selected >= 0 and button.is_item_disabled(selected):
		var allowed := _coopplus_allowed_zone_indices()
		if not allowed.empty():
			button.select(allowed[0])
			_on_ZoneSelectionButton_item_selected(allowed[0])


# DLC of the zone with this id ("" for the base game and the random entry).
static func _coopplus_zone_dlc(zone_id: int) -> String:
	for zone_data in ZoneService.zones:
		if zone_data.my_id == zone_id:
			return zone_data.dlc_id
	return ""


# Zone list indices the room allows, the random entry left out.
func _coopplus_allowed_zone_indices() -> Array:
	var out := []
	for i in _zone_selection_button.get_item_count():
		if not _zone_selection_button.is_item_disabled(i) and _zone_selection_button.get_item_id(i) != ZoneService.zones.size() + 1:
			out.append(i)
	return out


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
	if _zone_selection_button != null:
		# Same look as the zone dropdown above it (its font and styles are scene overrides).
		_coopplus_copy_overrides(_zone_selection_button, button)
		_coopplus_copy_overrides(_zone_selection_button.get_popup(), button.get_popup())
		button.rect_min_size = _zone_selection_button.rect_min_size
		button.size_flags_horizontal = _zone_selection_button.size_flags_horizontal
	var _e = button.connect("item_selected", self, "_coopplus_on_room_selected")
	_run_options_panel_content.add_child(button)
	_coopplus_room_button = button
	_coopplus_room_button.disabled = RuntimeGate.room_capacity() > 0


static func _coopplus_copy_overrides(source: Control, target: Control) -> void:
	if source.theme != null:
		target.theme = source.theme
	for prop in source.get_property_list():
		var key: String = prop.name
		if key.begins_with("custom_fonts/") or key.begins_with("custom_styles/") \
				or key.begins_with("custom_colors/") or key.begins_with("custom_constants/"):
			var value = source.get(key)
			if value != null:
				target.set(key, value)


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


# Parent: character_selection.gd:465 (characters needing a switched-off set).
func _get_item_disabled_update(item: ItemParentData) -> UpdateData:
	var update = ._get_item_disabled_update(item)
	if update == null and item is CharacterData:
		var blocked = ProgressData.get("coopplus_blocked_dlcs")
		if blocked is Array:
			update = DlcRoster.blocked_dlc_of_character(item, blocked)
	return update


func _update_locked_panel(element: InventoryElement, player_index: int) -> void:
	._update_locked_panel(element, player_index)
	_coopplus_name_missing_players(element, player_index)


func _coopplus_name_missing_players(element: InventoryElement, player_index: int) -> void:
	var locked_panels: Array = _get_locked_panels()
	if player_index < 0 or player_index >= locked_panels.size() or not locked_panels[player_index].visible:
		return
	var roster = DlcRoster.find(get_tree())
	var text: String = roster.locked_text(_get_element_disabled_update(element)) if roster != null else ""
	if text != "":
		locked_panels[player_index].set_description(text)


# Parent: character_selection.gd:525/539 refresh the background of Panel1..4.
# On the host a zone the room's DLCs do not allow (the random zone's draw,
# character_selection.gd:514, or a selection made before the roster arrived)
# becomes an allowed one: a random one for the random zone, else the first.
func _setup_zone(index: int) -> void:
	var roster = DlcRoster.find(get_tree())
	if roster != null and roster.is_host() and _zone_selection_button != null:
		var i := int(index)
		if i >= 0 and i < _zone_selection_button.get_item_count() and _zone_selection_button.is_item_disabled(i):
			var allowed := _coopplus_allowed_zone_indices()
			if not allowed.empty():
				index = allowed[randi() % allowed.size()] if ProgressData.settings.zone_is_random else allowed[0]
	._setup_zone(index)
	_coopplus_update_extra_backgrounds()


func _on_ZoneSelectionButton_item_selected(index: int) -> void:
	._on_ZoneSelectionButton_item_selected(index)
	_coopplus_update_extra_backgrounds()


func _coopplus_update_extra_backgrounds() -> void:
	for panel in _coopplus_extra_panels:
		if is_instance_valid(panel) and panel.has_method("_update_bg"):
			panel._update_bg()
