extends Reference
# Capacity rules for one session (R01, F01). Keeps the different meanings of
# "player count" apart:
#   capacity      - fixed when the session is created, never changes mid-run
#   member count  - connected session members (host included), drops on disconnect
#   roster count  - stable slots that belong to the current run, kept on disconnect
# Pure rules: no autoloads, no scene tree.

const VANILLA_MAX_PLAYERS := 4
const MAX_SUPPORTED_PLAYERS := 8

const REJECT_NONE := ""
const REJECT_FULL := "session_full"
const REJECT_RUN_FROZEN := "run_slots_frozen"
const REJECT_INVALID_CAPACITY := "invalid_capacity"

var capacity: int = MAX_SUPPORTED_PLAYERS


func _init(p_capacity: int = MAX_SUPPORTED_PLAYERS) -> void:
	capacity = p_capacity


func is_valid() -> bool:
	return capacity >= 1 and capacity <= MAX_SUPPORTED_PLAYERS


func is_extended() -> bool:
	return capacity > VANILLA_MAX_PLAYERS


func is_legal_count(count: int) -> bool:
	return is_valid() and count >= 1 and count <= capacity


# One player per machine, so every slot except the host's is remote.
func max_remote_players() -> int:
	return capacity - 1 if is_valid() else 0


func free_slots(member_count: int) -> int:
	return int(max(0, capacity - member_count)) if is_valid() else 0


# Decision for a new (not previously seated) member asking to join.
# Returning members are handled by the slot registry, not here.
func check_join(member_count: int, run_slots_frozen: bool) -> Dictionary:
	if not is_valid():
		return {"accepted": false, "reason": REJECT_INVALID_CAPACITY}
	if run_slots_frozen:
		return {"accepted": false, "reason": REJECT_RUN_FROZEN}
	if member_count >= capacity:
		return {"accepted": false, "reason": REJECT_FULL}
	return {"accepted": true, "reason": REJECT_NONE}


# Replacement for upstream clamp(count, 1, 4): legal counts pass through
# unchanged; anything outside 1..capacity is reported instead of being
# silently cut, so callers can stop the flow (F01) rather than drop P5..P8.
func layout_count(roster_count: int) -> Dictionary:
	if is_legal_count(roster_count):
		return {"ok": true, "count": roster_count}
	return {"ok": false, "count": int(clamp(roster_count, 1, max(1, capacity)))}
