extends "res://mods-unpacked/six666-BrotatoOnline/scripts/player_identity_registry.gd"
# Brotato Online's identity registry without its four-slot limit, for
# continuing 5..8 player runs (AP-017; CAP-17, SAVE-09). Never installed as a
# script extension: player_identity_manager_ext.gd creates it in place of the
# parent's registry (SAVE-M01: the manager's const preload binds the original).
# load_metadata above four slots validates the saved slots in chunks of at most
# four through the parent's own load_metadata (every per-entry rule stays the
# parent's) and then checks what a chunk cannot see: slot ids and owner/local
# slot pairs unique across all chunks. No parent code is restated.

const BASE_PATH := "res://mods-unpacked/six666-BrotatoOnline/scripts/player_identity_registry.gd"
const CHUNK := 4
const MAX_SLOTS := 8


func load_metadata(metadata, player_count: int) -> bool:
	if player_count <= CHUNK:
		return .load_metadata(metadata, player_count)
	if player_count > MAX_SLOTS or typeof(metadata) != TYPE_DICTIONARY:
		return false
	var incoming = metadata.get("slots", [])
	if typeof(incoming) != TYPE_ARRAY or incoming.size() != player_count:
		return false
	var loaded := []
	var base = load(BASE_PATH)
	for start in range(0, player_count, CHUNK):
		var chunk := []
		for i in range(start, int(min(start + CHUNK, player_count))):
			chunk.append(incoming[i])
		var part = base.new()
		if not part.load_metadata({"version": metadata.get("version"), "run_id": metadata.get("run_id"), "slots": chunk}, chunk.size()):
			return false
		loaded.append_array(part.slots)
	var slot_ids := {}
	var owner_slots := {}
	for slot in loaded:
		var owner_slot := "%s:%d" % [slot.owner_id, int(slot.local_slot)]
		if slot_ids.has(slot.slot_id) or owner_slots.has(owner_slot):
			return false
		slot_ids[slot.slot_id] = true
		owner_slots[owner_slot] = true
	run_id = metadata.run_id
	slots = loaded
	return true
