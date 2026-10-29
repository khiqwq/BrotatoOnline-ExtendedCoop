extends "res://tests/runner/test_case.gd"

const VirtualDevicePool = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/virtual_device_pool.gd")

# Brotato Online's remote placeholder ids, in its order.
const ONLINE_PLACEHOLDERS := [1, 2, 3, 4, 5, 0]
# CoopService special ids: gamepad remap 6, keyboard remap 7.
const COOP_REMAP_IDS := [6, 7]
# Placeholders plus CoopService's four debug device ids 8..11.
const EXTENDED_CANDIDATES := [1, 2, 3, 4, 5, 0, 8, 9, 10, 11]
const NO_DEVICE := VirtualDevicePool.NO_DEVICE


func _owner(n: int) -> String:
	return "steam:%d" % (76561198000000000 + n)


# Every owner holds its own id, none of them reserved, and both maps agree.
func _assert_consistent(pool, owners: Array, message: String) -> void:
	var seen := {}
	for o in owners:
		var d = pool.device_of(o)
		if d == NO_DEVICE:
			continue
		assert_false(seen.has(d), "%s: device %d shared" % [message, d])
		assert_false(pool.is_reserved(d), "%s: reserved device %d allocated" % [message, d])
		assert_eq(pool.owner_of(d), o, message)
		seen[d] = true
	assert_eq(seen.size(), pool.allocated_count(), message)
	assert_eq(pool.free_count() + pool.allocated_count(), pool.usable_count(), message)


func test_allocates_first_free_candidate_in_given_order() -> void:
	# Unsorted on purpose: the order is the configuration, not numeric order.
	var pool = VirtualDevicePool.new([3, 1, 2], [1])
	var a = pool.allocate(_owner(1))
	var b = pool.allocate(_owner(2))
	assert_true(a.ok)
	assert_true(a.changed)
	assert_eq(a.device_id, 3)
	assert_eq(b.device_id, 2)
	var c = pool.allocate(_owner(3))
	assert_false(c.ok)
	assert_eq(c.reason, VirtualDevicePool.REASON_EXHAUSTED)
	assert_eq(c.device_id, NO_DEVICE)


func test_seven_remote_players_fit_with_extended_candidates() -> void:
	# Local physical gamepad 0 plus CoopService's remap ids are reserved.
	for remote_count in range(1, 8):
		var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS + [0])
		var owners := []
		for n in range(remote_count):
			var r = pool.allocate(_owner(n))
			assert_true(r.ok, "remote_count %d owner %d" % [remote_count, n])
			assert_ne(r.device_id, 0, "local gamepad id must stay free")
			owners.append(_owner(n))
		assert_eq(pool.allocated_count(), remote_count)
		assert_eq(pool.free_count(), 9 - remote_count, "remote_count %d" % remote_count)
		_assert_consistent(pool, owners, "remote_count %d" % remote_count)


func test_upstream_placeholders_cannot_host_seven_remote_players() -> void:
	# With the local gamepad on 0 only five placeholders are usable.
	var pool = VirtualDevicePool.new(ONLINE_PLACEHOLDERS, [0])
	var owners := []
	for n in range(5):
		assert_true(pool.allocate(_owner(n)).ok, "owner %d" % n)
		owners.append(_owner(n))
	var before = var2str(pool.snapshot())
	for n in range(5, 7):
		var r = pool.allocate(_owner(n))
		assert_false(r.ok, "owner %d" % n)
		assert_eq(r.reason, VirtualDevicePool.REASON_EXHAUSTED)
		assert_eq(pool.device_of(_owner(n)), NO_DEVICE)
	assert_eq(var2str(pool.snapshot()), before, "failed allocations change nothing")
	_assert_consistent(pool, owners, "placeholders")
	# Without a local gamepad, six fit and the seventh still fails.
	var bare = VirtualDevicePool.new(ONLINE_PLACEHOLDERS, [])
	for n in range(6):
		assert_true(bare.allocate(_owner(n)).ok, "bare owner %d" % n)
	assert_eq(bare.allocate(_owner(6)).reason, VirtualDevicePool.REASON_EXHAUSTED)


func test_one_more_owner_than_ids_is_refused_for_every_size() -> void:
	for size in range(0, 9):
		var pool = VirtualDevicePool.new(range(size), [])
		var owners := []
		for n in range(size):
			assert_true(pool.allocate(_owner(n)).ok, "size %d owner %d" % [size, n])
			owners.append(_owner(n))
		var extra = pool.allocate(_owner(size))
		assert_false(extra.ok, "size %d" % size)
		assert_eq(extra.reason, VirtualDevicePool.REASON_EXHAUSTED, "size %d" % size)
		assert_eq(pool.free_count(), 0, "size %d" % size)
		_assert_consistent(pool, owners, "size %d" % size)


