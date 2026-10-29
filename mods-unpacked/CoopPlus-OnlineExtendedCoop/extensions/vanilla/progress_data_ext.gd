extends "res://singletons/progress_data.gd"
# Keeps 5..8 player runs out of the vanilla run save (AP-016; R12, R13;
# SAVE-01, SAVE-02, SAVE-04, SAVE-14, SAVE-16; F13, F14). Every in-run save
# reaches save(): the shop's GO (save_run_state), Brotato Online's retry
# guard and player removal, and RunData's retry-wave restore
# (reset_and_save_run_state). With more than four players the vanilla v3
# serializer indexes past its four shop entries (a crash on the release
# engine) and its reader would drop the shop entries of players 5+, so:
#   - the full state goes to the isolated checkpoint store under
#     <SAVE_DIR>/coopplus_runs/profile_<n> (scripts/persistence/checkpoint_store.gd:
#     staged write, read-back check, commit record, previous copy kept),
#     serialized by the vanilla serializer for everything it handles plus the
#     extra players' shop entries in the same shape
#     (scripts/persistence/extended_run_state.gd);
#   - vanilla then saves a placeholder in its place (no run to continue, a
#     marker naming the checkpoint), so progress, settings and the run file
#     stay readable by vanilla; the in-memory state is restored right after.
#     Brotato Online's identity sidecar sees the placeholder and writes
#     nothing for the run.
# Runs with 1..4 players, and saves while no such run is held, go to the
# parent unchanged (R08). The profile's checkpoint is removed once the
# profile gets another run state: a reset (run over, new run, restart) or a
# 1..4 player run saved at the shop, the same one-run-per-profile rule as
# vanilla.
# Continuing (load_game_file): when the vanilla run save holds the
# placeholder, the checkpoint it names is read, checked (schema, player count,
# game save version; ExtendedRunState.validate_payload) and deserialized with
# the vanilla v3 deserializer, the extra players' shop entries through a
# second call on a state holding only them; the result becomes
# saved_run_state, so the title screen offers Continue as for any run. A
# checkpoint that fails a check is refused with a logged reason and the
# placeholder stays (no Continue); the checkpoint is kept on disk.
# Brotato Online's player identities go into the same checkpoint
# (player_identity_manager_ext.gd reads them back).
# See docs/adr/ADR-004-extended-run-checkpoint.md.

const CheckpointStore = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/persistence/checkpoint_store.gd")
const ExtendedRunState = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/persistence/extended_run_state.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_UPSTREAM_ID := "six666-BrotatoOnline"
const COOPPLUS_RUNS_DIR := "coopplus_runs"
const COOPPLUS_IDENTITY_MANAGER_PATH := "ModLoader/six666-BrotatoOnline/BrotatoOnlinePlayerIdentityManager"

# Marker of the last extended-run checkpoint write (diagnostics and probes):
# {run_id, checkpoint_id, players, reason}; checkpoint_id is "" on failure.
var coopplus_last_checkpoint := {}
# Checkpoint the current saved_run_state was restored from:
# {run_id, checkpoint_id, identities}; {} otherwise.
var coopplus_loaded_checkpoint := {}
# That restored state itself: saves of it before anyone hosts (title screen,
# settings) keep the loaded identities instead of writing none.
var _coopplus_loaded_state = null


func save() -> void:
	if not ExtendedRunState.is_extended(saved_run_state):
		.save()
		if bool(saved_run_state.get("has_run_state", false)):
			_coopplus_discard_checkpoint("vanilla_run_saved")
		return
	# Vanilla writes nothing in these cases (progress_data.gd save()); neither
	# does the checkpoint. The parent returns before it reads the run state.
	if DebugService.disable_saving or load_status == LoadStatus.CORRUPTED_ALL_SAVES_NO_STEAM or load_status == LoadStatus.CORRUPTED_ALL_SAVES_NO_EPIC:
		.save()
		return
	var full: Dictionary = saved_run_state
	saved_run_state = ExtendedRunState.placeholder(_coopplus_write_checkpoint(full))
	.save()
	saved_run_state = full


# Parent: progress_data.gd:702 (startup, profile switch, fallback; the
# fallback calls it again, after which saved_run_state holds a run and
# nothing is restored twice).
func load_game_file(try_fallback := true) -> void:
	.load_game_file(try_fallback)
	_coopplus_restore_extended_run()


