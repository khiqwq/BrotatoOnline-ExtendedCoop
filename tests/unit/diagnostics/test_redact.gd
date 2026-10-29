extends "res://tests/runner/test_case.gd"

const Redact = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/diagnostics/redact.gd")

const SALT := "test-salt-0123456789"
const STEAM_A := "76561198000000001"
const STEAM_B := "76561198000000002"
const HEX_TOKEN := "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
const B64_TOKEN := "dGhpcyBpcyBhIHNlY3JldCB0b2tlbjEyMw=="

var r


func before_each() -> void:
	r = Redact.new()


func _steam(n: int) -> String:
	return str(76561198000000000 + n)


func _rep(text: String, count: int) -> String:
	var out := ""
	for i in range(count):
		out += text
	return out


func _is_short_form(text: String, prefix: String) -> bool:
	var re := RegEx.new()
	re.compile("^%s:#[0-9a-f]{8}$" % prefix)
	return re.search(text) != null


# --- redact_identity ---------------------------------------------------------

func test_identity_short_form_hides_value_and_salt() -> void:
	var out: String = r.redact_identity("steam:" + STEAM_A, SALT)
	assert_true(_is_short_form(out, "steam"), out)
	assert_eq(out.find(STEAM_A), -1)
	assert_eq(out.find(SALT), -1)
	assert_eq(out, r.redact_identity("steam:" + STEAM_A, SALT), "stable for the same input")


func test_identity_hash_is_salted() -> void:
	var a: String = r.redact_identity(STEAM_A, SALT)
	assert_ne(a, r.redact_identity(STEAM_A, "other-salt-abcdef"))
	assert_ne(a, r.redact_identity(STEAM_A, SALT + "x"))


func test_identity_hash_format_is_stable() -> void:
	# Pins the scheme sha256("<len(salt)>:<salt><canonical>")[0..8]; changing it
	# breaks comparing hashes between reports made by different builds.
	var expected := ("%d:%s%s" % [SALT.length(), SALT, "steam:" + STEAM_A]).sha256_text().substr(0, 8)
	assert_eq(r.redact_identity(STEAM_A, SALT), "steam:#" + expected)


func test_salt_and_value_boundary_is_unambiguous() -> void:
	# A plain salt+value concatenation hashes "boundary_axbc" for both.
	var a: String = r.redact_identity("xbc", "boundary_a")
	var b: String = r.redact_identity("c", "boundary_axb")
	assert_true(_is_short_form(a, "id") and _is_short_form(b, "id"), "same prefix, only the hash can differ")
	assert_ne(a, b)


func test_every_player_of_eight_gets_a_distinct_hash() -> void:
	for count in range(1, 10):
		var seen := {}
		for i in range(count):
			var out: String = r.redact_identity(_steam(i + 1), SALT)
			assert_true(_is_short_form(out, "steam"), out)
			assert_false(seen.has(out), "players %d collide at %d" % [count, i])
			seen[out] = true
		assert_eq(seen.size(), count, "players %d" % count)


func test_bare_and_prefixed_steam_ids_are_the_same_identity() -> void:
	var expected: String = r.redact_identity("steam:" + STEAM_A, SALT)
	assert_eq(r.redact_identity(STEAM_A, SALT), expected)
	assert_eq(r.redact_identity("STEAM:" + STEAM_A, SALT), expected)
	assert_eq(r.redact_identity(" steam: " + STEAM_A + " ", SALT), expected)
	assert_eq(r.redact_identity(76561198000000001, SALT), expected, "int steam id")
	assert_eq(r.canonical_identity(STEAM_A), "steam:" + STEAM_A)


func test_known_prefixes_are_kept_and_unknown_ones_hidden() -> void:
	assert_true(_is_short_form(r.redact_identity("lan:3f2a-host", SALT), "lan"))
	assert_true(_is_short_form(r.redact_identity("peer:1234567", SALT), "peer"))
	var named: String = r.redact_identity("alice:42", SALT)
	assert_true(_is_short_form(named, "id"), named)
	assert_eq(named.find("alice"), -1)
	var numeric: String = r.redact_identity("76561198000000001:x", SALT)
	assert_true(_is_short_form(numeric, "id"), numeric)
	assert_true(_is_short_form(r.redact_identity("no prefix at all", SALT), "id"))
	assert_ne(r.redact_identity("alice:42", SALT), r.redact_identity("bob:42", SALT), "hash covers the hidden prefix")


