extends Reference
# Redaction rules for diagnostics and problem reports (R21, AP-008/AP-018).
# Readers must be able to tell players apart without learning who they are:
#   identities  -> "<prefix>:#<8 hex>", a salted SHA-256 short hash. The salt
#                  is never written into any output; without a salt (or with
#                  one shorter than MIN_SALT_LENGTH) nothing is hashed (a
#                  known salt makes Steam ids brute-forceable)
#   free text   -> Steam64 ids become the same short form; UUIDs, long hex
#                  and base64-like tokens become MASK_TOKEN
#   structures  -> copied recursively (the input is never mutated); values
#                  under sensitive keys are masked or hashed by key class
# Output size is bounded per call: depth, items per container, string
# length, and a total node and character budget (a cyclic or shared-subtree
# input with fan-out would otherwise grow exponentially with depth). Every
# cut carries an explicit marker, so an oversized payload cannot grow the
# log without limit and nothing disappears silently. Non-finite floats
# become text markers so a report always survives to_json/parse_json.
# Pure rules: no autoloads, no scene tree.

const HASH_HEX_LENGTH := 8
const HASH_NO_SALT := "nosalt"
const HASH_EMPTY := "empty"
const FALLBACK_PREFIX := "id"
const STEAM_PREFIX := "steam"
const DEFAULT_IDENTITY_PREFIXES := ["steam", "lan", "peer", "local", "name", "id"]
# Shorter salts count as no salt: identities are hidden, not hashed. A short
# salt is guessable, and a known salt makes Steam ids brute-forceable.
const MIN_SALT_LENGTH := 8

const MASK_SECRET := "<redacted>"
const MASK_TOKEN := "<token>"
const MASK_OBJECT := "<object>"
const MASK_DEPTH := "<max_depth>"
const MASK_NAN := "<nan>"
const MASK_INF := "<inf>"
const MASK_NEG_INF := "<-inf>"
const BYTES_FORMAT := "<bytes:%d>"
const TRUNCATED_ITEMS_FORMAT := "<+%d items>"
const TRUNCATED_TEXT_FORMAT := "...<+%d chars>"
const TRUNCATED_KEY := "<truncated_items>"
const DUPLICATE_KEY_FORMAT := "%s~%d"

# Key classes, strongest first: a key matching several classes takes the
# first one in this order.
const KEY_SECRET := "secret"
const KEY_IDENTITY := "identity"
const KEY_PUBLIC := "public"
const KEY_PLAIN := "plain"

# Fragments are compared after lower-casing and dropping everything except
# a-z/0-9, so "reconnect_token", "ReconnectToken" and "reconnect-token" all
# contain "token". Matching is deliberately broad: a false positive only
# hides a value, a false negative leaks one.
#   secret   -> value replaced by MASK_SECRET (bool/null kept)
#   identity -> scalars hashed with redact_identity; inside containers the
#               dictionary keys are hashed as identities too
#   public   -> long hex kept (fingerprints, commits, seeds); Steam ids still hashed
const DEFAULT_SECRET_KEYS := ["token", "ticket", "auth", "password", "passwd", "secret", "credential", "reconnect", "session_key", "private_key", "api_key", "cookie", "salt"]
const DEFAULT_IDENTITY_KEYS := ["steam_id", "peer_key", "identity", "identities", "persona", "username", "nickname", "player_name", "display_name", "account_id", "user_id"]
const DEFAULT_PUBLIC_KEYS := ["fingerprint", "sha256", "checksum", "digest", "hash", "version", "commit", "run_id", "checkpoint_id", "seed"]

const DEFAULT_MAX_DEPTH := 12
const DEFAULT_MAX_ITEMS := 100
const DEFAULT_MAX_STRING_LENGTH := 1000
# Per redact_value call: values emitted (containers and scalars) and string
# characters kept, keys included. Typical 8-player records use well under 100.
const DEFAULT_MAX_TOTAL_NODES := 2000
const DEFAULT_MAX_TOTAL_CHARS := 32768
# Raw text kept before redaction, as a multiple of max_string_length: masks
# shrink tokens, so more raw text is needed to fill the limit afterwards.
const PRE_CUT_FACTOR := 4

# Individual Steam64 ids run from 76561197960265728 (account 0) up to
# 76561202255233023 (account 2^32-1), so new accounts reach the 7656120
# prefix. The range below covers both 17-digit prefixes 7656119 and 7656120.
const STEAM64_MIN := 76561190000000000
const STEAM64_MAX := 76561209999999999

