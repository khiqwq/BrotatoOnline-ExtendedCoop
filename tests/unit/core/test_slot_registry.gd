extends "res://tests/runner/test_case.gd"

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const VirtualDevicePool = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/virtual_device_pool.gd")
const SlotRegistry = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/slot_registry.gd")

# Brotato Online's remote placeholder ids, in its order.
const ONLINE_PLACEHOLDERS := [1, 2, 3, 4, 5, 0]
# Placeholders plus CoopService's four debug device ids 8..11.
const EXTENDED_CANDIDATES := [1, 2, 3, 4, 5, 0, 8, 9, 10, 11]
# CoopService special ids: gamepad remap 6, keyboard remap 7.
const COOP_REMAP_IDS := [6, 7]
const NO_DEVICE := SlotRegistry.NO_DEVICE

var pool
var reg


func _setup(capacity: int = 8, candidates: Array = EXTENDED_CANDIDATES, reserved: Array = COOP_REMAP_IDS) -> void:
	pool = VirtualDevicePool.new(candidates, reserved)
	reg = SlotRegistry.new(CapacityPolicy.new(capacity), pool)


func _id(n: int) -> String:
	return "steam:%d" % (76561198000000000 + n)


# Seats _id(0).._id(count-1) in order; the one at local_at is the local player.
func _seat_all(count: int, local_at: int = 0) -> void:
	for n in range(count):
		var r = reg.seat(_id(n), n == local_at)
		assert_true(r.ok, "seat %d: %s" % [n, r.reason])


func _codes(violations: Array) -> Array:
	var out := []
	for v in violations:
		out.append(v.code)
	return out


# Remote online players hold distinct, unreserved devices; nobody else holds one.
func _assert_devices_sound(message: String) -> void:
	var seen := {}
	for e in reg.roster():
		if e.online and not e.is_local:
			assert_ne(e.device_id, NO_DEVICE, "%s: %s has no device" % [message, e.display_name])
			assert_false(seen.has(e.device_id), "%s: device %d shared" % [message, e.device_id])
			assert_false(pool.is_reserved(e.device_id), "%s: reserved device in use" % message)
			seen[e.device_id] = true
		else:
			assert_eq(e.device_id, NO_DEVICE, "%s: %s should hold no device" % [message, e.display_name])
	assert_eq(pool.allocated_count(), seen.size(), message)


func _seat_map() -> Dictionary:
	var out := {}
	for e in reg.roster():
		out[e.identity] = [e.slot, e.player_index]
	return out


func test_one_to_eight_players_get_contiguous_indices_and_unique_seats() -> void:
	for count in range(1, 9):
		_setup()
		_seat_all(count)
		var roster: Array = reg.roster()
		assert_eq(roster.size(), count, "count %d" % count)
		assert_eq(reg.roster_count(), count)
		assert_eq(reg.online_count(), count)
		for i in range(count):
			var e = roster[i]
			assert_eq(e.player_index, i, "count %d" % count)
			assert_eq(e.slot, i, "first seat order gives slot ids")
			assert_eq(e.identity, _id(i))
			assert_eq(e.display_name, "P%d" % (i + 1))
			assert_eq(e.is_local, i == 0)
			assert_true(e.online)
			assert_eq(reg.identity_at_index(i), _id(i))
			assert_eq(reg.player_index_of(_id(i)), i)
		_assert_devices_sound("count %d" % count)
		assert_eq(reg.validate(), [], "count %d" % count)
		assert_true(reg.check_setup().ok, "count %d" % count)


func test_player_after_capacity_is_refused_for_every_capacity() -> void:
	for capacity in range(1, 9):
		_setup(capacity)
		_seat_all(capacity)
		var allocated: int = pool.allocated_count()
		var extra = reg.seat(_id(capacity), false)
		assert_false(extra.ok, "capacity %d" % capacity)
		assert_eq(extra.reason, CapacityPolicy.REJECT_FULL, "capacity %d" % capacity)
		assert_eq(extra.reason, SlotRegistry.REASON_FULL)
		assert_eq(extra.player_index, SlotRegistry.NO_INDEX)
		assert_eq(reg.roster_count(), capacity)
		assert_false(reg.has_identity(_id(capacity)))
		assert_eq(pool.allocated_count(), allocated, "no device leaked by a refused join")
		assert_eq(reg.next_slot(), capacity, "no slot consumed by a refused join")


func test_ninth_player_is_refused_with_full_roster_of_eight() -> void:
	_setup(8)
	_seat_all(8)
	var ninth = reg.seat(_id(8), false)
	assert_false(ninth.ok)
	assert_eq(ninth.reason, CapacityPolicy.REJECT_FULL)
	assert_eq(reg.roster_count(), 8)
	assert_eq(reg.validate(), [])


func test_upstream_placeholders_refuse_the_seventh_player_clearly() -> void:
	# Local gamepad 0 reserved: five placeholders for seven possible remotes.
	_setup(8, ONLINE_PLACEHOLDERS, COOP_REMAP_IDS + [0])
	var setup = reg.check_setup()
	assert_false(setup.ok)
	assert_eq(setup.reason, SlotRegistry.REASON_DEVICE_SHORTFALL)
	assert_eq(setup.remote_capacity, 7)
	assert_eq(setup.usable_devices, 5)
	assert_eq(setup.shortfall, 2)
	_seat_all(6)
	var seventh = reg.seat(_id(6), false)
	assert_false(seventh.ok)
	assert_eq(seventh.reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE)
	assert_eq(seventh.device_reason, VirtualDevicePool.REASON_EXHAUSTED)
	assert_eq(reg.roster_count(), 6)
	assert_eq(reg.next_slot(), 6, "refused join consumes no slot")
	_assert_devices_sound("placeholders")
	# The same session with the extended ids seats all eight.
	_setup(8, EXTENDED_CANDIDATES, COOP_REMAP_IDS + [0])
	assert_true(reg.check_setup().ok)
	_seat_all(8)
	_assert_devices_sound("extended")
	assert_eq(reg.validate(), [])