func test_identity_without_salt_is_not_hashed() -> void:
	for salt in ["", null, 12345, "1234567", "short"]:
		var out: String = r.redact_identity(STEAM_A, salt)
		assert_eq(out, "steam:#" + Redact.HASH_NO_SALT, "salt %s" % str(salt))
		assert_eq(out.find("7656"), -1)


func test_short_salt_is_treated_as_no_salt_everywhere() -> void:
	# A short salt is guessable; hashing with it would make Steam ids
	# reversible, and it would not be masked in text either.
	var short := "1234567"
	assert_eq(short.length(), Redact.MIN_SALT_LENGTH - 1)
	assert_eq(r.redact_value({"identity": STEAM_A}, short).identity, "steam:#" + Redact.HASH_NO_SALT)
	assert_eq(r.redact_text("p " + STEAM_A, short), "p steam:#" + Redact.HASH_NO_SALT)
	var just_long_enough := "12345678"
	assert_true(_is_short_form(r.redact_identity(STEAM_A, just_long_enough), "steam"), "8 characters hash")
	assert_eq(r.redact_text("salt=" + just_long_enough, just_long_enough), "salt=" + Redact.MASK_SECRET)


func test_empty_identity_is_marked() -> void:
	assert_eq(r.redact_identity("", SALT), "id:#" + Redact.HASH_EMPTY)
	assert_eq(r.redact_identity(null, SALT), "id:#" + Redact.HASH_EMPTY)
	assert_eq(r.redact_identity("   ", SALT), "id:#" + Redact.HASH_EMPTY)
	# A known prefix with no value is a missing id, not a hashed player.
	assert_eq(r.redact_identity("steam:", SALT), "steam:#" + Redact.HASH_EMPTY)
	assert_eq(r.redact_identity("LAN: ", SALT), "lan:#" + Redact.HASH_EMPTY)
	var unknown: String = r.redact_identity("alice:", SALT)
	assert_true(_is_short_form(unknown, "id"), "unknown prefix stays hashed: " + unknown)


func test_identity_redaction_is_idempotent() -> void:
	for identity in [STEAM_A, "lan:host", "alice:1", ""]:
		var once: String = r.redact_identity(identity, SALT)
		assert_eq(r.redact_identity(once, SALT), once, identity)
		assert_eq(r.redact_identity(once, "different-salt-1"), once, identity)
	assert_eq(r.redact_identity("steam:#nosalt", SALT), "steam:#nosalt")


# --- redact_text -------------------------------------------------------------

func test_text_steam_ids_use_the_identity_short_form() -> void:
	var out: String = r.redact_text("peer %s left, %s joined" % [STEAM_A, STEAM_B], SALT)
	var a: String = r.redact_identity(STEAM_A, SALT)
	var b: String = r.redact_identity(STEAM_B, SALT)
	assert_eq(out, "peer %s left, %s joined" % [a, b])
	assert_eq(r.redact_text("owner=steam:%s;" % STEAM_A, SALT), "owner=%s;" % a, "prefix not doubled")
	assert_eq(r.redact_text("x%sy" % STEAM_A, SALT), "x%sy" % a, "letters around the id")


func test_text_masks_all_eight_steam_ids() -> void:
	var parts := []
	for i in range(8):
		parts.append(_steam(i + 1))
	var out: String = r.redact_text(PoolStringArray(parts).join(","), SALT)
	for i in range(8):
		assert_eq(out.find(_steam(i + 1)), -1, "player %d" % (i + 1))
		assert_true(out.find(r.redact_identity(_steam(i + 1), SALT)) != -1, "player %d" % (i + 1))
	assert_eq(out.split(",").size(), 8)


