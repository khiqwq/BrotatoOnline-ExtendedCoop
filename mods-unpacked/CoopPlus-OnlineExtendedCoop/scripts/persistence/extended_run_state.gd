extends Reference
# Rules for keeping a 5..8 player run out of the vanilla run save (AP-016;
# R12, R13; SAVE-01, SAVE-02, SAVE-04, SAVE-15, SAVE-16; F13, F14).
# Vanilla's v3 loader rebuilds shop_items and locked_shop_items with exactly
# four entries when it serializes and when it deserializes a run
# (progress_data_loader_v3.gd:603-613, :390-406). Writing a fifth player's
# shop entries indexes past them, which on the release engine is a method
# call on null; reading drops them. Such a state therefore never reaches the
# vanilla run file. The ProgressData extension serializes it itself (the
# vanilla serializer for the first four players' shop entries and everything
# else, plus the extra players' entries in the same shape), commits it to the
# isolated checkpoint store, and gives vanilla a placeholder: a run state
# without a run (has_run_state false, so vanilla offers nothing to continue
# and never deserializes players) that carries a marker naming the
# checkpoint.
# Pure rules: no autoloads, no file access, no scene tree.

const VANILLA_SLOTS := 4
const MARKER_KEY := "coopplus_extended_run"
const PAYLOAD_SCHEMA := 1
# Run-state fields that the vanilla v3 serializer sizes to four players.
const FOUR_SLOT_FIELDS := ["shop_items", "locked_shop_items"]
const RUN_ID_PREFIX := "profile_"


# Players in a run state; 0 for a state without a run.
static func player_count(state) -> int:
	if not state is Dictionary or not bool(state.get("has_run_state", false)):
		return 0
	var players = state.get("players_data")
	return players.size() if players is Array else 0


static func is_extended(state) -> bool:
	return player_count(state) > VANILLA_SLOTS


# One run in progress per save profile, as in vanilla (SAVE-16).
static func run_id_for_profile(profile_id: int) -> String:
	return RUN_ID_PREFIX + str(int(max(0, profile_id)))


static func make_marker(run_id: String, checkpoint_id: String, players: int, reason: String) -> Dictionary:
	return {"run_id": run_id, "checkpoint_id": checkpoint_id, "players": players, "reason": reason}


static func placeholder(marker: Dictionary) -> Dictionary:
	return {"has_run_state": false, MARKER_KEY: marker.duplicate(true)}


# The marker a placeholder carries, or {} for any other state.
static func marker_of(state) -> Dictionary:
	if state is Dictionary and not bool(state.get("has_run_state", false)):
		var marker = state.get(MARKER_KEY)
		if marker is Dictionary:
			return marker
	return {}


# {head, extra}: head is a shallow copy of state whose FOUR_SLOT_FIELDS keep
# their first four entries; extra[field] holds the rest, player 5 first.
# Fields with four entries or fewer are left alone and get no extra entry.
static func split_four_slot_fields(state: Dictionary) -> Dictionary:
	var head := state.duplicate()
	var extra := {}
	for field in FOUR_SLOT_FIELDS:
		var values = state.get(field)
		if not values is Array or values.size() <= VANILLA_SLOTS:
			continue
		var kept := []
		var rest := []
		for i in values.size():
			if i < VANILLA_SLOTS:
				kept.append(values[i])
			else:
				rest.append(values[i])
		head[field] = kept
		extra[field] = rest
	return {"head": head, "extra": extra}


# Vanilla stores a shop entry as [item.serialize(), value]
# (progress_data_loader_v3.gd:603-613); the extra players' entries get the
# same shape. Entries of any other shape are counted, not written.
# Returns {players: [[serialized entries] per player], skipped}.
static func serialize_shop_entries(players: Array) -> Dictionary:
	var out := []
	var skipped := 0
	for entries in players:
		var serialized := []
		if entries is Array:
			for entry in entries:
				if entry is Array and entry.size() >= 2 and entry[0] is Object and entry[0].has_method("serialize"):
					serialized.append([entry[0].serialize(), entry[1]])
				else:
					skipped += 1
		else:
			skipped += 1
		out.append(serialized)
	return {"players": out, "skipped": skipped}


