extends Node
# The game's options menu (title screen and pause menu) gets one more
# Gameplay switch: how the player list of rooms with nine players or more
# scrolls (ui/player_status_strip.gd, D-015). On: a whole page of new rows at
# a time; off: one row at a time, the top row leaving as the next comes in.
# The switch is a copy of the menu's own "share co-op loot" switch, placed
# under it, so it has the menu's font, style and sounds; the menu's script is
# not extended (Brotato Online avoids that as well, pause_focus_alias_manager.gd).
# The choice is saved per PC with the display mode (user://coopplus_view.cfg)
# and read by each scroll, so a change made from the pause menu applies at once.

const PlayerStatusStrip = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/player_status_strip.gd")

const ENTRY_NAME := "CoopPlusListScrollButton"
const ANCHOR_PATH := "%ShareCoopLootButton"
const TEXT := {
	"zh": "超四人玩家列表：整页翻动（关闭则逐个滚动）",
	"en": "Extended player list: flip a page at a time (off: one row at a time)",
}


func _ready() -> void:
	name = "CoopPlusOptionsEntry"
	var _e = get_tree().connect("node_added", self, "_on_node_added")


# The menu root is added with its children already in place; the switch goes
# in once the menu is ready (its own _ready reads its nodes).
func _on_node_added(node: Node) -> void:
	if node.name != "MenuOptions" or not node.has_method("init_values_from_progress_data"):
		return
	if not node.is_connected("ready", self, "_add_entry"):
		var _e = node.connect("ready", self, "_add_entry", [node], CONNECT_ONESHOT)


func _add_entry(menu: Node) -> void:
	if not is_instance_valid(menu):
		return
	var anchor = menu.get_node_or_null(ANCHOR_PATH)
	if not anchor is CheckButton or anchor.get_parent().has_node(ENTRY_NAME):
		return
	var entry: CheckButton = anchor.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	entry.name = ENTRY_NAME
	entry.unique_name_in_owner = false
	entry.text = TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else TEXT["en"]
	entry.pressed = PlayerStatusStrip.load_scroll_mode() == PlayerStatusStrip.SCROLL_PAGE
	anchor.get_parent().add_child_below_node(anchor, entry)
	var _e = entry.connect("toggled", self, "_on_toggled")


func _on_toggled(pressed: bool) -> void:
	PlayerStatusStrip.save_scroll_mode(PlayerStatusStrip.SCROLL_PAGE if pressed else PlayerStatusStrip.SCROLL_ROW)