func test_steam_ids_with_the_7656120_prefix_are_identities_too() -> void:
	# Account ids above 2039734271 give Steam64 ids 76561200000000000 and up.
	var newer := "76561200000000123"
	var newer_int := 76561200000000123
	var expected: String = r.redact_identity("steam:" + newer, SALT)
	assert_true(_is_short_form(expected, "steam"), expected)
	assert_eq(r.canonical_identity(newer), "steam:" + newer)
	assert_eq(r.redact_identity(newer, SALT), expected, "bare id")
	assert_eq(r.redact_identity(newer_int, SALT), expected, "int id")
	assert_eq(r.redact_text("peer %s left" % newer, SALT), "peer %s left" % expected, "short form in text, not <token>")
	var out = r.redact_value({"owner": newer_int, "version": "built by " + newer, "keys": {newer_int: 1}}, SALT)
	assert_eq(out.owner, expected, "int under a plain key")
	assert_eq(out.version, "built by " + expected, "text under a public key")
	assert_eq(out["keys"].keys(), [expected], "int dictionary key")
	assert_eq(var2str(out).find(newer), -1)
	# Both prefixes side by side: eight players and a ninth stay distinct.
	var seen := {}
	for i in range(9):
		var raw := str((76561199999999996 if i % 2 == 0 else 76561200000000000) + i)
		seen[r.redact_identity(raw, SALT)] = true
		assert_eq(r.redact_text(raw, SALT), r.redact_identity(raw, SALT), raw)
	assert_eq(seen.size(), 9)


func test_longer_digit_runs_are_not_read_as_steam_ids_but_still_masked() -> void:
	var longer := "1" + STEAM_A + "1"
	var out: String = r.redact_text("n=%s" % longer, SALT)
	assert_eq(out, "n=" + Redact.MASK_TOKEN)
	assert_eq(out.find("steam"), -1)


func test_text_masks_hex_uuid_and_base64_tokens() -> void:
	assert_eq(r.redact_text("ticket " + HEX_TOKEN + " end", SALT), "ticket <token> end")
	assert_eq(r.redact_text("0x0123456789abcdef", SALT), Redact.MASK_TOKEN)
	assert_eq(r.redact_text("id 123e4567-e89b-12d3-a456-426614174000.", SALT), "id <token>.")
	assert_eq(r.redact_text("tok=" + B64_TOKEN, SALT), "tok=<token>")
	assert_eq(r.redact_text("u=abcDEF123_-xyzXYZ789abcDEF", SALT), "u=<token>")
	assert_eq(r.redact_text("ABCDEF0123456789", SALT), Redact.MASK_TOKEN, "upper-case hex")


func test_hex_threshold_is_sixteen_characters() -> void:
	assert_eq(r.redact_text("0123456789abcde", SALT), "0123456789abcde", "15 kept")
	assert_eq(r.redact_text("0123456789abcdef", SALT), Redact.MASK_TOKEN, "16 masked")


func test_ordinary_text_is_kept() -> void:
	for text in [
		"res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd",
		"CoopPlus-OnlineExtendedCoop six666-BrotatoOnline 6.6.6",
		"wave 12 phase shop roster_generation 3 players 8",
		"at 1730000000000 msec, P5 timed out after 30000",
		"steam:#1a2b3c4d and lan:#0f0f0f0f",
		"session_full",
		"",
	]:
		assert_eq(r.redact_text(text, SALT), text, text)


func test_text_masks_the_salt_itself() -> void:
	var out: String = r.redact_text("salt is %s here" % SALT, SALT)
	assert_eq(out.find(SALT), -1)
	assert_eq(out, "salt is <redacted> here")


func test_text_accepts_non_strings() -> void:
	assert_eq(r.redact_text(null, SALT), "")
	assert_eq(r.redact_text(76561198000000001, SALT), r.redact_identity(STEAM_A, SALT))
	assert_eq(r.redact_text(42, SALT), "42")


func test_text_redaction_is_idempotent() -> void:
	var text := "peer %s token %s uuid 123e4567-e89b-12d3-a456-426614174000 b64 %s" % [STEAM_A, HEX_TOKEN, B64_TOKEN]
	var once: String = r.redact_text(text, SALT)
	assert_eq(r.redact_text(once, SALT), once)


# --- key classes ---------------------------------------------------------------

