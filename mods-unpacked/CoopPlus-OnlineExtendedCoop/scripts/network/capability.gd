extends Reference
# Extension capability handshake (AP-009; R03 R04 R06 R07 R08 R18; F13 F15 F17).
# Runs after a client joins and before the formal flow starts: the client's
# extension sends build_hello(), the host answers build_result(evaluate(...)),
# the client turns that RESULT (or its absence) into client_decision(...).
#   capacity 1..4  plain Brotato Online clients and hosts stay welcome; the
#                  extension is dormant for everyone (MODE_VANILLA_COMPAT, R08)
#   capacity 5..8  every machine needs a matching extension and the host's own
#                  environment must be a verified one (MODE_EXTENDED)
# Wire rules: the hello envelope (msg_type, extension_id, extension_version,
# capability_version, plus MAX_HELLO_KEYS and MAX_HELLO_BYTES) and the whole
# RESULT message are frozen across capability versions, so a mismatch is
# always reported as a mismatch rather than as a malformed message. Numbers
# may arrive as floats (JSON transports).
# Pure rules: no autoloads, no scene tree, time comes in as msec arguments.

const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")

# Every extension msg_type starts with this prefix, so none can collide with a
# Brotato Online msg_type.
const MSG_PREFIX := "coopplus_"
const MSG_HELLO := "coopplus_capability_hello"
const MSG_RESULT := "coopplus_capability_result"

const UPSTREAM_ID := "six666-BrotatoOnline"
const UPSTREAM_ROLE_REQUIRED := "required"
# compatibility.json entries with this role are combinations that are not
# verified yet; they block extended sessions like incompatible_mods (R07).
const UPSTREAM_ROLE_CANDIDATE := "compatibility-candidate"

# docs/requirements.md section 5: negotiation completes within 10 s of joining.
# Callers may wait less, never more.
const HANDSHAKE_TIMEOUT_MSEC := 10000

const MODE_NONE := ""
const MODE_VANILLA_COMPAT := "vanilla_compat"
const MODE_EXTENDED := "extended"

# evaluate() / RESULT reasons. Also used as the "note" of a vanilla-compat
# acceptance: why that peer would not have been extended-compatible.
const REASON_NONE := ""
const REASON_INVALID_CAPACITY := "invalid_capacity"
const REASON_HOST_UNVERIFIED := "host_unverified"
const REASON_EXTENSION_MISSING := "extension_missing"
const REASON_MALFORMED_HELLO := "malformed_hello"
const REASON_OVERSIZED_HELLO := "oversized_hello"
const REASON_EXTENSION_ID_MISMATCH := "extension_id_mismatch"
const REASON_CAPABILITY_MISMATCH := "capability_mismatch"
const REASON_EXTENSION_VERSION_MISMATCH := "extension_version_mismatch"
const REASON_GAME_VERSION_MISMATCH := "game_version_mismatch"
const REASON_ENGINE_VERSION_MISMATCH := "engine_version_mismatch"
const REASON_UPSTREAM_MISMATCH := "upstream_mismatch"
const REASON_DLC_MISMATCH := "dlc_mismatch"
const REASON_CAPACITY_UNSUPPORTED := "capacity_unsupported"
const REASON_INCOMPATIBLE_MOD := "incompatible_mod"
# build_result() / read_result() / client_decision()
const REASON_INVALID_DECISION := "invalid_decision"
const REASON_MALFORMED_RESULT := "malformed_result"
const REASON_HANDSHAKE_TIMEOUT := "handshake_timeout"
const REASON_MODE_MISMATCH := "mode_mismatch"
# check_timeout()
const REASON_INVALID_TIMER := "invalid_timer"
# check_local_support(); evaluate() reports them as REASON_HOST_UNVERIFIED
# with "<reason>:<detail>" as detail.
const REASON_INFO_INVALID := "info_invalid"
const REASON_RECORD_INVALID := "support_record_invalid"
const REASON_RECORD_MISMATCH := "support_record_mismatch"
const REASON_GAME_UNVERIFIED := "game_version_unverified"
const REASON_ENGINE_UNVERIFIED := "engine_version_unverified"
const REASON_UPSTREAM_UNVERIFIED := "upstream_unverified"
const REASON_LOCAL_INCOMPATIBLE_MOD := "local_incompatible_mod"
# parse_semver() / compare_semver()
const REASON_INVALID_SEMVER := "invalid_semver"