func test_allocate_is_idempotent_per_owner() -> void:
	var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, [])
	var first = pool.allocate(_owner(1))
	var free_after_first: int = pool.free_count()
	var again = pool.allocate(_owner(1))
	assert_true(again.ok)
	assert_false(again.changed)
	assert_eq(again.device_id, first.device_id)
	assert_eq(pool.free_count(), free_after_first)
	assert_eq(pool.allocated_count(), 1)


func test_release_frees_the_id_and_first_free_is_reused() -> void:
	var pool = VirtualDevicePool.new([1, 2, 3, 4], [])
	for n in range(3):
		pool.allocate(_owner(n))
	var released = pool.release(_owner(1))
	assert_true(released.ok)
	assert_true(released.changed)
	assert_eq(released.device_id, 2)
	assert_eq(pool.device_of(_owner(1)), NO_DEVICE)
	assert_eq(pool.owner_of(2), "")
	assert_eq(pool.allocate(_owner(9)).device_id, 2, "lowest free id in candidate order")
	var twice = pool.release(_owner(1))
	assert_true(twice.ok)
	assert_false(twice.changed)
	assert_eq(twice.device_id, NO_DEVICE)
	assert_false(pool.release(_owner(42)).changed)
	assert_eq(pool.allocated_count(), 3)


func test_invalid_owner_keys_are_rejected() -> void:
	var pool = VirtualDevicePool.new([1, 2], [])
	for key in ["", null, 5, 1.0, [], {}, true]:
		var r = pool.allocate(key)
		assert_false(r.ok, var2str(key))
		assert_eq(r.reason, VirtualDevicePool.REASON_INVALID_OWNER, var2str(key))
		assert_eq(pool.release(key).reason, VirtualDevicePool.REASON_INVALID_OWNER, var2str(key))
		assert_eq(pool.device_of(key), NO_DEVICE, var2str(key))
	assert_eq(pool.allocated_count(), 0)
	assert_eq(pool.free_count(), 2)


func test_reserve_displaces_remote_owner_for_rehoming() -> void:
	var pool = VirtualDevicePool.new([1, 2, 3], [])
	pool.allocate(_owner(1))
	pool.allocate(_owner(2))
	var r = pool.reserve(1)
	assert_true(r.ok)
	assert_true(r.changed)
	assert_eq(r.displaced_owner, _owner(1))
	assert_true(pool.is_reserved(1))
	assert_eq(pool.owner_of(1), "")
	assert_eq(pool.device_of(_owner(1)), NO_DEVICE, "displaced owner must not keep the id")
	assert_eq(pool.device_of(_owner(2)), 2, "other owners untouched")
	var rehomed = pool.allocate(_owner(1))
	assert_eq(rehomed.device_id, 3)
	_assert_consistent(pool, [_owner(1), _owner(2)], "after rehome")
	var again = pool.reserve(1)
	assert_true(again.ok)
	assert_false(again.changed)
	assert_eq(again.displaced_owner, "")
	var outside = pool.reserve(42)
	assert_true(outside.ok)
	assert_eq(outside.displaced_owner, "")
	assert_eq(pool.usable_count(), 2)


func test_unreserve_returns_id_but_fixed_ids_stay_reserved() -> void:
	var pool = VirtualDevicePool.new([6, 7, 1, 2], COOP_REMAP_IDS)
	assert_eq(pool.usable_count(), 2)
	assert_true(pool.reserve(1).changed)
	assert_eq(pool.free_count(), 1)
	var back = pool.unreserve(1)
	assert_true(back.ok)
	assert_true(back.changed)
	assert_false(pool.is_reserved(1))
	assert_false(pool.unreserve(1).changed, "second unreserve is a no-op")
	for fixed in COOP_REMAP_IDS:
		var r = pool.unreserve(fixed)
		assert_false(r.ok, "fixed %d" % fixed)
		assert_eq(r.reason, VirtualDevicePool.REASON_FIXED_RESERVED)
		assert_true(pool.is_reserved(fixed))
	assert_eq(pool.allocate(_owner(1)).device_id, 1)
	assert_eq(pool.allocate(_owner(2)).device_id, 2)
	assert_eq(pool.allocate(_owner(3)).reason, VirtualDevicePool.REASON_EXHAUSTED, "6 and 7 are never handed out")