func test_key_classes_ignore_case_and_separators() -> void:
	for key in ["token", "reconnect_token", "ReconnectToken", "auth-ticket", "PASSWORD", "client_secret", "credentials", "session_key", "SessionKey"]:
		assert_eq(r.key_class(key), Redact.KEY_SECRET, key)
	for key in ["steam_id", "steamId", "owner_steam_id", "SteamID64", "peer_key", "identity", "identities", "player_identity", "persona_name"]:
		assert_eq(r.key_class(key), Redact.KEY_IDENTITY, key)
	for key in ["fingerprint", "upstream_fingerprint", "sha256", "versions", "commit", "run_id", "seed", "rng_seed"]:
		assert_eq(r.key_class(key), Redact.KEY_PUBLIC, key)
	for key in ["salt", "diag_salt", "HashSalt"]:
		assert_eq(r.key_class(key), Redact.KEY_SECRET, key)
	for key in ["slot", "wave", "phase", "reason", "", 5, null]:
		assert_eq(r.key_class(key), Redact.KEY_PLAIN, str(key))
	assert_eq(r.key_class("identity_token"), Redact.KEY_SECRET, "secret wins over identity")
	assert_eq(r.key_class("password_hash"), Redact.KEY_SECRET, "secret wins over public")


func test_key_lists_are_configurable() -> void:
	var custom = Redact.new(["pin_code"], ["member"], [])
	assert_eq(custom.key_class("PinCode"), Redact.KEY_SECRET)
	assert_eq(custom.key_class("member_list"), Redact.KEY_IDENTITY)
	assert_eq(custom.key_class("token"), Redact.KEY_PLAIN, "list replaces the default")
	assert_eq(custom.key_class("fingerprint"), Redact.KEY_PLAIN)
	var kept_defaults = Redact.new(["pin"], null, null)
	assert_eq(kept_defaults.key_class("steam_id"), Redact.KEY_IDENTITY, "null keeps the default")
	var ignores_empty = Redact.new(["", "__", "pin"], null, null)
	assert_eq(ignores_empty.key_class("slot"), Redact.KEY_PLAIN, "empty fragment must not match everything")
	# A PoolStringArray is a list too; it must not fall back to the defaults
	# and silently leave the caller's own secret key unmasked.
	var pooled = Redact.new(PoolStringArray(["pin_code"]), PoolStringArray(["member"]), PoolStringArray([]))
	assert_eq(pooled.key_class("pin_code"), Redact.KEY_SECRET)
	assert_eq(pooled.key_class("member"), Redact.KEY_IDENTITY)
	assert_eq(pooled.key_class("token"), Redact.KEY_PLAIN, "pooled list replaces the default")
	assert_eq(pooled.key_class("fingerprint"), Redact.KEY_PLAIN)
	assert_eq(pooled.redact_value({"pin_code": "0000"}, SALT).pin_code, Redact.MASK_SECRET)
	var wrong_type = Redact.new("pin", 5, {})
	assert_eq(wrong_type.key_class("token"), Redact.KEY_SECRET, "non-list keeps the default")
	assert_eq(wrong_type.key_class("steam_id"), Redact.KEY_IDENTITY)
	assert_eq(wrong_type.key_class("fingerprint"), Redact.KEY_PUBLIC)


# --- redact_value --------------------------------------------------------------

func _sample_context(players: int) -> Dictionary:
	var slots := []
	for i in range(players):
		slots.append({"slot": i + 1, "identity": "steam:" + _steam(i + 1), "connected": i % 2 == 0})
	return {
		"reason": "peer %s timed out" % STEAM_A,
		"reconnect_token": HEX_TOKEN,
		"auth": {"ticket": B64_TOKEN, "steam_id": 76561198000000001},
		"Password": "hunter2",
		"has_token": true,
		"secret_none": null,
		"owner": 76561198000000002,
		"versions": {"six666-BrotatoOnline": "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819", "extension": "0.1.0"},
		"stamp": {"run_id": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "wave": 7, "phase": "shop", "roster_generation": 2},
		"slots": slots,
	}


