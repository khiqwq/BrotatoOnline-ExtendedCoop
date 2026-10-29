extends Reference
# Replay harness for application events (AP-008; F01 F05 F06 F08 F11, T05 T06
# T08 T11). Feeds an event list through the pure rule modules the way the host
# adapter is meant to use them:
#   slot_registry + virtual_device_pool   seats, devices, removal remaps
#   flow_guard                            run/wave/phase/roster stamps
#   ready_barrier                         phase confirmations, R18 timing
#   payload_guard                         message shape and size limits
#   action_ledger                         menu actions executed once
# plus a toy economy (gold, items, upgrades, chests, rerolls, locks) kept in
# Arrays indexed by player_index like the game's own data, so a missing or
# partial remap shows up as gold or items following the wrong player (F11).
# The toy takes prices from the message; a real host prices items itself.
# run() returns a deterministic digest: the committed state (roster,
# generations, committed actions with execution counts, economy, barrier
# outcomes, phase commits) and a log line per event (status, layer, reason),
# which locates duplicates, old generations and ownership violations by event.
# Test support only: lives under tests/, never packaged.
#
# FIXTURE (JSON in tests/fixtures/events/, or the same Dictionary built in
# code), format version 1:
#   {"format": "coopplus_event_replay", "version": 1,
#    "name": String, "description": String,    optional
#    "seed": int,                               optional, for fault plans
#    "session": {...},                          optional, see below
#    "events": [event, ...],                    1..MAX_EVENTS
#    "expect": {...}}                           optional; ignored here, read
#                                               by tests/unit/replay
# Unknown keys in a fixture, its session or an event are refused, so a typo
# cannot quietly drop a field. JSON: load_fixture() turns every integral
# number into an int (parse_json gives floats); write {"$float": 2} for 2.0.
#
# SESSION, all optional: capacity 8, session_id "session", start_gold 30,
#   device_candidates [1, 2, 3, 4, 5, 0, 8, 9, 10, 11] and device_reserved
#   [6, 7] (placeholders until the upstream audit), hint_after_msec 10000 and
#   timeout_msec 30000 (R18), ledger_max_entries 512,
#   ledger_max_entries_per_sender 64. Values are handed to the modules, which
#   judge them (an invalid capacity gives an invalid registry, not an error).
#
# EVENT {"type": T, ...}. Any event may carry:
#   "t"      host receive time in msec. The clock is the largest t so far (an
#            event without t happens at the current clock); the open barrier
#            is polled at the clock before every event.
#   "eid"    stable id, default its position; debug/fault_injection.gd copies
#            keep the eid of their source
#   "label"  names the flow stamp right after this event, for "@label"
#   "fault"  set by the fault injector on events it made or changed
#   "note"   free text
# Host events, the host's own decisions and transport notifications:
#   join {identity, local}          seat(); local defaults to false
#   disconnect / reconnect / remove {identity}
#   freeze                          registry.freeze()
#   device_plug / device_unplug {device_id}     local gamepad (F03)
#   begin_run {run_id}              flow.begin_run(); the roster generation is
#                                   then re-asserted from the registry
#   advance {wave, phase, requires} flow.advance(); with "requires" only when
#                                   that key was committed in the current
#                                   stamp (else phase_not_committed): the host
#                                   moves on because its barrier completed
#   barrier {key}                   ready barrier over every seated slot for
#                                   the current stamp (offline ones included).
#                                   One barrier per stamp; a retry advances
#                                   first (else barrier_stamp_reused)
#   drop_expected {identity}        the host stops waiting for that slot
#   tick                            only moves the clock
# Messages, what a client sent as the host receives it:
#   ready {from, ...}               a phase confirmation
#   action {from, kind, ...}        buy / sell / reroll / lock / upgrade / chest
#   "from" is the identity the transport authenticated, never payload data. A
#   message is LITERAL, {"payload": <wire Dictionary or any value>}, delivered
#   exactly as given, or AUTHORED and resolved when the host receives it:
#     "stamp"         "current" (default): the committed stamp at that moment;
#                     "@label": a labelled earlier stamp; or a Dictionary
#     "player_index"  "self" (default): the sender's index at that moment
#     "action_id"     "auto" (default): one above the sender's highest id
#                     so far                                    (action only)
#     "kind", "body"  kind and body fields                      (action only)
#   run() returns every event in literal form ("events"), and replaying that
#   list gives the same digest. Faults go on literal events: a reordered or
#   replayed message must keep the stamp it was sent with.
# Wire payload: {"kind", "action_id", "player_index", "stamp", <body fields>};
# ready has no action_id. schema_for(kind) is its payload_guard schema.
#
# HOST PIPELINE for a message; the first refusal wins and nothing after it runs
#   session  sender seated, then online     sender_not_seated / sender_offline
#   payload  payload_guard.validate(schema_for(kind), {"roster_count": n})
#   flow     flow_guard.check_stamp(stamp): only the committed stamp passes;
#            "ahead" messages are dropped too (on the host they can only be
#            forged or a bug)
#   ready    registry.owns_index(sender, player_index), barrier.mark_ready(
#            slot); a complete barrier then commits its key with commit_for()
#            on every confirmation, so only the first commit counts (F06)
#   action   action_ledger.check() in the scope of the current stamp, with
#            owns_index() as ownership and a fingerprint of the body; only
#            STATUS_NEW executes, and its result (also a refusal such as
#            no_gold) is committed at once
# Every stamp change (begin_run, advance, a remove's new roster generation)
# closes the barrier and opens a new ledger scope; remove() applies its remap
# to every economy Array in one step.
# Log statuses: applied, unchanged (host op without effect), duplicate (a
# repeat recognised by the ledger or the barrier), rejected.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const VirtualDevicePool = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/virtual_device_pool.gd")
const SlotRegistry = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/slot_registry.gd")
const FlowGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/flow_guard.gd")
const ReadyBarrier = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/ready_barrier.gd")
const ActionLedger = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/action_ledger.gd")
const PayloadGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/payload_guard.gd")

const FORMAT := "coopplus_event_replay"
const FORMAT_VERSION := 1
const MAX_EVENTS := 50000
const MAX_LABEL_LENGTH := 64
const MAX_SESSION_ID_LENGTH := 64
const MAX_START_GOLD := 1000000
const MAX_JSON_DEPTH := 64
const FLOAT_MARKER := "$float"