# Bounds for data received from a peer. Byte sizes are measured with
# var2bytes(); a hello at every list/string limit still fits MAX_HELLO_BYTES.
const MAX_HELLO_BYTES := 32768
const MAX_HELLO_KEYS := 32
const MAX_RESULT_BYTES := 2048
const MAX_RESULT_KEYS := 16
const MAX_DLC := 16
const MAX_MODS := 128
const MAX_ID_LENGTH := 64
const MAX_VERSION_LENGTH := 32
const MAX_TEXT_LENGTH := 64
const MAX_REASON_LENGTH := 64
const MAX_DETAIL_LENGTH := 160
const MAX_PEER_CAPACITY := 64
const MAX_CAPABILITY_VERSION := 1000000
const MAX_SEMVER_PART_DIGITS := 9

const HELLO_FIELDS := ["msg_type", "extension_id", "extension_version", "capability_version", "game_version", "engine_version", "upstream_fingerprint", "capacity", "dlc", "mods"]
const MODES := [MODE_NONE, MODE_VANILLA_COMPAT, MODE_EXTENDED]

# Characters allowed besides ASCII letters and digits.
const ID_CHARS := "_.-"
const VERSION_CHARS := "_.+-"
const DETAIL_CHARS := " _.,:=+-/"


# info keys: extension_id, extension_version (x.y.z), capability_version (int),
# game_version, engine_version, upstream_fingerprint (64 hex), capacity (max
# players this install supports), dlc (Array of DLC ids active for the run),
# mods (Array of {"id", "version"}). Other keys are not sent. Missing or wrong
# values are copied as they are so validate_hello() names them; nothing is
# guessed. Senders check validate_hello(build_hello(info)).ok before sending.
func build_hello(info: Dictionary) -> Dictionary:
	var fingerprint = info.get("upstream_fingerprint")
	if typeof(fingerprint) == TYPE_STRING:
		fingerprint = fingerprint.to_lower()
	return {
		"msg_type": MSG_HELLO,
		"extension_id": info.get("extension_id"),
		"extension_version": info.get("extension_version"),
		"capability_version": _int_or_raw(info.get("capability_version")),
		"game_version": info.get("game_version"),
		"engine_version": info.get("engine_version"),
		"upstream_fingerprint": fingerprint,
		"capacity": _int_or_raw(info.get("capacity")),
		"dlc": _sorted_strings(info.get("dlc")),
		"mods": _sorted_mods(info.get("mods")),
	}


# Full check of a hello. Returns {"ok", "reason", "detail", "hello"}; "hello"
# is a normalized copy (ints, sorted dlc/mods) and the input is not changed.
func validate_hello(msg) -> Dictionary:
	var envelope := _check_envelope(msg)
	if not envelope.ok:
		return envelope
	return _check_body(msg, envelope.hello)


# Whether the formal flow must wait for the handshake. 1..4 player sessions
# never wait, so plain clients see no delay (R08). Clients send a hello only
# when this is true for the lobby capacity: a 1..4 host may be a plain
# Brotato Online host, which must never receive a coopplus_ message either.
func requires_handshake(session_capacity: int) -> bool:
	return mode_for_capacity(session_capacity) != MODE_VANILLA_COMPAT


# The mode every member of a session with this capacity runs in:
# MODE_VANILLA_COMPAT for 1..4, MODE_EXTENDED for 5..8, MODE_NONE if invalid.
func mode_for_capacity(session_capacity: int) -> String:
	var policy = CapacityPolicy.new(session_capacity)
	if not policy.is_valid():
		return MODE_NONE
	return MODE_EXTENDED if policy.is_extended() else MODE_VANILLA_COMPAT


# Can this machine host (or join) a 5..8 player session at all (R03 R04 R07,
# F16 F17)? local_info is the build_hello() info plus:
#   incompatible_mods  Array of mod ids that block extended sessions (required,
#                      may be empty); the record's UPSTREAM_ROLE_CANDIDATE
#                      entries are added to it
#   supported          the parsed compatibility.json record
# Returns {"ok", "reason", "detail"}.
func check_local_support(local_info: Dictionary) -> Dictionary:
	var local := _check_local(local_info)
	return {"ok": local.ok, "reason": local.reason, "detail": local.detail}