func test_value_masks_sensitive_keys_and_keeps_the_rest() -> void:
	var out = r.redact_value(_sample_context(8), SALT)
	assert_eq(out.reconnect_token, Redact.MASK_SECRET)
	assert_eq(out.auth, Redact.MASK_SECRET, "whole container under a secret key")
	assert_eq(out.Password, Redact.MASK_SECRET)
	assert_eq(out.has_token, true, "booleans carry no secret")
	assert_null(out.secret_none)
	assert_eq(out.owner, r.redact_identity(STEAM_B, SALT), "steam id as an int value")
	assert_eq(out.reason, "peer %s timed out" % r.redact_identity(STEAM_A, SALT))
	assert_eq(out.versions["six666-BrotatoOnline"], "17443875f52fd7659af33d0f0deb9fb495b0d46110aaeba08d0fc419d439b819", "fingerprint kept")
	assert_eq(out.versions.extension, "0.1.0")
	assert_eq(out.stamp.run_id, "a1b2c3d4e5f60718293a4b5c6d7e8f90", "run id is public")
	assert_eq(out.stamp.wave, 7)
	assert_eq(out.stamp.phase, "shop")
	assert_eq(out.stamp.roster_generation, 2)
	var dump := var2str(out)
	for raw in [STEAM_A, STEAM_B, HEX_TOKEN, B64_TOKEN, "hunter2", SALT]:
		assert_eq(dump.find(raw), -1, "leaked %s" % raw)


func test_slot_summary_keeps_every_player_for_one_to_nine() -> void:
	for players in range(1, 10):
		var out = r.redact_value(_sample_context(players), SALT)
		assert_eq(out.slots.size(), players, "players %d" % players)
		var seen := {}
		for i in range(out.slots.size()):
			var s: Dictionary = out.slots[i]
			assert_eq(s.slot, i + 1, "slot number keeps int type, players %d" % players)
			assert_eq(s.connected, i % 2 == 0)
			assert_eq(s.identity, r.redact_identity(_steam(i + 1), SALT))
			seen[s.identity] = true
		assert_eq(seen.size(), players, "distinct identities, players %d" % players)


func test_value_never_mutates_its_input() -> void:
	var input := _sample_context(8)
	input["bytes"] = PoolByteArray([1, 2, 3])
	input["list"] = [STEAM_A, [HEX_TOKEN]]
	var before := var2str(input)
	var out = r.redact_value(input, SALT)
	assert_eq(var2str(input), before)
	out.slots[0].slot = 99
	out.list[1].append("x")
	assert_eq(input.slots[0].slot, 1, "output shares no containers with the input")
	assert_eq(input.list[1].size(), 1)


func test_identity_containers_hash_scalars_and_keys() -> void:
	var out = r.redact_value({
		"identities": [STEAM_A, "lan:host-2", 1234567, true],
		"peer_key": 1234567,
		"slot_by_identity": {"steam:" + STEAM_B: 3},
	}, SALT)
	assert_eq(out.identities[0], r.redact_identity(STEAM_A, SALT))
	assert_true(_is_short_form(out.identities[1], "lan"))
	assert_eq(out.identities[2], r.redact_identity("1234567", SALT), "int identity hashed")
	assert_eq(out.identities[3], true)
	assert_eq(out.peer_key, out.identities[2])
	var keys: Array = out.slot_by_identity.keys()
	assert_eq(keys.size(), 1)
	assert_eq(keys[0], r.redact_identity(STEAM_B, SALT), "identity map key hashed")
	# Strict rule: scalars under an identity key are identities, so a slot
	# number in an identity-keyed map is hashed too (use lists of records).
	assert_eq(out.slot_by_identity[keys[0]], r.redact_identity("3", SALT))


func test_steam_ids_as_dictionary_keys_are_hashed() -> void:
	var out = r.redact_value({STEAM_A: {"slot": 1}, 76561198000000002: {"slot": 2}, 7: "seven"}, SALT)
	assert_eq(out.size(), 3)
	assert_true(out.has(r.redact_identity(STEAM_A, SALT)))
	assert_true(out.has(r.redact_identity(STEAM_B, SALT)), "int key")
	assert_eq(out[r.redact_identity(STEAM_B, SALT)].slot, 2)
	assert_eq(out[7], "seven", "ordinary int keys keep their type")