func test_invalid_device_ids_are_rejected() -> void:
	var pool = VirtualDevicePool.new([1, 2], [])
	pool.allocate(_owner(1))
	for bad in ["1", 1.0, null, [1]]:
		assert_eq(pool.reserve(bad).reason, VirtualDevicePool.REASON_INVALID_DEVICE, var2str(bad))
		assert_eq(pool.unreserve(bad).reason, VirtualDevicePool.REASON_INVALID_DEVICE, var2str(bad))
		assert_false(pool.is_reserved(bad), var2str(bad))
		assert_eq(pool.owner_of(bad), "", var2str(bad))
	assert_eq(pool.device_of(_owner(1)), 1, "rejected calls change nothing")
	assert_eq(pool.usable_count(), 2)


func test_out_of_range_device_ids_are_refused_everywhere() -> void:
	var top: int = VirtualDevicePool.MAX_DEVICE_ID
	var pool = VirtualDevicePool.new([1, 2], [])
	pool.allocate(_owner(1))
	for bad in [NO_DEVICE, -2, top + 1, 1 << 40]:
		var r = pool.reserve(bad)
		assert_false(r.ok, "reserve %d" % bad)
		assert_eq(r.reason, VirtualDevicePool.REASON_INVALID_DEVICE, "reserve %d" % bad)
		assert_eq(r.displaced_owner, "", "reserve %d" % bad)
		assert_false(r.changed, "reserve %d" % bad)
		assert_eq(pool.unreserve(bad).reason, VirtualDevicePool.REASON_INVALID_DEVICE, "unreserve %d" % bad)
		assert_false(pool.is_reserved(bad), "%d" % bad)
	assert_eq(pool.snapshot().reserved, [], "nothing out of range is stored")
	assert_eq(pool.device_of(_owner(1)), 1)
	var bad_configs := [
		[[1, 2], [-1]],
		[[1, 2], [top + 1]],
		[[top + 1], []],
	]
	for config in bad_configs:
		assert_false(VirtualDevicePool.new(config[0], config[1]).is_valid(), var2str(config))
	var edges = VirtualDevicePool.new([0, top], [top])
	assert_true(edges.is_valid(), "both ends of the range are legal")
	assert_eq(edges.allocate(_owner(1)).device_id, 0)
	assert_true(edges.reserve(0).ok)


func test_every_accepted_reservation_survives_json() -> void:
	# Whatever reserve() accepts must come back from a JSON snapshot; a pool
	# that cannot restore its own snapshot would lose a checkpoint (F14).
	var top: int = VirtualDevicePool.MAX_DEVICE_ID
	var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS + [top])
	for n in range(3):
		pool.allocate(_owner(n))
	for id in [0, 42, top - 1, top + 1]:
		pool.reserve(id)
	var snap = pool.snapshot()
	var target = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS + [top])
	var r = target.restore(parse_json(to_json(snap)))
	assert_true(r.ok, r.reason)
	assert_eq(var2str(target.snapshot()), var2str(snap))
	assert_true(target.is_reserved(top - 1))
	assert_true(target.is_reserved(42))


func test_bad_configuration_is_reported_not_repaired() -> void:
	var bad_configs := [
		[[1, 1], []],
		[[1, "2"], []],
		[[1, 2.0], []],
		[[-1, 2], []],
		[[1, 2], ["7"]],
	]
	for config in bad_configs:
		var pool = VirtualDevicePool.new(config[0], config[1])
		assert_false(pool.is_valid(), var2str(config))
		assert_false(pool.config_errors().empty(), var2str(config))
		assert_eq(pool.allocate(_owner(1)).reason, VirtualDevicePool.REASON_INVALID_CONFIG, var2str(config))
		assert_eq(pool.free_count(), 0, var2str(config))
		assert_eq(pool.usable_count(), 0, var2str(config))
	var empty = VirtualDevicePool.new([], [])
	assert_true(empty.is_valid())
	assert_eq(empty.allocate(_owner(1)).reason, VirtualDevicePool.REASON_EXHAUSTED)


func test_random_replug_and_churn_never_shares_an_id() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261028
	var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	var owners := []
	for n in range(7):
		owners.append(_owner(n))
	for step in range(600):
		var op := rng.randi_range(0, 3)
		if op == 0:
			pool.allocate(owners[rng.randi_range(0, owners.size() - 1)])
		elif op == 1:
			pool.release(owners[rng.randi_range(0, owners.size() - 1)])
		elif op == 2:
			var plugged = pool.reserve(rng.randi_range(0, 3))
			if plugged.displaced_owner != "":
				assert_eq(pool.device_of(plugged.displaced_owner), NO_DEVICE, "step %d" % step)
		else:
			pool.unreserve(rng.randi_range(0, 3))
		_assert_consistent(pool, owners, "step %d" % step)