# host_info: see check_local_support(). peer_hello: the received hello, or null
# when none arrived before check_timeout() expired. Call once per connection
# and resend the stored result for repeated hellos.
# Returns {"accepted", "reason", "mode", "note", "detail", "reply"}:
#   reason  REASON_NONE when accepted
#   note    on MODE_VANILLA_COMPAT, why the peer is not extended-compatible
#   detail  short display text (host/peer values, field or mod id)
#   reply   send build_result() back; false when the peer sent no hello, since
#           a plain client must not receive extension messages
func evaluate(host_info: Dictionary, peer_hello, session_capacity: int) -> Dictionary:
	var reply := typeof(peer_hello) != TYPE_NIL
	var mode := mode_for_capacity(session_capacity)
	if mode == MODE_NONE:
		return _decision(false, REASON_INVALID_CAPACITY, MODE_NONE, REASON_NONE, "session=%d" % session_capacity, reply)
	var verdict := _extended_verdict(host_info, peer_hello, session_capacity)
	if mode == MODE_VANILLA_COMPAT:
		return _decision(true, REASON_NONE, MODE_VANILLA_COMPAT, verdict.reason, verdict.detail, reply)
	if verdict.reason != REASON_NONE:
		return _decision(false, verdict.reason, MODE_NONE, REASON_NONE, verdict.detail, reply)
	return _decision(true, REASON_NONE, MODE_EXTENDED, REASON_NONE, "", reply)


# RESULT message for a decision. An inconsistent decision becomes a rejection
# (REASON_INVALID_DECISION) instead of being sent as an acceptance.
func build_result(decision: Dictionary) -> Dictionary:
	if not _is_consistent_decision(decision, false):
		return {"msg_type": MSG_RESULT, "accepted": false, "reason": REASON_INVALID_DECISION, "mode": MODE_NONE, "note": "", "detail": ""}
	return {
		"msg_type": MSG_RESULT,
		"accepted": decision.accepted,
		"reason": decision.reason,
		"mode": decision.mode,
		"note": decision.get("note", ""),
		"detail": _sanitize_detail(decision.get("detail", "")),
	}


# Client side. Returns {"ok", "accepted", "reason", "mode", "note", "detail"};
# a malformed RESULT reads as a rejection with REASON_MALFORMED_RESULT.
# Unknown extra keys are ignored so newer hosts stay readable.
func read_result(msg) -> Dictionary:
	var bad := {"ok": false, "accepted": false, "reason": REASON_MALFORMED_RESULT, "mode": MODE_NONE, "note": "", "detail": ""}
	if typeof(msg) != TYPE_DICTIONARY or msg.size() > MAX_RESULT_KEYS:
		return bad
	if var2bytes(msg).size() > MAX_RESULT_BYTES:
		return bad
	for key in msg.keys():
		if typeof(key) != TYPE_STRING:
			return bad
	if not _is_string(msg.get("msg_type"), MSG_RESULT) or not _is_consistent_decision(msg, true):
		return bad
	return {"ok": true, "accepted": msg.accepted, "reason": msg.reason, "mode": msg.mode, "note": msg.get("note", ""), "detail": msg.get("detail", "")}


