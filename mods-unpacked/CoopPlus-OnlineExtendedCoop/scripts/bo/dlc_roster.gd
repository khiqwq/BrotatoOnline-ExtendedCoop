extends Node
# Which DLCs each player in the room has installed (D-014), for the DLC icons
# on the player panels and status strip rows (ui/dlc_badges.gd). Every
# machine in an online extended room runs this node; data goes through
# Brotato Online's public mod-message API (brotato_online_api.gd send_to_host
# / broadcast), which works on Steam and LAN alike and leaves Brotato
# Online's own messages untouched:
#   client -> host  "dlc_report"  {"dlcs": [...]}  its installed DLCs
#                   (ProgressData.available_dlc_ids), again every few seconds
#                   and whenever its player index changes
#   host -> all     "dlc_roster"  {"owners": {"<player index>": [...]}}
# The host's own entries come from its ProgressData. Nothing is restricted:
# Brotato Online registers the host's DLC content on players who do not own
# it (session_content_catalog.gd), so a DLC run works for everyone; each
# player still picks only DLC characters they own (Brotato Online's own
# rule). Offline, and in standard rooms (RuntimeGate.is_extended() false,
# R08), the roster is inactive and no icons are shown.

const DlcRule = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/dlc_rule.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const NODE_NAME := "CoopPlusDlcRoster"
const API_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlineAPI"
const MOD_ID := "CoopPlus-OnlineExtendedCoop"
const ROUTE_REPORT := "dlc_report"
const ROUTE_ROSTER := "dlc_roster"
const POLL_SEC := 0.5
const RESEND_SEC := 3.0

# player index -> [dlc id, ...] as reported (host) or broadcast (clients)
var owners := {}
var _api = null
var _poll := 0.0
var _resend := 0.0
var _last_sent_key := ""
# Local simulation only (debug/local_sim_probe.gd): every player is on this
# PC, these entries replace their DLC lists, and the roster is active offline.
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


func _ready() -> void:
	name = NODE_NAME
	pause_mode = Node.PAUSE_MODE_PROCESS


func is_active() -> bool:
	if not RuntimeGate.is_extended():
		return false
	if not _debug_owners.empty():
		return true
	return _api_node() != null and bool(_api.is_online())


# {player_index: [dlc ids]} for the players that reported, this machine's
# players filled in.
func current_owners() -> Dictionary:
	var out := owners.duplicate(true)
	var mine := DlcRule.clean_ids(ProgressData.available_dlc_ids)
	var local := _local_indices()
	if not _debug_owners.empty():
		local = range(RunData.get_player_count())
	for i in local:
		out[int(i)] = mine
	for k in _debug_owners:
		out[int(k)] = _debug_owners[k]
	return out


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
		_last_sent_key = ""


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