func test_snapshot_restore_round_trip() -> void:
	var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	for n in range(4):
		pool.allocate(_owner(n))
	pool.reserve(2)
	var snap = pool.snapshot()
	var expected = var2str(snap)
	pool.release(_owner(0))
	pool.unreserve(2)
	pool.allocate(_owner(9))
	var r = pool.restore(snap)
	assert_true(r.ok, r.reason)
	assert_eq(var2str(pool.snapshot()), expected)
	assert_true(pool.is_reserved(2))
	assert_eq(pool.device_of(_owner(9)), NO_DEVICE)
	var fresh = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	assert_true(fresh.restore(snap).ok)
	for n in range(4):
		assert_eq(fresh.device_of(_owner(n)), pool.device_of(_owner(n)), "owner %d" % n)


func test_snapshot_is_a_copy() -> void:
	var pool = VirtualDevicePool.new([1, 2, 3], [])
	pool.allocate(_owner(1))
	var snap = pool.snapshot()
	snap.owners[_owner(2)] = 2
	snap.reserved.append(3)
	snap.candidates.append(99)
	assert_eq(pool.device_of(_owner(2)), NO_DEVICE)
	assert_false(pool.is_reserved(3))
	assert_eq(pool.candidate_ids(), [1, 2, 3])


func test_restore_accepts_json_and_bytes_with_int_types() -> void:
	var pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	for n in range(3):
		pool.allocate(_owner(n))
	pool.reserve(0)
	var snap = pool.snapshot()
	var copies := [
		parse_json(to_json(snap)),
		bytes2var(var2bytes(snap), false),
	]
	for copy in copies:
		var target = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
		var r = target.restore(copy)
		assert_true(r.ok, r.reason)
		for n in range(3):
			var d = target.device_of(_owner(n))
			assert_eq(typeof(d), TYPE_INT, "device type after transport")
			assert_eq(d, pool.device_of(_owner(n)))
			assert_eq(target.owner_of(d), _owner(n), "reverse map uses int keys")
		assert_true(target.is_reserved(0))
		assert_eq(target.allocate(_owner(5)).device_id, 4, "next free id after restore")


func test_restore_rejects_bad_snapshots_and_keeps_state() -> void:
	var pool = VirtualDevicePool.new([1, 2, 3, 4], [7])
	pool.allocate(_owner(1))
	pool.reserve(3)
	var good = pool.snapshot()
	var before = var2str(good)
	var cases := []
	cases.append([null, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	cases.append([[], VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var missing = good.duplicate(true)
	missing.erase("owners")
	cases.append([missing, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var owners_list = good.duplicate(true)
	owners_list.owners = [1]
	cases.append([owners_list, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var on_reserved = good.duplicate(true)
	on_reserved.owners[_owner(2)] = 3
	cases.append([on_reserved, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var on_fixed = good.duplicate(true)
	on_fixed.owners[_owner(2)] = 7
	cases.append([on_fixed, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var not_candidate = good.duplicate(true)
	not_candidate.owners[_owner(2)] = 9
	cases.append([not_candidate, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var shared = good.duplicate(true)
	shared.owners[_owner(2)] = 1
	cases.append([shared, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var empty_key = good.duplicate(true)
	empty_key.owners[""] = 2
	cases.append([empty_key, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var fractional = good.duplicate(true)
	fractional.owners[_owner(2)] = 2.5
	cases.append([fractional, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var dup_reserved = good.duplicate(true)
	dup_reserved.reserved = [3, 3]
	cases.append([dup_reserved, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var negative_reserved = good.duplicate(true)
	negative_reserved.reserved = [3, -3]
	cases.append([negative_reserved, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	# JSON hands every number back as a float.
	var negative_float = good.duplicate(true)
	negative_float.reserved = [3.0, -3.0]
	cases.append([negative_float, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var huge_reserved = good.duplicate(true)
	huge_reserved.reserved = [3, VirtualDevicePool.MAX_DEVICE_ID + 1]
	cases.append([huge_reserved, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var negative_owner = good.duplicate(true)
	negative_owner.owners[_owner(2)] = -1
	cases.append([negative_owner, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var int_key = good.duplicate(true)
	int_key.owners[5] = 2
	cases.append([int_key, VirtualDevicePool.REASON_MALFORMED_SNAPSHOT])
	var other_candidates = good.duplicate(true)
	other_candidates.candidates = [1, 2, 3, 4, 5]
	cases.append([other_candidates, VirtualDevicePool.REASON_CONFIG_MISMATCH])
	var other_fixed = good.duplicate(true)
	other_fixed.fixed_reserved = []
	cases.append([other_fixed, VirtualDevicePool.REASON_CONFIG_MISMATCH])
	for c in cases:
		var r = pool.restore(c[0])
		assert_false(r.ok, var2str(c[0]))
		assert_eq(r.reason, c[1], var2str(c[0]))
		assert_eq(var2str(pool.snapshot()), before, "state unchanged after %s" % var2str(c[0]))