# Client side: the host's RESULT message, or null when none arrived before
# check_timeout() expired, judged against the lobby capacity. An acceptance
# must carry mode_for_capacity(); any other mode is refused, so a client is
# never dormant in a 5..8 session (F01) nor extended in a 1..4 one (R08).
# In 1..4 a missing or malformed RESULT still means vanilla compat (the host
# may be a plain one); in 5..8 it is a rejection. A host's rejection stands.
# Returns {"accepted", "reason", "mode", "note", "detail"}.
func client_decision(result_msg, session_capacity: int) -> Dictionary:
	var expected := mode_for_capacity(session_capacity)
	if expected == MODE_NONE:
		return _client_decision(false, REASON_INVALID_CAPACITY, MODE_NONE, REASON_NONE, "session=%d" % session_capacity)
	var problem := REASON_HANDSHAKE_TIMEOUT
	var result := {}
	if typeof(result_msg) != TYPE_NIL:
		result = read_result(result_msg)
		problem = REASON_NONE if result.ok else REASON_MALFORMED_RESULT
	if problem != REASON_NONE:
		if expected == MODE_VANILLA_COMPAT:
			return _client_decision(true, REASON_NONE, MODE_VANILLA_COMPAT, problem, "")
		return _client_decision(false, problem, MODE_NONE, REASON_NONE, "")
	if not result.accepted:
		return _client_decision(false, result.reason, MODE_NONE, result.note, result.detail)
	if result.mode != expected:
		return _client_decision(false, REASON_MODE_MISMATCH, MODE_NONE, REASON_NONE, "host=%s session=%d" % [result.mode, session_capacity])
	return _client_decision(true, REASON_NONE, result.mode, result.note, result.detail)


# Host waiting for a hello, or client waiting for the RESULT. Expired means
# decide now: the host with evaluate(local_info, null, capacity), the client
# with client_decision(null, capacity). A timeout outside
# 1..HANDSHAKE_TIMEOUT_MSEC or a clock going backwards is reported as
# REASON_INVALID_TIMER and treated as expired, so nothing waits forever.
# Returns {"expired", "remaining_msec", "reason"}.
func check_timeout(now_msec: int, started_msec: int, timeout_msec: int = HANDSHAKE_TIMEOUT_MSEC) -> Dictionary:
	if timeout_msec <= 0 or timeout_msec > HANDSHAKE_TIMEOUT_MSEC or started_msec < 0 or now_msec < started_msec:
		return {"expired": true, "remaining_msec": 0, "reason": REASON_INVALID_TIMER}
	var elapsed := now_msec - started_msec
	if elapsed >= timeout_msec:
		return {"expired": true, "remaining_msec": 0, "reason": REASON_NONE}
	return {"expired": false, "remaining_msec": timeout_msec - elapsed, "reason": REASON_NONE}


# Strict x.y.z (same rule as manifest version_number). Returns
# {"ok", "reason", "major", "minor", "patch"}.
func parse_semver(text) -> Dictionary:
	var bad := {"ok": false, "reason": REASON_INVALID_SEMVER, "major": 0, "minor": 0, "patch": 0}
	if typeof(text) != TYPE_STRING or text.length() > MAX_VERSION_LENGTH:
		return bad
	var parts: PoolStringArray = text.split(".")
	if parts.size() != 3:
		return bad
	var numbers := []
	for part in parts:
		if part.empty() or part.length() > MAX_SEMVER_PART_DIGITS or (part.length() > 1 and part.begins_with("0")):
			return bad
		for i in range(part.length()):
			var c: int = part.ord_at(i)
			if c < 48 or c > 57:
				return bad
		numbers.append(part.to_int())
	return {"ok": true, "reason": REASON_NONE, "major": numbers[0], "minor": numbers[1], "patch": numbers[2]}


# Returns {"ok", "reason", "order"} with order -1, 0 or 1 (numeric per part).
func compare_semver(a, b) -> Dictionary:
	var pa := parse_semver(a)
	var pb := parse_semver(b)
	if not pa.ok or not pb.ok:
		return {"ok": false, "reason": REASON_INVALID_SEMVER, "order": 0}
	for key in ["major", "minor", "patch"]:
		if pa[key] != pb[key]:
			return {"ok": true, "reason": REASON_NONE, "order": -1 if pa[key] < pb[key] else 1}
	return {"ok": true, "reason": REASON_NONE, "order": 0}


# Extension versions that may share a session once capability_version is
# equal: same major; while major is 0 the minor counts as the major (SemVer
# item 4), so 0.1.x and 0.2.x never mix.
func semver_compatible(a, b) -> bool:
	var pa := parse_semver(a)
	var pb := parse_semver(b)
	if not pa.ok or not pb.ok or pa.major != pb.major:
		return false
	return pa.major != 0 or pa.minor == pb.minor


