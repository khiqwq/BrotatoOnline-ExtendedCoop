# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: online player count clamped to the session capacity instead of 4, never growing empty players. See THIRD_PARTY_NOTICES.md.
extends "res://main.gd"
# Battle scene guard (AP-006; R01, R08; BAT-02, BAT-03, BAT-04, BAT-08,
# BAT-M02, DATA-12, MENU-12, INP-M01). At runtime the parent is Brotato
# Online's extensions/main_safe_pool_exit.gd (manifest dependency, ADR-001).
# On players_spawned it trims the spawned players and RunData to its
# "authoritative" online count, clamped to 4, which frees the nodes of P5..P8
# and cuts them out of RunData.players_data.
# The mod loader first compiles this file against vanilla main.gd, so Brotato
# Online helpers are reached through has_method/call or a parent call only.
#
# Extended mode only (RuntimeGate.is_extended()):
#   - the online count follows the connected players up to the session
#     capacity, and never above the PlayerRunData that exists
#   - Main's per-player arrays (main.gd:31,32,48,50) and the StatsManager
#     queues (stats_manager.gd:10-11) get one entry per possible player before
#     anything indexes them; RunData._players_die_args gets the slot of a dying
#     player before vanilla writes it (main.gd:471)
#   - picked-up materials and experience are split over every player:
#     vanilla's local [0, 0, 0, 0] (main.gd:879-880) cannot hold P5..P8; a
#     gold rotation index that a 5+ -> 1..4 player cut left at 4..7 is
#     wrapped before vanilla uses it (DATA-12)
# Whenever the gate is vanilla every override runs the parent unchanged. With
# 1..4 players in extended mode the extra array entries are never indexed
# (vanilla loops by RunData.get_player_count(), Brotato Online checks each
# index), so play stays the same (R08).
# on_gold_picked_up with 5..8 players still runs the game's own method, which
# does every pickup effect; only its split cannot cover P5..P8 (four-entry
# local arrays, main.gd:879-880). It runs with the player count limited to 4
# for that call, its material and experience grants are captured
# (run_data_ext.gd) and the split's total is shared over every player in turn
# (D-006: no game code is restated here).
#   - P5..P8 battle HUD (BAT-07): ui/extra_player_hud.gd clones the P1..P4
#     life bars, HUD blocks and pending-icon containers in _enter_tree; the
#     pending containers join _things_to_process_player_containers right
#     before players_spawned uses them, and the P5..P8 blocks are placed in
#     the P1..P4 corners afterwards; in _ready the team bag of leftover
#     materials moves from P1's block to P5's
# Left for later: camera
# targets (BAT-M08), log_run_info defaults (BAT-10) and the RunData
# per-player arrays other than _players_die_args (DATA-01/02, BAT-M04).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const ExtraPlayerHud = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_hud.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"

# Pending-icon containers of P5..P8, created in _enter_tree.
var _coopplus_extra_things := []


# Main has no _init of its own (vanilla or Brotato Online); member
# initialisers have run, and none of these arrays is reassigned later, so the
# grown arrays hold for the whole battle (Brotato Online writes the queues
# back into the same arrays, battle_replica_manager.gd:2958-2961).
func _init() -> void:
	if not RuntimeGate.is_extended():
		return
	var slot_count := _coopplus_slot_count()
	while _upgrades_to_process.size() < slot_count:
		_upgrades_to_process.push_back([])
	while _consumables_to_process.size() < slot_count:
		_consumables_to_process.push_back([])
	while _proj_on_death_stat_caches.size() < slot_count:
		_proj_on_death_stat_caches.push_back(null)
	while _player_is_under_half_health.size() < slot_count:
		_player_is_under_half_health.push_back(false)


# The scene is fully instanced but nothing has run _ready yet. StatsManager
# indexes its queues by player whenever a player's stats are reloaded
# (stats_manager.gd:119-125, from Main.on_stats_updated, connected in
# Main._ready), so they grow here, before the first reload. Never calls the
# parent (ADR-001 rule 1); neither vanilla nor Brotato Online defines
# _enter_tree.
func _enter_tree() -> void:
	if not RuntimeGate.is_extended():
		return
	_coopplus_grow_stats_manager_queues()
	var player_count: int = RunData.get_player_count()
	if player_count > CapacityPolicy.VANILLA_MAX_PLAYERS and _coopplus_extra_things.empty():
		var built: Dictionary = ExtraPlayerHud.build(self, int(min(player_count, _coopplus_slot_count())))
		if not bool(built.ok):
			ModLoaderLog.error("main: no P5+ battle HUD (%s)" % built.reason, COOPPLUS_MOD_ID)
		_coopplus_extra_things = built.things