# serialized: the vanilla serializer's output for the head state. Appends
# the extra players' serialized entries after the first four players.
static func merge_serialized(serialized: Dictionary, extra_serialized: Dictionary) -> Dictionary:
	var out := serialized.duplicate()
	for field in extra_serialized:
		var merged := []
		var base = out.get(field)
		if base is Array:
			merged = base.duplicate()
		while merged.size() < VANILLA_SLOTS:
			merged.append([])
		for entries in extra_serialized[field]:
			merged.append(entries)
		out[field] = merged
	return out


# Checkpoint state payload. versions: game, Brotato Online and extension
# versions at write time, for the schema check when the run is resumed.
static func payload(serialized_run_state: Dictionary, players: int, versions: Dictionary) -> Dictionary:
	return {
		"schema": PAYLOAD_SCHEMA,
		"players": players,
		"versions": versions.duplicate(),
		"run_state": serialized_run_state,
	}


# Before a checkpoint is resumed (R13: unsupported checkpoints are refused
# explicitly, never handed to the vanilla loader). current_versions:
# {"game_save": ...} of this game. Returns {ok, reason, detail}.
const REFUSE_NOT_A_PAYLOAD := "not_a_payload"
const REFUSE_SCHEMA := "unsupported_schema"
const REFUSE_PLAYER_COUNT := "bad_player_count"
const REFUSE_STATE := "state_mismatch"
const REFUSE_SHOP := "shop_mismatch"
const REFUSE_GAME_VERSION := "game_version_changed"
const MAX_PLAYERS := 8


static func validate_payload(data, current_versions: Dictionary) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return _refusal(REFUSE_NOT_A_PAYLOAD, typeof(data))
	var schema = data.get("schema")
	if not (typeof(schema) == TYPE_INT or typeof(schema) == TYPE_REAL) or int(schema) != PAYLOAD_SCHEMA:
		return _refusal(REFUSE_SCHEMA, schema)
	var players = data.get("players")
	if not (typeof(players) == TYPE_INT or typeof(players) == TYPE_REAL) or int(players) <= VANILLA_SLOTS or int(players) > MAX_PLAYERS:
		return _refusal(REFUSE_PLAYER_COUNT, players)
	var count := int(players)
	var state = data.get("run_state")
	if typeof(state) != TYPE_DICTIONARY or not bool(state.get("has_run_state", false)):
		return _refusal(REFUSE_STATE, "no run state")
	var players_data = state.get("players_data")
	if not players_data is Array or players_data.size() != count:
		return _refusal(REFUSE_STATE, "players_data %s" % (players_data.size() if players_data is Array else -1))
	# Brotato Online pads these lists back to their old length when a player is
	# removed (player_removal_manager.gd:158-170): longer is fine when the tail
	# is empty.
	for field in FOUR_SLOT_FIELDS:
		var values = state.get(field)
		if values == null:
			continue
		if not values is Array or values.size() < count or not _empty_tail(values, count):
			return _refusal(REFUSE_SHOP, "%s %s" % [field, values.size() if values is Array else -1])
	var versions = data.get("versions")
	var saved_game := str(versions.get("game_save", "")) if typeof(versions) == TYPE_DICTIONARY else ""
	var current_game := str(current_versions.get("game_save", ""))
	if saved_game == "" or saved_game != current_game:
		return _refusal(REFUSE_GAME_VERSION, "%s -> %s" % [saved_game, current_game])
	return {"ok": true, "reason": "", "detail": ""}


static func _empty_tail(values: Array, from: int) -> bool:
	for i in range(from, values.size()):
		if values[i] is Array and not values[i].empty():
			return false
	return true


# Sequence number of a checkpoint id ("%08d-<hash>", checkpoint_store.gd); -1
# when unreadable.
static func checkpoint_sequence(checkpoint_id) -> int:
	var text := str(checkpoint_id)
	var dash := text.find("-")
	if dash <= 0 or not text.substr(0, dash).is_valid_integer():
		return -1
	return int(text.substr(0, dash))


# State for the vanilla v3 deserializer holding only the extra players' shop
# lists (at most four, as many as the deserializer builds); the fields its
# loops read are present and empty (progress_data_loader_v3.gd:363-426).
static func extras_state(extra: Dictionary) -> Dictionary:
	var state := {"has_run_state": true, "players_data": [], "current_background": "", "challenges_completed_this_run": []}
	for field in FOUR_SLOT_FIELDS:
		state[field] = extra.get(field, []).duplicate() if extra.get(field) is Array else []
	return state


static func _refusal(reason: String, detail) -> Dictionary:
	return {"ok": false, "reason": reason, "detail": str(detail)}