# Why this pairing could not run in MODE_EXTENDED; REASON_NONE when it could.
# Order: host, presence, envelope, protocol, versions, content, mods.
func _extended_verdict(host_info: Dictionary, peer_hello, session_capacity: int) -> Dictionary:
	var local := _check_local(host_info)
	if not local.ok:
		return _verdict(REASON_HOST_UNVERIFIED, _join_detail(local.reason, local.detail))
	var host: Dictionary = local.hello
	if session_capacity > host.capacity:
		return _verdict(REASON_CAPACITY_UNSUPPORTED, "host=%d session=%d" % [host.capacity, session_capacity])
	if typeof(peer_hello) == TYPE_NIL:
		return _verdict(REASON_EXTENSION_MISSING, "")
	var envelope := _check_envelope(peer_hello)
	if not envelope.ok:
		return _verdict(envelope.reason, envelope.detail)
	var peer: Dictionary = envelope.hello
	if peer.extension_id != host.extension_id:
		return _verdict(REASON_EXTENSION_ID_MISMATCH, "host=%s peer=%s" % [host.extension_id, peer.extension_id])
	if peer.capability_version != host.capability_version:
		return _verdict(REASON_CAPABILITY_MISMATCH, "host=%d peer=%d" % [host.capability_version, peer.capability_version])
	if not semver_compatible(host.extension_version, peer.extension_version):
		return _verdict(REASON_EXTENSION_VERSION_MISMATCH, "host=%s peer=%s" % [host.extension_version, peer.extension_version])
	var body := _check_body(peer_hello, peer)
	if not body.ok:
		return _verdict(body.reason, body.detail)
	peer = body.hello
	if peer.game_version != host.game_version:
		return _verdict(REASON_GAME_VERSION_MISMATCH, "host=%s peer=%s" % [host.game_version, peer.game_version])
	if peer.engine_version != host.engine_version:
		return _verdict(REASON_ENGINE_VERSION_MISMATCH, "host=%s peer=%s" % [host.engine_version, peer.engine_version])
	if peer.upstream_fingerprint != host.upstream_fingerprint:
		return _verdict(REASON_UPSTREAM_MISMATCH, "host=%s peer=%s" % [_short(host.upstream_fingerprint), _short(peer.upstream_fingerprint)])
	if not _same_strings(peer.dlc, host.dlc):
		return _verdict(REASON_DLC_MISMATCH, "host=%s peer=%s" % [_join_list(host.dlc), _join_list(peer.dlc)])
	if peer.capacity < session_capacity:
		return _verdict(REASON_CAPACITY_UNSUPPORTED, "peer=%d session=%d" % [peer.capacity, session_capacity])
	for mod in peer.mods:
		if local.incompatible.has(mod.id):
			return _verdict(REASON_INCOMPATIBLE_MOD, mod.id)
	return _verdict(REASON_NONE, "")


