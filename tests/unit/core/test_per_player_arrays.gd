extends "res://tests/runner/test_case.gd"

const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")


class Holder:
	extends Reference
	var dicts := [{}, {}, {}, {}]
	var lists := [[], [], [], []]
	var flags := [false, false, false, false]
	var counters := [0, 0, 0, 0]
	var not_an_array := 3


func test_target_size_keeps_vanilla_for_one_to_four_players() -> void:
	for n in range(0, 5):
		assert_eq(PerPlayerArrays.target_size(n, 8), 4, "players %d" % n)


func test_target_size_follows_players_up_to_capacity() -> void:
	for n in range(5, 9):
		assert_eq(PerPlayerArrays.target_size(n, 8), n, "players %d" % n)
	assert_eq(PerPlayerArrays.target_size(9, 8), 8)
	assert_eq(PerPlayerArrays.target_size(6, 4), 4, "vanilla capacity never grows")
	assert_eq(PerPlayerArrays.target_size(6, 2), 4, "capacity below 4 is treated as 4")


func test_grow_appends_fresh_entries_of_the_right_kind() -> void:
	var arr := [{"a": 1}, {}, {}, {}]
	assert_eq(PerPlayerArrays.grow(arr, 6, PerPlayerArrays.KIND_DICT), 2)
	assert_eq(arr.size(), 6)
	# Godot 3 compares dictionaries by reference, so check the content.
	assert_eq(arr[0].get("a"), 1, "existing entries untouched")
	arr[4]["x"] = 1
	assert_false(arr[5].has("x"), "new dictionaries are distinct objects")
	var lists := [[1], [], [], []]
	assert_eq(PerPlayerArrays.grow(lists, 8, PerPlayerArrays.KIND_ARRAY), 4)
	lists[7].append(2)
	assert_eq(lists[6], [], "new arrays are distinct objects")
	var values := [true, true, true, true]
	assert_eq(PerPlayerArrays.grow(values, 5, PerPlayerArrays.KIND_VALUE, false), 1)
	assert_eq(values[4], false)


func test_grow_never_shrinks() -> void:
	var arr := [0, 0, 0, 0, 0, 0]
	assert_eq(PerPlayerArrays.grow(arr, 4, PerPlayerArrays.KIND_VALUE, 0), 0)
	assert_eq(arr.size(), 6)


func test_grow_fields_grows_in_place_and_reports_skips() -> void:
	var h = Holder.new()
	var r: Dictionary = PerPlayerArrays.grow_fields(h, [
		["dicts", PerPlayerArrays.KIND_DICT],
		["lists", PerPlayerArrays.KIND_ARRAY],
		["flags", PerPlayerArrays.KIND_VALUE, false],
		["counters", PerPlayerArrays.KIND_VALUE, 0],
		["not_an_array", PerPlayerArrays.KIND_VALUE, 0],
		["missing", PerPlayerArrays.KIND_DICT],
	], 7)
	assert_eq(r.added, 12)
	assert_eq(r.skipped, ["not_an_array", "missing"])
	for name in ["dicts", "lists", "flags", "counters"]:
		assert_eq(h.get(name).size(), 7, name)
	assert_eq(h.counters[6], 0)
	assert_eq(h.flags[6], false)


func test_grow_fields_with_vanilla_size_changes_nothing() -> void:
	var h = Holder.new()
	var r: Dictionary = PerPlayerArrays.grow_fields(h, [["dicts", PerPlayerArrays.KIND_DICT], ["flags", PerPlayerArrays.KIND_VALUE, false]], 4)
	assert_eq(r.added, 0)
	assert_eq(h.dicts.size(), 4)
	assert_eq(h.flags.size(), 4)


func test_grow_fields_on_null_object() -> void:
	var r: Dictionary = PerPlayerArrays.grow_fields(null, [["x", PerPlayerArrays.KIND_DICT]], 8)
	assert_eq(r.added, 0)
	assert_eq(r.skipped, ["<null object>"])