# Runs after every parent _ready (ADR-001 rule 1: not called here). Main's
# onready references to the team bag and FPS label (main.gd:90-91, 106) are
# set by now and follow the nodes when they move to P5's block.
func _ready() -> void:
	if RuntimeGate.is_extended() and not _coopplus_extra_things.empty():
		if not ExtraPlayerHud.attach_team_widgets(self):
			ModLoaderLog.warning("main: team bag stays in P1's HUD block (no P5 block)", COOPPLUS_MOD_ID)


# Parent: main_safe_pool_exit.gd:162, which ends in vanilla main.gd:1361. Vanilla
# reads _things_to_process_player_containers[i] for every spawned player, but
# its _ready only collected P1..P4 (main.gd:215), so P5+ containers are added
# here, after that loop and before their first use.
func _on_EntitySpawner_players_spawned(players: Array) -> void:
	if RuntimeGate.is_extended():
		for container in _coopplus_extra_things:
			if not _things_to_process_player_containers.has(container):
				_things_to_process_player_containers.push_back(container)
	._on_EntitySpawner_players_spawned(players)
	if RuntimeGate.is_extended():
		ExtraPlayerHud.place_player_huds(_players_ui)


func _coopplus_grow_stats_manager_queues() -> void:
	var stats_manager = get_node_or_null("%StatsManager")
	if stats_manager == null:
		ModLoaderLog.warning("main: StatsManager not found; its per-player queues stay at 4", COOPPLUS_MOD_ID, true)
		return
	var slot_count := _coopplus_slot_count()
	for property in ["_structure_queues", "_pet_queues"]:
		var queues = stats_manager.get(property)
		if typeof(queues) != TYPE_ARRAY:
			continue
		while queues.size() < slot_count:
			queues.push_back({})


# Parent: main_safe_pool_exit.gd:80. Called through self by its
# _brotato_online_trim_spawned_players_to_authoritative_count (:142) and
# _brotato_online_repair_run_data_player_count_for_spawn (:111) from its
# _on_EntitySpawner_players_spawned (:162), before vanilla sees the players.
func _brotato_online_get_authoritative_online_player_count() -> int:
	var parent_count := int(._brotato_online_get_authoritative_online_player_count())
	if parent_count <= 0 or not RuntimeGate.is_extended():
		return parent_count
	# The parent's only source (:85); the spawner already restored the run
	# slot snapshot into it during EntitySpawner.init().
	var roster := int(CoopService.connected_players.size())
	if roster <= CapacityPolicy.VANILLA_MAX_PLAYERS:
		return parent_count
	var layout: Dictionary = CapacityPolicy.new(RuntimeGate.capacity()).layout_count(roster)
	var count := int(layout.count)
	if not bool(layout.ok):
		ModLoaderLog.warning("main: %d connected players exceed capacity %d; using %d" % [roster, RuntimeGate.capacity(), count], COOPPLUS_MOD_ID, true)
	# Vanilla spawned one player per PlayerRunData; a larger count would only
	# append characterless PlayerRunData after the players exist.
	var data_count := 0
	if typeof(RunData.players_data) == TYPE_ARRAY:
		data_count = RunData.players_data.size()
	if data_count > 0 and count > data_count:
		ModLoaderLog.warning("main: %d connected players but only %d players in RunData; not adding empty players" % [count, data_count], COOPPLUS_MOD_ID, true)
		count = data_count
	return count


# Parent: main_safe_pool_exit.gd:421, which ends in vanilla main.gd:466 (host
# and offline) or writes the same slot itself (client, :454-455). Both write
# RunData._players_die_args[player_index]; vanilla only allocates 4 slots
# (run_data.gd:30) and the end-of-run screen reads them back by player.
func _on_player_died(p_player, _args) -> void:
	if RuntimeGate.is_extended():
		_coopplus_ensure_die_args_slot(p_player)
	._on_player_died(p_player, _args)


# Parent: main_safe_pool_exit.gd:405, which passes everything except its
# online-client clean-up branch on to vanilla main.gd:827.
func on_gold_picked_up(gold: Node, player_index: int) -> void:
	if _coopplus_needs_wide_gold_split(gold, player_index):
		_coopplus_pick_up_gold(gold, player_index)
		return
	if RuntimeGate.is_extended():
		_coopplus_wrap_stale_gold_player()
	.on_gold_picked_up(gold, player_index)


# Entries per player array: the session capacity, never below vanilla's 4.
func _coopplus_slot_count() -> int:
	return int(clamp(RuntimeGate.capacity(), CapacityPolicy.VANILLA_MAX_PLAYERS, CapacityPolicy.MAX_SUPPORTED_PLAYERS))


