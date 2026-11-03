extends "res://tests/runner/test_case.gd"

const MapScale = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/map_scale.gd")


func test_one_to_four_players_keep_the_zone_size() -> void:
	for n in [0, 1, 2, 3, 4]:
		assert_eq(MapScale.side_factor(n), 1.0, str(n))
		assert_eq(MapScale.scaled_tiles(32, n), 32, str(n))
		assert_eq(MapScale.scaled_tiles(24, n), 24, str(n))


func test_five_to_eight_players_keep_the_four_player_area_per_player() -> void:
	var expected := {5: [36, 27], 6: [39, 29], 7: [42, 32], 8: [45, 34]}
	for n in expected:
		assert_eq(MapScale.scaled_tiles(32, n), expected[n][0], "width %d" % n)
		assert_eq(MapScale.scaled_tiles(24, n), expected[n][1], "height %d" % n)
		var area_per_player: float = float(MapScale.scaled_tiles(32, n) * MapScale.scaled_tiles(24, n)) / n
		assert_true(abs(area_per_player - 32 * 24 / 4.0) < 12.0, "area per player %d: %f" % [n, area_per_player])


func test_counts_past_eight_use_eight() -> void:
	assert_eq(MapScale.side_factor(12), MapScale.side_factor(8))


func test_never_shrinks_a_small_map() -> void:
	assert_eq(MapScale.scaled_tiles(12, 8), 17)
	assert_eq(MapScale.scaled_tiles(12, 3), 12)
