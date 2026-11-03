# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: shop-to-battle player count clamped to the session capacity instead of 4; shop arrays padded with neutral values. See THIRD_PARTY_NOTICES.md.
extends "res://mods-unpacked/six666-BrotatoOnline/scripts/menu_sync_manager.gd"
# Menu sync guards (AP-006; R01, R08; MENU-01, MENU-03, INP-M01). Brotato
# Online creates this manager with load()+set_script() in its mod_main._ready
# (mod_main.gd:332,342), after the mod loader applied this extension, and its
# constants are literals, so the extension is installed from mod_main._init
# (ADR-001).
#
# Extended mode only (RuntimeGate.is_extended()):
#   - on every shop -> battle start the RunData player count follows the
#     connected players up to the session capacity instead of 4, so the host
#     no longer cuts P5..P8 out of RunData.players_data before the battle
#   - per-player shop arrays that are shorter than the run are padded with the
#     neutral vanilla value instead of the value being written, so one
#     player's "pressed go" no longer marks the players after it as ready
# Whenever the gate is vanilla, and for every 1..4 player write, each
# override runs the parent unchanged (R08).
# Left for later: selection/shop/upgrade UI arrays and containers for P5..P8
# (MENU-04/05, AP-015), roster checks of incoming player indices (MENU-08/09,
# AP-011) and the ready barriers (MENU-02/10, AP-012).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"

var _coopplus_popup_refresh_queued := false


# Parent: menu_sync_manager.gd:8007 (clamp at :8015). Its only caller,
# _force_run_player_count_to_online_coop_layout (:8018), runs through self from
# _build_shop_start_run_config_for_scene_sync (:2592) and
# execute_synced_shop_game_start (:2620) and calls
# RunData.set_player_count(result, false) whenever the count differs.
func _get_online_coop_layout_player_count() -> int:
	var parent_count := int(._get_online_coop_layout_player_count())
	if parent_count <= 0 or not RuntimeGate.is_extended():
		return parent_count
	# The parent's only source (:8012).
	var count := int(CoopService.connected_players.size())
	if count <= CapacityPolicy.VANILLA_MAX_PLAYERS:
		return parent_count
	var layout: Dictionary = CapacityPolicy.new(RuntimeGate.capacity()).layout_count(count)
	if not bool(layout.ok):
		ModLoaderLog.warning("menu_sync: %d connected players exceed capacity %d; using %d" % [count, RuntimeGate.capacity(), int(layout.count)], COOPPLUS_MOD_ID, true)
	return int(layout.count)


# Parent: menu_sync_manager.gd:5988. It pads the shop node's array up to
# max(4, players) with the value being written (:5992-5994), so with 5+
# players a write for one slot fills every missing slot with that value
# (MENU-03). Here the size rule stays the same, the padding uses the vanilla
# neutral value of the same type (base_shop.gd:9-19: null, false, 0), and a
# write outside that size is skipped; the parent's indexed write would fail
# there anyway.
func _set_node_array_value(node: Node, prop_name: String, index: int, value) -> void:
	var player_count := int(_get_run_player_count())
	if not RuntimeGate.is_extended() or (player_count <= CapacityPolicy.VANILLA_MAX_PLAYERS and index < CapacityPolicy.VANILLA_MAX_PLAYERS):
		._set_node_array_value(node, prop_name, index, value)
		return
	var min_size := int(max(CapacityPolicy.VANILLA_MAX_PLAYERS, player_count))
	if index < 0 or index >= min_size or index >= RuntimeGate.capacity():
		ModLoaderLog.warning("menu_sync: skipped %s write for slot %d (%d players, capacity %d)" % [prop_name, index, player_count, RuntimeGate.capacity()], COOPPLUS_MOD_ID, true)
		return
	var arr = _safe_get(node, prop_name, [])
	if typeof(arr) != TYPE_ARRAY:
		arr = []
	while arr.size() < min_size:
		arr.append(_coopplus_neutral_value(value))
	arr[index] = value
	node.set(prop_name, arr)


# Default a fresh vanilla per-player slot holds for a value of this type.
func _coopplus_neutral_value(value):
	match typeof(value):
		TYPE_BOOL:
			return false
		TYPE_INT:
			return 0
		TYPE_REAL:
			return 0.0
		TYPE_STRING:
			return ""
		TYPE_ARRAY:
			return []
		TYPE_DICTIONARY:
			return {}
	return null


# The local player's item popup after Brotato Online rewrites their shop
# (reported from online play, 2026-11-02: right after entering the shop the
# popup showed an item the cursor was not on). A client builds its own random
# shop and shows the popup for its default slot; the host's first snapshot
# then replaces the slots and rebuilds the inventory (these three methods),
# and nothing showed the popup again, so it kept the old item. Afterwards the
# local player's current focus is replayed through the PopupManager (the same
# calls a focus change makes); a cursor left on a freed or hidden control
# goes to the shop's default control. Not while the popup itself has focus
# (buttons shown). Extended rooms only; local UI only.
# Parents: menu_sync_manager.gd _apply_shop_player_state_to_ui, _apply_shop_delta_state_to_ui,
# _force_rebuild_shop_gear_container (6.6.8).
func _apply_shop_player_state_to_ui(shop: Node, state: Dictionary) -> bool:
	var applied: bool = ._apply_shop_player_state_to_ui(shop, state)
	_coopplus_queue_popup_refresh(shop, int(state.get("player_index", -1)))
	return applied


func _apply_shop_delta_state_to_ui(shop: Node, state: Dictionary) -> bool:
	var applied: bool = ._apply_shop_delta_state_to_ui(shop, state)
	_coopplus_queue_popup_refresh(shop, int(state.get("player_index", -1)))
	return applied


func _force_rebuild_shop_gear_container(shop: Node, player_index: int) -> void:
	._force_rebuild_shop_gear_container(shop, player_index)
	_coopplus_queue_popup_refresh(shop, player_index)


func _coopplus_queue_popup_refresh(shop: Node, player_index: int) -> void:
	if _coopplus_popup_refresh_queued or not RuntimeGate.is_extended() or shop == null or not is_instance_valid(shop):
		return
	if player_index != LocalFocusLayout.local_player_index():
		return
	_coopplus_popup_refresh_queued = true
	call_deferred("_coopplus_refresh_local_popup", shop)


func _coopplus_refresh_local_popup(shop) -> void:
	_coopplus_popup_refresh_queued = false
	if shop == null or not is_instance_valid(shop) or shop != get_tree().current_scene:
		return
	var local: int = LocalFocusLayout.local_player_index()
	var manager = shop.get("_popup_manager")
	if local < 0 or manager == null:
		return
	var pressed = manager.get("_elements_pressed")
	if pressed is Array and local < pressed.size() and pressed[local] != null:
		return
	var emulator = Utils.get_focus_emulator(local, shop)
	if emulator == null:
		return
	var control = emulator.focused_control
	if control == null or not is_instance_valid(control) or control.is_queued_for_deletion() or not control.is_visible_in_tree():
		if shop.has_method("_get_default_focus_control"):
			Utils.focus_player_control(shop._get_default_focus_control(local), local, emulator)
		return
	var shop_item = _coopplus_shop_item_of(control)
	if shop_item != null:
		manager._on_shop_item_focused(shop_item)
	elif control is InventoryElement:
		manager._on_element_focused(control)


func _coopplus_shop_item_of(control: Node):
	var node = control
	while node != null:
		if node is ShopItem:
			return node
		node = node.get_parent()
	return null