func _coopplus_ensure_die_args_slot(p_player) -> void:
	if p_player == null or not is_instance_valid(p_player):
		return
	var index_value = p_player.get("player_index")
	if index_value == null:
		return
	var index := int(index_value)
	if index < 0 or index >= _coopplus_slot_count():
		return
	var die_args = RunData.get("_players_die_args")
	if typeof(die_args) != TYPE_ARRAY:
		return
	while die_args.size() <= index:
		die_args.push_back(Utils.default_die_args)


# Only a pickup vanilla would split over 5..8 players takes the wide path.
# Already picked-up gold and the parent's online-client clean-up branch
# (main_safe_pool_exit.gd:406-409) stay with the parent.
func _coopplus_needs_wide_gold_split(gold: Node, player_index: int) -> bool:
	if not RuntimeGate.is_extended() or player_index < 0:
		return false
	if RunData.get_player_count() <= CapacityPolicy.VANILLA_MAX_PLAYERS:
		return false
	if gold == null or not is_instance_valid(gold) or bool(gold.already_picked_up):
		return false
	if _cleaning_up and has_method("_brotato_online_is_online_client") and bool(call("_brotato_online_is_online_client")):
		return false
	return true


# DATA-12: Main._ready draws _next_gold_player from the count RunData has
# before the spawner guard settles it (main.gd:138 runs before :240). When a
# 5..8 player layout is cut to 1..4 players there, the index can be 4..7 and
# vanilla's rotation (main.gd:882) drops that share. Only such values are
# wrapped; 0..3 are left alone, so every state a 1..4 player run can reach
# without extended mode keeps its vanilla rotation (R08).
func _coopplus_wrap_stale_gold_player() -> void:
	var player_count: int = RunData.get_player_count()
	if player_count <= 0 or player_count > CapacityPolicy.VANILLA_MAX_PLAYERS:
		return
	if _next_gold_player >= CapacityPolicy.VANILLA_MAX_PLAYERS:
		_next_gold_player = posmod(_next_gold_player, player_count)


# The game's method runs with RunData.get_player_count() limited to 4, so its
# split stays inside its four-entry arrays, and _next_gold_player at 0. Its
# split ends the method with one material and one experience grant per slot
# 0..3; grants before that (e.g. gold from enemies hit by a pickup damage
# effect) are applied unchanged. The split's units then go to every player in
# turn from the rotation index, one material and one experience point each,
# so both stay equal as in the game. If the captured grants do not end with
# that pattern (a changed game), they are applied as the game made them.
func _coopplus_pick_up_gold(gold: Node, player_index: int) -> void:
	var player_count: int = RunData.get_player_count()
	var turn: int = posmod(_next_gold_player, player_count)
	RunData.call("coopplus_begin_grant_capture")
	RunData.call("coopplus_limit_player_count_this_frame", CapacityPolicy.VANILLA_MAX_PLAYERS)
	_next_gold_player = 0
	.on_gold_picked_up(gold, player_index)
	RunData.call("coopplus_clear_player_count_limit")
	var grants: Array = RunData.call("coopplus_end_grant_capture")
	var split_from: int = grants.size() - 2 * CapacityPolicy.VANILLA_MAX_PLAYERS
	if split_from < 0 or not _coopplus_is_split_tail(grants, split_from):
		ModLoaderLog.warning("gold pickup: unexpected grants %s; applied unchanged" % str(grants), COOPPLUS_MOD_ID)
		for grant in grants:
			RunData.call("coopplus_apply_grant", grant)
		_next_gold_player = turn
		return
	var units := 0
	for k in grants.size():
		if k < split_from:
			RunData.call("coopplus_apply_grant", grants[k])
		elif grants[k][0] == "gold":
			units += int(grants[k][1])
	var shares := []
	for _i in player_count:
		shares.push_back(0)
	for _u in units:
		shares[turn] += 1
		turn = (turn + 1) % player_count
	_next_gold_player = turn
	for i in player_count:
		RunData.add_gold(shares[i], i)
		RunData.add_xp(shares[i], i)


# grants[from..]: material then experience for slot 0, then slot 1, ... 3.
func _coopplus_is_split_tail(grants: Array, from: int) -> bool:
	for slot in CapacityPolicy.VANILLA_MAX_PLAYERS:
		var material: Array = grants[from + 2 * slot]
		var experience: Array = grants[from + 2 * slot + 1]
		if material[0] != "gold" or experience[0] != "xp" or int(material[2]) != slot or int(experience[2]) != slot:
			return false
	return true