var max_depth: int = DEFAULT_MAX_DEPTH
var max_items: int = DEFAULT_MAX_ITEMS
var max_string_length: int = DEFAULT_MAX_STRING_LENGTH
var max_total_nodes: int = DEFAULT_MAX_TOTAL_NODES
var max_total_chars: int = DEFAULT_MAX_TOTAL_CHARS

# Budgets left in the redact_value call in progress.
var _nodes_left := 0
var _chars_left := 0

var _secret_fragments := []
var _identity_fragments := []
var _public_fragments := []
var _non_alnum_re := RegEx.new()
var _steam_re := RegEx.new()
var _uuid_re := RegEx.new()
var _base64_re := RegEx.new()
var _hex_re := RegEx.new()
var _token_tail_re := RegEx.new()
var _redacted_identity_re := RegEx.new()


# Each list (Array or PoolStringArray) replaces the matching default when
# given; null or any other type keeps the default.
func _init(p_secret_keys = null, p_identity_keys = null, p_public_keys = null) -> void:
	_non_alnum_re.compile("[^a-z0-9]")
	# Optional "steam:" prefix so "steam:7656..." becomes "steam:#..." and not
	# "steam:steam:#...". Digits on either side mean it is part of a longer number.
	_steam_re.compile("(?i:steam:)?(?<![0-9])76561(?:19|20)[0-9]{10}(?![0-9])")
	_uuid_re.compile("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
	# Base64/base64url run of 24+ characters holding a digit, a lower-case and
	# an upper-case letter; the mix keeps ordinary words and most paths readable.
	_base64_re.compile("(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[A-Z])[A-Za-z0-9+/_-]{24,}={0,2}")
	_hex_re.compile("(?:0[xX])?[0-9A-Fa-f]{16,}")
	_token_tail_re.compile("[A-Za-z0-9+/=_-]+$")
	_redacted_identity_re.compile("^([a-z][a-z0-9_]{0,15}):#([0-9a-f]{%d}|%s|%s)$" % [HASH_HEX_LENGTH, HASH_NO_SALT, HASH_EMPTY])
	_secret_fragments = _normalize_list(_key_list(p_secret_keys, DEFAULT_SECRET_KEYS))
	_identity_fragments = _normalize_list(_key_list(p_identity_keys, DEFAULT_IDENTITY_KEYS))
	_public_fragments = _normalize_list(_key_list(p_public_keys, DEFAULT_PUBLIC_KEYS))


# Stable short form of one player identity, e.g. "steam:#1a2b3c4d". The same
# identity and salt always give the same result; a bare Steam64 id and
# "steam:<id>" are the same identity. Unknown prefixes become "id" so that a
# name or number in front of the colon is never shown. Already redacted
# values pass through unchanged.
func redact_identity(identity, salt) -> String:
	var text := _to_text(identity)
	if _is_redacted_identity(text):
		return text
	var canonical := canonical_identity(text)
	if canonical == "":
		return "%s:#%s" % [FALLBACK_PREFIX, HASH_EMPTY]
	var prefix := _prefix_of(canonical)
	# "steam:" with nothing after it is a missing id, not a player.
	if canonical == prefix + ":":
		return "%s:#%s" % [prefix, HASH_EMPTY]
	var salt_text := _salt_text(salt)
	if salt_text == "":
		return "%s:#%s" % [prefix, HASH_NO_SALT]
	# Length-prefixed salt so ("ab", "c") and ("a", "bc") hash differently.
	var digest := ("%d:%s%s" % [salt_text.length(), salt_text, canonical]).sha256_text()
	return "%s:#%s" % [prefix, digest.substr(0, HASH_HEX_LENGTH)]


func canonical_identity(identity) -> String:
	var text := _to_text(identity).strip_edges()
	if _is_steam64_text(text):
		return "%s:%s" % [STEAM_PREFIX, text]
	var colon := text.find(":")
	if colon > 0:
		var prefix := text.substr(0, colon).to_lower()
		if DEFAULT_IDENTITY_PREFIXES.has(prefix):
			return "%s:%s" % [prefix, text.substr(colon + 1).strip_edges()]
	return text


# Masks secrets inside free text. Unbounded: use redact_value for a length cap.
func redact_text(text, salt) -> String:
	return _redact_string(_to_text(text), _salt_text(salt), false)


# Redacted, bounded deep copy of any value. Dictionary keys are redacted as
# text; two keys that redact to the same text are kept apart with a "~N"
# suffix instead of overwriting each other. The node and character budgets
# start afresh on every call.
func redact_value(value, salt):
	_nodes_left = int(max(0, max_total_nodes))
	_chars_left = int(max(0, max_total_chars))
	return _walk(value, _salt_text(salt), KEY_PLAIN, 0)


func key_class(key) -> String:
	var normalized := _normalize(_to_text(key))
	if normalized == "":
		return KEY_PLAIN
	if _matches_any(normalized, _secret_fragments):
		return KEY_SECRET
	if _matches_any(normalized, _identity_fragments):
		return KEY_IDENTITY
	if _matches_any(normalized, _public_fragments):
		return KEY_PUBLIC
	return KEY_PLAIN


func _walk(value, salt: String, mode: String, depth: int):
	_nodes_left -= 1
	var t := typeof(value)
	if t == TYPE_NIL or t == TYPE_BOOL:
		return value
	if mode == KEY_SECRET:
		return MASK_SECRET
	if t == TYPE_DICTIONARY:
		return _walk_dict(value, salt, mode, depth)
	if t == TYPE_ARRAY:
		return _walk_array(value, salt, mode, depth)
	if t == TYPE_RAW_ARRAY:
		return BYTES_FORMAT % value.size()
	if t in [TYPE_INT_ARRAY, TYPE_REAL_ARRAY, TYPE_STRING_ARRAY, TYPE_VECTOR2_ARRAY, TYPE_VECTOR3_ARRAY, TYPE_COLOR_ARRAY]:
		return _walk_array(Array(value), salt, mode, depth)
	if t == TYPE_OBJECT:
		return MASK_OBJECT
	if t == TYPE_INT or t == TYPE_REAL:
		if mode == KEY_IDENTITY or _is_steam64_number(value):
			return redact_identity(value, salt)
		if t == TYPE_REAL and (is_nan(value) or is_inf(value)):
			# to_json writes nan/inf literally, which parse_json then rejects.
			if is_nan(value):
				return MASK_NAN
			return MASK_INF if value > 0.0 else MASK_NEG_INF
		return value
	if t == TYPE_STRING or t == TYPE_NODE_PATH:
		if mode == KEY_IDENTITY:
			return redact_identity(str(value), salt)
		return _bounded_string(str(value), salt, mode == KEY_PUBLIC)
	# Vectors, colors, rects and similar carry no text; copied by value.
	return value


# Children are walked while both the per-container item limit and the total
# node budget allow; the rest is counted in one marker.
func _walk_dict(source: Dictionary, salt: String, mode: String, depth: int):
	if depth >= max_depth:
		return MASK_DEPTH
	var out := {}
	var limit := int(max(0, max_items))
	var kept := 0
	for key in source.keys():
		if kept >= limit or _nodes_left <= 0:
			break
		kept += 1
		var out_key = _unique_key(out, _redact_key(key, salt, mode, depth))
		out[out_key] = _walk(source[key], salt, _child_mode(key, mode), depth + 1)
	if source.size() > kept:
		out[_unique_key(out, TRUNCATED_KEY)] = source.size() - kept
	return out


func _walk_array(source: Array, salt: String, mode: String, depth: int):
	if depth >= max_depth:
		return MASK_DEPTH
	var out := []
	var count := int(min(source.size(), max(0, max_items)))
	for i in range(count):
		if _nodes_left <= 0:
			break
		out.append(_walk(source[i], salt, mode, depth + 1))
	if source.size() > out.size():
		out.append(TRUNCATED_ITEMS_FORMAT % (source.size() - out.size()))
	return out


func _child_mode(key, parent_mode: String) -> String:
	var cls := key_class(key)
	if cls == KEY_SECRET or cls == KEY_IDENTITY:
		return cls
	if parent_mode == KEY_IDENTITY:
		return KEY_IDENTITY
	if cls == KEY_PUBLIC or parent_mode == KEY_PUBLIC:
		return KEY_PUBLIC
	return KEY_PLAIN


func _redact_key(key, salt: String, parent_mode: String, depth: int):
	if parent_mode == KEY_IDENTITY:
		return redact_identity(key, salt)
	var t := typeof(key)
	if t == TYPE_INT or t == TYPE_REAL:
		return redact_identity(key, salt) if _is_steam64_number(key) else key
	if t == TYPE_STRING or t == TYPE_NODE_PATH:
		return _bounded_string(str(key), salt, parent_mode == KEY_PUBLIC)
	if t == TYPE_OBJECT:
		return MASK_OBJECT
	if t == TYPE_DICTIONARY or t == TYPE_ARRAY or (t >= TYPE_RAW_ARRAY and t <= TYPE_COLOR_ARRAY):
		# A container key would otherwise be copied raw: unredacted and shared
		# with the input. Its redacted copy, as text, keeps it readable.
		return _bounded_string(str(_walk(key, salt, parent_mode, depth + 1)), salt, parent_mode == KEY_PUBLIC)
	return key


func _unique_key(target: Dictionary, key):
	if not target.has(key):
		return key
	var n := 2
	while target.has(DUPLICATE_KEY_FORMAT % [str(key), n]):
		n += 1
	return DUPLICATE_KEY_FORMAT % [str(key), n]


# Redacts first and cuts afterwards, so a token is never shortened below the
# masking threshold and leaked in part. A pre-cut of very long input drops
# the trailing token-like run it may have split; the salt is masked before
# that cut so no part of it can survive. The limit is the smaller of
# max_string_length and the characters left in the call's budget.
func _bounded_string(text: String, salt: String, public_mode: bool) -> String:
	var limit := int(max(0, min(max_string_length, _chars_left)))
	var work := text
	if salt != "":
		work = work.replace(salt, MASK_SECRET)
	var raw_length := work.length()
	var pre_limit := limit * PRE_CUT_FACTOR
	if work.length() > pre_limit:
		work = _token_tail_re.sub(work.substr(0, pre_limit), "")
	var omitted := raw_length - work.length()
	work = _redact_string(work, salt, public_mode)
	if work.length() > limit:
		omitted += work.length() - limit
		work = work.substr(0, limit)
	_chars_left -= work.length()
	if omitted > 0:
		work += TRUNCATED_TEXT_FORMAT % omitted
	return work


func _redact_string(text: String, salt: String, public_mode: bool) -> String:
	if text == "":
		return text
	var out := text
	if salt != "":
		out = out.replace(salt, MASK_SECRET)
	out = _replace_steam_ids(out, salt)
	if not public_mode:
		out = _uuid_re.sub(out, MASK_TOKEN, true)
		out = _base64_re.sub(out, MASK_TOKEN, true)
		out = _hex_re.sub(out, MASK_TOKEN, true)
	return out


func _replace_steam_ids(text: String, salt: String) -> String:
	var matches := _steam_re.search_all(text)
	if matches.empty():
		return text
	var out := ""
	var pos := 0
	for m in matches:
		var found: String = m.get_string()
		out += text.substr(pos, m.get_start() - pos)
		out += redact_identity(found.substr(found.length() - 17), salt)
		pos = m.get_end()
	return out + text.substr(pos)


func _is_redacted_identity(text: String) -> bool:
	var m := _redacted_identity_re.search(text)
	return m != null and DEFAULT_IDENTITY_PREFIXES.has(m.get_string(1))


func _prefix_of(canonical: String) -> String:
	var colon := canonical.find(":")
	if colon > 0:
		var prefix := canonical.substr(0, colon)
		if DEFAULT_IDENTITY_PREFIXES.has(prefix):
			return prefix
	return FALLBACK_PREFIX


func _is_steam64_text(text: String) -> bool:
	return text.length() == 17 and (text.begins_with("7656119") or text.begins_with("7656120")) and text.is_valid_integer()


func _is_steam64_number(value) -> bool:
	if typeof(value) == TYPE_INT:
		return value >= STEAM64_MIN and value <= STEAM64_MAX
	if typeof(value) == TYPE_REAL:
		return value >= float(STEAM64_MIN) and value <= float(STEAM64_MAX)
	return false


# The salt in effect: "" (no salt) unless a String of MIN_SALT_LENGTH or more.
func _salt_text(salt) -> String:
	if typeof(salt) != TYPE_STRING or salt.length() < MIN_SALT_LENGTH:
		return ""
	return salt


func _key_list(given, fallback: Array) -> Array:
	if typeof(given) == TYPE_ARRAY:
		return given
	if typeof(given) == TYPE_STRING_ARRAY:
		return Array(given)
	return fallback


# Integral floats print as integers so 7.6561198e16 hashes like its int.
func _to_text(value) -> String:
	var t := typeof(value)
	if t == TYPE_STRING:
		return value
	if t == TYPE_NIL:
		return ""
	if t == TYPE_REAL and value == floor(value) and abs(value) < 9.0e18:
		return str(int(value))
	return str(value)


func _normalize(text: String) -> String:
	return _non_alnum_re.sub(text.to_lower(), "", true)


func _normalize_list(items: Array) -> Array:
	var out := []
	for item in items:
		var n := _normalize(_to_text(item))
		if n != "" and not out.has(n):
			out.append(n)
	return out


func _matches_any(normalized: String, fragments: Array) -> bool:
	for f in fragments:
		if normalized.find(f) != -1:
			return true
	return false