const TYPE_JOIN := "join"
const TYPE_DISCONNECT := "disconnect"
const TYPE_RECONNECT := "reconnect"
const TYPE_REMOVE := "remove"
const TYPE_FREEZE := "freeze"
const TYPE_DEVICE_PLUG := "device_plug"
const TYPE_DEVICE_UNPLUG := "device_unplug"
const TYPE_BEGIN_RUN := "begin_run"
const TYPE_ADVANCE := "advance"
const TYPE_BARRIER := "barrier"
const TYPE_DROP_EXPECTED := "drop_expected"
const TYPE_TICK := "tick"
const TYPE_READY := "ready"
const TYPE_ACTION := "action"
const MESSAGE_TYPES := [TYPE_READY, TYPE_ACTION]
# Host events after which earlier messages carry an old stamp.
const FLOW_TYPES := [TYPE_BEGIN_RUN, TYPE_ADVANCE, TYPE_REMOVE]

const KIND_READY := "ready"
const KIND_BUY := "buy"
const KIND_SELL := "sell"
const KIND_REROLL := "reroll"
const KIND_LOCK := "lock"
const KIND_UPGRADE := "upgrade"
const KIND_CHEST := "chest"
const ACTION_KINDS := [KIND_BUY, KIND_SELL, KIND_REROLL, KIND_LOCK, KIND_UPGRADE, KIND_CHEST]
const ENVELOPE_KEYS := ["kind", "action_id", "player_index", "stamp"]

const STAMP_CURRENT := "current"
const LABEL_PREFIX := "@"
const INDEX_SELF := "self"
const ACTION_ID_AUTO := "auto"

const STATUS_APPLIED := "applied"
const STATUS_UNCHANGED := "unchanged"
const STATUS_DUPLICATE := "duplicate"
const STATUS_REJECTED := "rejected"
const STATUSES := [STATUS_APPLIED, STATUS_UNCHANGED, STATUS_DUPLICATE, STATUS_REJECTED]

const LAYER_NONE := ""
const LAYER_HOST := "host"
const LAYER_SESSION := "session"
const LAYER_PAYLOAD := "payload"
const LAYER_FLOW := "flow"
const LAYER_OWNER := "owner"
const LAYER_LEDGER := "ledger"
const LAYER_BARRIER := "barrier"

const REASON_NONE := ""
# The fixture itself is refused (run() returns ok = false, no digest).
const REASON_NOT_A_FIXTURE := "not_a_fixture"
const REASON_UNSUPPORTED_FORMAT := "unsupported_fixture_format"
const REASON_BAD_SESSION := "bad_session_config"
const REASON_BAD_EVENT := "bad_event"
const REASON_UNKNOWN_LABEL := "unknown_stamp_label"
const REASON_TOO_MANY_EVENTS := "too_many_events"
const REASON_UNREADABLE := "fixture_unreadable"
const REASON_NOT_JSON := "fixture_not_json"
# Host-side refusals this harness adds to the modules' own reasons.
const REASON_SENDER_NOT_SEATED := "sender_not_seated"
const REASON_SENDER_OFFLINE := "sender_offline"
const REASON_UNKNOWN_KIND := "unknown_action_kind"
const REASON_NOT_OWNER := ActionLedger.REASON_NOT_OWNER
const REASON_NO_BARRIER := "no_open_barrier"
const REASON_BARRIER_STAMP_REUSED := "barrier_stamp_reused"
const REASON_PHASE_NOT_COMMITTED := "phase_not_committed"
const REASON_REMAP_FAILED := "economy_remap_failed"
# Committed refusals of the toy economy.
const RESULT_NO_GOLD := "no_gold"
const RESULT_NO_ITEM := "no_item"

const PHASE_WAVE := "wave"
const PHASE_UPGRADE := "upgrade"
const PHASE_SHOP := "shop"
const KEY_CLOSE_UPGRADE := "close_upgrade"
const KEY_START_WAVE := "start_wave"

const DEFAULT_START_GOLD := 30
const MAX_SHOP_SLOT := 5
const MAX_PRICE := 999
const MAX_ITEM_LENGTH := 32
const MAX_UPGRADE_CHOICE := 3
const CHEST_RECYCLE_GOLD := 1
const UPGRADE_STATS := ["max_hp", "damage", "speed", "armor"]
const ECONOMY_KEYS := ["gold", "items", "upgrades", "chests", "rerolls", "locks"]
# Base of the made-up Steam ids generate_fixture() and the fixtures use.
const FAKE_STEAM_BASE := 76561198000000001

const FIXTURE_KEYS := ["format", "version", "name", "description", "seed", "session", "events", "expect"]
const SESSION_KEYS := ["capacity", "session_id", "start_gold", "device_candidates", "device_reserved", "hint_after_msec", "timeout_msec", "ledger_max_entries", "ledger_max_entries_per_sender"]
const SESSION_INT_KEYS := ["capacity", "start_gold", "hint_after_msec", "timeout_msec", "ledger_max_entries", "ledger_max_entries_per_sender"]
const SESSION_ARRAY_KEYS := ["device_candidates", "device_reserved"]
const COMMON_EVENT_KEYS := ["type", "t", "eid", "label", "fault", "note"]
const AUTHORED_KEYS := ["stamp", "player_index", "action_id", "kind", "body"]
const EVENT_KEYS := {
	TYPE_JOIN: ["identity", "local"],
	TYPE_DISCONNECT: ["identity"],
	TYPE_RECONNECT: ["identity"],
	TYPE_REMOVE: ["identity"],
	TYPE_FREEZE: [],
	TYPE_DEVICE_PLUG: ["device_id"],
	TYPE_DEVICE_UNPLUG: ["device_id"],
	TYPE_BEGIN_RUN: ["run_id"],
	TYPE_ADVANCE: ["wave", "phase", "requires"],
	TYPE_BARRIER: ["key"],
	TYPE_DROP_EXPECTED: ["identity"],
	TYPE_TICK: [],
	TYPE_READY: ["from", "payload", "stamp", "player_index"],
	TYPE_ACTION: ["from", "payload", "stamp", "player_index", "action_id", "kind", "body"],
}
const REQUIRED_EVENT_KEYS := {
	TYPE_JOIN: ["identity"],
	TYPE_DISCONNECT: ["identity"],
	TYPE_RECONNECT: ["identity"],
	TYPE_REMOVE: ["identity"],
	TYPE_DEVICE_PLUG: ["device_id"],
	TYPE_DEVICE_UNPLUG: ["device_id"],
	TYPE_BEGIN_RUN: ["run_id"],
	TYPE_ADVANCE: ["wave", "phase"],
	TYPE_BARRIER: ["key"],
	TYPE_DROP_EXPECTED: ["identity"],
	TYPE_READY: ["from"],
	TYPE_ACTION: ["from"],
}