func _coopplus_restore_extended_run() -> void:
	var marker := ExtendedRunState.marker_of(saved_run_state)
	if marker.empty():
		return
	var run_id := str(marker.get("run_id", ""))
	var players := int(marker.get("players", 0))
	if str(marker.get("checkpoint_id", "")) == "":
		_coopplus_refuse_resume(run_id, "checkpoint_not_written")
		return
	if RuntimeGate.verified_capacity() < players:
		_coopplus_refuse_resume(run_id, "extended_mode_off")
		return
	var read: Dictionary = CheckpointStore.new(_coopplus_runs_dir()).read_latest(run_id)
	if not bool(read.get("ok", false)):
		_coopplus_refuse_resume(run_id, str(read.get("reason", "read_failed")))
		return
	if ExtendedRunState.checkpoint_sequence(read.checkpoint_id) < ExtendedRunState.checkpoint_sequence(marker.checkpoint_id):
		_coopplus_refuse_resume(run_id, "checkpoint_older_than_save")
		return
	var check := ExtendedRunState.validate_payload(read.state, {"game_save": str(VERSION)})
	if not bool(check.ok):
		_coopplus_refuse_resume(run_id, "%s (%s)" % [check.reason, check.detail])
		return
	var restored := _coopplus_deserialize(read.state.run_state)
	if not bool(restored.get("has_run_state", false)) or restored.get("players_data", []).size() != int(read.state.players):
		_coopplus_refuse_resume(run_id, "deserialize_failed")
		return
	saved_run_state = restored
	_coopplus_loaded_state = saved_run_state
	var identities = read.get("identities", {})
	coopplus_loaded_checkpoint = {"run_id": run_id, "checkpoint_id": read.checkpoint_id, "identities": identities if typeof(identities) == TYPE_DICTIONARY else {}}
	ModLoaderLog.info("extended run: %d players restored from checkpoint %s/%s (%s)" % [players, run_id, read.checkpoint_id, read.get("source", "")], COOPPLUS_MOD_ID)


func _coopplus_refuse_resume(run_id: String, reason: String) -> void:
	coopplus_loaded_checkpoint = {}
	_coopplus_loaded_state = null
	ModLoaderLog.warning("extended run %s not offered for Continue: %s (checkpoint kept)" % [run_id, reason], COOPPLUS_MOD_ID)


# The serialized state's first four players through the vanilla deserializer;
# the extra players' shop entries through a second call on a state holding
# only them (the deserializer builds four lists), appended in order.
func _coopplus_deserialize(serialized: Dictionary) -> Dictionary:
	var split := ExtendedRunState.split_four_slot_fields(serialized)
	var loader = ProgressDataLoaderV3.new(SAVE_DIR, current_profile_id)
	var head: Dictionary = loader.deserialize_run_state(split.head)
	if split.extra.empty() or not bool(head.get("has_run_state", false)):
		return head
	var extras: Dictionary = loader.deserialize_run_state(ExtendedRunState.extras_state(split.extra))
	for field in split.extra:
		var lists: Array = head.get(field, []).duplicate()
		var extra_lists: Array = extras.get(field, [])
		for i in split.extra[field].size():
			lists.append(extra_lists[i] if i < extra_lists.size() else [])
		head[field] = lists
	return head


func reset_and_save_run_state(run_state: Dictionary) -> void:
	.reset_and_save_run_state(run_state)
	if not ExtendedRunState.is_extended(run_state):
		_coopplus_discard_checkpoint("run_state_reset")


# Used only for the bug reporter's save copy (get_current_save_object); it
# serializes the live RunData state, which with 5..8 players crashes the
# same way.
func _get_current_run_state() -> Dictionary:
	var state := ._get_current_run_state()
	# At the title screen the live state has no players but the restored
	# saved_run_state's shop lists are already longer than four.
	if ExtendedRunState.is_extended(state) or ExtendedRunState.is_extended(saved_run_state):
		var run_id := ExtendedRunState.run_id_for_profile(current_profile_id)
		return ExtendedRunState.placeholder(ExtendedRunState.make_marker(run_id, "", ExtendedRunState.player_count(state), "live_state_not_serialized"))
	return state


func _coopplus_runs_dir() -> String:
	return SAVE_DIR.plus_file(COOPPLUS_RUNS_DIR)