func _check_local(local_info: Dictionary) -> Dictionary:
	var result := {"ok": false, "reason": REASON_NONE, "detail": "", "hello": {}, "incompatible": []}
	var checked := validate_hello(build_hello(local_info))
	if not checked.ok:
		return _local_fail(result, REASON_INFO_INVALID, checked.detail)
	var hello: Dictionary = checked.hello
	var incompatible = _read_strings(local_info.get("incompatible_mods"))
	if typeof(incompatible) != TYPE_ARRAY:
		return _local_fail(result, REASON_INFO_INVALID, "incompatible_mods")
	var record = local_info.get("supported")
	if typeof(record) != TYPE_DICTIONARY:
		return _local_fail(result, REASON_RECORD_INVALID, "supported")
	if typeof(record.get("extension_id")) != TYPE_STRING:
		return _local_fail(result, REASON_RECORD_INVALID, "extension_id")
	if typeof(record.get("extension_version")) != TYPE_STRING:
		return _local_fail(result, REASON_RECORD_INVALID, "extension_version")
	var record_capability = _to_int(record.get("network_capability_version"))
	if typeof(record_capability) != TYPE_INT:
		return _local_fail(result, REASON_RECORD_INVALID, "network_capability_version")
	var game_versions = _read_strings(record.get("game_versions"))
	if typeof(game_versions) != TYPE_ARRAY:
		return _local_fail(result, REASON_RECORD_INVALID, "game_versions")
	var engine_versions = _read_strings(record.get("engine_versions"))
	if typeof(engine_versions) != TYPE_ARRAY:
		return _local_fail(result, REASON_RECORD_INVALID, "engine_versions")
	var upstream = _read_upstream(record.get("upstream"))
	if typeof(upstream) != TYPE_DICTIONARY:
		return _local_fail(result, REASON_RECORD_INVALID, "upstream")
	for id in upstream.candidates:
		if not incompatible.has(id):
			incompatible.append(id)
	# The record ships in the same package; a difference means a broken install.
	if record.extension_id != hello.extension_id:
		return _local_fail(result, REASON_RECORD_MISMATCH, "extension_id")
	if record.extension_version != hello.extension_version:
		return _local_fail(result, REASON_RECORD_MISMATCH, "extension_version")
	if record_capability != hello.capability_version:
		return _local_fail(result, REASON_RECORD_MISMATCH, "capability_version")
	if not game_versions.has(hello.game_version):
		return _local_fail(result, REASON_GAME_UNVERIFIED, hello.game_version)
	if not engine_versions.has(hello.engine_version):
		return _local_fail(result, REASON_ENGINE_UNVERIFIED, hello.engine_version)
	if not upstream.fingerprints.has(hello.upstream_fingerprint):
		return _local_fail(result, REASON_UPSTREAM_UNVERIFIED, _short(hello.upstream_fingerprint))
	for mod in hello.mods:
		if incompatible.has(mod.id):
			return _local_fail(result, REASON_LOCAL_INCOMPATIBLE_MOD, mod.id)
	result["ok"] = true
	result["hello"] = hello
	result["incompatible"] = incompatible
	return result


func _local_fail(result: Dictionary, reason: String, detail: String) -> Dictionary:
	result["reason"] = reason
	result["detail"] = detail
	return result


# Envelope fields are frozen across capability versions; extra keys are only
# judged by _check_body() once the capability version is known to match.
func _check_envelope(msg) -> Dictionary:
	if typeof(msg) != TYPE_DICTIONARY:
		return _hello_fail(REASON_MALFORMED_HELLO, "message")
	if msg.size() > MAX_HELLO_KEYS:
		return _hello_fail(REASON_OVERSIZED_HELLO, "keys")
	if var2bytes(msg).size() > MAX_HELLO_BYTES:
		return _hello_fail(REASON_OVERSIZED_HELLO, "bytes")
	for key in msg.keys():
		if typeof(key) != TYPE_STRING:
			return _hello_fail(REASON_MALFORMED_HELLO, "keys")
	if not _is_string(msg.get("msg_type"), MSG_HELLO):
		return _hello_fail(REASON_MALFORMED_HELLO, "msg_type")
	if not _is_token(msg.get("extension_id"), MAX_ID_LENGTH, ID_CHARS):
		return _hello_fail(REASON_MALFORMED_HELLO, "extension_id")
	if not parse_semver(msg.get("extension_version")).ok:
		return _hello_fail(REASON_MALFORMED_HELLO, "extension_version")
	var capability_version = _to_int(msg.get("capability_version"))
	if typeof(capability_version) != TYPE_INT or capability_version < 1 or capability_version > MAX_CAPABILITY_VERSION:
		return _hello_fail(REASON_MALFORMED_HELLO, "capability_version")
	var hello := {
		"msg_type": MSG_HELLO,
		"extension_id": msg.extension_id,
		"extension_version": msg.extension_version,
		"capability_version": capability_version,
	}
	return {"ok": true, "reason": REASON_NONE, "detail": "", "hello": hello}