var _session := {}
var _registry = null
var _pool = null
var _flow = null
var _guard = null
var _ledger = null
# The open barrier always belongs to the current stamp (closed on any change).
var _barrier = null
var _barrier_info := {}
var _barriers := []
var _barrier_seqs := {}
var _phase_commits := []
var _commit_refusals := []
# name -> Array indexed by player_index
var _economy := {}
# "<sender>|<stamp seq>|<action_id>" -> committed action record / executions
var _actions := {}
var _executions := {}
var _log := []
var _literal := []
var _labels := {}
var _last_action_id := {}
var _clock := 0
var _setup := {}


# Result keys are the same on success and failure:
#   ok, reason, at (event position of a fixture problem, else -1), field,
#   events (literal form), committed, digest, committed_hash, digest_hash
# committed_hash covers the committed state only, so runs that differ only in
# rejected or repeated messages share it; digest_hash covers everything.
func run(fixture) -> Dictionary:
	var checked := check_fixture(fixture)
	if not checked.ok:
		return {"ok": false, "reason": checked.reason, "at": checked.at, "field": checked.field, "events": [], "committed": {}, "digest": {}, "committed_hash": "", "digest_hash": ""}
	var session := default_session()
	var raw: Dictionary = fixture.get("session", {})
	for key in raw:
		session[key] = _copy(raw[key])
	_start(session)
	var events: Array = fixture.events
	for at in range(events.size()):
		_process(at, events[at])
	return _finish()


static func default_session() -> Dictionary:
	return {
		"capacity": CapacityPolicy.MAX_SUPPORTED_PLAYERS,
		"session_id": "session",
		"start_gold": DEFAULT_START_GOLD,
		"device_candidates": [1, 2, 3, 4, 5, 0, 8, 9, 10, 11],
		"device_reserved": [6, 7],
		"hint_after_msec": ReadyBarrier.DEFAULT_HINT_AFTER_MSEC,
		"timeout_msec": ReadyBarrier.DEFAULT_TIMEOUT_MSEC,
		"ledger_max_entries": ActionLedger.DEFAULT_MAX_ENTRIES,
		"ledger_max_entries_per_sender": ActionLedger.DEFAULT_MAX_ENTRIES_PER_SENDER,
	}


# Body fields of each kind, as payload_guard specs.
static func body_specs(kind) -> Dictionary:
	var shop_slot := {"type": "int", "min": 0, "max": MAX_SHOP_SLOT}
	var price := {"type": "int", "min": 0, "max": MAX_PRICE}
	var item := {"type": "string", "min_len": 1, "max_len": MAX_ITEM_LENGTH}
	if kind == KIND_BUY:
		return {"shop_slot": shop_slot, "item": item, "cost": price}
	if kind == KIND_SELL:
		return {"item": item, "value": price}
	if kind == KIND_REROLL:
		return {"cost": price}
	if kind == KIND_LOCK:
		return {"shop_slot": shop_slot, "locked": {"type": "bool"}}
	if kind == KIND_UPGRADE:
		return {"choice": {"type": "int", "min": 0, "max": MAX_UPGRADE_CHOICE}, "stat": item}
	if kind == KIND_CHEST:
		return {"item": item, "take": {"type": "bool"}}
	return {}


# payload_guard schema of a wire payload, {} for an unknown kind.
static func schema_for(kind) -> Dictionary:
	if typeof(kind) != TYPE_STRING or not (kind == KIND_READY or kind in ACTION_KINDS):
		return {}
	var fields := {"kind": {"type": "string", "allowed": [kind]}}
	if kind != KIND_READY:
		fields["action_id"] = {"type": "int", "min": 1, "max": ActionLedger.MAX_ACTION_ID}
	fields["player_index"] = {"type": "player_index"}
	fields["stamp"] = {"type": "dict", "fields": {
		"run_id": {"type": "string", "min_len": 1, "max_len": FlowGuard.MAX_RUN_ID_LENGTH},
		"wave": {"type": "int", "min": 0, "max": FlowGuard.MAX_EXACT_INT},
		"phase": {"type": "string", "min_len": 1, "max_len": FlowGuard.MAX_PHASE_LENGTH},
		"roster_generation": {"type": "int", "min": 0, "max": FlowGuard.MAX_EXACT_INT},
		"seq": {"type": "int", "min": 1, "max": FlowGuard.MAX_EXACT_INT},
	}}
	var body := body_specs(kind)
	for name in body:
		fields[name] = body[name]
	return {"type": "dict", "fields": fields}


static func identity_for(index: int) -> String:
	return "steam:" + str(FAKE_STEAM_BASE + index)


# Reads a JSON fixture and normalises its numbers (see normalize_json()).
# Result: {"ok", "reason", "fixture"}.
static func load_fixture(path: String) -> Dictionary:
	var f := File.new()
	if f.open(path, File.READ) != OK:
		return {"ok": false, "reason": REASON_UNREADABLE, "fixture": {}}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		return {"ok": false, "reason": REASON_NOT_JSON, "fixture": {}}
	return {"ok": true, "reason": REASON_NONE, "fixture": normalize_json(parsed.result)}


# JSON numbers -> real types: an integral finite float up to 2^53 - 1 becomes
# an int; {"$float": x} becomes the float x; everything else is kept.
static func normalize_json(value, depth: int = 0):
	if depth > MAX_JSON_DEPTH:
		return value
	var t := typeof(value)
	if t == TYPE_REAL:
		if not is_nan(value) and not is_inf(value) and value == floor(value) and abs(value) <= FlowGuard.MAX_EXACT_INT:
			return int(value)
		return value
	if t == TYPE_ARRAY:
		var items := []
		for v in value:
			items.append(normalize_json(v, depth + 1))
		return items
	if t == TYPE_DICTIONARY:
		if value.size() == 1 and value.has(FLOAT_MARKER):
			var number = value[FLOAT_MARKER]
			if typeof(number) == TYPE_INT or typeof(number) == TYPE_REAL:
				return float(number)
		var fields := {}
		for key in value:
			fields[key] = normalize_json(value[key], depth + 1)
		return fields
	return value


