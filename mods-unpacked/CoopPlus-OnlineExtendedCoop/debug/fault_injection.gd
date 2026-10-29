extends Reference
# Seeded application-level faults for replayable event lists (AP-008; F05 F06
# F07 F08, T05 T06 T08). Debug/test only: debug/ is excluded from release
# packages (project.lock.json package.excluded_dirs), so no packaged script may
# preload this file, and no player-facing switch reaches it.
#
# Boundary: the APPLICATION message boundary. The input is the event list a
# host adapter hands to the rules (format: tests/support/event_replay.gd), i.e.
# what reaches the host AFTER the transport delivered a message. Transport
# faults are NOT simulated here: on the reliable Steam/LAN channels a lost
# packet is retransmitted below the application or the connection times out,
# so deleting one business message from this list would not model packet loss
# (ACTION_PLAN section 6). There is deliberately no "drop" fault; loss, latency
# and retransmission belong to transport-level tests (AP-018, with a network
# degradation tool).
#
# apply(events, faults, seed) returns a new list; the input is never changed.
# Faults are applied in list order with one RandomNumberGenerator seeded with
# seed, so the same input and seed always give the same output.
# Each fault spec is a Dictionary: {"kind": FAULT_*, "rate": 0..1} (every
# candidate is picked with that probability) or {"kind", "count": n} (exactly
# n distinct candidates; fewer available is an error, never a silent cut),
# plus the keys of its kind. Candidates are message events (ready, action)
# that carry no "fault" tag yet, so faults never stack on injected copies.
#   duplicate     "copies" (1..4, default 1) copies, each placed 0..window-1
#                 events after its source ("window" 1..64, default 1);
#                 "types" limits the message types
#   reorder       shuffles chunks of "window" (2..64, default 4) consecutive
#                 messages; never across a host event, so every message keeps
#                 the phase it was sent in, and with "keep_sender_order"
#                 (default true) each sender's own order stays (reliable
#                 ordered channels keep it per peer). Times stay with the
#                 positions: "t" is when the host received something.
#                 rate/count pick chunks, not messages. Copies made by
#                 earlier faults move too, except a late_ready ready: it
#                 ends a chunk like a host event and keeps its place and t.
#   stale_replay  one copy re-delivered after the next stamp-changing host
#                 event (begin_run, advance, remove) and before the one after
#                 it: an old-phase packet. Messages with no later
#                 stamp-changing event are not candidates.
#   forge_index   one copy right after its source whose payload.player_index
#                 names another seat 0..8 (8 is the ninth player). The sender
#                 stays the identity the transport authenticated; forging the
#                 sender itself is a transport matter.
#   oversize      one copy right after its source with payload.padding sized
#                 from payload_guard's defaults; "mode" picks the limit:
#                   long_string  one 4096-character string
#                   many_items   an Array of 256 ints
#                   deep         Arrays nested 32 levels
#                   huge         56 strings of 240 characters: within every
#                                per-value limit, ~14 KB encoded (> 8192)
#                 or "random" (default) per copy.
#   late_ready    a ready that reaches the host after its barrier's R18
#                 timeout: its "t" becomes the receive clock + "timeout_msec"
#                 (default 30000, the R18 default; pass the session's own
#                 value when it differs) + 1..1000. Later events keep their
#                 t, so the clock stays at least there.
# Copies keep the source's "eid", drop "t" (received at the current clock) and
# "label", and get "fault": <kind>; late_ready tags the ready it delays. Events
# without "eid" get their input position first, so every report and log line
# points back to an input event.
# Messages must be literal ({"payload": ...}): an authored message resolves
# its stamp when the host receives it, which would make a reordered or
# replayed message look current. EventReplay.run() returns literal events.
# Result: {"ok", "reason", "field", "events", "injected", "counts"};
# "injected" lists {"fault", "eid", "detail"}, "counts" maps kinds to how many
# events each fault made or moved. On failure events and injected are empty.
# Pure: no autoloads, no scene tree, no clock.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const ReadyBarrier = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/ready_barrier.gd")
const PayloadGuard = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/network/payload_guard.gd")

