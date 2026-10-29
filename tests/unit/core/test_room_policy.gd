extends "res://tests/runner/test_case.gd"

const RoomPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/room_policy.gd")

const TMP_PATH := "user://test_room_policy.cfg"


func after_each() -> void:
	var dir := Directory.new()
	if dir.file_exists(TMP_PATH):
		var _r = dir.remove(TMP_PATH)


func test_normalize_standard_is_four() -> void:
	var room = RoomPolicy.normalize(RoomPolicy.TYPE_STANDARD, 8)
	assert_eq(room.type, RoomPolicy.TYPE_STANDARD)
	assert_eq(room.capacity, 4)


func test_normalize_extended_clamps_to_five_through_eight() -> void:
	var cases := {3: 5, 5: 5, 7: 7, 8: 8, 12: 8, "6": 6, 6.0: 6}
	for given in cases:
		var room = RoomPolicy.normalize(RoomPolicy.TYPE_EXTENDED, given)
		assert_eq(room.capacity, cases[given], str(given))
	assert_eq(RoomPolicy.normalize(RoomPolicy.TYPE_EXTENDED, "x").capacity, RoomPolicy.DEFAULT_CAPACITY, "unreadable capacity")
	assert_eq(RoomPolicy.normalize("other", 6).type, RoomPolicy.DEFAULT_TYPE, "unknown type")


func test_host_room_follows_gate() -> void:
	var pref := {"type": RoomPolicy.TYPE_EXTENDED, "capacity": 8}
	assert_eq(var2str(RoomPolicy.host_room(pref, 8)), var2str({"type": "extended", "capacity": 8}))
	assert_eq(RoomPolicy.host_room(pref, 4).type, RoomPolicy.TYPE_STANDARD, "extended mode off here: standard room")
	assert_eq(RoomPolicy.host_room(pref, 6).capacity, 6, "never above what this machine supports")
	assert_eq(RoomPolicy.host_room({"type": "standard"}, 8).capacity, 4)


func test_next_preference_cycles() -> void:
	var seen := []
	var pref := {"type": RoomPolicy.TYPE_STANDARD, "capacity": 4}
	for _i in 6:
		pref = RoomPolicy.next_preference(pref)
		seen.append("%s%d" % [pref.type.substr(0, 1), pref.capacity])
	assert_eq(seen, ["e5", "e6", "e7", "e8", "s4", "e5"])


func test_metadata_round_trip() -> void:
	var meta = RoomPolicy.to_metadata({"type": "extended", "capacity": 7}, 3)
	assert_eq(meta[RoomPolicy.META_TYPE], "extended")
	assert_eq(meta[RoomPolicy.META_CAPACITY], "7", "lobby data values are strings")
	var room = RoomPolicy.from_metadata(meta)
	assert_eq(room.type, "extended")
	assert_eq(room.capacity, 7)
	assert_eq(room.capability_version, 3)


func test_missing_metadata_is_a_standard_room() -> void:
	for meta in [{}, null, {"coopplus_room": "standard", "coopplus_capacity": "8"}, {"member_limit": 4}]:
		var room = RoomPolicy.from_metadata(meta)
		assert_eq(room.type, RoomPolicy.TYPE_STANDARD, var2str(meta))
		assert_eq(room.capacity, 4, var2str(meta))


func test_join_room_rules() -> void:
	var extended = RoomPolicy.to_metadata({"type": "extended", "capacity": 8}, 1)
	var ok = RoomPolicy.join_room(extended, 8, 1)
	assert_true(ok.ok)
	assert_eq(ok.capacity, 8)
	var unsupported = RoomPolicy.join_room(extended, 4, 1)
	assert_false(unsupported.ok)
	assert_eq(unsupported.reason, "extended_room_unsupported")
	var mismatch = RoomPolicy.join_room(extended, 8, 2)
	assert_false(mismatch.ok)
	assert_eq(mismatch.reason, "capability_mismatch")
	var standard = RoomPolicy.join_room({}, 8, 1)
	assert_true(standard.ok, "a plain Brotato Online host: standard room")
	assert_eq(standard.capacity, 4)


func test_preference_round_trip_through_file() -> void:
	assert_eq(RoomPolicy.load_preference(TMP_PATH).type, RoomPolicy.DEFAULT_TYPE, "no file: default")
	RoomPolicy.save_preference({"type": "extended", "capacity": 6}, TMP_PATH)
	var pref = RoomPolicy.load_preference(TMP_PATH)
	assert_eq(pref.type, "extended")
	assert_eq(pref.capacity, 6)
	RoomPolicy.save_preference({"type": "standard", "capacity": 8}, TMP_PATH)
	assert_eq(RoomPolicy.load_preference(TMP_PATH).capacity, 4)
