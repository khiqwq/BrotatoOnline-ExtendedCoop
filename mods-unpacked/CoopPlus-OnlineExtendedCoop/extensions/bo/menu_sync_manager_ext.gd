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

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"


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
