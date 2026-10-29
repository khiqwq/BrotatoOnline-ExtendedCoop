extends "res://singletons/run_data.gd"
# Per-player run arrays for P5..P8 (AP-013; R01, R08; DATA-01, DATA-02,
# DATA-04, DATA-05, DATA-07, F01). RunData, TempStats, LinkedStats and Utils keep
# per-player caches as four-entry arrays (run_data.gd:148-164, 193;
# temp_stats.gd:5-6; linked_stats.gd:4; utils.gd:60, 65) and several reset
# paths rebuild them with four entries (run_data.gd:268-269 in
# _reset_per_wave_properties, :556 in reset, :606 in reset_run_caches). On the
# release engine an index past the end reads null, and the first method call on
# it crashes the game: adding P5's character did exactly that (EV-0014).
# After every call that sets the player count or rebuilds those arrays, they are
# grown to max(4, player count); only while the gate is extended, so 1..4 player
# runs keep the vanilla arrays (R08). Utils' own resets are covered by
# utils_ext.gd. No callback here calls its parent version (ADR-001 rule 1).
# Left for AP-016: run states loaded from a save rebuild locked_shop_items and
# tracked_item_effects with four entries in the ProgressDataLoader classes.
#
# get_player_count() can be limited for the current frame only
# (coopplus_limit_player_count_this_frame). The co-op end-of-run screen uses it
# so its vanilla _ready, which indexes four-entry onready arrays by player,
# only sets up P1..P4; coop_end_run_ext.gd sets up P5..P8 right after and
# lifts the limit. The limit expires by itself at the next frame.
#
# add_gold/add_xp can be captured instead of applied
# (coopplus_begin_grant_capture .. coopplus_end_grant_capture): main_ext.gd
# runs the game's own gold pickup with the count limited to 4 and shares the
# material and experience it hands out over all 5..8 players.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")

var _coopplus_count_limit := 0
var _coopplus_count_limit_frame := -1
# [[kind, value, player_index], ...] while capturing, else null.
var _coopplus_grants = null

const COOPPLUS_RUN_DATA_FIELDS := [
	["remove_speed_effect_cache", PerPlayerArrays.KIND_DICT],
	["items_nb_cache", PerPlayerArrays.KIND_DICT],
	["different_items_nb_cache", PerPlayerArrays.KIND_DICT],
	["duplicate_items_cache", PerPlayerArrays.KIND_VALUE, null],
	["max_consumable_stats_gained_this_wave", PerPlayerArrays.KIND_ARRAY],
	["_are_player_stats_dirty", PerPlayerArrays.KIND_VALUE, false],
	["current_charmed_enemies", PerPlayerArrays.KIND_VALUE, 0],
	["steps_taken_this_wave", PerPlayerArrays.KIND_VALUE, 0],
	["locked_shop_items", PerPlayerArrays.KIND_ARRAY],
]
const COOPPLUS_TEMP_STATS_FIELDS := [
	["player_stats", PerPlayerArrays.KIND_DICT],
	["are_player_stats_dirty", PerPlayerArrays.KIND_VALUE, false],
]
const COOPPLUS_LINKED_STATS_FIELDS := [
	["update_for_player_every_half_sec", PerPlayerArrays.KIND_VALUE, false],
]
const COOPPLUS_UTILS_FIELDS := [
	["last_elt_selected", PerPlayerArrays.KIND_VALUE, null],
	["_stat_caches", PerPlayerArrays.KIND_DICT],
]


# Parent: run_data.gd:273.
func get_player_count() -> int:
	var count := .get_player_count()
	if _coopplus_count_limit > 0 and Engine.get_idle_frames() == _coopplus_count_limit_frame:
		return int(min(count, _coopplus_count_limit))
	return count


func coopplus_limit_player_count_this_frame(limit: int) -> void:
	_coopplus_count_limit = limit
	_coopplus_count_limit_frame = Engine.get_idle_frames()


func coopplus_clear_player_count_limit() -> void:
	_coopplus_count_limit = 0
	_coopplus_count_limit_frame = -1


# Parent: run_data.gd:879.
func add_gold(value: int, player_index: int) -> void:
	if _coopplus_grants != null:
		_coopplus_grants.append(["gold", value, player_index])
		return
	.add_gold(value, player_index)


# Parent: run_data.gd:818.
func add_xp(value: int, player_index: int) -> void:
	if _coopplus_grants != null:
		_coopplus_grants.append(["xp", value, player_index])
		return
	.add_xp(value, player_index)


func coopplus_begin_grant_capture() -> void:
	_coopplus_grants = []


# Returns the captured grants in call order and stops capturing.
func coopplus_end_grant_capture() -> Array:
	var grants: Array = _coopplus_grants if _coopplus_grants != null else []
	_coopplus_grants = null
	return grants


# Applies one captured grant as the game would have.
func coopplus_apply_grant(grant: Array) -> void:
	if grant[0] == "gold":
		.add_gold(int(grant[1]), int(grant[2]))
	else:
		.add_xp(int(grant[1]), int(grant[2]))


# Parent: run_data.gd:282.
func set_player_count(count: int, reset:= false) -> void:
	.set_player_count(count, reset)
	coopplus_fit_per_player_arrays()


# Parent: run_data.gd:263 (rebuilds current_charmed_enemies, steps_taken_this_wave).
func _reset_per_wave_properties() -> void:
	._reset_per_wave_properties()
	coopplus_fit_per_player_arrays()


# Parent: run_data.gd:480 (rebuilds locked_shop_items; calls reset_run_caches).
func reset(restart: bool = false) -> void:
	.reset(restart)
	coopplus_fit_per_player_arrays()


# Parent: run_data.gd:599 (rebuilds duplicate_items_cache).
func reset_run_caches() -> void:
	.reset_run_caches()
	coopplus_fit_per_player_arrays()


# Also called by utils_ext.gd after Utils rebuilds its arrays.
# Parent: run_data.gd:1785 (Continue). It ends with LinkedStats.reset(),
# which loops every player of the resumed state over LinkedStats/TempStats
# arrays that are still four long right after launch, so they grow to the
# state's player count first.
func resume_from_state(state: Dictionary) -> void:
	var players = state.get("players_data")
	if RuntimeGate.is_extended() and players is Array and players.size() > PerPlayerArrays.VANILLA_SLOTS:
		_coopplus_grow_per_player_arrays(players.size())
	.resume_from_state(state)
	coopplus_fit_per_player_arrays()


func coopplus_fit_per_player_arrays() -> void:
	if not RuntimeGate.is_extended():
		return
	_coopplus_grow_per_player_arrays(players_data.size())


func _coopplus_grow_per_player_arrays(player_count: int) -> void:
	var size := PerPlayerArrays.target_size(player_count, RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var _r = PerPlayerArrays.grow_fields(self, COOPPLUS_RUN_DATA_FIELDS, size)
	while tracked_item_effects.size() < size:
		tracked_item_effects.append(init_tracked_effects())
	# Autoloads after RunData in the project order; all exist once the game runs.
	for pair in [[TempStats, COOPPLUS_TEMP_STATS_FIELDS], [LinkedStats, COOPPLUS_LINKED_STATS_FIELDS], [Utils, COOPPLUS_UTILS_FIELDS]]:
		if is_instance_valid(pair[0]):
			_r = PerPlayerArrays.grow_fields(pair[0], pair[1], size)
