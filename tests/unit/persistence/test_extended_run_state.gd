extends "res://tests/runner/test_case.gd"

const ExtendedRunState = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/persistence/extended_run_state.gd")


class FakeItem:
	extends Reference
	var my_id := ""

	func _init(id: String) -> void:
		my_id = id

	func serialize() -> Dictionary:
		return {"my_id": my_id}


func _state(players: int) -> Dictionary:
	var players_data := []
	var shop := []
	var locked := []
	for i in players:
		players_data.append({"p": i})
		shop.append([[FakeItem.new("shop_%d" % i), 10 + i]])
		locked.append([])
	return {"has_run_state": true, "players_data": players_data, "shop_items": shop, "locked_shop_items": locked, "current_wave": 3}


func test_player_count_and_extended_threshold() -> void:
	assert_eq(ExtendedRunState.player_count({"has_run_state": false}), 0)
	assert_eq(ExtendedRunState.player_count({"has_run_state": true}), 0, "no players_data")
	assert_eq(ExtendedRunState.player_count(null), 0)
	assert_eq(ExtendedRunState.player_count(_state(3)), 3)
	for n in range(1, 5):
		assert_false(ExtendedRunState.is_extended(_state(n)), "players %d stay vanilla" % n)
	for n in range(5, 9):
		assert_true(ExtendedRunState.is_extended(_state(n)), "players %d" % n)
	var no_run := _state(8)
	no_run.has_run_state = false
	assert_false(ExtendedRunState.is_extended(no_run), "a state without a run is never extended")


func test_run_id_is_per_profile_and_store_safe() -> void:
	assert_eq(ExtendedRunState.run_id_for_profile(0), "profile_0")
	assert_eq(ExtendedRunState.run_id_for_profile(2), "profile_2")
	assert_eq(ExtendedRunState.run_id_for_profile(-1), "profile_0")


func test_placeholder_has_no_run_and_carries_the_marker() -> void:
	var marker := ExtendedRunState.make_marker("profile_0", "abc", 8, "")
	var ph := ExtendedRunState.placeholder(marker)
	assert_false(bool(ph.has_run_state))
	assert_false(ph.has("players_data"), "vanilla never sees the players")
	assert_eq(ExtendedRunState.player_count(ph), 0)
	assert_eq(ExtendedRunState.marker_of(ph).get("checkpoint_id"), "abc")
	marker.checkpoint_id = "changed"
	assert_eq(ExtendedRunState.marker_of(ph).get("checkpoint_id"), "abc", "placeholder keeps its own copy")


func test_marker_of_ignores_other_states() -> void:
	# Godot 3 compares dictionaries by reference, so emptiness is checked directly.
	assert_true(ExtendedRunState.marker_of({"has_run_state": false}).empty())
	assert_true(ExtendedRunState.marker_of(null).empty())
	var with_run := _state(8)
	with_run[ExtendedRunState.MARKER_KEY] = {"checkpoint_id": "x"}
	assert_true(ExtendedRunState.marker_of(with_run).empty(), "a real run is never a placeholder")
	assert_true(ExtendedRunState.marker_of({"has_run_state": false, ExtendedRunState.MARKER_KEY: "x"}).empty(), "non-dictionary marker")


func test_split_keeps_four_players_for_vanilla() -> void:
	var state := _state(6)
	var split := ExtendedRunState.split_four_slot_fields(state)
	assert_eq(split.head.shop_items.size(), 4)
	assert_eq(split.head.locked_shop_items.size(), 4)
	assert_eq(split.extra.shop_items.size(), 2)
	assert_eq(split.extra.shop_items[0][0][0].my_id, "shop_4", "player 5 first")
	assert_eq(split.head.players_data.size(), 6, "other fields are untouched")
	assert_eq(state.shop_items.size(), 6, "the input state is not modified")


func test_split_leaves_four_players_alone() -> void:
	var split := ExtendedRunState.split_four_slot_fields(_state(4))
	assert_true(split.extra.empty())
	assert_eq(split.head.shop_items.size(), 4)


func test_serialize_shop_entries_uses_vanilla_shape() -> void:
	var result := ExtendedRunState.serialize_shop_entries([[[FakeItem.new("a"), 12], [FakeItem.new("b"), 7]], []])
	assert_eq(result.skipped, 0)
	assert_eq(result.players.size(), 2)
	assert_eq(result.players[0][0][0].my_id, "a")
	assert_eq(result.players[0][1][1], 7)
	assert_eq(result.players[1], [])


func test_serialize_shop_entries_counts_bad_entries() -> void:
	var result := ExtendedRunState.serialize_shop_entries([[["not an item", 1], [FakeItem.new("a")]], "junk"])
	assert_eq(result.skipped, 3)
	assert_eq(result.players, [[], []])


func test_merge_appends_extra_players_after_four() -> void:
	var serialized := {"shop_items": [[1], [2], [3], [4]], "current_wave": 3}
	var merged := ExtendedRunState.merge_serialized(serialized, {"shop_items": [[5], [6]]})
	assert_eq(merged.shop_items, [[1], [2], [3], [4], [5], [6]])
	assert_eq(serialized.shop_items.size(), 4, "input not modified")
	var short := ExtendedRunState.merge_serialized({"locked_shop_items": [[1]]}, {"locked_shop_items": [[5]]})
	assert_eq(short.locked_shop_items, [[1], [], [], [], [5]], "pads to four before the extra players")


func test_round_trip_split_serialize_merge() -> void:
	var state := _state(8)
	var split := ExtendedRunState.split_four_slot_fields(state)
	var head_serialized := {
		"shop_items": ExtendedRunState.serialize_shop_entries(split.head.shop_items).players,
		"locked_shop_items": ExtendedRunState.serialize_shop_entries(split.head.locked_shop_items).players,
	}
	var extra := {}
	for field in split.extra:
		extra[field] = ExtendedRunState.serialize_shop_entries(split.extra[field]).players
	var merged := ExtendedRunState.merge_serialized(head_serialized, extra)
	assert_eq(merged.shop_items.size(), 8)
	for i in 8:
		assert_eq(merged.shop_items[i][0][0].my_id, "shop_%d" % i)
		assert_eq(merged.shop_items[i][0][1], 10 + i)
	assert_eq(merged.locked_shop_items.size(), 8)


func test_payload_records_schema_players_and_versions() -> void:
	var versions := {"game": "1.1.15.4"}
	var p := ExtendedRunState.payload({"current_wave": 3}, 8, versions)
	assert_eq(p.schema, ExtendedRunState.PAYLOAD_SCHEMA)
	assert_eq(p.players, 8)
	assert_eq(p.versions.game, "1.1.15.4")
	assert_eq(p.run_state.current_wave, 3)
	versions.game = "x"
	assert_eq(p.versions.game, "1.1.15.4", "payload keeps its own copy")
