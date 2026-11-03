extends Node
# Which DLCs each player in the room has installed (D-014). Every machine in
# an online extended room runs this node; data goes through Brotato Online's
# public mod-message API (brotato_online_api.gd send_to_host / broadcast),
# which works on Steam and LAN alike and leaves Brotato Online's own messages
# untouched:
#   client -> host  "dlc_report"  {"dlcs": [...]}  its installed DLCs
#                   (ProgressData.available_dlc_ids), again every few seconds
#                   and whenever its player index changes
#   host -> all     "dlc_roster"  {"owners": {"<player index>": [...]}}
# The host's own entries come from its ProgressData. A DLC that some player
# lacks is blocked. A player who has not reported yet counts as having every
# DLC for REPORT_GRACE_MSEC after they appear (each join would otherwise
# switch every DLC off for a moment, clearing DLC character picks and moving
# the zone), then as having none; the run start (strict) counts them as
# having none at once. Blocked DLCs are switched off: on the selection
# screens it is switched off through ProgressData.coopplus_set_blocked_dlcs
# (progress_data_ext.gd) - on the host on all three screens, on clients on
# character selection only (later Brotato Online applies the host's content
# there, menu_sync_manager.gd _apply_host_content_configuration) - so its
# characters, weapons and items are disabled as for a set switched off in the
# item set bar. The bar (item_set_bar_ext.gd) and the zone list
# (character_selection_ext.gd) name the players lacking it, the player panels
# show each player's DLC icons, and difficulty_selection_ext.gd leaves it out
# of the run. Offline, and in standard rooms (RuntimeGate.is_extended() false,
# R08), nothing is blocked.

const DlcRule = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/dlc_rule.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const NODE_NAME := "CoopPlusDlcRoster"
const API_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlineAPI"
const MOD_ID := "CoopPlus-OnlineExtendedCoop"
const ROUTE_REPORT := "dlc_report"
const ROUTE_ROSTER := "dlc_roster"
const POLL_SEC := 0.5
const RESEND_SEC := 3.0
const REPORT_GRACE_MSEC := 5000
const SELECTION_SCENES := [
	"res://ui/menus/run/character_selection.tscn",
	"res://ui/menus/run/weapon_selection.tscn",
	"res://ui/menus/run/difficulty_selection/difficulty_selection.tscn",
]
const TEXT := {
	"zh": {"blocked": "%s 没有安装此 DLC，无法启用", "zone": "%s（%s 未安装）", "locked": "%s：%s", "separator": "、"},
	"en": {"blocked": "Not installed by %s: cannot be enabled", "zone": "%s (not installed by %s)", "locked": "%s: %s", "separator": ", "},
}

# player index -> [dlc id, ...] as reported (host) or broadcast (clients)
var owners := {}
var _api = null
var _poll := 0.0
var _resend := 0.0
var _last_sent_key := ""
# player index -> OS.get_ticks_msec() when first seen without a report
var _unreported_since := {}
# Local simulation only (debug/local_sim_probe.gd): every player is on this
# PC, these entries replace their DLC lists, and the rule applies offline.
var _debug_owners := {}


static func find(tree: SceneTree):
	return tree.root.get_node_or_null("ModLoader/" + MOD_ID + "/" + NODE_NAME) if tree != null else null


# Every DLC the game knows, installed here or not.
static func dlc_updates() -> Array:
	var out := []
	for update in ItemService.update_data_list:
		if update != null and update.update_type == UpdateData.UpdateType.DLC:
			out.append(update)
	return out


static func texts() -> Dictionary:
	return TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else TEXT["en"]


static func players_text(indices: Array) -> String:
	return DlcRule.players_text(indices, texts().separator)


func _ready() -> void:
	name = NODE_NAME
	pause_mode = Node.PAUSE_MODE_PROCESS


func is_active() -> bool:
	if not RuntimeGate.is_extended():
		return false
	if not _debug_owners.empty():
		return true
	return _api_node() != null and bool(_api.is_online())


func is_host() -> bool:
	if not _debug_owners.empty():
		return true
	return _api_node() != null and bool(_api.is_host())


# {player_index: [dlc ids]} with this machine's players filled in; unless
# strict, players still in their report grace get every DLC.
func current_owners(strict := true) -> Dictionary:
	var out := owners.duplicate(true)
	var mine := DlcRule.clean_ids(ProgressData.available_dlc_ids)
	var local := _local_indices()
	if not _debug_owners.empty():
		local = range(RunData.get_player_count())
	for i in local:
		out[int(i)] = mine
	for k in _debug_owners:
		out[int(k)] = _debug_owners[k]
	var now := OS.get_ticks_msec()
	for i in range(RunData.get_player_count()):
		if out.has(i):
			_unreported_since.erase(i)
			continue
		if not _unreported_since.has(i):
			_unreported_since[i] = now
		if not strict and now - int(_unreported_since[i]) < REPORT_GRACE_MSEC:
			out[i] = _all_ids()
	return out