func test_second_local_identity_is_refused() -> void:
	_setup()
	assert_true(reg.seat("lan:a", true).ok)
	var second = reg.seat("lan:b", true)
	assert_false(second.ok)
	assert_eq(second.reason, SlotRegistry.REASON_SECOND_LOCAL)
	reg.disconnect_identity("lan:a")
	assert_eq(reg.seat("lan:b", true).reason, SlotRegistry.REASON_SECOND_LOCAL, "an offline local still counts")
	assert_eq(reg.seat("lan:a", false).reason, SlotRegistry.REASON_LOCAL_MISMATCH)
	assert_true(reg.seat("lan:c", false).ok)
	assert_eq(reg.seat("lan:c", true).reason, SlotRegistry.REASON_LOCAL_MISMATCH)
	assert_eq(reg.local_identity(), "lan:a")
	assert_eq(reg.roster_count(), 2)


func test_malformed_seat_arguments_are_refused() -> void:
	_setup()
	var long_id := "steam:"
	while long_id.length() <= SlotRegistry.MAX_IDENTITY_LENGTH:
		long_id += "9"
	var cases := [
		["", false, SlotRegistry.REASON_INVALID_IDENTITY],
		[null, false, SlotRegistry.REASON_INVALID_IDENTITY],
		[5, false, SlotRegistry.REASON_INVALID_IDENTITY],
		[long_id, false, SlotRegistry.REASON_INVALID_IDENTITY],
		["steam:1", "true", SlotRegistry.REASON_INVALID_ARGUMENT],
		["steam:1", 1, SlotRegistry.REASON_INVALID_ARGUMENT],
		["steam:1", null, SlotRegistry.REASON_INVALID_ARGUMENT],
	]
	for c in cases:
		var r = reg.seat(c[0], c[1])
		assert_false(r.ok, var2str(c))
		assert_eq(r.reason, c[2], var2str(c))
	assert_eq(reg.roster_count(), 0)
	assert_eq(reg.next_slot(), 0)
	assert_eq(pool.allocated_count(), 0)
	for bad in ["", null, 5, "steam:unknown"]:
		assert_false(reg.disconnect_identity(bad).ok, var2str(bad))
		assert_false(reg.reconnect(bad).ok, var2str(bad))
		assert_false(reg.remove(bad).ok, var2str(bad))
	assert_eq(reg.reconnect("steam:unknown").reason, SlotRegistry.REASON_UNKNOWN_IDENTITY)


func test_invalid_setup_refuses_everything() -> void:
	var good_pool = VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	var setups := [
		SlotRegistry.new(),
		SlotRegistry.new(CapacityPolicy.new(8), null),
		SlotRegistry.new(null, good_pool),
		SlotRegistry.new(good_pool, CapacityPolicy.new(8)),
		SlotRegistry.new(CapacityPolicy.new(9), good_pool),
		SlotRegistry.new(CapacityPolicy.new(0), good_pool),
		SlotRegistry.new(CapacityPolicy.new(8), VirtualDevicePool.new([1, 1], [])),
	]
	for i in range(setups.size()):
		var r = setups[i]
		assert_false(r.is_valid(), "setup %d" % i)
		assert_eq(r.seat(_id(1), false).reason, SlotRegistry.REASON_INVALID_SETUP, "setup %d" % i)
		assert_eq(r.roster_count(), 0, "setup %d" % i)
		assert_eq(_codes(r.validate()), [SlotRegistry.VIOLATION_INVALID_SETUP], "setup %d" % i)
		assert_false(r.check_setup().ok, "setup %d" % i)
		assert_false(r.freeze().ok, "setup %d" % i)
		assert_false(r.deserialize({}).ok, "setup %d" % i)
	assert_eq(good_pool.allocated_count(), 0)


func test_repeated_seat_of_online_identity_is_a_no_op() -> void:
	_setup()
	_seat_all(3)
	var first = reg.entry_of(_id(2))
	var again = reg.seat(_id(2), false)
	assert_true(again.ok)
	assert_false(again.changed)
	assert_true(again.returning)
	assert_eq(again.slot, first.slot)
	assert_eq(again.player_index, first.player_index)
	assert_eq(again.device_id, first.device_id)
	assert_eq(reg.roster_count(), 3)
	assert_eq(pool.allocated_count(), 2)
	assert_eq(reg.next_slot(), 3)


func test_disconnect_keeps_seat_and_releases_device() -> void:
	for count in range(2, 9):
		for k in range(1, count):
			_setup()
			_seat_all(count)
			var before = reg.entry_of(_id(k))
			var r = reg.disconnect_identity(_id(k))
			assert_true(r.ok)
			assert_true(r.changed)
			assert_eq(r.released_device_id, before.device_id)
			assert_eq(r.slot, before.slot)
			assert_eq(r.player_index, before.player_index)
			assert_false(reg.is_online(_id(k)))
			assert_eq(reg.device_of(_id(k)), NO_DEVICE)
			assert_eq(pool.owner_of(before.device_id), "", "count %d k %d" % [count, k])
			assert_eq(reg.roster_count(), count)
			assert_eq(reg.online_count(), count - 1)
			assert_eq(reg.identity_at_index(k), _id(k))
			assert_eq(reg.generation(), 0)
			assert_eq(reg.validate(), [], "count %d k %d" % [count, k])
			var twice = reg.disconnect_identity(_id(k))
			assert_true(twice.ok)
			assert_false(twice.changed)


func test_offline_seat_still_counts_against_capacity() -> void:
	_setup(8)
	_seat_all(8)
	reg.disconnect_identity(_id(5))
	var newcomer = reg.seat(_id(100), false)
	assert_false(newcomer.ok, "a newcomer may not take an offline player's seat")
	assert_eq(newcomer.reason, CapacityPolicy.REJECT_FULL)
	var back = reg.seat(_id(5), false)
	assert_true(back.ok)
	assert_true(back.returning)
	assert_eq(back.player_index, 5)
	assert_eq(back.slot, 5)


