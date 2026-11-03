extends Reference
# Room DLC rule (D-014): in an online extended room a DLC can be used only
# when every player in the room has it installed. Pure rules: no autoloads,
# no scene tree.
#   owners: {player_index (int): [dlc id, ...]} for the players that reported;
#   a player in range 0..count-1 without an entry has not reported yet and
#   counts as missing every DLC until they do.

# {dlc_id: [player_index, ...]} for each DLC some player lacks (indices sorted).
static func blocked(dlc_ids: Array, owners: Dictionary, count: int) -> Dictionary:
	var out := {}
	for dlc_id in dlc_ids:
		var missing := []
		for i in range(max(0, count)):
			var has := false
			if owners.has(i) and owners[i] is Array:
				has = str(dlc_id) in owners[i]
			if not has:
				missing.append(i)
		if not missing.empty():
			out[str(dlc_id)] = missing
	return out


# "P3、P5" / "P3, P5" for player indices 2 and 4.
static func players_text(indices: Array, separator: String) -> String:
	var names := PoolStringArray()
	for i in indices:
		names.append("P%d" % (int(i) + 1))
	return names.join(separator)


# Ids a list may carry: strings only, at most `limit` of them, no duplicates.
static func clean_ids(value, limit: int = 16) -> Array:
	var out := []
	if not value is Array:
		return out
	for v in value:
		if typeof(v) == TYPE_STRING and v != "" and not v in out:
			out.append(v)
			if out.size() >= limit:
				break
	return out