# {dlc_id: [player indices lacking it]}; empty when the rule does not apply.
# strict (the run start): players who have not reported count as lacking all.
func blocked(strict := false) -> Dictionary:
	if not is_active():
		return {}
	return DlcRule.blocked(_all_ids(), current_owners(strict), RunData.get_player_count())


static func _all_ids() -> Array:
	var ids := []
	for update in dlc_updates():
		ids.append(update.id)
	return ids


# A selection screen's locked panel for content of a blocked DLC
# ("深渊恐惧：P5 没有安装此 DLC，无法启用"); "" when the DLC is not blocked.
func locked_text(update) -> String:
	var missing: Array = blocked().get(update.id, []) if update != null else []
	if missing.empty():
		return ""
	return texts().locked % [tr(update.name), texts().blocked % players_text(missing)]


# The DLC whose characters include this one, among the blocked ids; null if none.
static func blocked_dlc_of_character(character, blocked_ids: Array):
	if character == null or blocked_ids.empty():
		return null
	for update in dlc_updates():
		if update.id in blocked_ids and update.item_set != null:
			for c in update.item_set.characters:
				if c != null and c.my_id == character.my_id:
					return update
	return null


func debug_set_owner(player_index: int, dlc_ids: Array) -> void:
	_debug_owners[player_index] = DlcRule.clean_ids(dlc_ids)


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_SEC
	if RuntimeGate.is_extended() and _api_node() != null and bool(_api.is_online()):
		_resend -= POLL_SEC
		if bool(_api.is_host()):
			_host_tick()
		else:
			_client_tick()
	elif not owners.empty() or _last_sent_key != "":
		owners.clear()
		_unreported_since.clear()
		_last_sent_key = ""
	_apply_to_selection()


func _host_tick() -> void:
	var count: int = RunData.get_player_count()
	for k in owners.keys():
		if int(k) >= count:
			owners.erase(k)
	var roster := current_owners()
	var wire := {}
	for k in roster:
		wire[str(k)] = roster[k]
	var key := var2str(wire)
	if key != _last_sent_key or _resend <= 0.0:
		_last_sent_key = key
		_resend = RESEND_SEC
		var _sent = _api.broadcast(MOD_ID, ROUTE_ROSTER, {"owners": wire})


func _client_tick() -> void:
	var mine := DlcRule.clean_ids(ProgressData.available_dlc_ids)
	var key := var2str([_local_indices(), mine])
	if key != _last_sent_key or _resend <= 0.0:
		_last_sent_key = key
		_resend = RESEND_SEC
		var _sent = _api.send_to_host(MOD_ID, ROUTE_REPORT, {"dlcs": mine})


# Only on the selection screens: during a run the content is fixed (a player
# joining later never changes it, and no item pool is rebuilt mid-run).
func _apply_to_selection() -> void:
	if not ProgressData.has_method("coopplus_set_blocked_dlcs"):
		return
	var scene = get_tree().current_scene
	var file: String = scene.filename if scene != null else ""
	var screens: Array = SELECTION_SCENES if is_host() or not is_active() else [SELECTION_SCENES[0]]
	if not file in screens:
		return
	var ids: Array = blocked().keys()
	ids.sort()
	ProgressData.coopplus_set_blocked_dlcs(ids)


func _on_mod_message(mod_id: String, route: String, payload: Dictionary, meta: Dictionary) -> void:
	if mod_id != MOD_ID or not RuntimeGate.is_extended() or _api_node() == null:
		return
	if route == ROUTE_REPORT and bool(_api.is_host()):
		var index := int(meta.get("from_player_index", -1))
		if index >= 0 and index < RunData.get_player_count():
			owners[index] = DlcRule.clean_ids(payload.get("dlcs", []))
	elif route == ROUTE_ROSTER and not bool(_api.is_host()) and str(meta.get("from_role", "")) == "host":
		var incoming = payload.get("owners", {})
		if typeof(incoming) != TYPE_DICTIONARY:
			return
		var next := {}
		for k in incoming:
			if str(k).is_valid_integer():
				next[int(k)] = DlcRule.clean_ids(incoming[k])
		owners = next


# Player indices move when the roster changes: drop the remote entries until
# their owners report again (clients re-report on their own index change).
func _on_slot_layout_changed(_context = null) -> void:
	if _api_node() != null and bool(_api.is_host()):
		owners.clear()
		_unreported_since.clear()
		_last_sent_key = ""


func _local_indices() -> Array:
	if _api_node() == null:
		return []
	var indices = _api.get_local_player_indices()
	return indices if indices is Array else []


func _api_node():
	if _api != null and is_instance_valid(_api):
		return _api
	_api = get_node_or_null(API_PATH)
	if _api != null:
		if not _api.is_connected("mod_message_received", self, "_on_mod_message"):
			var _e = _api.connect("mod_message_received", self, "_on_mod_message")
		if _api.has_signal("slot_layout_changed") and not _api.is_connected("slot_layout_changed", self, "_on_slot_layout_changed"):
			var _e2 = _api.connect("slot_layout_changed", self, "_on_slot_layout_changed")
	return _api
