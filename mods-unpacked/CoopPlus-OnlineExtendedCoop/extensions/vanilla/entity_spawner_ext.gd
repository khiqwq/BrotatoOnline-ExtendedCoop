# Contains modified excerpts of Brotato Online (six666-BrotatoOnline 6.6.6), GPL-3.0.
# Changes: online player count clamped to the session capacity instead of 4, never growing empty players. See THIRD_PARTY_NOTICES.md.
extends "res://global/entity_spawner.gd"
# Battle spawner guard (AP-006; R01, R08; BAT-01, BAT-05, BAT-21, BAT-M01,
# INP-M01). At runtime the parent is Brotato Online's
# extensions/entity_spawner_online_player_count_guard.gd (manifest dependency,
# ADR-001), which forces RunData to its "authoritative" online count right
# before and after vanilla init() and clamps that count to 4, cutting P5..P8
# out of RunData.players_data.
# The mod loader first compiles this file against the vanilla spawner, so
# Brotato Online helpers are reached through has_method/call or a parent call
# only; nothing here names a Brotato Online member directly.
#
# Extended mode only (RuntimeGate.is_extended()):
#   - the online count follows the run slot snapshot (or connected players)
#     up to the session capacity, and never above the PlayerRunData that
#     exists, so set_player_count cannot create characterless players
#   - the per-player spawner arrays (lootworms, structure and pet spawn
#     queues; vanilla holds 4 each) cover every player, before vanilla init()
#     spawns anyone and before the first StructureTimer tick
# Whenever the session has 4 or fewer players, or the gate is vanilla, every
# override returns exactly what the parent returns and the arrays keep their
# vanilla size of 4 (the structure loop shuffles one index per array entry,
# so a longer array would also change random number use in 1..4 player runs).
#   - P5..P8 spawn two grid columns to the right of P1..P4: vanilla init()
#     uses a 2x2 grid (entity_spawner.gd:92-97), so P5 landed exactly on P1
#     and the two bodies stuck together for the whole wave (local simulation,
#     BAT-06)
# Left for later: blocking a start on a roster mismatch (BAT-21 is only
# reported here; the flow guard is AP-012).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
# Vanilla grid columns are 100 px apart; P5..P8 use the next two columns.
const COOPPLUS_EXTRA_PLAYER_X_OFFSET := 200.0


# Member initialisers have already run, so the arrays exist. RunData holds the
# roster committed in the shop or character selection at this point; the
# count override below grows the arrays again if the slot snapshot restore
# adds players before vanilla init() runs.
func _init() -> void:
	if RuntimeGate.is_extended():
		_coopplus_ensure_player_slots(RunData.get_player_count())


# Parent: entity_spawner_online_player_count_guard.gd:140, which passes on to
# vanilla entity_spawner.gd:346. Vanilla init() hands every player its grid
# position through args.position; only P5..P8 are moved.
func spawn_entity(scene: PackedScene, args: SpawnEntityArgs, data: Resource = null, source = null, charmed_by: int = -1) -> KinematicBody2D:
	if RuntimeGate.is_extended() and args != null and args.type == EntityType.PLAYER and args.player_index >= CapacityPolicy.VANILLA_MAX_PLAYERS:
		args.position.x += COOPPLUS_EXTRA_PLAYER_X_OFFSET
	return .spawn_entity(scene, args, data, source, charmed_by)


# Parent: entity_spawner_online_player_count_guard.gd:66. Called through self
# by _brotato_online_force_run_player_count (guard :91-92) before and after
# vanilla init(). The parent call comes first because it restores the run slot
# snapshot into CoopService.connected_players (guard :74-77).
func _brotato_online_get_authoritative_online_player_count() -> int:
	var parent_count := int(._brotato_online_get_authoritative_online_player_count())
	if parent_count <= 0 or not RuntimeGate.is_extended():
		return parent_count
	var roster := _coopplus_online_roster_count()
	if roster <= CapacityPolicy.VANILLA_MAX_PLAYERS:
		# Same source and order as the parent, so this is the parent's value.
		return parent_count
	var count := _coopplus_extended_count(roster)
	_coopplus_ensure_player_slots(int(max(count, RunData.get_player_count())))
	return count


# Same sources and order as the parent (guard :74-88) without its clamp: the
# run slot snapshot when the slot manager holds one, else connected players.
func _coopplus_online_roster_count() -> int:
	if has_method("_brotato_online_get_slot_manager"):
		var slot_manager = call("_brotato_online_get_slot_manager")
		if slot_manager != null and is_instance_valid(slot_manager) and slot_manager.has_method("get_online_run_slot_snapshot_count"):
			var snapshot_count := int(slot_manager.get_online_run_slot_snapshot_count())
			if snapshot_count > 0:
				return snapshot_count
	if CoopService == null:
		return -1
	return int(CoopService.connected_players.size())


# Roster of 5..8 players. Shrinking down to the roster is still allowed (that
# is the parent's repair of a stale, larger RunData layout), but the count
# never exceeds the PlayerRunData that exists: set_player_count would append
# players without a character and vanilla init() would spawn them.
func _coopplus_extended_count(roster: int) -> int:
	var layout: Dictionary = CapacityPolicy.new(RuntimeGate.capacity()).layout_count(roster)
	var count := int(layout.count)
	if not bool(layout.ok):
		ModLoaderLog.warning("entity_spawner: online roster %d exceeds capacity %d; using %d" % [roster, RuntimeGate.capacity(), count], COOPPLUS_MOD_ID, true)
	var data_count := _coopplus_players_data_count()
	if data_count > 0 and count > data_count:
		ModLoaderLog.warning("entity_spawner: online roster %d but only %d players in RunData; not adding empty players" % [count, data_count], COOPPLUS_MOD_ID, true)
		count = data_count
	# BAT-21: vanilla init() reads CoopService.connected_players[i] for every
	# spawned player (entity_spawner.gd:105). Reported here, blocked by AP-012.
	var connected: int = int(CoopService.connected_players.size()) if CoopService != null else 0
	if connected < count:
		ModLoaderLog.warning("entity_spawner: %d players to spawn but %d connected slots" % [count, connected], COOPPLUS_MOD_ID, true)
	ModLoaderLog.info("entity_spawner: online player count %d (capacity %d)" % [count, RuntimeGate.capacity()], COOPPLUS_MOD_ID, true)
	return count


func _coopplus_players_data_count() -> int:
	if typeof(RunData.players_data) != TYPE_ARRAY:
		return 0
	return RunData.players_data.size()


# Grows, in place, the per-player arrays declared at entity_spawner.gd:33,40,41
# to cover player_count players (never below 4, never above the capacity).
# Brotato Online clears these arrays element by element and never resizes
# them, so the grown arrays are kept for the whole battle.
func _coopplus_ensure_player_slots(player_count: int) -> void:
	var slot_count := int(clamp(player_count, CapacityPolicy.VANILLA_MAX_PLAYERS, max(CapacityPolicy.VANILLA_MAX_PLAYERS, RuntimeGate.capacity())))
	while lootworms.size() < slot_count:
		lootworms.push_back(null)
	while queues_to_spawn_structures.size() < slot_count:
		queues_to_spawn_structures.push_back([])
	while queues_to_spawn_pets.size() < slot_count:
		queues_to_spawn_pets.push_back([])
