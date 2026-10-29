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