func test_frozen_run_refuses_newcomers_but_takes_back_returning_players() -> void:
	_setup(8)
	_seat_all(5)
	assert_true(reg.freeze().ok)
	assert_true(reg.is_frozen())
	assert_false(reg.freeze().changed)
	var newcomer = reg.seat(_id(50), false)
	assert_false(newcomer.ok)
	assert_eq(newcomer.reason, CapacityPolicy.REJECT_RUN_FROZEN)
	reg.disconnect_identity(_id(3))
	var back = reg.seat(_id(3), false)
	assert_true(back.ok, back.reason)
	assert_eq(back.slot, 3)
	assert_eq(back.player_index, 3)
	reg.disconnect_identity(_id(2))
	var rejoin = reg.reconnect(_id(2))
	assert_true(rejoin.ok)
	assert_eq(rejoin.player_index, 2)
	assert_eq(reg.roster_count(), 5)
	_assert_devices_sound("frozen")


func test_freeze_refuses_empty_roster() -> void:
	_setup()
	var r = reg.freeze()
	assert_false(r.ok)
	assert_eq(r.reason, SlotRegistry.REASON_EMPTY_ROSTER)
	assert_false(reg.is_frozen())


func test_reconnect_order_never_moves_seats() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9001
	_setup(8)
	_seat_all(8, 3)
	var expected = var2str(_seat_map())
	var remotes := []
	for n in range(8):
		if n != 3:
			remotes.append(_id(n))
	for round_no in range(6):
		for identity in remotes:
			reg.disconnect_identity(identity)
		var order := remotes.duplicate()
		if round_no == 0:
			order.invert()
		else:
			for i in range(order.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var tmp = order[i]
				order[i] = order[j]
				order[j] = tmp
		for identity in order:
			var r = reg.reconnect(identity)
			assert_true(r.ok, "round %d" % round_no)
		assert_eq(var2str(_seat_map()), expected, "round %d" % round_no)
		assert_eq(reg.online_count(), 8)
		_assert_devices_sound("round %d" % round_no)
		assert_eq(reg.validate(), [], "round %d" % round_no)
	assert_eq(reg.generation(), 0)


func test_new_identity_never_takes_an_existing_slot() -> void:
	_setup(8)
	_seat_all(3)
	reg.disconnect_identity(_id(1))
	var d = reg.seat(_id(77), false)
	assert_true(d.ok)
	assert_eq(d.slot, 3, "fresh slot, not the offline player's slot 1")
	assert_eq(d.player_index, 3)
	assert_false(d.returning)
	assert_eq(reg.player_index_of(_id(1)), 1)
	assert_false(reg.owns_index(_id(77), 1))
	assert_true(reg.reconnect(_id(1)).ok)
	assert_eq(reg.slot_of(_id(1)), 1)
	assert_eq(reg.identity_at_index(1), _id(1))


func test_reconnect_without_free_device_fails_and_keeps_seat() -> void:
	# Local gamepad on 0: exactly five ids for five remote players.
	_setup(6, ONLINE_PLACEHOLDERS, [0])
	_seat_all(6)
	var lost: int = reg.device_of(_id(2))
	reg.disconnect_identity(_id(2))
	# A local gamepad shows up on the freed id while the player is away.
	reg.reserve_local_device(lost)
	var r = reg.reconnect(_id(2))
	assert_false(r.ok)
	assert_eq(r.reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE)
	assert_false(reg.is_online(_id(2)))
	assert_eq(reg.player_index_of(_id(2)), 2)
	assert_eq(reg.validate(), [])
	reg.release_local_device(lost)
	var again = reg.reconnect(_id(2))
	assert_true(again.ok)
	assert_eq(again.device_id, lost)
	_assert_devices_sound("after reconnect")


func test_remove_compacts_indices_and_returns_full_remap() -> void:
	for count in range(2, 9):
		var local_at := count / 2
		for removed in range(count):
			if removed == local_at:
				continue
			_setup(8)
			_seat_all(count, local_at)
			var old_roster: Array = reg.roster()
			var per_index := []
			for e in old_roster:
				per_index.append(e.identity)
			var removed_device: int = reg.device_of(_id(removed))
			var r = reg.remove(_id(removed))
			var tag = "count %d removed %d" % [count, removed]
			assert_true(r.ok, tag)
			assert_eq(r.removed_index, removed, tag)
			assert_eq(r.removed_slot, removed, tag)
			assert_eq(r.old_count, count, tag)
			assert_eq(r.new_count, count - 1, tag)
			assert_eq(r.generation, 1, tag)
			assert_eq(reg.generation(), 1, tag)
			assert_eq(r.remap.size(), count - 1, tag)
			assert_false(r.remap.has(removed), tag)
			for old_index in range(count):
				if old_index == removed:
					continue
				var expected_new = old_index if old_index < removed else old_index - 1
				assert_eq(r.remap[old_index], expected_new, "%s old %d" % [tag, old_index])
				var identity: String = old_roster[old_index].identity
				assert_eq(reg.player_index_of(identity), expected_new, tag)
				assert_eq(reg.slot_of(identity), old_roster[old_index].slot, "slots never move: %s" % tag)
				assert_eq(reg.display_name_of(identity), "P%d" % (expected_new + 1), tag)
			assert_false(reg.has_identity(_id(removed)), tag)
			assert_eq(pool.owner_of(removed_device), "", tag)
			assert_eq(r.released_device_id, removed_device, "caller must learn which input to clear: %s" % tag)
			assert_eq(r.rehomed, [], tag)
			assert_eq(r.unhomed, [], tag)
			var moved = SlotRegistry.remap_array(per_index, r.remap, r.old_count)
			assert_true(moved.ok, tag)
			var now := []
			for e in reg.roster():
				now.append(e.identity)
			assert_eq(moved.values, now, "remapped data lines up with the roster: %s" % tag)
			assert_eq(reg.local_identity(), _id(local_at), tag)
			assert_eq(reg.validate(), [], tag)
			_assert_devices_sound(tag)
			var newcomer = reg.seat(_id(90), false)
			assert_true(newcomer.ok, tag)
			assert_eq(newcomer.slot, count, "removed slot is never reused: %s" % tag)
			assert_eq(newcomer.player_index, count - 1, tag)


func test_remove_refuses_local_and_unknown_identities() -> void:
	_setup()
	_seat_all(4, 2)
	var before = var2str(reg.roster())
	var local = reg.remove(_id(2))
	assert_false(local.ok)
	assert_eq(local.reason, SlotRegistry.REASON_LOCAL_NOT_REMOVABLE)
	var unknown = reg.remove(_id(40))
	assert_false(unknown.ok)
	assert_eq(unknown.reason, SlotRegistry.REASON_UNKNOWN_IDENTITY)
	assert_eq(var2str(reg.roster()), before)
	assert_eq(reg.generation(), 0)
	# A failed remove hands back the identity remap: applying it by mistake
	# keeps every player's data where it is.
	for failed in [local, unknown]:
		assert_eq(var2str(failed.remap), var2str({0: 0, 1: 1, 2: 2, 3: 3}))
		assert_eq(failed.old_count, 4)
		assert_eq(failed.new_count, 4)
		assert_eq(failed.generation, 0)
		assert_eq(failed.released_device_id, NO_DEVICE)
		var applied = SlotRegistry.remap_array(["a", "b", "c", "d"], failed.remap, failed.old_count)
		assert_true(applied.ok)
		assert_eq(applied.values, ["a", "b", "c", "d"])


func test_removing_offline_player_frees_room_only_before_freeze() -> void:
	_setup(8)
	_seat_all(8)
	reg.disconnect_identity(_id(4))
	assert_true(reg.remove(_id(4)).ok)
	assert_eq(reg.roster_count(), 7)
	assert_true(reg.seat(_id(60), false).ok)
	reg.disconnect_identity(_id(5))
	assert_true(reg.freeze().ok)
	assert_true(reg.remove(_id(5)).ok)
	assert_eq(reg.generation(), 2)
	assert_eq(reg.seat(_id(61), false).reason, CapacityPolicy.REJECT_RUN_FROZEN)


func test_generation_changes_only_on_remove() -> void:
	_setup()
	_seat_all(4)
	reg.disconnect_identity(_id(1))
	reg.reconnect(_id(1))
	reg.seat(_id(9), false)
	reg.reserve_local_device(1)
	reg.release_local_device(1)
	assert_eq(reg.generation(), 0)
	reg.remove(_id(9))
	assert_eq(reg.generation(), 1)
	reg.remove(_id(1))
	assert_eq(reg.generation(), 2)


func test_owns_index_rejects_forged_and_out_of_range_indices() -> void:
	_setup()
	_seat_all(5)
	for n in range(5):
		for i in range(5):
			assert_eq(reg.owns_index(_id(n), i), n == i, "identity %d index %d" % [n, i])
		assert_true(reg.owns_index(_id(n), float(n)), "integral float from JSON")
	for bad in [-1, 5, 8, 100, "1", 1.5, null, true]:
		assert_false(reg.owns_index(_id(1), bad), var2str(bad))
		assert_eq(reg.identity_at_index(bad), "", var2str(bad))
	assert_false(reg.owns_index(_id(99), 0))
	assert_false(reg.owns_index(null, 0))
	reg.remove(_id(1))
	assert_true(reg.owns_index(_id(2), 1), "ownership follows the identity after a remap")
	assert_false(reg.owns_index(_id(2), 2))
	assert_false(reg.owns_index(_id(1), 1))


func test_validate_reports_pool_desync_and_freeze_refuses_it() -> void:
	_setup()
	_seat_all(4)
	pool.release(_id(2))
	assert_has(_codes(reg.validate()), SlotRegistry.VIOLATION_MISSING_DEVICE)
	var frozen = reg.freeze()
	assert_false(frozen.ok)
	assert_eq(frozen.reason, SlotRegistry.REASON_INVARIANT_VIOLATION)
	assert_has(_codes(frozen.get("violations", [])), SlotRegistry.VIOLATION_MISSING_DEVICE)
	assert_false(reg.is_frozen())
	var repaired = reg.rehome_devices()
	assert_true(repaired.ok)
	assert_eq(repaired.rehomed.size(), 1)
	assert_eq(repaired.rehomed[0].identity, _id(2))
	assert_eq(reg.validate(), [])
	pool.allocate("steam:ghost")
	assert_eq(_codes(reg.validate()), [SlotRegistry.VIOLATION_ORPHAN_DEVICE])
	pool.release("steam:ghost")
	reg.disconnect_identity(_id(3))
	pool.allocate(_id(3))
	assert_eq(_codes(reg.validate()), [SlotRegistry.VIOLATION_STALE_DEVICE])


func _entry(slot: int, identity: String, index: int, device: int, online: bool, is_local: bool) -> Dictionary:
	return {"slot": slot, "identity": identity, "player_index": index, "device_id": device, "online": online, "is_local": is_local}


func test_check_roster_detects_each_violation() -> void:
	var base := [
		_entry(0, "a", 0, NO_DEVICE, true, true),
		_entry(1, "b", 1, 1, true, false),
		_entry(4, "c", 2, NO_DEVICE, false, false),
	]
	assert_eq(SlotRegistry.check_roster(base, 8), [])
	var cases := []
	cases.append([[base[0], base[1], _entry(1, "c", 2, NO_DEVICE, false, false)], SlotRegistry.VIOLATION_DUPLICATE_SLOT])
	cases.append([[base[0], base[1], _entry(4, "c", 1, NO_DEVICE, false, false)], SlotRegistry.VIOLATION_DUPLICATE_INDEX])
	cases.append([[base[0], base[1], _entry(4, "c", 3, NO_DEVICE, false, false)], SlotRegistry.VIOLATION_INDEX_GAP])
	cases.append([[base[0], _entry(1, "b", 0, 1, true, false)], SlotRegistry.VIOLATION_INDEX_GAP])
	cases.append([[base[0], _entry(1, "b", 0, 1, true, false)], SlotRegistry.VIOLATION_DUPLICATE_INDEX])
	cases.append([[base[0], base[1], _entry(4, "c", 2, 1, true, false)], SlotRegistry.VIOLATION_DUPLICATE_DEVICE])
	cases.append([[base[0], base[1], _entry(4, "b", 2, NO_DEVICE, false, false)], SlotRegistry.VIOLATION_DUPLICATE_IDENTITY])
	cases.append([[base[0], base[1], _entry(4, "c", 2, NO_DEVICE, false, true)], SlotRegistry.VIOLATION_MULTIPLE_LOCAL])
	cases.append([[base[0], base[1], _entry(4, "c", 2, NO_DEVICE, true, false)], SlotRegistry.VIOLATION_MISSING_DEVICE])
	cases.append([[base[0], base[1], _entry(4, "c", 2, 3, false, false)], SlotRegistry.VIOLATION_STALE_DEVICE])
	cases.append([[_entry(0, "a", 0, 2, true, true), base[1]], SlotRegistry.VIOLATION_STALE_DEVICE])
	cases.append([[base[0], base[1], {"slot": 4, "identity": "c"}], SlotRegistry.VIOLATION_MALFORMED_ENTRY])
	cases.append([[base[0], base[1], "c"], SlotRegistry.VIOLATION_MALFORMED_ENTRY])
	var float_slot := _entry(4, "c", 2, NO_DEVICE, false, false)
	float_slot.slot = 4.0
	cases.append([[base[0], base[1], float_slot], SlotRegistry.VIOLATION_MALFORMED_ENTRY])
	for c in cases:
		assert_has(_codes(SlotRegistry.check_roster(c[0], 8)), c[1], var2str(c[0]))
	assert_has(_codes(SlotRegistry.check_roster(base, 2)), SlotRegistry.VIOLATION_OVER_CAPACITY)
	assert_has(_codes(SlotRegistry.check_roster("roster", 8)), SlotRegistry.VIOLATION_MALFORMED_ENTRY)
	# One player per machine: a roster without its local player may hold at
	# most capacity - 1 remote entries.
	var remote_only := [_entry(0, "a", 0, NO_DEVICE, false, false), _entry(1, "b", 1, NO_DEVICE, false, false)]
	assert_eq(SlotRegistry.check_roster(remote_only, 3), [])
	assert_eq(_codes(SlotRegistry.check_roster(remote_only, 2)), [SlotRegistry.VIOLATION_REMOTE_OVER_CAPACITY])
	assert_eq(_codes(SlotRegistry.check_roster([remote_only[0]], 1)), [SlotRegistry.VIOLATION_REMOTE_OVER_CAPACITY])
	# Details carry slots and indices, never identities (R21).
	var leaky := [
		_entry(0, "steam:secret", 0, 5, true, true),
		_entry(0, "steam:secret", 0, 5, true, true),
		_entry(1, "steam:other", 4, NO_DEVICE, true, false),
	]
	var leaks: Array = SlotRegistry.check_roster(leaky, 2)
	assert_true(leaks.size() >= 5, var2str(leaks))
	for v in leaks:
		assert_eq(v.detail.find("steam"), -1, v.detail)


func test_checkpoint_round_trip_through_bytes_and_json() -> void:
	_setup(8)
	_seat_all(7, 1)
	reg.remove(_id(3))
	reg.disconnect_identity(_id(5))
	assert_true(reg.freeze().ok)
	var data = reg.serialize()
	var expected := []
	for e in reg.roster():
		expected.append([e.slot, e.identity, e.player_index, e.is_local])
	var copies := [data, bytes2var(var2bytes(data), false), parse_json(to_json(data))]
	for k in range(copies.size()):
		var tag = "copy %d" % k
		_setup(8)
		var r = reg.deserialize(copies[k])
		assert_true(r.ok, "%s: %s" % [tag, r.reason])
		var got := []
		for e in reg.roster():
			got.append([e.slot, e.identity, e.player_index, e.is_local])
			assert_false(e.online, tag)
			assert_eq(e.device_id, NO_DEVICE, tag)
			assert_eq(typeof(e.slot), TYPE_INT, tag)
		assert_eq(var2str(got), var2str(expected), tag)
		assert_eq(reg.generation(), 1, tag)
		assert_eq(typeof(reg.generation()), TYPE_INT, tag)
		assert_eq(reg.next_slot(), 7, tag)
		assert_true(reg.is_frozen(), tag)
		assert_eq(reg.online_count(), 0, tag)
		# Everybody comes back in reverse order; seats follow identities.
		var order: Array = reg.roster()
		order.invert()
		for e in order:
			assert_true(reg.seat(e.identity, e.is_local).ok, tag)
		assert_eq(reg.player_index_of(_id(4)), 3, tag)
		assert_eq(reg.slot_of(_id(4)), 4, tag)
		_assert_devices_sound(tag)
		assert_eq(reg.validate(), [], tag)
		assert_eq(reg.seat(_id(70), false).reason, CapacityPolicy.REJECT_RUN_FROZEN, tag)


func _held_devices() -> Array:
	var out := []
	for e in reg.roster():
		if e.device_id != NO_DEVICE:
			out.append(e.device_id)
	out.sort()
	return out


func test_deserialize_releases_devices_held_before() -> void:
	_setup(8)
	_seat_all(5)
	var data = reg.serialize()
	# Same identities: their devices go back because everyone loads offline.
	assert_eq(pool.allocated_count(), 4)
	var held := _held_devices()
	var same = reg.deserialize(data)
	assert_true(same.ok)
	assert_eq(same.released_device_ids, held, "caller must learn which inputs to clear")
	assert_eq(pool.allocated_count(), 0)
	assert_eq(reg.validate(), [])
	# Different identities: the replaced players' devices must not leak.
	_setup(8)
	for n in range(10, 15):
		reg.seat(_id(n), n == 10)
	reg.disconnect_identity(_id(12))
	assert_eq(pool.allocated_count(), 3)
	held = _held_devices()
	var other = reg.deserialize(data)
	assert_true(other.ok)
	assert_eq(other.released_device_ids, held)
	assert_eq(pool.allocated_count(), 0)
	assert_eq(pool.owners(), [])
	assert_false(reg.has_identity(_id(11)))
	assert_eq(reg.validate(), [])


func test_deserialize_orders_entries_by_player_index() -> void:
	_setup(8)
	var data := _checkpoint([_row(5, "c", 2), _row(0, "a", 0, true), _row(3, "b", 1)])
	var r = reg.deserialize(data)
	assert_true(r.ok, r.reason)
	assert_eq(reg.identity_at_index(0), "a")
	assert_eq(reg.identity_at_index(1), "b")
	assert_eq(reg.identity_at_index(2), "c")
	assert_eq(reg.slot_of("c"), 5)
	assert_eq(reg.local_identity(), "a")
	assert_true(reg.seat("d", false).ok)
	assert_eq(reg.slot_of("d"), 8, "slot counter comes from the checkpoint")


func _checkpoint(entries: Array) -> Dictionary:
	return {"schema": 1, "capacity": 8, "next_slot": 8, "generation": 0, "frozen": false, "entries": entries}


func _row(slot, identity, index, is_local = false) -> Dictionary:
	return {"slot": slot, "identity": identity, "player_index": index, "is_local": is_local}


func _full_state() -> String:
	return var2str([reg.serialize(), reg.roster(), pool.snapshot()])


func test_deserialize_rejects_bad_checkpoints_and_keeps_state() -> void:
	_setup(8)
	_seat_all(3)
	reg.remove(_id(2))
	assert_true(reg.freeze().ok)
	var before := _full_state()
	var good := _checkpoint([_row(0, "a", 0, true), _row(1, "b", 1)])
	var cases := []
	cases.append([null, SlotRegistry.REASON_MALFORMED])
	cases.append([[], SlotRegistry.REASON_MALFORMED])
	var missing := good.duplicate(true)
	missing.erase("next_slot")
	cases.append([missing, SlotRegistry.REASON_MALFORMED])
	var schema := good.duplicate(true)
	schema.schema = 2
	cases.append([schema, SlotRegistry.REASON_UNSUPPORTED_SCHEMA])
	var schema_text := good.duplicate(true)
	schema_text.schema = "1"
	cases.append([schema_text, SlotRegistry.REASON_MALFORMED])
	var nine := []
	for i in range(9):
		nine.append(_row(i, "p%d" % i, i))
	cases.append([_checkpoint(nine), SlotRegistry.REASON_OVER_CAPACITY])
	var huge := []
	for i in range(1000):
		huge.append(i)
	cases.append([_checkpoint(huge), SlotRegistry.REASON_OVER_CAPACITY])
	var small := _checkpoint([_row(0, "a", 0), _row(1, "b", 1), _row(2, "c", 2)])
	small.capacity = 2
	cases.append([small, SlotRegistry.REASON_OVER_CAPACITY])
	var bad_capacity := good.duplicate(true)
	bad_capacity.capacity = 9
	cases.append([bad_capacity, SlotRegistry.REASON_MALFORMED])
	cases.append([_checkpoint([_row(0, "a", 0), _row(0, "b", 1)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1, "b", 0)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1, "b", 2)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1, "a", 1)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0, true), _row(1, "b", 1, true)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0), _row(8, "b", 1)]), SlotRegistry.REASON_INVARIANT_VIOLATION])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1.5, "b", 1)]), SlotRegistry.REASON_MALFORMED])
	cases.append([_checkpoint([_row(0, "a", 0), _row(-1, "b", 1)]), SlotRegistry.REASON_MALFORMED])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1, "", 1)]), SlotRegistry.REASON_MALFORMED])
	cases.append([_checkpoint([_row(0, "a", 0), _row(1, "b", 1, "yes")]), SlotRegistry.REASON_MALFORMED])
	cases.append([_checkpoint([_row(0, "a", 0), "b"]), SlotRegistry.REASON_MALFORMED])
	var negative_generation := good.duplicate(true)
	negative_generation.generation = -1
	cases.append([negative_generation, SlotRegistry.REASON_MALFORMED])
	var frozen_text := good.duplicate(true)
	frozen_text.frozen = "true"
	cases.append([frozen_text, SlotRegistry.REASON_MALFORMED])
	var frozen_empty := _checkpoint([])
	frozen_empty.frozen = true
	cases.append([frozen_empty, SlotRegistry.REASON_EMPTY_ROSTER])
	var frozen_remote_only := _checkpoint([_row(0, "a", 0), _row(1, "b", 1)])
	frozen_remote_only.frozen = true
	cases.append([frozen_remote_only, SlotRegistry.REASON_NO_LOCAL])
	var eight_remotes := []
	for i in range(8):
		eight_remotes.append(_row(i, "p%d" % i, i))
	cases.append([_checkpoint(eight_remotes), SlotRegistry.REASON_INVARIANT_VIOLATION])
	for c in cases:
		var r = reg.deserialize(c[0])
		assert_false(r.ok, var2str(c[0]).left(200))
		assert_eq(r.reason, c[1], var2str(c[0]).left(200))
		assert_eq(r.released_device_ids, [], var2str(c[0]).left(200))
		assert_eq(_full_state(), before, "state unchanged: %s" % var2str(c[0]).left(200))
	assert_true(reg.is_frozen())
	assert_eq(reg.generation(), 1)
	assert_eq(reg.next_slot(), 3)
	var dup = reg.deserialize(_checkpoint([_row(0, "a", 0), _row(0, "b", 1)]))
	assert_has(_codes(dup.violations), SlotRegistry.VIOLATION_DUPLICATE_SLOT)
	var counter = reg.deserialize(_checkpoint([_row(0, "a", 0), _row(8, "b", 1)]))
	assert_has(_codes(counter.violations), SlotRegistry.VIOLATION_SLOT_COUNTER)
	var remotes = reg.deserialize(_checkpoint(eight_remotes))
	assert_eq(_codes(remotes.violations), [SlotRegistry.VIOLATION_REMOTE_OVER_CAPACITY])
	var loaded = reg.deserialize(good)
	assert_true(loaded.ok, "the unmodified checkpoint loads")
	assert_eq(loaded.violations, [])
	assert_eq(reg.generation(), 0)
	assert_false(reg.is_frozen())


