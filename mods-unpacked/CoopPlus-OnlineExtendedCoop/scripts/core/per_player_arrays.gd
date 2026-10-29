extends Reference
# Grows the game's fixed four-entry per-player arrays (DATA-01/02/04/05/07,
# UI-10) so P5..P8 have an entry before vanilla indexes them. The game runs on
# a release engine template: an out-of-range read silently yields null and a
# call on a null object crashes the process (local simulation EV-0014), so the
# arrays must be long enough before the first access, not repaired afterwards.
# Rules:
#   - only ever grows; never shrinks or replaces entries that exist
#   - target size is max(4, player_count), capped at the session capacity, so
#     1..4 player runs keep exactly the vanilla arrays (R08)
# Field spec: [property_name, kind] or [property_name, KIND_VALUE, default].

const VANILLA_SLOTS := 4

const KIND_DICT := "dict"
const KIND_ARRAY := "array"
const KIND_VALUE := "value"


static func target_size(player_count: int, capacity: int) -> int:
	var cap := int(max(VANILLA_SLOTS, capacity))
	return int(clamp(player_count, VANILLA_SLOTS, cap))


# Returns how many entries were appended.
static func grow(arr: Array, size: int, kind: String, default_value = null) -> int:
	var added := 0
	while arr.size() < size:
		if kind == KIND_DICT:
			arr.append({})
		elif kind == KIND_ARRAY:
			arr.append([])
		else:
			arr.append(default_value)
		added += 1
	return added


# Grows every listed property of obj that is an Array; missing properties and
# non-array values are skipped and reported in "skipped".
static func grow_fields(obj: Object, fields: Array, size: int) -> Dictionary:
	var added := 0
	var skipped := []
	if obj == null:
		return {"added": 0, "skipped": ["<null object>"]}
	for field in fields:
		var name: String = field[0]
		if not name in obj:
			skipped.append(name)
			continue
		var arr = obj.get(name)
		if typeof(arr) != TYPE_ARRAY:
			skipped.append(name)
			continue
		var default_value = field[2] if field.size() > 2 else null
		added += grow(arr, size, field[1], default_value)
	return {"added": added, "skipped": skipped}