# Returns the marker for the placeholder.
func _coopplus_write_checkpoint(full: Dictionary) -> Dictionary:
	var run_id := ExtendedRunState.run_id_for_profile(current_profile_id)
	var players := ExtendedRunState.player_count(full)
	var serialized := _coopplus_serialize(full)
	if serialized.skipped > 0:
		ModLoaderLog.warning("extended run: %d shop entries of players 5+ not saved (unexpected shape)" % serialized.skipped, COOPPLUS_MOD_ID)
	var store = CheckpointStore.new(_coopplus_runs_dir())
	var result: Dictionary = store.write_checkpoint(run_id, ExtendedRunState.payload(serialized.state, players, _coopplus_versions()), _coopplus_identities(full))
	var checkpoint_id: String = str(result.get("checkpoint_id", "")) if bool(result.get("ok", false)) else ""
	var marker := ExtendedRunState.make_marker(run_id, checkpoint_id, players, str(result.get("reason", "")))
	coopplus_last_checkpoint = marker.duplicate()
	if checkpoint_id != "":
		ModLoaderLog.info("extended run: %d players saved to checkpoint %s/%s" % [players, run_id, checkpoint_id], COOPPLUS_MOD_ID)
	else:
		ModLoaderLog.error("extended run: checkpoint not written (%s); the vanilla save keeps no run" % marker.reason, COOPPLUS_MOD_ID)
	return marker


# {state, skipped}: vanilla's serializer for the first four players' shop
# entries and every other field, the extra players' entries appended.
func _coopplus_serialize(full: Dictionary) -> Dictionary:
	var split := ExtendedRunState.split_four_slot_fields(full)
	var loader = ProgressDataLoaderV3.new(SAVE_DIR, current_profile_id)
	var serialized: Dictionary = loader.serialize_run_state(split.head)
	var extra := {}
	var skipped := 0
	for field in split.extra:
		var entries := ExtendedRunState.serialize_shop_entries(split.extra[field])
		extra[field] = entries.players
		skipped += int(entries.skipped)
	return {"state": ExtendedRunState.merge_serialized(serialized, extra), "skipped": skipped}


func _coopplus_discard_checkpoint(why: String) -> void:
	if DebugService.disable_saving:
		return
	var store = CheckpointStore.new(_coopplus_runs_dir())
	var run_id := ExtendedRunState.run_id_for_profile(current_profile_id)
	var result: Dictionary = store.delete_run(run_id)
	if bool(result.get("deleted", false)):
		ModLoaderLog.info("extended run: checkpoint %s removed (%s)" % [run_id, why], COOPPLUS_MOD_ID)
	elif not bool(result.get("ok", false)):
		ModLoaderLog.error("extended run: checkpoint %s not removed (%s): %s" % [run_id, why, result.get("reason", "")], COOPPLUS_MOD_ID)


# {"bo": Brotato Online's identity metadata for this state}
# (player_identity_manager.gd _metadata_for_state, the data it would bind to
# the vanilla run save). It is empty while nobody hosts or a resume is
# pending; a save of the untouched restored state then keeps the identities it
# was loaded with.
func _coopplus_identities(full: Dictionary) -> Dictionary:
	var bo := {}
	var manager = get_tree().root.get_node_or_null(COOPPLUS_IDENTITY_MANAGER_PATH) if is_inside_tree() else null
	if manager != null and manager.has_method("_metadata_for_state"):
		var metadata = manager._metadata_for_state(full)
		if typeof(metadata) == TYPE_DICTIONARY:
			bo = metadata
	if bo.empty() and _coopplus_loaded_state != null and full == _coopplus_loaded_state:
		bo = coopplus_loaded_identities()
	return {"bo": bo} if not bo.empty() else {}


# Identities of the restored run for Brotato Online's resume (player_identity_
# manager_ext.gd); {} when saved_run_state is not the restored 5..8 player run.
func coopplus_loaded_identities() -> Dictionary:
	if _coopplus_loaded_state == null or saved_run_state != _coopplus_loaded_state:
		return {}
	var identities = coopplus_loaded_checkpoint.get("identities", {})
	var loaded = identities.get("bo", {}) if typeof(identities) == TYPE_DICTIONARY else {}
	return loaded if typeof(loaded) == TYPE_DICTIONARY else {}


func _coopplus_versions() -> Dictionary:
	var versions := {"game_save": str(VERSION)}
	for mod_id in [COOPPLUS_MOD_ID, COOPPLUS_UPSTREAM_ID]:
		var mod = ModLoaderStore.mod_data.get(mod_id)
		if mod != null and mod.manifest != null:
			versions[mod_id] = str(mod.manifest.version_number)
	return versions
