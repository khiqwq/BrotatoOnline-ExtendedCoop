extends Node
# Entry point loaded by the game's Mod Loader after six666-BrotatoOnline
# (manifest dependency). Install rules: docs/adr/ADR-001-extension-loading.md.
#   _init        decide the runtime gate once (RuntimeGate.initialize), then
#                queue the extensions of vanilla autoloads/scenes and of
#                Brotato Online scripts whose consts are literals; Mod Loader
#                applies them after every mod_main._init (ADR-001 rule 1)
#   _enter_tree  extensions whose parent const expressions read autoloads
#                (ADR-001 rule 5); applied at once, before BO's mod_main._ready
#                creates its managers
#   _ready       debug probes only
# On the verified target the extensions are installed even when the gate keeps
# capacity 4 (--coopplus-vanilla, an unsupported mod or a CoopFix-OnlineMouseUI
# other than the locked one running): each keeps the parent behaviour while
# RuntimeGate.is_extended() is false, so 1-4 player
# sessions stay vanilla (R08). When the target itself is not verified (game /
# engine / Mod Loader version, Brotato Online fingerprint, stopped Brotato
# Online LIFE-20, unreadable compatibility.json) none is installed: an override
# that no longer compiles against a changed parent logs a script error under
# mods-unpacked, and CrashReporter then disables every mod next start (LIFE-03).
# Development builds only (debug/ present, never packaged):
#   --coopplus-probe              AP-005 lifecycle probe; --coopplus-probe-only=a,b
#                                 narrows its extensions when bisecting
#   --coopplus-capacity-probe     AP-006 capacity probe (debug/capacity_probe.gd)
#   --coopplus-local-sim=<N>      local N-player run with simulated controllers
#                                 (debug/local_sim_probe.gd, test harness only)
#   --coopplus-probe-quit         quit once a probe report is written
# Probe extensions are installed after the production ones so they sit on top.
# For _enter_tree that is exact; for _init it is only the queue order, because
# Mod Loader sorts equal inheritance stacks of one mod with an unstable sort.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const MOD_ID := "CoopPlus-OnlineExtendedCoop"
const MOD_DIR := "res://mods-unpacked/CoopPlus-OnlineExtendedCoop"

const EXTENSIONS_INIT := [
	"extensions/vanilla/coop_service_ext.gd",
	"extensions/vanilla/input_service_ext.gd",
	"extensions/vanilla/utils_ext.gd",
	"extensions/vanilla/entity_spawner_ext.gd",
	"extensions/vanilla/main_ext.gd",
	"extensions/vanilla/run_data_ext.gd",
	"extensions/vanilla/progress_data_ext.gd",
	"extensions/vanilla/popup_manager_ext.gd",
	"extensions/vanilla/upgrades_ui_ext.gd",
	"extensions/vanilla/debug_service_ext.gd",
	"extensions/vanilla/coop_shop_ext.gd",
	"extensions/vanilla/coop_end_run_ext.gd",
	"extensions/vanilla/character_selection_ext.gd",
	"extensions/vanilla/weapon_selection_ext.gd",
	"extensions/vanilla/difficulty_selection_ext.gd",
	"extensions/bo/session_manager_ext.gd",
	"extensions/bo/public_lobby_browser_ext.gd",
	"extensions/bo/steam_transport_ext.gd",
	"extensions/bo/lan_transport_ext.gd",
	"extensions/bo/network_heartbeat_ext.gd",
	"extensions/bo/menu_sync_manager_ext.gd",
	"extensions/bo/player_removal_manager_ext.gd",
]
# Parent declares const REMOTE_PLACEHOLDER_PLAYER_TYPE = CoopService.PlayerType...
# (INP-M02), which cannot compile while ModLoader._init runs.
const EXTENSIONS_ENTER_TREE := [
	"extensions/bo/online_player_slot_manager_ext.gd",
]

const PROBE_FLAG := "--coopplus-probe"
const CAPACITY_PROBE_FLAG := "--coopplus-capacity-probe"
const LOCAL_SIM_PREFIX := "--coopplus-local-sim="
const LOCAL_SIM_EXTENSIONS := [
	"debug/probe_extensions/main_sim_probe.gd",
	"debug/probe_extensions/entity_spawner_sim_probe.gd",
	"debug/probe_extensions/debug_service_sim_probe.gd",
	"debug/probe_extensions/upgrades_ui_sim_probe.gd",
	"debug/probe_extensions/end_run_sim_probe.gd",
]
const PROBE_EXTENSIONS := [
	"debug/probe_extensions/coop_service_probe.gd",
	"debug/probe_extensions/entity_spawner_probe.gd",
	"debug/probe_extensions/session_manager_probe.gd",
	"debug/probe_extensions/menu_sync_probe.gd",
]
# Parents that read autoload values in const expressions cannot be compiled during
# ModLoader._init (autoloads are not instanced yet). They are installed in
# _enter_tree: after every autoload exists, before any mod_main._ready runs.
const PROBE_EXTENSIONS_ENTER_TREE := [
	"debug/probe_extensions/slot_manager_probe.gd",
]

var _probe_enabled := false
var _capacity_probe_enabled := false
var _local_sim_enabled := false
var _install_extensions := true
var _enter_tree_done := false