func test_keys_that_redact_alike_are_not_merged() -> void:
	var input := {}
	for i in range(8):
		input["%064x" % (i + 1)] = i
	var out = r.redact_value(input, SALT)
	assert_eq(out.size(), 8, "no entry overwritten")
	var values: Array = out.values()
	values.sort()
	assert_eq(values, [0, 1, 2, 3, 4, 5, 6, 7])
	assert_true(out.has(Redact.MASK_TOKEN))
	assert_true(out.has(Redact.MASK_TOKEN + "~2"))


func test_public_keys_still_hash_steam_ids() -> void:
	var out = r.redact_value({"version": "build by " + STEAM_A, "fingerprint": HEX_TOKEN}, SALT)
	assert_eq(out.version, "build by " + r.redact_identity(STEAM_A, SALT))
	assert_eq(out.fingerprint, HEX_TOKEN)
	assert_eq(r.redact_value({"note": HEX_TOKEN}, SALT).note, Redact.MASK_TOKEN, "same hex under a plain key")


func test_special_types() -> void:
	var out = r.redact_value({
		"bytes": PoolByteArray([1, 2, 3, 4]),
		"names": PoolStringArray([STEAM_A, "ok"]),
		"object": Reference.new(),
		"pos": Vector2(1, 2),
		"ratio": 0.5,
		"steam_float": 76561198000000001.0,
		"path": NodePath("/root/Main"),
	}, SALT)
	assert_eq(out.bytes, "<bytes:4>")
	assert_eq(out.names, [r.redact_identity(STEAM_A, SALT), "ok"])
	assert_eq(out.object, Redact.MASK_OBJECT)
	assert_eq(out.pos, Vector2(1, 2))
	assert_eq(out.ratio, 0.5)
	assert_true(_is_short_form(out.steam_float, "steam"), str(out.steam_float))
	assert_eq(out.path, "/root/Main")


func test_non_finite_floats_become_markers_so_json_survives() -> void:
	var out = r.redact_value({"ratio": NAN, "fps_over_zero": INF, "low": -INF, "ok": 1.5, "list": [NAN, 2.0]}, SALT)
	assert_eq(out.ratio, Redact.MASK_NAN)
	assert_eq(out.fps_over_zero, Redact.MASK_INF)
	assert_eq(out.low, Redact.MASK_NEG_INF)
	assert_eq(out.ok, 1.5)
	assert_eq(out.list, [Redact.MASK_NAN, 2.0])
	# Godot 3 to_json writes nan/inf literally and parse_json rejects that.
	var parsed = parse_json(to_json(out))
	assert_eq(typeof(parsed), TYPE_DICTIONARY, "report text must stay valid JSON")
	assert_eq(r.redact_value(INF, SALT), Redact.MASK_INF, "top level")


func test_container_keys_are_redacted_and_not_shared() -> void:
	var array_key := [STEAM_A, HEX_TOKEN]
	var dict_key := {"token": "hunter2"}
	var bytes_key := PoolByteArray([1, 2, 3])
	var input := {array_key: 1, dict_key: 2, bytes_key: 3, Vector2(1, 2): 4}
	var out = r.redact_value(input, SALT)
	assert_eq(out.size(), 4, "no key merged or dropped")
	var dump := var2str(out)
	for raw in [STEAM_A, HEX_TOKEN, "hunter2"]:
		assert_eq(dump.find(raw), -1, "leaked %s through a container key" % raw)
	var string_keys := 0
	for k in out.keys():
		if typeof(k) == TYPE_STRING:
			string_keys += 1
	assert_eq(string_keys, 3, "container keys become redacted text")
	assert_true(out.has(str([r.redact_identity(STEAM_A, SALT), Redact.MASK_TOKEN])), dump)
	assert_true(out.has(Vector2(1, 2)), "value-type keys are kept as they are")
	array_key.append("later")
	assert_eq(var2str(out).find("later"), -1, "output key shares nothing with the input")
	var under_identity = r.redact_value({"identities": {[STEAM_A]: 1}}, SALT)
	assert_eq(var2str(under_identity).find(STEAM_A), -1)