# Copy of fixture with another event list (e.g. a fault-injected one). The
# "expect" block belongs to the original list and is dropped.
static func with_events(fixture: Dictionary, events: Array) -> Dictionary:
	var copy: Dictionary = fixture.duplicate(true)
	copy["events"] = events.duplicate(true)
	copy.erase("expect")
	return copy


# Static shape check: {"ok", "reason", "at", "field"}. Values handed to typed
# parameters of the rule modules (run_id, wave, phase, keys) must have that
# type, because a wrong type there is undefined in release builds; values
# the modules check themselves (identities, device ids, payloads) may be
# anything, so fixtures can probe those checks.
static func check_fixture(fixture) -> Dictionary:
	if typeof(fixture) != TYPE_DICTIONARY:
		return _problem(REASON_NOT_A_FIXTURE, -1, "")
	for key in fixture:
		if typeof(key) != TYPE_STRING or not (key in FIXTURE_KEYS):
			return _problem(REASON_NOT_A_FIXTURE, -1, _key_name(key))
	var format = fixture.get("format")
	var version = fixture.get("version")
	if typeof(format) != TYPE_STRING or format != FORMAT or typeof(version) != TYPE_INT or version != FORMAT_VERSION:
		return _problem(REASON_UNSUPPORTED_FORMAT, -1, "version")
	for key in ["name", "description"]:
		if fixture.has(key) and typeof(fixture[key]) != TYPE_STRING:
			return _problem(REASON_NOT_A_FIXTURE, -1, key)
	if fixture.has("seed") and typeof(fixture.seed) != TYPE_INT:
		return _problem(REASON_NOT_A_FIXTURE, -1, "seed")
	var session_field := _session_problem(fixture.get("session", {}))
	if session_field != "":
		return _problem(REASON_BAD_SESSION, -1, session_field)
	var events = fixture.get("events")
	if typeof(events) != TYPE_ARRAY or events.empty():
		return _problem(REASON_NOT_A_FIXTURE, -1, "events")
	if events.size() > MAX_EVENTS:
		return _problem(REASON_TOO_MANY_EVENTS, -1, "events")
	var labels := {}
	for at in range(events.size()):
		var problem := _event_problem(events[at], labels)
		if problem.reason != REASON_NONE:
			return _problem(problem.reason, at, problem.field)
	return _problem(REASON_NONE, -1, "")


# Scenario builder for parameterised tests: player_count seats (index 0 is the
# local player), freeze, begin_run, then per wave: wave -> upgrade (one upgrade
# and one chest per player, close_upgrade barrier) -> shop (1..3 shop actions
# per player, start_wave barrier) -> next wave. Every advance after a barrier
# requires its key. Messages are authored; the senders' messages interleave
# randomly but each sender's order is kept. Same arguments, same fixture.
static func generate_fixture(player_count: int, waves: int, seed_value: int, capacity: int = 8) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var ids := []
	for i in range(player_count):
		ids.append(identity_for(i))
	var events := []
	var t := 0
	for i in range(player_count):
		var join := {"type": TYPE_JOIN, "identity": ids[i], "t": t}
		if i == 0:
			join["local"] = true
		events.append(join)
		t += 100
	events.append({"type": TYPE_FREEZE, "t": t})
	t += 900
	events.append({"type": TYPE_BEGIN_RUN, "run_id": "run-%d" % seed_value, "t": t})
	var owned := []
	for _i in range(player_count):
		owned.append([])
	var requires := ""
	for wave in range(1, waves + 1):
		t += 1000
		events.append(_advance_event(wave, PHASE_WAVE, requires, t))
		t += 20000
		events.append(_advance_event(wave, PHASE_UPGRADE, "", t))
		var queues := []
		for i in range(player_count):
			var choice: int = rng.randi_range(0, MAX_UPGRADE_CHOICE)
			var take: bool = rng.randi_range(0, 1) == 1
			queues.append([
				_action_event(ids[i], KIND_UPGRADE, {"choice": choice, "stat": UPGRADE_STATS[choice]}),
				_action_event(ids[i], KIND_CHEST, {"item": "chest_%d_%d" % [wave, i], "take": take}),
			])
		t = _append_messages(events, _interleave(queues, rng), t, rng)
		t = _append_barrier(events, KEY_CLOSE_UPGRADE, ids, t, rng)
		events.append(_advance_event(wave, PHASE_SHOP, KEY_CLOSE_UPGRADE, t))
		queues = []
		for i in range(player_count):
			var queue := []
			for _n in range(rng.randi_range(1, 3)):
				queue.append(_shop_action(ids[i], owned[i], rng))
			queues.append(queue)
		t = _append_messages(events, _interleave(queues, rng), t, rng)
		t = _append_barrier(events, KEY_START_WAVE, ids, t, rng)
		requires = KEY_START_WAVE
	events.append(_advance_event(waves + 1, PHASE_WAVE, requires, t + 1000))
	return {
		"format": FORMAT,
		"version": FORMAT_VERSION,
		"name": "generated_%d_players_seed_%d" % [player_count, seed_value],
		"seed": seed_value,
		"session": {"capacity": capacity, "session_id": "gen-%d" % seed_value},
		"events": events,
	}


func _start(session: Dictionary) -> void:
	_session = session
	_pool = VirtualDevicePool.new(session.device_candidates, session.device_reserved)
	_registry = SlotRegistry.new(CapacityPolicy.new(session.capacity), _pool)
	_flow = FlowGuard.new()
	_guard = PayloadGuard.new()
	_ledger = ActionLedger.new(session.ledger_max_entries, session.ledger_max_entries_per_sender)
	_barrier = null
	_barrier_info = {}
	_barriers = []
	_barrier_seqs = {}
	_phase_commits = []
	_commit_refusals = []
	_economy = {}
	for name in ECONOMY_KEYS:
		_economy[name] = []
	_actions = {}
	_executions = {}
	_log = []
	_literal = []
	_labels = {}
	_last_action_id = {}
	_clock = 0
	var setup = _registry.check_setup()
	_setup = {
		"ok": setup.ok,
		"reason": setup.reason,
		"remote_capacity": setup.remote_capacity,
		"usable_devices": setup.usable_devices,
		"shortfall": setup.shortfall,
		"pool_errors": _pool.config_errors(),
	}


