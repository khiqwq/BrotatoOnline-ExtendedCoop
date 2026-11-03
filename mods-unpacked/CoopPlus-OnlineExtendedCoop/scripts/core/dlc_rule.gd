extends Reference
# DLC id lists exchanged between the machines of a room (D-014,
# scripts/bo/dlc_roster.gd). Pure rules: no autoloads, no scene tree.

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