func _init() -> void:
	var args := OS.get_cmdline_args()
	_probe_enabled = PROBE_FLAG in args and _mod_file_exists("debug/lifecycle_probe.gd")
	_capacity_probe_enabled = CAPACITY_PROBE_FLAG in args and _mod_file_exists("debug/capacity_probe.gd")
	for arg in args:
		if arg.begins_with(LOCAL_SIM_PREFIX):
			_local_sim_enabled = _mod_file_exists("debug/local_sim_probe.gd")
	if _probe_enabled:
		# First, so the cache flags still describe the state before any install.
		_probe_log().event("coopplus.mod_main._init", {
			"bo_session_manager_cached": ResourceLoader.has_cached("res://mods-unpacked/six666-BrotatoOnline/scripts/session_manager.gd"),
			"coop_service_cached": ResourceLoader.has_cached("res://singletons/coop_service.gd"),
			"main_loop_set": Engine.get_main_loop() != null,
		})

	var decision: Dictionary = RuntimeGate.initialize(_gate_environment())
	_install_extensions = bool(decision.get("install_extensions", true))
	if _install_extensions:
		var queued := _install_list(EXTENSIONS_INIT, "init")
		ModLoaderLog.info("queued %d of %d extensions" % [queued, EXTENSIONS_INIT.size()], MOD_ID)
	else:
		ModLoaderLog.warning("target not verified (%s); no extensions installed, Brotato Online runs unchanged" % ",".join(PoolStringArray(decision.get("reasons", []))), MOD_ID)

	if _probe_enabled:
		_install_probe_extensions()
	if _local_sim_enabled and _install_extensions:
		var _n := _install_list(LOCAL_SIM_EXTENSIONS, "init")


func _enter_tree() -> void:
	if _enter_tree_done:
		return
	_enter_tree_done = true
	if _probe_enabled:
		_probe_log().event("coopplus.mod_main._enter_tree", {
			"mod_loader_initializing": ModLoaderStore.is_initializing,
			"bo_slot_manager_cached": ResourceLoader.has_cached("res://mods-unpacked/six666-BrotatoOnline/scripts/online_player_slot_manager.gd"),
			"coop_service_in_tree": get_tree().root.has_node("CoopService"),
		})
	if _install_extensions:
		var installed := _install_list(EXTENSIONS_ENTER_TREE, "enter_tree")
		ModLoaderLog.info("installed %d of %d enter_tree extensions" % [installed, EXTENSIONS_ENTER_TREE.size()], MOD_ID)
	if _probe_enabled:
		for rel in PROBE_EXTENSIONS_ENTER_TREE:
			_probe_log().event("coopplus.install_script_extension", {"path": rel, "stage": "enter_tree"})
			ModLoaderMod.install_script_extension(MOD_DIR.plus_file(rel))


func _ready() -> void:
	# Continuing 5..8 player runs online (scripts/bo/resume_identity_patch.gd);
	# idle unless a resume scene with more than four players is current.
	if RuntimeGate.decision().get("install_extensions", false):
		var patch = load(MOD_DIR.plus_file("scripts/bo/resume_identity_patch.gd")).new()
		add_child(patch)
	if _probe_enabled:
		_probe_log().event("coopplus.mod_main._ready", {"path": str(get_path())})
		_add_probe_node("CoopPlusLifecycleProbe", "debug/lifecycle_probe.gd")
	if _capacity_probe_enabled:
		_add_probe_node("CoopPlusCapacityProbe", "debug/capacity_probe.gd")
	if _local_sim_enabled:
		_add_probe_node("CoopPlusLocalSim", "debug/local_sim_probe.gd")


# Mod Loader facts for the gate. ModLoaderStore and CrashReporter are created
# before ModLoader, so both are safe to read here (later autoloads are still
# null during _init, LIFE-13). mod_data is complete before any mod_main._init.
func _gate_environment() -> Dictionary:
	var mods := {}
	for mod_id in ModLoaderStore.mod_data:
		var mod = ModLoaderStore.mod_data[mod_id]
		mods[str(mod_id)] = {"loadable": bool(mod.is_loadable), "active": bool(mod.is_active)}
	var game_version = CrashReporter.get("VERSION") if CrashReporter != null else ""
	return {
		"mods": mods,
		"game_version": game_version if typeof(game_version) == TYPE_STRING else "",
		"mod_loader_version": ModLoaderStore.MODLOADER_VERSION,
	}


# Installs the files that exist and returns how many. A missing file is logged
# by its relative path only: CrashReporter disables every mod on the next start
# when an ERROR line mentions mods-unpacked (LIFE-03), and Mod Loader's own
# error for a missing extension would contain the full path.
func _install_list(list: Array, stage: String) -> int:
	var count := 0
	for rel in list:
		if not _mod_file_exists(rel):
			ModLoaderLog.error("missing extension %s (%s); skipped" % [rel, stage], MOD_ID)
			continue
		ModLoaderMod.install_script_extension(MOD_DIR.plus_file(rel))
		count += 1
	return count


func _install_probe_extensions() -> void:
	var probe_log = _probe_log()
	var only := []
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coopplus-probe-only="):
			only = arg.substr("--coopplus-probe-only=".length()).split(",", false)
	for rel in PROBE_EXTENSIONS:
		var selected := only.empty()
		for part in only:
			if part in rel:
				selected = true
		if selected:
			probe_log.event("coopplus.install_script_extension", {"path": rel})
			ModLoaderMod.install_script_extension(MOD_DIR.plus_file(rel))
	ModLoaderLog.info("lifecycle probe extensions queued", MOD_ID)


func _add_probe_node(node_name: String, rel: String) -> void:
	var probe := Node.new()
	probe.name = node_name
	probe.set_script(load(MOD_DIR.plus_file(rel)))
	add_child(probe)


# Loaded on demand: debug/ is absent from release packages.
func _probe_log():
	return load(MOD_DIR.plus_file("debug/probe_log.gd"))


func _mod_file_exists(rel: String) -> bool:
	return File.new().file_exists(MOD_DIR.plus_file(rel))