func _process(at: int, event: Dictionary) -> void:
	var t = event.get("t")
	if typeof(t) == TYPE_INT and t > _clock:
		_clock = t
	if _barrier != null:
		var _state = _barrier.poll(_clock)
	var type: String = event.type
	var literal: Dictionary = event.duplicate(true)
	var outcome: Dictionary
	if type in MESSAGE_TYPES:
		var payload = _payload_of(event)
		for key in AUTHORED_KEYS:
			literal.erase(key)
		literal["payload"] = _copy(payload)
		outcome = _deliver(type, event.from, payload)
	else:
		outcome = _host_event(type, event)
	literal["eid"] = event.get("eid", at)
	_literal.append(literal)
	_log.append({
		"at": at,
		"eid": literal.eid,
		"type": type,
		"from": event.get("from", ""),
		"fault": event.get("fault", ""),
		"t": _clock,
		"status": outcome.status,
		"layer": outcome.layer,
		"reason": outcome.reason,
	})
	if event.has("label"):
		_labels[event.label] = _flow.stamp()


# Wire payload of a message event: as given when literal, else resolved now.
func _payload_of(event: Dictionary):
	if event.has("payload"):
		return _copy(event.payload)
	var sender: String = event.from
	var p := {}
	if event.type == TYPE_ACTION:
		p["kind"] = _copy(event.kind)
		p["action_id"] = _resolve_action_id(sender, event.get("action_id", ACTION_ID_AUTO))
	else:
		p["kind"] = KIND_READY
	p["player_index"] = _resolve_index(sender, event.get("player_index", INDEX_SELF))
	p["stamp"] = _resolve_stamp(event.get("stamp", STAMP_CURRENT))
	var body: Dictionary = event.get("body", {})
	for name in body:
		p[name] = _copy(body[name])
	return p


func _resolve_action_id(sender: String, value):
	var last := int(_last_action_id.get(sender, 0))
	var id = value
	if typeof(value) == TYPE_STRING and value == ACTION_ID_AUTO:
		id = last + 1
	if typeof(id) == TYPE_INT and id > last:
		_last_action_id[sender] = id
	return id


func _resolve_index(sender: String, value):
	if typeof(value) == TYPE_STRING and value == INDEX_SELF:
		return _registry.player_index_of(sender)
	return _copy(value)


func _resolve_stamp(value):
	if typeof(value) == TYPE_DICTIONARY:
		return value.duplicate(true)
	if value == STAMP_CURRENT:
		return _flow.stamp()
	var label: String = value.substr(LABEL_PREFIX.length(), value.length() - LABEL_PREFIX.length())
	if _labels.has(label):
		return _labels[label].duplicate()
	return {}


func _deliver(type: String, sender: String, payload) -> Dictionary:
	if not _registry.has_identity(sender):
		return _rejected(LAYER_SESSION, REASON_SENDER_NOT_SEATED)
	if not _registry.is_online(sender):
		return _rejected(LAYER_SESSION, REASON_SENDER_OFFLINE)
	if type == TYPE_READY:
		return _deliver_ready(sender, payload)
	return _deliver_action(sender, payload)


func _deliver_ready(sender: String, payload) -> Dictionary:
	var shape = _guard.validate(payload, schema_for(KIND_READY), _guard_context())
	if not shape.ok:
		return _rejected(LAYER_PAYLOAD, shape.reason)
	var verdict = _flow.check_stamp(payload.stamp)
	if not verdict.accepted:
		return _rejected(LAYER_FLOW, verdict.reason)
	if not _registry.owns_index(sender, payload.player_index):
		return _rejected(LAYER_OWNER, REASON_NOT_OWNER)
	if _barrier == null:
		return _rejected(LAYER_BARRIER, REASON_NO_BARRIER)
	var r = _barrier.mark_ready(_registry.slot_of(sender), payload.stamp)
	if not r.ok:
		return _rejected(LAYER_BARRIER, r.reason)
	_try_phase_commit()
	if r.changed:
		return _applied()
	return _outcome(STATUS_DUPLICATE, LAYER_BARRIER, r.reason)


func _deliver_action(sender: String, payload) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return _rejected(LAYER_PAYLOAD, PayloadGuard.REASON_WRONG_TYPE)
	var kind = payload.get("kind")
	if typeof(kind) != TYPE_STRING or not (kind in ACTION_KINDS):
		return _rejected(LAYER_PAYLOAD, REASON_UNKNOWN_KIND)
	var shape = _guard.validate(payload, schema_for(kind), _guard_context())
	if not shape.ok:
		return _rejected(LAYER_PAYLOAD, shape.reason)
	var verdict = _flow.check_stamp(payload.stamp)
	if not verdict.accepted:
		return _rejected(LAYER_FLOW, verdict.reason)
	var owns: bool = _registry.owns_index(sender, payload.player_index)
	var scope := _scope_key(_flow.stamp())
	var c = _ledger.check(scope, sender, payload.action_id, payload.player_index, owns, _fingerprint(kind, payload))
	if c.status == ActionLedger.STATUS_REJECTED:
		return _rejected(LAYER_LEDGER, c.reason)
	if c.status != ActionLedger.STATUS_NEW:
		return _outcome(STATUS_DUPLICATE, LAYER_LEDGER, c.status)
	var result := _execute(kind, payload)
	var committed = _ledger.commit(scope, sender, payload.action_id, result)
	_record_action(sender, kind, payload, result)
	if not committed.ok:
		return _outcome(STATUS_APPLIED, LAYER_LEDGER, committed.reason)
	return _applied()


func _host_event(type: String, e: Dictionary) -> Dictionary:
	if type == TYPE_JOIN:
		return _join(e)
	if type == TYPE_DISCONNECT:
		return _registry_change(_registry.disconnect_identity(e.identity))
	if type == TYPE_RECONNECT:
		return _registry_change(_registry.reconnect(e.identity))
	if type == TYPE_REMOVE:
		return _remove(e)
	if type == TYPE_FREEZE:
		return _registry_change(_registry.freeze())
	if type == TYPE_DEVICE_PLUG:
		var plugged = _registry.reserve_local_device(e.device_id)
		return _applied() if plugged.ok else _rejected(LAYER_HOST, plugged.reason)
	if type == TYPE_DEVICE_UNPLUG:
		var unplugged = _registry.release_local_device(e.device_id)
		return _applied() if unplugged.ok else _rejected(LAYER_HOST, unplugged.reason)
	if type == TYPE_BEGIN_RUN:
		return _begin_run(e)
	if type == TYPE_ADVANCE:
		return _advance(e)
	if type == TYPE_BARRIER:
		return _open_barrier(e)
	if type == TYPE_DROP_EXPECTED:
		return _drop_expected(e)
	return _applied()