# Body of the current capability version: exact field set, bounded lists, no
# duplicates. Detail names the field only; peer text is never echoed here.
func _check_body(msg: Dictionary, envelope: Dictionary) -> Dictionary:
	for key in msg.keys():
		if not HELLO_FIELDS.has(key):
			return _hello_fail(REASON_MALFORMED_HELLO, "unknown_field")
	var hello: Dictionary = envelope.duplicate()
	for field in ["game_version", "engine_version"]:
		if not _is_token(msg.get(field), MAX_TEXT_LENGTH, VERSION_CHARS):
			return _hello_fail(REASON_MALFORMED_HELLO, field)
		hello[field] = msg[field]
	if not _is_hex64(msg.get("upstream_fingerprint")):
		return _hello_fail(REASON_MALFORMED_HELLO, "upstream_fingerprint")
	hello["upstream_fingerprint"] = msg.upstream_fingerprint
	var capacity = _to_int(msg.get("capacity"))
	if typeof(capacity) != TYPE_INT or capacity < 1 or capacity > MAX_PEER_CAPACITY:
		return _hello_fail(REASON_MALFORMED_HELLO, "capacity")
	hello["capacity"] = capacity
	var dlc = msg.get("dlc")
	if typeof(dlc) != TYPE_ARRAY:
		return _hello_fail(REASON_MALFORMED_HELLO, "dlc")
	if dlc.size() > MAX_DLC:
		return _hello_fail(REASON_OVERSIZED_HELLO, "dlc")
	var dlc_ids := []
	for item in dlc:
		if not _is_token(item, MAX_ID_LENGTH, ID_CHARS):
			return _hello_fail(REASON_MALFORMED_HELLO, "dlc")
		dlc_ids.append(item)
	dlc_ids.sort()
	for i in range(1, dlc_ids.size()):
		if dlc_ids[i] == dlc_ids[i - 1]:
			return _hello_fail(REASON_MALFORMED_HELLO, "dlc")
	hello["dlc"] = dlc_ids
	var mods = msg.get("mods")
	if typeof(mods) != TYPE_ARRAY:
		return _hello_fail(REASON_MALFORMED_HELLO, "mods")
	if mods.size() > MAX_MODS:
		return _hello_fail(REASON_OVERSIZED_HELLO, "mods")
	var entries := []
	for entry in mods:
		if typeof(entry) != TYPE_DICTIONARY or entry.size() != 2:
			return _hello_fail(REASON_MALFORMED_HELLO, "mods")
		var id = entry.get("id")
		var version = entry.get("version")
		if not _is_token(id, MAX_ID_LENGTH, ID_CHARS) or not _is_token(version, MAX_VERSION_LENGTH, VERSION_CHARS):
			return _hello_fail(REASON_MALFORMED_HELLO, "mods")
		entries.append({"id": id, "version": version})
	entries.sort_custom(self, "_mod_id_less")
	for i in range(1, entries.size()):
		if entries[i].id == entries[i - 1].id:
			return _hello_fail(REASON_MALFORMED_HELLO, "mods")
	hello["mods"] = entries
	return {"ok": true, "reason": REASON_NONE, "detail": "", "hello": hello}


# accepted => reason "" and a session mode; rejected => a reason and no mode.
# strict: received data, where detail must already be display-safe.
func _is_consistent_decision(d: Dictionary, strict: bool) -> bool:
	var accepted = d.get("accepted")
	var reason = d.get("reason")
	var mode = d.get("mode")
	var note = d.get("note", "")
	var detail = d.get("detail", "")
	if typeof(accepted) != TYPE_BOOL or not _is_reason(reason) or not _is_reason(note):
		return false
	if typeof(mode) != TYPE_STRING or not MODES.has(mode) or typeof(detail) != TYPE_STRING:
		return false
	if strict and not _is_detail(detail):
		return false
	if accepted:
		return reason == REASON_NONE and mode != MODE_NONE
	return reason != REASON_NONE and mode == MODE_NONE


func _decision(accepted: bool, reason: String, mode: String, note: String, detail: String, reply: bool) -> Dictionary:
	return {"accepted": accepted, "reason": reason, "mode": mode, "note": note, "detail": _sanitize_detail(detail), "reply": reply}


func _verdict(reason: String, detail: String) -> Dictionary:
	return {"reason": reason, "detail": detail}


func _hello_fail(reason: String, detail: String) -> Dictionary:
	return {"ok": false, "reason": reason, "detail": detail, "hello": {}}


func _client_decision(accepted: bool, reason: String, mode: String, note: String, detail: String) -> Dictionary:
	return {"accepted": accepted, "reason": reason, "mode": mode, "note": note, "detail": _sanitize_detail(detail)}