func test_scalars_at_top_level() -> void:
	assert_eq(r.redact_value(5, SALT), 5)
	assert_eq(r.redact_value(null, SALT), null)
	assert_eq(r.redact_value(STEAM_A, SALT), r.redact_identity(STEAM_A, SALT))
	assert_eq(r.redact_value(76561198000000001, SALT), r.redact_identity(STEAM_A, SALT))
	assert_eq(r.redact_value(HEX_TOKEN, SALT), Redact.MASK_TOKEN)


func test_value_redaction_is_idempotent() -> void:
	var once = r.redact_value(_sample_context(8), SALT)
	assert_eq(var2str(r.redact_value(once, SALT)), var2str(once))


# --- bounds ----------------------------------------------------------------------

func test_cyclic_and_deep_structures_stop_at_max_depth() -> void:
	var cyclic := {"name": "loop"}
	cyclic["self"] = cyclic
	var out = r.redact_value(cyclic, SALT)
	cyclic.erase("self")
	var depth := 0
	var node = out
	while typeof(node) == TYPE_DICTIONARY:
		assert_eq(node.name, "loop")
		node = node["self"]
		depth += 1
	assert_eq(node, Redact.MASK_DEPTH)
	assert_eq(depth, Redact.DEFAULT_MAX_DEPTH)
	var nested := []
	var inner := nested
	for i in range(50):
		var next := []
		inner.append(next)
		inner = next
	var deep = r.redact_value(nested, SALT)
	var levels := 0
	while typeof(deep) == TYPE_ARRAY:
		deep = deep[0]
		levels += 1
	assert_eq(levels, Redact.DEFAULT_MAX_DEPTH)
	assert_eq(deep, Redact.MASK_DEPTH)


func test_large_containers_are_cut_with_a_marker() -> void:
	r.max_items = 8
	var big := []
	for i in range(20):
		big.append(i)
	var out = r.redact_value(big, SALT)
	assert_eq(out.size(), 9)
	assert_eq(out[7], 7)
	assert_eq(out[8], "<+12 items>")
	var exact := [0, 1, 2, 3, 4, 5, 6, 7]
	assert_eq(r.redact_value(exact, SALT), exact, "eight items fit without a marker")
	var dict := {}
	for i in range(11):
		dict["k%d" % i] = i
	var dout = r.redact_value(dict, SALT)
	assert_eq(dout.size(), 9)
	assert_eq(dout[Redact.TRUNCATED_KEY], 3)
	assert_eq(dout.k7, 7)
	assert_false(dout.has("k8"))


func test_long_strings_are_cut_after_redaction() -> void:
	r.max_string_length = 40
	var text := "start " + STEAM_A + " " + _rep("x", 100)
	var out: String = r.redact_value(text, SALT)
	assert_true(out.begins_with("start " + r.redact_identity(STEAM_A, SALT)), out)
	assert_true(out.ends_with(Redact.TRUNCATED_TEXT_FORMAT % (text.length() - 40 - 2)), out)
	assert_eq(out.find(STEAM_A), -1)
	var short := _rep("x", 40)
	assert_eq(r.redact_value(short, SALT), short, "exactly at the limit")


func test_pre_cut_never_leaks_part_of_a_token() -> void:
	# Limit 20 keeps 80 raw characters before redaction. The cut splits the
	# second value after 15 characters, too short to be masked on its own,
	# and the first token shrinks to MASK_TOKEN, so without dropping the
	# split tail part of it would survive the final cut.
	r.max_string_length = 20
	var out: String = r.redact_value(HEX_TOKEN + " " + _rep("fedcba9876543210", 4), SALT)
	assert_eq(out, Redact.MASK_TOKEN + " " + Redact.TRUNCATED_TEXT_FORMAT % 64)
	assert_eq(out.find("fedcba"), -1, out)
	var steam_out: String = r.redact_value(HEX_TOKEN + " " + STEAM_A + " tail", SALT)
	assert_eq(steam_out.find("7656119"), -1, steam_out)
	assert_eq(steam_out, Redact.MASK_TOKEN + " " + Redact.TRUNCATED_TEXT_FORMAT % 22)


