extends Reference
# Room types (D-008; R01, R08). The host picks one when it opens a room and it
# stays fixed for that room:
#   standard  capacity 4; plain Brotato Online players may join; the extension
#             stays dormant (every override runs its parent, R08)
#   extended  capacity 5..8; every member needs a matching extension
#             (scripts/network/capability.gd decides from the capacity)
# The choice is kept per PC (PREFS_PATH). The host advertises the room in its
# lobby / LAN discovery data (to_metadata); a joining extension reads it
# (from_metadata) and takes the room's capacity. A host without the extension
# advertises nothing, which reads as a standard room.
# Pure rules: no autoloads, no scene tree; file access only in the load/save
# helpers, which take the path as an argument for the tests.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

const TYPE_STANDARD := "standard"
const TYPE_EXTENDED := "extended"
const TYPES := [TYPE_STANDARD, TYPE_EXTENDED]
const DEFAULT_TYPE := TYPE_EXTENDED
const DEFAULT_CAPACITY := 8
const MIN_EXTENDED := 5

const PREFS_PATH := "user://coopplus_settings.cfg"
const PREFS_SECTION := "room"

# Lobby data values are strings on Steam; LAN discovery carries them as-is.
const META_TYPE := "coopplus_room"
const META_CAPACITY := "coopplus_capacity"
const META_CAPABILITY := "coopplus_capability"


# {type, capacity} with capacity 4 for standard rooms and 5..8 for extended.
static func normalize(room_type, room_capacity) -> Dictionary:
	var t := str(room_type) if str(room_type) in TYPES else DEFAULT_TYPE
	if t == TYPE_STANDARD:
		return {"type": t, "capacity": CapacityPolicy.VANILLA_MAX_PLAYERS}
	var cap := _to_int(room_capacity, DEFAULT_CAPACITY)
	return {"type": t, "capacity": int(clamp(cap, MIN_EXTENDED, CapacityPolicy.MAX_SUPPORTED_PLAYERS))}


# The room a host would open now: its preference, limited to what this
# machine supports (gate_capacity 4 when extended mode is off: always a
# standard room).
static func host_room(preference: Dictionary, gate_capacity: int) -> Dictionary:
	var room := normalize(preference.get("type"), preference.get("capacity"))
	if room.type == TYPE_EXTENDED and gate_capacity < MIN_EXTENDED:
		return normalize(TYPE_STANDARD, 0)
	if room.type == TYPE_EXTENDED and room.capacity > gate_capacity:
		room.capacity = gate_capacity
	return room


# Next preference in the order standard, extended 5, 6, 7, 8 (wrapping); the
# room-type button steps through it.
static func next_preference(preference: Dictionary) -> Dictionary:
	var room := normalize(preference.get("type"), preference.get("capacity"))
	if room.type == TYPE_STANDARD:
		return normalize(TYPE_EXTENDED, MIN_EXTENDED)
	if room.capacity >= CapacityPolicy.MAX_SUPPORTED_PLAYERS:
		return normalize(TYPE_STANDARD, 0)
	return normalize(TYPE_EXTENDED, room.capacity + 1)


static func to_metadata(room: Dictionary, capability_version: int) -> Dictionary:
	var r := normalize(room.get("type"), room.get("capacity"))
	return {META_TYPE: r.type, META_CAPACITY: str(r.capacity), META_CAPABILITY: str(capability_version)}


# Room advertised by a host. Missing or unreadable data is a standard room:
# a host without the extension, or one that opened a standard room.
static func from_metadata(meta) -> Dictionary:
	if typeof(meta) != TYPE_DICTIONARY or str(meta.get(META_TYPE, "")) != TYPE_EXTENDED:
		var standard := normalize(TYPE_STANDARD, 0)
		standard["capability_version"] = 0
		return standard
	var room := normalize(TYPE_EXTENDED, meta.get(META_CAPACITY))
	room["capability_version"] = _to_int(meta.get(META_CAPABILITY), 0)
	return room


# Can this machine join the advertised room, and with which capacity?
# {ok, capacity, reason}: an extended room needs extended mode here
# (gate_capacity >= the room's) and the same capability version.
static func join_room(meta, gate_capacity: int, capability_version: int) -> Dictionary:
	var room := from_metadata(meta)
	if room.type == TYPE_STANDARD:
		return {"ok": true, "capacity": room.capacity, "reason": ""}
	if gate_capacity < room.capacity:
		return {"ok": false, "capacity": CapacityPolicy.VANILLA_MAX_PLAYERS, "reason": "extended_room_unsupported"}
	if room.capability_version != capability_version:
		return {"ok": false, "capacity": CapacityPolicy.VANILLA_MAX_PLAYERS, "reason": "capability_mismatch"}
	return {"ok": true, "capacity": room.capacity, "reason": ""}


static func load_preference(path: String = PREFS_PATH) -> Dictionary:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return normalize(DEFAULT_TYPE, DEFAULT_CAPACITY)
	return normalize(config.get_value(PREFS_SECTION, "type", DEFAULT_TYPE), config.get_value(PREFS_SECTION, "capacity", DEFAULT_CAPACITY))


static func save_preference(preference: Dictionary, path: String = PREFS_PATH) -> void:
	var room := normalize(preference.get("type"), preference.get("capacity"))
	var config := ConfigFile.new()
	var _r = config.load(path)
	config.set_value(PREFS_SECTION, "type", room.type)
	config.set_value(PREFS_SECTION, "capacity", room.capacity)
	var _s = config.save(path)


static func _to_int(value, fallback: int) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_REAL:
		return int(value)
	if typeof(value) == TYPE_STRING and value.is_valid_integer():
		return int(value)
	return fallback
