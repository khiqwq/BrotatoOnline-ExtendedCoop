extends Reference
# "Own panel large" layout for the four-panel co-op screens with 5..8 players
# (AP-014; R14; D-010). Every player sits at their own PC and can only operate
# their own panel, so each machine shows its local player's panel at a larger
# width and condenses everyone else into ui/player_status_strip.gd. The other
# panels stay in the scene, only hidden: vanilla and Brotato Online keep
# addressing them by player index (purchases, rerolls and ready state go
# through the screen's methods, not through the panels' visibility; the
# focus-restore helpers that check visibility only pick where to draw a remote
# cursor). The hidden players' popups are un-registered as well (_mute_popups).
# On the shop and end-run screens the strip's rows can be selected to show that
# player's panel beside the local one (D-011); the strip joins the local
# player's FocusEmulator area for that (_add_focus_base). The upgrade screen's
# strip stays display-only: Brotato Online moves a client's focus back into its
# own panel there (menu_sync_manager.gd _ensure_local_progression_focus).
# Applied only with more than four players and exactly one local player; with
# several local players (not a supported setup, R02) the full row stays.

const PlayerStatusStrip = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/player_status_strip.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"

const VANILLA_SLOTS := 4
# Local panel : status strip width ratio in the screen's panel row.
const LOCAL_PANEL_STRETCH := 1.5
# Gap around the strip. The shop and upgrade rows span the screen with no
# separation and each panel keeps a 15 px inner margin
# (coop_shop_player_container.tscn), so the strip gets the same; the end-run
# row already spaces its children (separation 50, inside a MarginContainer).
const STRIP_MARGIN := {"shop": 15, "upgrades": 15, "end_run": 0}
# The upgrade screen is drawn over the battle, whose HUD blocks for P2..P8 sit
# under the strip and showed through it and between its rows (EV-0025); the
# strip's column gets a dark backdrop there. The shop and end-run screens
# have their own opaque backgrounds.
const STRIP_BACKDROP := {"upgrades": Color(0.04, 0.04, 0.04, 0.92)}
const SELECTABLE_MODES := ["shop", "end_run"]
const FOCUS_PATH_LISTS := [
	"contain_horizontal_focus_exception_paths",
	"require_entry_from_control_paths",
	"focus_neighbour_top_paths",
	"focus_neighbour_bottom_paths",
	"focus_neighbour_left_paths",
	"focus_neighbour_right_paths",
]


# The one connected player on a real (non-virtual) device, or -1. Remote
# players always use the gate's virtual devices in extended mode.
static func local_player_index() -> int:
	var found := -1
	var players: Array = CoopService.connected_players
	for i in players.size():
		var device := int(players[i][0])
		if RuntimeGate.is_virtual_device(device):
			continue
		if found >= 0:
			return -1
		found = i
	return found


# panels: every player's panel in player order (vanilla and cloned). Returns
# the strip, or null when the layout does not apply.
static func apply(screen: Node, row: Container, panels: Array, mode: String) -> Node:
	if panels.size() <= VANILLA_SLOTS or row == null:
		return null
	var local := local_player_index()
	if local < 0 or local >= panels.size() or panels[local] == null:
		return null
	var others := []
	for i in panels.size():
		if i == local:
			continue
		others.append(i)
		if panels[i] != null:
			panels[i].visible = false
	var local_panel: Control = panels[local]
	local_panel.visible = true
	local_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	local_panel.size_flags_stretch_ratio = LOCAL_PANEL_STRETCH
	var holder := PanelContainer.new()
	holder.name = "CoopPlusPlayerStatusStripHolder"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style: StyleBox = StyleBoxEmpty.new()
	if STRIP_BACKDROP.has(mode):
		style = StyleBoxFlat.new()
		style.bg_color = STRIP_BACKDROP[mode]
	var margin := float(STRIP_MARGIN.get(mode, 0))
	style.content_margin_left = margin
	style.content_margin_top = margin
	style.content_margin_right = margin
	style.content_margin_bottom = margin
	holder.add_stylebox_override("panel", style)
	row.add_child(holder)
	row.move_child(holder, local_panel.get_index() + 1)
	var strip = PlayerStatusStrip.new()
	holder.add_child(strip)
	strip.setup(screen, mode, others)
	var muted := _mute_popups(screen, others)
	if mode in SELECTABLE_MODES:
		strip.enable_view(row, panels, local, LOCAL_PANEL_STRETCH, muted)
		if not _add_focus_base(screen, local, strip):
			ModLoaderLog.warning("%s: player rows not reachable by focus (FocusEmulator%d layout changed)" % [mode, local + 1], COOPPLUS_MOD_ID)
	return strip


# Adds `base` to the player's FocusEmulator area, as the screens' own
# focus_base_data entries do for the panels: moving right from the panel
# reaches the rows (the panels do not contain horizontal focus), up/down stays
# within the rows, accept emits the row button's "pressed" through
# FocusEmulatorSignal, and CoopFix-OnlineMouseUI routes clicks to buttons in an
# owned emulator's area (mouse_router.gd _hit_test). The new entry is a copy of
# the panel's entry, so no game class is referenced here; the emulator's lists
# are replaced, not changed in place (the scene resource shares them).
static func _add_focus_base(screen: Node, player_index: int, base: Control) -> bool:
	var emulator = screen.get_node_or_null("FocusEmulator%d" % (player_index + 1))
	if emulator == null or not "focus_base_data" in emulator or not "_focus_base_nodes" in emulator:
		return false
	var datas: Array = emulator.focus_base_data
	var nodes: Array = emulator._focus_base_nodes
	# _find_control_base_data pairs both lists by index.
	if datas.empty() or datas.size() != nodes.size():
		return false
	var data = datas[0].duplicate()
	data.path = emulator.get_path_to(base)
	data.apply_player_color = true
	data.contain_horizontal_focus = false
	data.contain_vertical_focus = true
	for field in FOCUS_PATH_LISTS:
		if field in data:
			data.set(field, [])
	var new_datas := datas.duplicate()
	new_datas.append(data)
	emulator.focus_base_data = new_datas
	nodes.append(base)
	return true


# The screens register one item popup and one stat popup per player with
# their PopupManager, which shows them when that player focuses an element
# (popup_manager.gd); coop_end_run.gd _ready focuses every player's first
# item, so the hidden players' popups appeared over the local panel (EV-0025).
# PopupManager null-checks every entry before use and nothing else reads its
# lists, so un-registering them keeps them hidden, including focus mirrored
# from remote players later. The popup nodes stay in the scene. Returns
# {field: {player_index: popup}} so the strip can register a player's popups
# again while that player's panel is shown.
static func _mute_popups(screen: Node, player_indices: Array) -> Dictionary:
	var muted := {}
	var manager = screen.get("_popup_manager")
	if manager == null:
		return muted
	for field in ["_item_popups", "_stat_popups"]:
		var popups = manager.get(field)
		if not popups is Array:
			continue
		muted[field] = {}
		for i in player_indices:
			if i < popups.size() and popups[i] != null:
				muted[field][i] = popups[i]
				popups[i].hide()
				popups[i] = null
	return muted