# Counts every value in an output tree (containers, scalars, markers).
func _count_values(value) -> int:
	var n := 1
	if typeof(value) == TYPE_DICTIONARY:
		for k in value.keys():
			n += _count_values(value[k])
	elif typeof(value) == TYPE_ARRAY:
		for v in value:
			n += _count_values(v)
	return n


func _has_marker(value) -> bool:
	if typeof(value) == TYPE_DICTIONARY:
		if value.has(Redact.TRUNCATED_KEY):
			return true
		for k in value.keys():
			if _has_marker(value[k]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for v in value:
			if typeof(v) == TYPE_STRING and v.begins_with("<+"):
				return true
			if _has_marker(v):
				return true
	return false


func test_shared_subtrees_with_fan_out_stay_within_the_node_budget() -> void:
	# Depth and per-container limits alone multiply: a node referenced four
	# times per level yields 4^depth values. The node budget caps the total.
	r.max_depth = 8
	r.max_total_nodes = 200
	var fan := {}
	for i in range(4):
		fan["child%d" % i] = fan
	var fan_list := []
	for i in range(4):
		fan_list.append(fan_list)
	for input in [fan, fan_list]:
		var out = r.redact_value(input, SALT)
		var count := _count_values(out)
		assert_true(count <= 2 * r.max_total_nodes, "values %d" % count)
		assert_true(count >= r.max_total_nodes / 2, "budget is used, not cut early: %d" % count)
		assert_true(_has_marker(out), "the cut is marked")
	fan.clear()
	fan_list.clear()
	r.max_depth = Redact.DEFAULT_MAX_DEPTH
	r.max_total_nodes = Redact.DEFAULT_MAX_TOTAL_NODES
	var normal = r.redact_value(_sample_context(8), SALT)
	assert_false(_has_marker(normal), "an eight-player context is far below the budget")


func test_total_character_budget_is_shared_by_one_call() -> void:
	r.max_total_chars = 5000
	var big := []
	for i in range(50):
		big.append(_rep("x", 1000))
	var out = r.redact_value(big, SALT)
	assert_eq(out.size(), 50, "every item keeps a place")
	for i in range(5):
		assert_eq(out[i], big[i], "item %d within budget" % i)
	for i in range(5, 50):
		assert_eq(out[i], Redact.TRUNCATED_TEXT_FORMAT % 1000, "item %d marked" % i)
	# Keys draw on the same budget: the 1000 key characters leave 500 for the value.
	r.max_total_chars = 1500
	var keyed := {}
	keyed[_rep("k", 3000)] = _rep("v ", 1500)
	var kout = r.redact_value(keyed, SALT)
	var key_out := _rep("k", 1000) + Redact.TRUNCATED_TEXT_FORMAT % 2000
	assert_eq(kout.keys(), [key_out])
	assert_eq(kout[key_out], _rep("v ", 250) + Redact.TRUNCATED_TEXT_FORMAT % 2500)
	assert_eq(r.redact_value(big, SALT)[0], big[0], "the next call starts with a fresh budget")


func test_salt_split_by_the_pre_cut_never_leaks() -> void:
	# Salt with characters outside the token class: before the fix the pre-cut
	# split it, the full-salt mask missed, and its front survived the cut.
	var salt := "pepper. salt. 42"
	r.max_string_length = 20
	var out: String = r.redact_value(HEX_TOKEN + " " + salt + " tail", salt)
	assert_eq(out.find("pepper"), -1, out)
	assert_eq(out.find("salt."), -1, out)
	assert_true(out.begins_with(Redact.MASK_TOKEN + " " + Redact.MASK_SECRET), out)


func test_zero_limits_still_mark_everything() -> void:
	r.max_items = 0
	r.max_string_length = 0
	var out = r.redact_value({"a": [1, 2], "b": "text"}, SALT)
	assert_eq(out.size(), 1)
	assert_eq(out[Redact.TRUNCATED_KEY], 2)
	assert_eq(r.redact_value("abc", SALT), Redact.TRUNCATED_TEXT_FORMAT % 3)
	r.max_depth = 0
	assert_eq(r.redact_value({"a": 1}, SALT), Redact.MASK_DEPTH)