func _join(e: Dictionary) -> Dictionary:
	var r = _registry.seat(e.identity, e.get("local", false))
	if not r.ok:
		return _rejected(LAYER_HOST, r.reason)
	if not r.returning:
		for name in ECONOMY_KEYS:
			_economy[name].append(_new_economy_value(name))
		_refresh_senders()
	return _applied() if r.changed else _outcome(STATUS_UNCHANGED, LAYER_HOST, REASON_NONE)


func _remove(e: Dictionary) -> Dictionary:
	var r = _registry.remove(e.identity)
	if not r.ok:
		return _rejected(LAYER_HOST, r.reason)
	var remapped := _remap_economy(r.remap, r.old_count)
	if _flow.has_run():
		var g = _flow.set_roster_generation(r.generation)
		if g.changed:
			_rescope()
	_refresh_senders()
	if not remapped:
		return _outcome(STATUS_APPLIED, LAYER_HOST, REASON_REMAP_FAILED)
	return _applied()


func _begin_run(e: Dictionary) -> Dictionary:
	var r = _flow.begin_run(e.run_id)
	if not r.ok:
		return _rejected(LAYER_FLOW, r.reason)
	# begin_run starts the roster generation over; the registry's is the truth.
	if _registry.generation() > 0:
		var _synced = _flow.set_roster_generation(_registry.generation())
	_rescope()
	return _applied()


func _advance(e: Dictionary) -> Dictionary:
	if e.has("requires") and not _flow.was_committed(e.requires):
		return _rejected(LAYER_HOST, REASON_PHASE_NOT_COMMITTED)
	var r = _flow.advance(e.wave, e.phase)
	if not r.ok:
		return _rejected(LAYER_FLOW, r.reason)
	_rescope()
	return _applied()


func _open_barrier(e: Dictionary) -> Dictionary:
	if not _flow.has_run():
		return _rejected(LAYER_FLOW, FlowGuard.REJECT_NO_RUN)
	var stamp: Dictionary = _flow.stamp()
	if _barrier_seqs.has(stamp.seq):
		return _rejected(LAYER_HOST, REASON_BARRIER_STAMP_REUSED)
	_barrier_seqs[stamp.seq] = true
	var slots := []
	for entry in _registry.roster():
		slots.append(entry.slot)
	_barrier = ReadyBarrier.new(slots, stamp, _clock, _session.hint_after_msec, _session.timeout_msec)
	_barrier_info = {"key": e.key, "seq": stamp.seq, "commits": 0}
	if not _barrier.is_valid():
		var reason: String = _barrier.init_reason()
		_close_barrier()
		return _rejected(LAYER_BARRIER, reason)
	return _applied()


func _drop_expected(e: Dictionary) -> Dictionary:
	if _barrier == null:
		return _rejected(LAYER_BARRIER, REASON_NO_BARRIER)
	var r = _barrier.remove_expected(_registry.slot_of(e.identity))
	if not r.ok:
		return _rejected(LAYER_BARRIER, r.reason)
	_try_phase_commit()
	return _applied() if r.changed else _outcome(STATUS_UNCHANGED, LAYER_BARRIER, r.reason)


# Called after every confirmation while the barrier is complete: the flow
# guard must let exactly the first one through (F06).
func _try_phase_commit() -> void:
	if _barrier == null or not _barrier.is_complete():
		return
	var key: String = _barrier_info.key
	var r = _flow.commit_for(_barrier.stamp(), key)
	if r.committed:
		_barrier_info.commits += 1
		_phase_commits.append({"key": key, "seq": r.seq})
	else:
		_commit_refusals.append({"at": _log.size(), "key": key, "reason": r.reason})


# A new stamp: the barrier of the old one is closed and the ledger moves to a
# scope of its own, which drops every entry of the old one.
func _rescope() -> void:
	_close_barrier()
	var _opened = _ledger.begin_scope(_scope_key(_flow.stamp()), _roster_identities())


func _refresh_senders() -> void:
	var scope: String = _ledger.current_scope()
	if scope != "":
		var _refreshed = _ledger.begin_scope(scope, _roster_identities())


func _close_barrier() -> void:
	if _barrier == null:
		return
	_barriers.append(_barrier_record(true))
	_barrier = null
	_barrier_info = {}


# superseded: closed by a stamp change while still waiting.
func _barrier_record(closing: bool) -> Dictionary:
	var state: String = _barrier.state()
	var terminal := state == ReadyBarrier.STATE_COMPLETE or state == ReadyBarrier.STATE_TIMED_OUT or state == ReadyBarrier.STATE_INVALID
	return {
		"key": _barrier_info.key,
		"seq": _barrier_info.seq,
		"state": state,
		"expected": _barrier.expected(),
		"ready": _barrier.ready_slots(),
		"missing": _barrier.missing(),
		"removed": _barrier.removed(),
		"commits": _barrier_info.commits,
		"superseded": closing and not terminal,
	}


func _remap_economy(remap, old_count) -> bool:
	var remapped := {}
	for name in ECONOMY_KEYS:
		var r = SlotRegistry.remap_array(_economy[name], remap, old_count)
		if not r.ok:
			return false
		remapped[name] = r.values
	_economy = remapped
	return true


func _new_economy_value(name: String):
	if name == "gold":
		return _session.start_gold
	if name == "rerolls":
		return 0
	return []


