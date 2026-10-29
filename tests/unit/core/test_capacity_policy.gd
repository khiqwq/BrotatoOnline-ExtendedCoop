extends "res://tests/runner/test_case.gd"

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")


func test_default_capacity_is_eight() -> void:
	var p = CapacityPolicy.new()
	assert_eq(p.capacity, 8)
	assert_true(p.is_valid())
	assert_true(p.is_extended())
	assert_eq(p.max_remote_players(), 7)


func test_invalid_capacities_are_rejected() -> void:
	for cap in [0, -1, 9, 16]:
		var p = CapacityPolicy.new(cap)
		assert_false(p.is_valid(), "capacity %d" % cap)
		assert_eq(p.check_join(0, false).reason, CapacityPolicy.REJECT_INVALID_CAPACITY, "capacity %d" % cap)
		assert_eq(p.max_remote_players(), 0, "capacity %d" % cap)


func test_legal_counts_for_every_capacity() -> void:
	for cap in range(1, 9):
		var p = CapacityPolicy.new(cap)
		for n in range(0, 10):
			assert_eq(p.is_legal_count(n), n >= 1 and n <= cap, "cap %d n %d" % [cap, n])


func test_join_until_full_then_ninth_rejected() -> void:
	var p = CapacityPolicy.new(8)
	for members in range(1, 8):
		assert_true(p.check_join(members, false).accepted, "members %d" % members)
	var ninth = p.check_join(8, false)
	assert_false(ninth.accepted)
	assert_eq(ninth.reason, CapacityPolicy.REJECT_FULL)


func test_frozen_run_rejects_new_members_even_with_room() -> void:
	var p = CapacityPolicy.new(8)
	var r = p.check_join(5, true)
	assert_false(r.accepted)
	assert_eq(r.reason, CapacityPolicy.REJECT_RUN_FROZEN)


func test_layout_count_never_truncates_legal_counts() -> void:
	var p = CapacityPolicy.new(8)
	for n in range(1, 9):
		var r = p.layout_count(n)
		assert_true(r.ok, "n %d" % n)
		assert_eq(r.count, n, "n %d" % n)
	assert_false(p.layout_count(0).ok)
	assert_false(p.layout_count(9).ok)
	assert_eq(p.layout_count(9).count, 8)


func test_vanilla_capacity_keeps_four_player_rules() -> void:
	var p = CapacityPolicy.new(4)
	assert_false(p.is_extended())
	assert_eq(p.max_remote_players(), 3)
	assert_false(p.check_join(4, false).accepted)
	assert_false(p.layout_count(5).ok)


func test_free_slots() -> void:
	var p = CapacityPolicy.new(8)
	assert_eq(p.free_slots(3), 5)
	assert_eq(p.free_slots(8), 0)
	assert_eq(p.free_slots(10), 0)