const FAULT_DUPLICATE := "duplicate"
const FAULT_REORDER := "reorder"
const FAULT_STALE_REPLAY := "stale_replay"
const FAULT_FORGE_INDEX := "forge_index"
const FAULT_OVERSIZE := "oversize"
const FAULT_LATE_READY := "late_ready"
const FAULTS := [FAULT_DUPLICATE, FAULT_REORDER, FAULT_STALE_REPLAY, FAULT_FORGE_INDEX, FAULT_OVERSIZE, FAULT_LATE_READY]

const MODE_RANDOM := "random"
const MODE_LONG_STRING := "long_string"
const MODE_MANY_ITEMS := "many_items"
const MODE_DEEP := "deep"
const MODE_HUGE := "huge"
const OVERSIZE_MODES := [MODE_LONG_STRING, MODE_MANY_ITEMS, MODE_DEEP, MODE_HUGE]
const PADDING_KEY := "padding"

# Event types this file relies on; tests/support/event_replay.gd defines the
# format and a test keeps the two in step.
const TYPE_READY := "ready"
const TYPE_ACTION := "action"
const MESSAGE_TYPES := [TYPE_READY, TYPE_ACTION]
const FLOW_TYPES := ["begin_run", "advance", "remove"]

const REASON_NONE := ""
const REASON_INVALID_SEED := "invalid_seed"
const REASON_INVALID_EVENTS := "invalid_event_list"
const REASON_NOT_LITERAL := "message_not_literal"
const REASON_TOO_MANY_EVENTS := "too_many_events"
const REASON_INVALID_FAULTS := "invalid_fault_list"
const REASON_UNKNOWN_FAULT := "unknown_fault"
const REASON_BAD_PARAMETER := "bad_fault_parameter"
const REASON_TOO_FEW_CANDIDATES := "too_few_candidates"

const MAX_EVENTS := 50000
const MAX_FAULTS := 32
const MAX_WINDOW := 64
const MAX_COPIES := 4
const DEFAULT_DUPLICATE_WINDOW := 1
const DEFAULT_REORDER_WINDOW := 4
const MAX_TIMEOUT_MSEC := 3600000
const MAX_LATE_EXTRA_MSEC := 1000
# Forged indices cover every seat of the largest session and the ninth.
const MAX_FORGED_INDEX := CapacityPolicy.MAX_SUPPORTED_PLAYERS
const LONG_STRING_LENGTH := PayloadGuard.DEFAULT_MAX_STRING_LENGTH * 16
const MANY_ITEMS_COUNT := PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE * 4
const DEEP_LEVELS := PayloadGuard.DEFAULT_MAX_DEPTH * 4
const HUGE_STRING_LENGTH := PayloadGuard.DEFAULT_MAX_STRING_LENGTH - 16
const HUGE_STRING_COUNT := PayloadGuard.DEFAULT_MAX_COLLECTION_SIZE - 8
const MAX_FIELD_KEY_LENGTH := 32

const _COMMON_SPEC_KEYS := ["kind", "rate", "count"]
const _SPEC_KEYS := {
	FAULT_DUPLICATE: ["copies", "window", "types"],
	FAULT_REORDER: ["window", "keep_sender_order"],
	FAULT_STALE_REPLAY: ["types"],
	FAULT_FORGE_INDEX: ["types"],
	FAULT_OVERSIZE: ["types", "mode"],
	FAULT_LATE_READY: ["timeout_msec"],
}