# Toy shop rules; every outcome, refusals included, becomes the committed
# result {"ok", "reason", "gold"}.
func _execute(kind: String, p: Dictionary) -> Dictionary:
	var i: int = p.player_index
	var gold: int = _economy.gold[i]
	var reason := REASON_NONE
	if kind == KIND_BUY:
		if gold < p.cost:
			reason = RESULT_NO_GOLD
		else:
			gold -= p.cost
			_economy.items[i].append(p.item)
	elif kind == KIND_SELL:
		var at: int = _economy.items[i].find(p.item)
		if at < 0:
			reason = RESULT_NO_ITEM
		else:
			_economy.items[i].remove(at)
			gold += p.value
	elif kind == KIND_REROLL:
		if gold < p.cost:
			reason = RESULT_NO_GOLD
		else:
			gold -= p.cost
			_economy.rerolls[i] = int(_economy.rerolls[i]) + 1
	elif kind == KIND_LOCK:
		var locks: Array = _economy.locks[i]
		if p.locked and not locks.has(p.shop_slot):
			locks.append(p.shop_slot)
			locks.sort()
		elif not p.locked:
			locks.erase(p.shop_slot)
	elif kind == KIND_UPGRADE:
		_economy.upgrades[i].append(p.stat)
	else:
		_economy.chests[i].append(p.item)
		if p.take:
			_economy.items[i].append(p.item)
		else:
			gold += CHEST_RECYCLE_GOLD
	_economy.gold[i] = gold
	return {"ok": reason == REASON_NONE, "reason": reason, "gold": gold}


func _record_action(sender: String, kind: String, p: Dictionary, result: Dictionary) -> void:
	var key := _action_key(sender, p.stamp.seq, p.action_id)
	_executions[key] = int(_executions.get(key, 0)) + 1
	_actions[key] = {
		"sender": sender,
		"action_id": p.action_id,
		"kind": kind,
		"slot": _registry.slot_of(sender),
		"player_index": p.player_index,
		"seq": p.stamp.seq,
		"result": result.duplicate(true),
	}


func _finish() -> Dictionary:
	var barriers: Array = _barriers.duplicate(true)
	if _barrier != null:
		barriers.append(_barrier_record(false))
	var violations := []
	for v in _registry.validate():
		violations.append(v.code)
	var committed := {
		"roster": _registry.roster(),
		"roster_generation": _registry.generation(),
		"frozen": _registry.is_frozen(),
		"violations": violations,
		"flow": _flow.stamp(),
		"players": _players(),
		"actions": _committed_actions(),
		"barriers": barriers,
		"phase_commits": _phase_commits.duplicate(true),
	}
	var rejections := []
	var counts := {}
	for status in STATUSES:
		counts[status] = 0
	var reason_counts := {}
	for entry in _log:
		counts[entry.status] += 1
		if entry.status == STATUS_REJECTED:
			rejections.append(entry)
		if entry.reason != REASON_NONE:
			var key: String = "%s:%s" % [entry.layer, entry.reason]
			reason_counts[key] = int(reason_counts.get(key, 0)) + 1
	# var2bytes encodes a Dictionary in insertion order: sorted keys keep the
	# summary independent of which refusal happened to come first.
	var names: Array = reason_counts.keys()
	names.sort()
	var reasons := {}
	for name in names:
		reasons[name] = reason_counts[name]
	var digest := {
		"setup": _setup,
		"committed": committed,
		"log": _log,
		"rejections": rejections,
		"counts": counts,
		"reasons": reasons,
		"commit_refusals": _commit_refusals,
	}
	return {
		"ok": true,
		"reason": REASON_NONE,
		"at": -1,
		"field": "",
		"events": _literal,
		"committed": committed,
		"digest": digest,
		"committed_hash": ActionLedger.make_fingerprint(committed),
		"digest_hash": ActionLedger.make_fingerprint(digest),
	}


# Economy per stable slot, ascending.
func _players() -> Array:
	var index_of_slot := {}
	for entry in _registry.roster():
		index_of_slot[entry.slot] = entry.player_index
	var slots := index_of_slot.keys()
	slots.sort()
	var out := []
	for slot in slots:
		var i: int = index_of_slot[slot]
		out.append({
			"slot": slot,
			"gold": _economy.gold[i],
			"items": _economy.items[i].duplicate(),
			"upgrades": _economy.upgrades[i].duplicate(),
			"chests": _economy.chests[i].duplicate(),
			"rerolls": _economy.rerolls[i],
			"locks": _economy.locks[i].duplicate(),
		})
	return out


# Sorted by sender, stamp seq and action id, whatever order they ran in.
func _committed_actions() -> Array:
	var keys := _actions.keys()
	keys.sort()
	var out := []
	for key in keys:
		var record: Dictionary = _actions[key].duplicate(true)
		record["executions"] = _executions[key]
		out.append(record)
	return out


func _roster_identities() -> Array:
	var ids := []
	for entry in _registry.roster():
		ids.append(entry.identity)
	return ids


func _guard_context() -> Dictionary:
	return {"roster_count": _registry.roster_count()}


func _scope_key(stamp: Dictionary) -> String:
	return ActionLedger.make_fingerprint([_session.session_id, stamp.run_id, stamp.seq])


func _registry_change(r) -> Dictionary:
	if not r.ok:
		return _rejected(LAYER_HOST, r.reason)
	return _applied() if r.changed else _outcome(STATUS_UNCHANGED, LAYER_HOST, REASON_NONE)


# Hash of the body in a fixed field order, so a reused id with other content
# is refused by the ledger instead of getting the earlier result.
static func _fingerprint(kind: String, payload: Dictionary) -> String:
	var parts := [kind, payload.player_index]
	var names: Array = body_specs(kind).keys()
	names.sort()
	for name in names:
		parts.append(payload[name])
	return ActionLedger.make_fingerprint(parts)


# Ids are unique per sender within one scope (one stamp), and may start over in
# the next one, so the stamp seq is part of the key.
static func _action_key(sender: String, seq: int, action_id: int) -> String:
	return "%s|%016d|%010d" % [sender, seq, action_id]


static func _session_problem(raw) -> String:
	if typeof(raw) != TYPE_DICTIONARY:
		return "session"
	for key in raw:
		if typeof(key) != TYPE_STRING or not (key in SESSION_KEYS):
			return _key_name(key)
	for key in SESSION_INT_KEYS:
		if raw.has(key) and typeof(raw[key]) != TYPE_INT:
			return key
	for key in SESSION_ARRAY_KEYS:
		if raw.has(key) and typeof(raw[key]) != TYPE_ARRAY:
			return key
	if raw.has("session_id") and not _is_text(raw.session_id, MAX_SESSION_ID_LENGTH):
		return "session_id"
	if raw.has("start_gold") and (raw.start_gold < 0 or raw.start_gold > MAX_START_GOLD):
		return "start_gold"
	return ""


