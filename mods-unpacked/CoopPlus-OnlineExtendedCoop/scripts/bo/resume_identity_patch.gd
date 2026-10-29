extends Node
# Continuing 5..8 player runs online with Brotato Online's identity panel
# (AP-016/AP-017; CAP-17, SAVE-09, SAVE-12, SAVE-M06). Its player identity
# manager cannot be script-extended: the manager preloads its registry by a
# relative path, which no longer resolves once an extension takes over the
# script's path (local simulation: Brotato Online's manager failed to
# compile, EV-0033). This node adjusts the manager instance instead while a
# co-op resume scene is current and the run has more than four players:
#   - when the manager's registry refused the saved 5..8 slot record
#     (player_identity_registry.gd:29) and fell back to manual assignment,
#     the identities restored with the checkpoint
#     (progress_data_ext.gd coopplus_loaded_identities) are loaded into
#     extended_identity_registry.gd and the panel is rebuilt, the state the
#     manager reaches after a successful load (player_identity_manager.gd
#     prepare_resume_if_needed)
#   - every panel the manager builds grows by the extra rows, and its Offline
#     button is disabled with a message: local co-op stops at four players
#     (CoopService, SAVE-12)
# Saving needs nothing here: progress_data_ext.gd asks the manager for its
# metadata (_metadata_for_state) whenever the run is saved, which writes the
# identities into the checkpoint.

const ExtendedRegistry = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/bo/extended_identity_registry.gd")

const MANAGER_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlinePlayerIdentityManager"
const RESUME_SCENE_SUFFIX := "/coop_resume.tscn"
const POLL_SEC := 0.1
const LOCAL_LIMIT := 4
const ROW_HEIGHT := 52
const OFFLINE_TEXT := {
	"zh": "本地离线继续最多支持 4 人",
	"en": "Offline continue supports at most 4 players",
}

var _registry_scene_id := 0
var _patched_panel_id := 0
var _poll := 0.0


func _ready() -> void:
	name = "CoopPlusResumeIdentityPatch"
	pause_mode = Node.PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_SEC
	var count: int = RunData.get_player_count()
	if count <= LOCAL_LIMIT:
		return
	var scene = get_tree().current_scene
	if scene == null or not str(scene.filename).ends_with(RESUME_SCENE_SUFFIX):
		return
	var manager = get_node_or_null(MANAGER_PATH)
	if manager == null:
		return
	_upgrade_registry(manager, scene, count)
	_patch_panel(manager, count)


func _upgrade_registry(manager: Node, scene: Node, count: int) -> void:
	var scene_id: int = scene.get_instance_id()
	if scene_id == _registry_scene_id or int(manager.get("_prepared_scene_id")) != scene_id:
		return
	if not bool(manager.get("_pending")) or not bool(manager.get("_manual")):
		return
	_registry_scene_id = scene_id
	var identities = ProgressData.call("coopplus_loaded_identities") if ProgressData.has_method("coopplus_loaded_identities") else {}
	var registry = ExtendedRegistry.new()
	if typeof(identities) != TYPE_DICTIONARY or not registry.load_metadata(identities, count):
		return
	manager.registry = registry
	manager.set("_manual", false)
	manager.set("_legacy_save", false)
	var hashes: Dictionary = manager.get("_lan_hashes")
	hashes.clear()
	for slot in registry.slots:
		if str(slot.resume_hash) != "":
			hashes[str(slot.owner_id)] = str(slot.resume_hash)
	manager.call("_clear_panel")
	manager.call("_build_panel")
	ModLoaderLog.info("resume: %d player identities restored from the checkpoint" % count, "CoopPlus-OnlineExtendedCoop")


func _patch_panel(manager: Node, count: int) -> void:
	var panel = manager.get("_panel")
	if not panel is Control or not is_instance_valid(panel) or panel.get_instance_id() == _patched_panel_id:
		return
	_patched_panel_id = panel.get_instance_id()
	var extra := count - LOCAL_LIMIT
	panel.margin_top -= extra * ROW_HEIGHT / 2
	panel.margin_bottom += extra * ROW_HEIGHT / 2
	var text: String = OFFLINE_TEXT["zh"] if TranslationServer.get_locale().begins_with("zh") else OFFLINE_TEXT["en"]
	for button in _buttons(panel):
		if button.is_connected("pressed", manager, "_continue_offline"):
			button.disconnect("pressed", manager, "_continue_offline")
			button.disabled = true
			button.text = text


func _buttons(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_buttons(child))
	return out