# The record's upstream list as {"fingerprints", "candidates"}, or null when an
# entry is malformed. Only role "required" Brotato Online entries verify the
# upstream; UPSTREAM_ROLE_CANDIDATE entries name mods that block (R07).
func _read_upstream(entries):
	if typeof(entries) != TYPE_ARRAY:
		return null
	var fingerprints := []
	var candidates := []
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			return null
		var id = entry.get("id")
		var role = entry.get("role")
		var fingerprint = entry.get("normalized_fingerprint")
		if typeof(id) != TYPE_STRING or typeof(role) != TYPE_STRING or typeof(fingerprint) != TYPE_STRING:
			return null
		if id == UPSTREAM_ID and role == UPSTREAM_ROLE_REQUIRED:
			fingerprints.append(fingerprint.to_lower())
		elif role == UPSTREAM_ROLE_CANDIDATE:
			candidates.append(id)
	return {"fingerprints": fingerprints, "candidates": candidates}


# Array of Strings, or null.
func _read_strings(list):
	if typeof(list) != TYPE_ARRAY and typeof(list) != TYPE_STRING_ARRAY:
		return null
	var out := []
	for item in list:
		if typeof(item) != TYPE_STRING:
			return null
		out.append(item)
	return out


func _sorted_strings(list):
	if typeof(list) != TYPE_ARRAY and typeof(list) != TYPE_STRING_ARRAY:
		return list
	var out := []
	var all_strings := true
	for item in list:
		out.append(item)
		all_strings = all_strings and typeof(item) == TYPE_STRING
	if all_strings:
		out.sort()
	return out


func _sorted_mods(list):
	if typeof(list) != TYPE_ARRAY:
		return list
	var out := []
	for entry in list:
		if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("id")) != TYPE_STRING:
			return list.duplicate(true)
		out.append({"id": entry.get("id"), "version": entry.get("version")})
	out.sort_custom(self, "_mod_id_less")
	return out


func _mod_id_less(a: Dictionary, b: Dictionary) -> bool:
	return a.id < b.id


# int, or an integral float (JSON numbers) as int; anything else gives null.
func _to_int(value):
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_REAL and value == floor(value) and abs(value) < 1e15:
		return int(value)
	return null


func _int_or_raw(value):
	var as_int = _to_int(value)
	return as_int if typeof(as_int) == TYPE_INT else value


func _is_string(value, expected: String) -> bool:
	return typeof(value) == TYPE_STRING and value == expected


func _is_token(value, max_length: int, extra: String) -> bool:
	if typeof(value) != TYPE_STRING or value.empty() or value.length() > max_length:
		return false
	for i in range(value.length()):
		if not _is_allowed_char(value.ord_at(i), extra):
			return false
	return true


# Reason/note strings: "" or lower-case snake case.
func _is_reason(value) -> bool:
	if typeof(value) != TYPE_STRING or value.length() > MAX_REASON_LENGTH:
		return false
	for i in range(value.length()):
		var c: int = value.ord_at(i)
		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
			return false
	return true


func _is_detail(value) -> bool:
	if typeof(value) != TYPE_STRING or value.length() > MAX_DETAIL_LENGTH:
		return false
	for i in range(value.length()):
		if not _is_allowed_char(value.ord_at(i), DETAIL_CHARS):
			return false
	return true


func _is_hex64(value) -> bool:
	if typeof(value) != TYPE_STRING or value.length() != 64:
		return false
	for i in range(64):
		var c: int = value.ord_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


func _is_allowed_char(c: int, extra: String) -> bool:
	if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
		return true
	return c < 128 and extra.find(char(c)) != -1


# Display text for the UI and logs: bounded, and no markup characters.
func _sanitize_detail(text) -> String:
	if typeof(text) != TYPE_STRING:
		return ""
	var out := ""
	for i in range(int(min(text.length(), MAX_DETAIL_LENGTH))):
		out += text[i] if _is_allowed_char(text.ord_at(i), DETAIL_CHARS) else "_"
	return out


func _same_strings(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


func _join_list(list: Array) -> String:
	return "none" if list.empty() else PoolStringArray(list).join(",")


func _join_detail(reason: String, detail: String) -> String:
	return reason if detail.empty() else "%s:%s" % [reason, detail]


func _short(fingerprint: String) -> String:
	return fingerprint.substr(0, 12)