func apply(events, faults, seed_value) -> Dictionary:
	if typeof(seed_value) != TYPE_INT:
		return _fail(REASON_INVALID_SEED, "seed")
	var checked := check_events(events)
	if not checked.ok:
		return _fail(checked.reason, checked.field)
	checked = check_faults(faults)
	if not checked.ok:
		return _fail(checked.reason, checked.field)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = events.duplicate(true)
	for k in range(out.size()):
		if not out[k].has("eid"):
			out[k]["eid"] = k
	var injected := []
	var counts := {}
	for i in range(faults.size()):
		var step := _apply_one(out, faults[i], rng)
		if not step.ok:
			return _fail(step.reason, "faults[%d]" % i)
		out = step.events
		injected += step.injected
		var kind: String = faults[i].kind
		counts[kind] = int(counts.get(kind, 0)) + step.injected.size()
	return {"ok": true, "reason": REASON_NONE, "field": "", "events": out, "injected": injected, "counts": counts}


# Shape of an event list the injector can work on (see the header).
func check_events(events) -> Dictionary:
	if typeof(events) != TYPE_ARRAY:
		return _problem(REASON_INVALID_EVENTS, "events")
	if events.size() > MAX_EVENTS:
		return _problem(REASON_TOO_MANY_EVENTS, "events")
	for k in range(events.size()):
		var e = events[k]
		var field: String = "events[%d]" % k
		if typeof(e) != TYPE_DICTIONARY or typeof(e.get("type")) != TYPE_STRING:
			return _problem(REASON_INVALID_EVENTS, field)
		if e.has("t") and (typeof(e.t) != TYPE_INT or e.t < 0):
			return _problem(REASON_INVALID_EVENTS, field + ".t")
		if e.has("eid") and typeof(e.eid) != TYPE_INT:
			return _problem(REASON_INVALID_EVENTS, field + ".eid")
		if e.has("fault") and typeof(e.fault) != TYPE_STRING:
			return _problem(REASON_INVALID_EVENTS, field + ".fault")
		if e.type in MESSAGE_TYPES:
			if typeof(e.get("from")) != TYPE_STRING:
				return _problem(REASON_INVALID_EVENTS, field + ".from")
			if not e.has("payload"):
				return _problem(REASON_NOT_LITERAL, field)
	return _problem(REASON_NONE, "")


# Every spec is checked before anything runs; unknown keys are refused so a
# typo such as "windw" cannot silently fall back to a default.
func check_faults(faults) -> Dictionary:
	if typeof(faults) != TYPE_ARRAY or faults.size() > MAX_FAULTS:
		return _problem(REASON_INVALID_FAULTS, "faults")
	for i in range(faults.size()):
		var spec = faults[i]
		var field: String = "faults[%d]" % i
		if typeof(spec) != TYPE_DICTIONARY:
			return _problem(REASON_INVALID_FAULTS, field)
		var kind = spec.get("kind")
		if typeof(kind) != TYPE_STRING or not (kind in FAULTS):
			return _problem(REASON_UNKNOWN_FAULT, field + ".kind")
		var own: Array = _SPEC_KEYS[kind]
		for key in spec:
			if typeof(key) != TYPE_STRING or not (key in _COMMON_SPEC_KEYS or key in own):
				return _problem(REASON_BAD_PARAMETER, _key_field(field, key))
		if spec.has("rate") == spec.has("count"):
			return _problem(REASON_BAD_PARAMETER, field + ".rate")
		if spec.has("rate"):
			var rate = spec.rate
			if (typeof(rate) != TYPE_INT and typeof(rate) != TYPE_REAL) or is_nan(float(rate)) or rate < 0 or rate > 1:
				return _problem(REASON_BAD_PARAMETER, field + ".rate")
		if spec.has("count") and not _int_in(spec.count, 0, MAX_EVENTS):
			return _problem(REASON_BAD_PARAMETER, field + ".count")
		var min_window := 2 if kind == FAULT_REORDER else 1
		if spec.has("window") and not _int_in(spec.window, min_window, MAX_WINDOW):
			return _problem(REASON_BAD_PARAMETER, field + ".window")
		if spec.has("copies") and not _int_in(spec.copies, 1, MAX_COPIES):
			return _problem(REASON_BAD_PARAMETER, field + ".copies")
		if spec.has("types") and not _valid_types(spec.types):
			return _problem(REASON_BAD_PARAMETER, field + ".types")
		if spec.has("mode") and (typeof(spec.mode) != TYPE_STRING or not (spec.mode in OVERSIZE_MODES or spec.mode == MODE_RANDOM)):
			return _problem(REASON_BAD_PARAMETER, field + ".mode")
		if spec.has("keep_sender_order") and typeof(spec.keep_sender_order) != TYPE_BOOL:
			return _problem(REASON_BAD_PARAMETER, field + ".keep_sender_order")
		if spec.has("timeout_msec") and not _int_in(spec.timeout_msec, 0, MAX_TIMEOUT_MSEC):
			return _problem(REASON_BAD_PARAMETER, field + ".timeout_msec")
	return _problem(REASON_NONE, "")