# {"reason", "field"} of the first problem; labels collects the labels defined
# so far, so "@label" can only name an earlier event.
static func _event_problem(e, labels: Dictionary) -> Dictionary:
	if typeof(e) != TYPE_DICTIONARY or typeof(e.get("type")) != TYPE_STRING or not EVENT_KEYS.has(e.type):
		return _bad("type")
	var own: Array = EVENT_KEYS[e.type]
	for key in e:
		if typeof(key) != TYPE_STRING or not (key in COMMON_EVENT_KEYS or key in own):
			return _bad(_key_name(key))
	for key in REQUIRED_EVENT_KEYS.get(e.type, []):
		if not e.has(key):
			return _bad(key)
	if e.has("t") and (typeof(e.t) != TYPE_INT or e.t < 0):
		return _bad("t")
	if e.has("eid") and (typeof(e.eid) != TYPE_INT or e.eid < 0):
		return _bad("eid")
	if e.has("label") and not _is_text(e.label, MAX_LABEL_LENGTH):
		return _bad("label")
	for key in ["fault", "note", "run_id", "phase", "requires", "key"]:
		if e.has(key) and typeof(e[key]) != TYPE_STRING:
			return _bad(key)
	if e.has("wave") and typeof(e.wave) != TYPE_INT:
		return _bad("wave")
	if e.type in MESSAGE_TYPES:
		if typeof(e.from) != TYPE_STRING:
			return _bad("from")
		var authored := false
		for key in AUTHORED_KEYS:
			if e.has(key):
				authored = true
		if e.has("payload") and authored:
			return _bad("payload")
		if e.type == TYPE_ACTION and not e.has("payload") and not e.has("kind"):
			return _bad("kind")
		if e.has("body"):
			if typeof(e.body) != TYPE_DICTIONARY:
				return _bad("body")
			for name in e.body:
				if typeof(name) != TYPE_STRING or name in ENVELOPE_KEYS:
					return _bad("body")
		if e.has("stamp"):
			var s = e.stamp
			if typeof(s) == TYPE_STRING and s.begins_with(LABEL_PREFIX):
				if not labels.has(s.substr(LABEL_PREFIX.length(), s.length() - LABEL_PREFIX.length())):
					return {"reason": REASON_UNKNOWN_LABEL, "field": "stamp"}
			elif typeof(s) == TYPE_STRING:
				if s != STAMP_CURRENT:
					return _bad("stamp")
			elif typeof(s) != TYPE_DICTIONARY:
				return _bad("stamp")
	if e.has("label"):
		labels[e.label] = true
	return {"reason": REASON_NONE, "field": ""}


static func _advance_event(wave: int, phase: String, requires: String, t: int) -> Dictionary:
	var e := {"type": TYPE_ADVANCE, "wave": wave, "phase": phase, "t": t}
	if requires != "":
		e["requires"] = requires
	return e


static func _action_event(sender: String, kind: String, body: Dictionary) -> Dictionary:
	return {"type": TYPE_ACTION, "from": sender, "kind": kind, "body": body}


static func _shop_action(sender: String, owned: Array, rng: RandomNumberGenerator) -> Dictionary:
	var roll: int = rng.randi_range(0, 9)
	if roll >= 8 and not owned.empty():
		var at: int = rng.randi_range(0, owned.size() - 1)
		var item: String = owned[at]
		owned.remove(at)
		return _action_event(sender, KIND_SELL, {"item": item, "value": rng.randi_range(1, 10)})
	if roll >= 6:
		return _action_event(sender, KIND_LOCK, {"shop_slot": rng.randi_range(0, MAX_SHOP_SLOT), "locked": rng.randi_range(0, 1) == 1})
	if roll >= 4:
		return _action_event(sender, KIND_REROLL, {"cost": rng.randi_range(1, 5)})
	var bought: String = "item_%d" % rng.randi_range(0, 9)
	owned.append(bought)
	return _action_event(sender, KIND_BUY, {"shop_slot": rng.randi_range(0, MAX_SHOP_SLOT), "item": bought, "cost": rng.randi_range(1, 15)})


# Random interleaving of queues (chance proportional to what is left of each),
# each queue kept in order.
static func _interleave(queues: Array, rng: RandomNumberGenerator) -> Array:
	var heads := []
	var remaining := 0
	for q in queues:
		heads.append(0)
		remaining += q.size()
	var out := []
	while remaining > 0:
		var pick: int = rng.randi_range(0, remaining - 1)
		for i in range(queues.size()):
			var left: int = queues[i].size() - heads[i]
			if pick < left:
				out.append(queues[i][heads[i]])
				heads[i] += 1
				break
			pick -= left
		remaining -= 1
	return out


static func _append_messages(events: Array, messages: Array, t: int, rng: RandomNumberGenerator) -> int:
	for m in messages:
		t += rng.randi_range(5, 300)
		m["t"] = t
		events.append(m)
	return t


# A barrier over everyone, then each player's ready in a random order.
static func _append_barrier(events: Array, key: String, ids: Array, t: int, rng: RandomNumberGenerator) -> int:
	t += 50
	events.append({"type": TYPE_BARRIER, "key": key, "t": t})
	var order: Array = ids.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var held = order[i]
		order[i] = order[j]
		order[j] = held
	for sender in order:
		t += rng.randi_range(5, 300)
		events.append({"type": TYPE_READY, "from": sender, "t": t})
	return t + 50


static func _copy(value):
	if typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_DICTIONARY:
		return value.duplicate(true)
	return value


static func _is_text(value, max_length: int) -> bool:
	return typeof(value) == TYPE_STRING and value.length() >= 1 and value.length() <= max_length


static func _key_name(key) -> String:
	if typeof(key) == TYPE_STRING and key.length() <= MAX_LABEL_LENGTH:
		return key
	return "?"


static func _bad(field: String) -> Dictionary:
	return {"reason": REASON_BAD_EVENT, "field": field}


static func _problem(reason: String, at: int, field: String) -> Dictionary:
	return {"ok": reason == REASON_NONE, "reason": reason, "at": at, "field": field}


static func _outcome(status: String, layer: String, reason: String) -> Dictionary:
	return {"status": status, "layer": layer, "reason": reason}


static func _applied() -> Dictionary:
	return _outcome(STATUS_APPLIED, LAYER_NONE, REASON_NONE)


static func _rejected(layer: String, reason: String) -> Dictionary:
	return _outcome(STATUS_REJECTED, layer, reason)