func test_checkpoint_over_smaller_session_capacity_is_refused() -> void:
	_setup(8)
	_seat_all(6)
	var data = reg.serialize()
	_setup(4)
	var r = reg.deserialize(data)
	assert_false(r.ok)
	assert_eq(r.reason, SlotRegistry.REASON_OVER_CAPACITY)
	assert_eq(reg.roster_count(), 0)


func test_local_device_plug_moves_remote_player_without_new_seats() -> void:
	_setup(8, EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	_seat_all(8)
	var seats = var2str(_seat_map())
	var victim := _id(2)
	var taken: int = reg.device_of(victim)
	var r = reg.reserve_local_device(taken)
	assert_true(r.ok)
	assert_eq(r.displaced, victim)
	assert_ne(r.new_device_id, NO_DEVICE)
	assert_ne(r.new_device_id, taken)
	assert_eq(reg.device_of(victim), r.new_device_id)
	assert_eq(var2str(_seat_map()), seats)
	assert_eq(reg.online_count(), 8)
	_assert_devices_sound("after plug")
	assert_eq(reg.validate(), [])
	var free_plug = reg.reserve_local_device(42)
	assert_true(free_plug.ok)
	assert_eq(free_plug.displaced, "")


func test_local_device_plug_without_spare_id_is_reported() -> void:
	_setup(6, ONLINE_PLACEHOLDERS, [0])
	_seat_all(6)
	var victim := _id(3)
	var taken: int = reg.device_of(victim)
	var r = reg.reserve_local_device(taken)
	assert_true(r.ok)
	assert_eq(r.displaced, victim)
	assert_eq(r.new_device_id, NO_DEVICE)
	assert_eq(r.rehome_reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE)
	assert_true(reg.is_online(victim), "the remote player is still connected")
	assert_eq(_codes(reg.validate()), [SlotRegistry.VIOLATION_MISSING_DEVICE])
	assert_false(reg.freeze().ok)
	var back = reg.release_local_device(taken)
	assert_true(back.ok)
	assert_eq(back.rehomed.size(), 1)
	assert_eq(back.rehomed[0].identity, victim)
	assert_eq(back.rehomed[0].device_id, taken)
	assert_eq(reg.validate(), [])
	assert_eq(reg.release_local_device(6).ok, true, "unplugging an id never reserved is harmless")
	assert_false(reg.reserve_local_device("0").ok)


func test_random_gamepad_replug_never_adds_or_moves_players() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	_setup(8, EXTENDED_CANDIDATES, COOP_REMAP_IDS)
	_seat_all(8)
	var seats = var2str(_seat_map())
	for step in range(300):
		var device := rng.randi_range(0, 3)
		if rng.randi_range(0, 1) == 0:
			reg.reserve_local_device(device)
		else:
			reg.release_local_device(device)
		var tag = "step %d" % step
		assert_eq(reg.roster_count(), 8, tag)
		assert_eq(var2str(_seat_map()), seats, tag)
		var homed := 0
		var seen := {}
		for e in reg.roster():
			if e.device_id != NO_DEVICE:
				homed += 1
				assert_false(seen.has(e.device_id), tag)
				assert_false(pool.is_reserved(e.device_id), tag)
				seen[e.device_id] = true
		assert_eq(homed, int(min(7, pool.usable_count())), "every remote with a usable id has one: %s" % tag)


func test_remap_array_refuses_inconsistent_input() -> void:
	var values := ["a", "b", "c"]
	var ok = SlotRegistry.remap_array(values, {0: 0, 2: 1}, 3)
	assert_true(ok.ok)
	assert_eq(ok.values, ["a", "c"])
	var bad := [
		[values, {0: 0, 2: 1}, 4],
		[["a", "b"], {0: 0, 2: 1}, 3],
		[values, {0: 0, 2: 0}, 3],
		[values, {0: 0, 3: 1}, 3],
		[values, {0: 0, 2: 2}, 3],
		[values, {"0": 0, "2": 1}, 3],
		[values, {0: 0.0, 2: 1.0}, 3],
		[values, {0: 0, 1: 1, 2: 2, 3: 3}, 3],
		# More than one index dropped: an emptied or foreign remap must never
		# wipe several players' data in one go (F01).
		[values, {}, 3],
		[values, {1: 0}, 3],
	]
	for c in bad:
		var r = SlotRegistry.remap_array(c[0], c[1], c[2])
		assert_false(r.ok, var2str(c))
		assert_eq(r.reason, SlotRegistry.REASON_BAD_REMAP, var2str(c))
		assert_eq(r.values, [], var2str(c))


func test_display_names_follow_player_index() -> void:
	for i in range(8):
		assert_eq(SlotRegistry.display_name_for_index(i), "P%d" % (i + 1))
	for bad in [-1, "1", null, 1.5]:
		assert_eq(SlotRegistry.display_name_for_index(bad), "", var2str(bad))
	_setup()
	_seat_all(3)
	reg.remove(_id(1))
	assert_eq(reg.display_name_of(_id(2)), "P2")
	assert_eq(reg.display_name_of(_id(1)), "")


func test_last_seat_is_kept_for_the_local_player() -> void:
	# One player per machine: remotes fill capacity - 1 seats at most, so a
	# remote that arrives before the local player cannot take its seat.
	for capacity in range(1, 9):
		_setup(capacity)
		for n in range(1, capacity):
			assert_true(reg.seat(_id(n), false).ok, "capacity %d remote %d" % [capacity, n])
		var extra = reg.seat(_id(50), false)
		assert_false(extra.ok, "capacity %d" % capacity)
		assert_eq(extra.reason, SlotRegistry.REASON_LOCAL_SEAT_RESERVED, "capacity %d" % capacity)
		assert_eq(pool.allocated_count(), capacity - 1, "no device leaked: capacity %d" % capacity)
		assert_eq(reg.next_slot(), capacity - 1, "no slot consumed: capacity %d" % capacity)
		var local = reg.seat(_id(0), true)
		assert_true(local.ok, "capacity %d: %s" % [capacity, local.reason])
		assert_eq(local.player_index, capacity - 1)
		assert_eq(local.display_name, "P%d" % capacity)
		assert_eq(reg.roster_count(), capacity)
		assert_eq(reg.validate(), [], "capacity %d" % capacity)
		assert_true(reg.freeze().ok, "capacity %d" % capacity)
		assert_eq(reg.seat(_id(51), false).reason, SlotRegistry.REASON_RUN_FROZEN, "capacity %d" % capacity)


func test_freeze_requires_the_local_player() -> void:
	_setup()
	for n in range(1, 4):
		assert_true(reg.seat(_id(n), false).ok)
	var r = reg.freeze()
	assert_false(r.ok)
	assert_eq(r.reason, SlotRegistry.REASON_NO_LOCAL)
	assert_eq(r.violations, [])
	assert_false(reg.is_frozen())
	assert_eq(reg.validate(), [], "a lobby still waiting for its local player is healthy")
	assert_true(reg.seat(_id(0), true).ok)
	assert_true(reg.freeze().ok)
	assert_eq(reg.seat(_id(9), true).reason, SlotRegistry.REASON_SECOND_LOCAL)


func test_freed_device_goes_to_waiting_player_before_anyone_else() -> void:
	for mode in ["disconnect", "remove"]:
		# Local gamepad on 0: five ids for five remote players.
		_setup(8, ONLINE_PLACEHOLDERS, [0])
		_seat_all(6)
		var victim := _id(3)
		var plug = reg.reserve_local_device(reg.device_of(victim))
		assert_eq(plug.rehome_reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE, mode)
		var freed: int = reg.device_of(_id(1))
		var r
		if mode == "disconnect":
			r = reg.disconnect_identity(_id(1))
		else:
			r = reg.remove(_id(1))
		assert_true(r.ok, mode)
		assert_eq(r.released_device_id, freed, mode)
		assert_eq(r.rehomed.size(), 1, mode)
		assert_eq(r.rehomed[0].identity, victim, mode)
		assert_eq(r.rehomed[0].device_id, freed, mode)
		assert_eq(r.unhomed, [], mode)
		assert_eq(reg.device_of(victim), freed, mode)
		assert_eq(reg.validate(), [], mode)
		_assert_devices_sound(mode)
		var newcomer = reg.seat(_id(20), false)
		assert_false(newcomer.ok, mode)
		assert_eq(newcomer.reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE, mode)
		if mode == "disconnect":
			assert_eq(reg.reconnect(_id(1)).reason, SlotRegistry.REASON_DEVICE_UNAVAILABLE)
	# Two players waiting, one id freed: the lower player_index goes first and
	# the other is still reported.
	_setup(8, ONLINE_PLACEHOLDERS, [0])
	_seat_all(6)
	reg.reserve_local_device(reg.device_of(_id(4)))
	reg.reserve_local_device(reg.device_of(_id(3)))
	var gone = reg.disconnect_identity(_id(5))
	assert_eq(gone.rehomed.size(), 1)
	assert_eq(gone.rehomed[0].identity, _id(3))
	assert_eq(gone.unhomed, [_id(4)])
	assert_eq(_codes(reg.validate()), [SlotRegistry.VIOLATION_MISSING_DEVICE])


func test_random_churn_never_leaves_a_free_id_while_someone_waits() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	# Seven usable ids for seven remotes, so every plug forces a shortage.
	_setup(8, ONLINE_PLACEHOLDERS + [8, 9], [0])
	_seat_all(8)
	var seats = var2str(_seat_map())
	for step in range(400):
		var op := rng.randi_range(0, 3)
		var who := _id(rng.randi_range(1, 7))
		var device := rng.randi_range(1, 5)
		if op == 0:
			reg.reserve_local_device(device)
		elif op == 1:
			reg.release_local_device(device)
		elif op == 2:
			reg.disconnect_identity(who)
		else:
			reg.reconnect(who)
		var tag = "step %d op %d" % [step, op]
		assert_eq(var2str(_seat_map()), seats, tag)
		var waiting := 0
		var seen := {}
		for e in reg.roster():
			if e.device_id != NO_DEVICE:
				assert_true(e.online and not e.is_local, tag)
				assert_false(seen.has(e.device_id), tag)
				assert_false(pool.is_reserved(e.device_id), tag)
				seen[e.device_id] = true
			elif e.online and not e.is_local:
				waiting += 1
		if waiting > 0:
			assert_eq(pool.free_count(), 0, "free id while %d players wait: %s" % [waiting, tag])
		assert_eq(pool.allocated_count(), seen.size(), tag)


func _keys(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


func test_results_keep_their_keys_on_failure() -> void:
	# Adapters read result fields without checking ok first; a key missing on
	# the failure path would be a runtime error in the game.
	_setup()
	var empty_freeze = reg.freeze()
	_seat_all(3)
	var pairs := []
	pairs.append(["seat", reg.seat(_id(5), false), reg.seat(_id(6), true)])
	pairs.append(["seat returning", reg.seat(_id(5), false), reg.seat(_id(5), true)])
	pairs.append(["disconnect", reg.disconnect_identity(_id(5)), reg.disconnect_identity(null)])
	pairs.append(["reconnect", reg.reconnect(_id(5)), reg.reconnect("steam:nobody")])
	pairs.append(["remove", reg.remove(_id(5)), reg.remove(_id(0))])
	pairs.append(["freeze", reg.freeze(), empty_freeze])
	var other = SlotRegistry.new(CapacityPolicy.new(8), VirtualDevicePool.new(EXTENDED_CANDIDATES, COOP_REMAP_IDS))
	pairs.append(["deserialize", other.deserialize(reg.serialize()), other.deserialize(null)])
	pairs.append(["reserve_local_device", reg.reserve_local_device(1), reg.reserve_local_device("1")])
	pairs.append(["release_local_device", reg.release_local_device(1), reg.release_local_device(null)])
	pairs.append(["rehome_devices", reg.rehome_devices(), SlotRegistry.new().rehome_devices()])
	pairs.append(["check_setup", reg.check_setup(), SlotRegistry.new().check_setup()])
	for p in pairs:
		assert_true(p[1].ok, "%s success: %s" % [p[0], p[1].reason])
		assert_false(p[2].ok, "%s failure" % p[0])
		assert_eq(_keys(p[2]), _keys(p[1]), p[0])