func _apply_one(events: Array, spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	if spec.kind == FAULT_REORDER:
		return _reorder(events, spec, rng)
	if spec.kind == FAULT_LATE_READY:
		return _late_ready(events, spec, rng)
	return _copies(events, spec, rng)


# duplicate, stale_replay, forge_index and oversize: new events next to their
# sources. All random choices are made in source order, then the copies are
# placed in one pass, so the result does not depend on insertion order.
func _copies(events: Array, spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var kind: String = spec.kind
	var types: Array = spec.get("types", MESSAGE_TYPES)
	var flow_positions := []
	for k in range(events.size()):
		if events[k].type in FLOW_TYPES:
			flow_positions.append(k)
	var candidates := []
	for k in range(events.size()):
		var e: Dictionary = events[k]
		if not (e.type in types) or e.has("fault"):
			continue
		if kind == FAULT_STALE_REPLAY and _next_after(flow_positions, k) < 0:
			continue
		if (kind == FAULT_FORGE_INDEX or kind == FAULT_OVERSIZE) and typeof(e.payload) != TYPE_DICTIONARY:
			continue
		candidates.append(k)
	var chosen = _select(candidates, spec, rng)
	if chosen == null:
		return _step_fail(REASON_TOO_FEW_CANDIDATES)
	var inserts := []
	var injected := []
	for k in chosen:
		var source: Dictionary = events[k]
		if kind == FAULT_DUPLICATE:
			var window: int = spec.get("window", DEFAULT_DUPLICATE_WINDOW)
			for _c in range(int(spec.get("copies", 1))):
				var offset: int = rng.randi_range(0, window - 1)
				inserts.append([int(min(k + 1 + offset, events.size())), _copy_of(source, kind)])
				injected.append(_report(kind, source, {"offset": offset}))
		elif kind == FAULT_STALE_REPLAY:
			var h: int = _next_after(flow_positions, k)
			var h2: int = _next_after(flow_positions, h)
			if h2 < 0:
				h2 = events.size()
			inserts.append([rng.randi_range(h + 1, h2), _copy_of(source, kind)])
			injected.append(_report(kind, source, {"after_eid": events[h].eid}))
		elif kind == FAULT_FORGE_INDEX:
			var forged := _copy_of(source, kind)
			var index := _forged_index(source.payload.get("player_index"), rng)
			forged.payload["player_index"] = index
			inserts.append([k + 1, forged])
			injected.append(_report(kind, source, {"player_index": index}))
		else:
			var mode: String = spec.get("mode", MODE_RANDOM)
			if mode == MODE_RANDOM:
				mode = OVERSIZE_MODES[rng.randi_range(0, OVERSIZE_MODES.size() - 1)]
			var padded := _copy_of(source, kind)
			padded.payload[PADDING_KEY] = _padding(mode)
			inserts.append([k + 1, padded])
			injected.append(_report(kind, source, {"mode": mode}))
	if events.size() + inserts.size() > MAX_EVENTS:
		return _step_fail(REASON_TOO_MANY_EVENTS)
	return {"ok": true, "reason": REASON_NONE, "events": _with_inserts(events, inserts), "injected": injected}


func _reorder(events: Array, spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var window: int = spec.get("window", DEFAULT_REORDER_WINDOW)
	var keep_sender_order: bool = spec.get("keep_sender_order", true)
	# Chunks [a, b) of consecutive messages, never spanning a host event.
	var chunks := []
	var k := 0
	while k < events.size():
		if not _reorderable(events[k]):
			k += 1
			continue
		var run_end := k
		while run_end < events.size() and _reorderable(events[run_end]):
			run_end += 1
		var a := k
		while a < run_end:
			var b := int(min(a + window, run_end))
			if b - a >= 2:
				chunks.append([a, b])
			a = b
		k = run_end
	var chosen = _select(range(chunks.size()), spec, rng)
	if chosen == null:
		return _step_fail(REASON_TOO_FEW_CANDIDATES)
	var out: Array = events.duplicate()
	var injected := []
	for c in chosen:
		var a: int = chunks[c][0]
		var n: int = chunks[c][1] - a
		var order: Array = _interleave_senders(events, a, n, rng) if keep_sender_order else _shuffled_offsets(n, rng)
		var times := []
		for j in range(n):
			times.append(events[a + j].get("t"))
		for j in range(n):
			var moved: Dictionary = events[a + order[j]]
			if typeof(times[j]) == TYPE_NIL:
				moved.erase("t")
			else:
				moved["t"] = times[j]
			out[a + j] = moved
			if order[j] != j:
				injected.append(_report(FAULT_REORDER, moved, {"from": a + order[j], "to": a + j}))
	return {"ok": true, "reason": REASON_NONE, "events": out, "injected": injected}


func _late_ready(events: Array, spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var timeout: int = spec.get("timeout_msec", ReadyBarrier.DEFAULT_TIMEOUT_MSEC)
	var candidates := []
	for k in range(events.size()):
		if events[k].type == TYPE_READY and not events[k].has("fault"):
			candidates.append(k)
	var chosen = _select(candidates, spec, rng)
	if chosen == null:
		return _step_fail(REASON_TOO_FEW_CANDIDATES)
	var extra := {}
	for k in chosen:
		extra[k] = rng.randi_range(1, MAX_LATE_EXTRA_MSEC)
	var injected := []
	var clock := 0
	for k in range(events.size()):
		var e: Dictionary = events[k]
		if e.has("t") and e.t > clock:
			clock = e.t
		if extra.has(k):
			clock += timeout + extra[k]
			e["t"] = clock
			e["fault"] = FAULT_LATE_READY
			injected.append(_report(FAULT_LATE_READY, e, {"t": clock}))
	return {"ok": true, "reason": REASON_NONE, "events": events, "injected": injected}


# Sorted subset of candidates, or null when "count" asks for more than exist.
# Every candidate consumes one draw with "rate", so the stream stays aligned.
func _select(candidates: Array, spec: Dictionary, rng: RandomNumberGenerator):
	var chosen := []
	if spec.has("count"):
		var count: int = spec.count
		if count > candidates.size():
			return null
		var pool := candidates.duplicate()
		for i in range(count):
			var j: int = rng.randi_range(i, pool.size() - 1)
			var held = pool[i]
			pool[i] = pool[j]
			pool[j] = held
			chosen.append(pool[i])
		chosen.sort()
		return chosen
	var rate := float(spec.rate)
	for c in candidates:
		var roll := rng.randf()
		if rate >= 1.0 or roll < rate:
			chosen.append(c)
	return chosen


# Random interleaving of the senders' queues (chance proportional to what is
# left of each queue), each queue kept in order. Offsets relative to a.
func _interleave_senders(events: Array, a: int, n: int, rng: RandomNumberGenerator) -> Array:
	var senders := []
	var queues := {}
	for j in range(n):
		var sender: String = events[a + j].from
		if not queues.has(sender):
			queues[sender] = []
			senders.append(sender)
		queues[sender].append(j)
	var heads := {}
	var order := []
	for remaining in range(n, 0, -1):
		var pick: int = rng.randi_range(0, remaining - 1)
		for sender in senders:
			var head: int = heads.get(sender, 0)
			var left: int = queues[sender].size() - head
			if pick < left:
				order.append(queues[sender][head])
				heads[sender] = head + 1
				break
			pick -= left
	return order


func _shuffled_offsets(n: int, rng: RandomNumberGenerator) -> Array:
	var order := range(n)
	for i in range(n - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var held = order[i]
		order[i] = order[j]
		order[j] = held
	return order


# inserts: [[before_position, event], ...]; copies for one position keep their
# generation order and come before the event already at that position.
static func _with_inserts(events: Array, inserts: Array) -> Array:
	var at := {}
	for item in inserts:
		if not at.has(item[0]):
			at[item[0]] = []
		at[item[0]].append(item[1])
	var out := []
	for k in range(events.size() + 1):
		if at.has(k):
			out += at[k]
		if k < events.size():
			out.append(events[k])
	return out


static func _copy_of(source: Dictionary, kind: String) -> Dictionary:
	var copy: Dictionary = source.duplicate(true)
	copy.erase("t")
	copy.erase("label")
	copy["fault"] = kind
	return copy


# Any seat 0..MAX_FORGED_INDEX except the one the sender used.
static func _forged_index(own, rng: RandomNumberGenerator) -> int:
	var choices := []
	for i in range(MAX_FORGED_INDEX + 1):
		if typeof(own) != TYPE_INT or i != own:
			choices.append(i)
	return choices[rng.randi_range(0, choices.size() - 1)]


static func _padding(mode: String):
	if mode == MODE_LONG_STRING:
		return _filler(LONG_STRING_LENGTH)
	if mode == MODE_MANY_ITEMS:
		return range(MANY_ITEMS_COUNT)
	if mode == MODE_DEEP:
		var nested := []
		for _i in range(DEEP_LEVELS):
			nested = [nested]
		return nested
	var strings := []
	for _i in range(HUGE_STRING_COUNT):
		strings.append(_filler(HUGE_STRING_LENGTH))
	return strings


static func _filler(length: int) -> String:
	var text := "x"
	while text.length() < length:
		text += text
	return text.substr(0, length)


# Messages reorder may move. A ready delayed by late_ready stays where it is:
# times stay with positions, so moving it would hand its delay to whatever
# message took its place.
static func _reorderable(e: Dictionary) -> bool:
	return e.type in MESSAGE_TYPES and e.get("fault", "") != FAULT_LATE_READY


static func _next_after(sorted_positions: Array, k: int) -> int:
	for p in sorted_positions:
		if p > k:
			return p
	return -1


static func _report(kind: String, event: Dictionary, detail: Dictionary) -> Dictionary:
	return {"fault": kind, "eid": event.get("eid", -1), "detail": detail}


static func _valid_types(types) -> bool:
	if typeof(types) != TYPE_ARRAY or types.empty():
		return false
	var seen := {}
	for t in types:
		if typeof(t) != TYPE_STRING or not (t in MESSAGE_TYPES) or seen.has(t):
			return false
		seen[t] = true
	return true


static func _int_in(value, lo: int, hi: int) -> bool:
	return typeof(value) == TYPE_INT and value >= lo and value <= hi


# Spec keys are shown only when they are short Strings (they are test input).
static func _key_field(field: String, key) -> String:
	if typeof(key) == TYPE_STRING and key.length() <= MAX_FIELD_KEY_LENGTH:
		return "%s.%s" % [field, key]
	return field


static func _problem(reason: String, field: String) -> Dictionary:
	return {"ok": reason == REASON_NONE, "reason": reason, "field": field}


static func _step_fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "events": [], "injected": []}


static func _fail(reason: String, field: String) -> Dictionary:
	return {"ok": false, "reason": reason, "field": field, "events": [], "injected": [], "counts": {}}
