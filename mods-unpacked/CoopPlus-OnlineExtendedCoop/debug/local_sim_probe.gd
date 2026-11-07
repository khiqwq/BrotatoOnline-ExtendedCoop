extends Node
# Local N-player simulation (debug/ only, never packaged). Started by mod_main with
#   --coopplus-local-sim=<N>          players, 1..CapacityPolicy.MAX_SUPPORTED_PLAYERS
#   --coopplus-local-sim-seconds=<S>  wave length (default 20); 0 keeps the
#                                     game's own wave lengths (20 s rising to
#                                     60 s, 90 s for wave 20)
#   --coopplus-local-sim-start-wave=<W>  first wave (DebugService.starting_wave,
#                                     read by RunData.reset); with -waves=21-W
#                                     the run ends on the end-of-run screen after
#                                     wave 20 (a clear: invulnerable players are
#                                     alive when its timer ends, main.gd
#                                     _set_run_states)
#   --coopplus-local-sim-kit=perf     every player gets the game's own
#                                     late-game performance kit instead of the
#                                     starting weapon: 6 tier-4 sniper guns and
#                                     its 20 turret/support items
#                                     (DebugService PERF_SCENARIO_*; the game's
#                                     handle_player_spawn_debug_options has
#                                     four-entry arrays, so the probe adds them)
#   --coopplus-local-sim-kit=weapons  the same 6 weapons without the items: a
#                                     typical late-game build without turrets
#   --coopplus-local-sim-seed=<int>   bot input seed (default 1)
#   --coopplus-local-sim-mortal       players can die (tests the loss / end-of-run
#                                     flow); by default they are invulnerable
#   --coopplus-local-sim-on-loss=end|retry  answer to the retry-wave dialog after
#                                     everyone died: go to the end-of-run screen
#                                     (default) or replay the wave
#   --coopplus-local-sim-waves=<W>    waves to play; between waves every player
#                                     presses GO in the co-op shop (default 1)
#   --coopplus-local-sim-save         let the game save as in normal play (shop
#                                     checkpoint, progress); by default saving is
#                                     off. Only in an isolated instance (AP-016)
#   --coopplus-local-sim-menus        go through character, weapon and difficulty
#                                     selection instead of building the run: the
#                                     seated players enter character selection the
#                                     way they come back from weapon selection
#                                     (RunData.menu_selection_back keeps them) and
#                                     every player keeps pressing ui_accept, which
#                                     picks the random character and weapon; P1
#                                     then confirms the difficulty
#   --coopplus-local-sim-continue     continue the saved run instead of starting
#                                     one (run after a --coopplus-local-sim-save
#                                     run without clearing the instance user
#                                     data): checks the title screen offers
#                                     Continue, presses it, takes Brotato Online's
#                                     offline resume path on the resume screen
#                                     (no lobby is created; its session manager is
#                                     paused there) and seats every player, then
#                                     logs the restored shop and plays on
#   --coopplus-local-sim-dlc-missing=<P>  with -menus: player P (1-based) has no
#                                     DLC installed (scripts/bo/dlc_roster.gd
#                                     debug owners, D-014; only the DLC icons
#                                     change) and the saved zone is the first
#                                     DLC zone. With -menus (with or without
#                                     this flag) local_sim.dlc is logged on each
#                                     selection screen (item set bar, zone list,
#                                     icons, DLC characters) and local_sim.dlc_run
#                                     once the run starts
#   --coopplus-local-sim-pad          exploration only: keep padding the vanilla
#                                     per-player arrays fixed at 4 entries (DATA-01,
#                                     BAT-03/04 ...) to 8 every frame, to find the
#                                     NEXT blocker after them. Not a fix (AP-013).
#   --coopplus-probe-quit             exit when done
# It skips the menus: once the title screen settles it seats N local players
# (P1 on the keyboard device 7, P2..PN on the gate's virtual devices 16+),
# builds RunData the way character/weapon/difficulty selection do, starts a run
# and drives every player with seeded random movement through the per-device
# actions. When the wave timer stops it switches to menu mode and sends
# ui_accept_<device> InputEventActions for every player (menus react to input
# events, not to Input.action_press), so end-of-wave upgrades/crates resolve and
# the shop opens. Every second it samples the scene, players and HUD; when the
# battle scene is left (or after a time limit) it writes
# user://coopplus_probe/local_sim.json.
# This is a test harness for 5-8 player code paths on one PC; it is not a
# supported way to play (R02: one player per PC).

const ProbeLog = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/debug/probe_log.gd")
const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")

const REPORT_DIR := "user://coopplus_probe"
const REPORT_PATH := "user://coopplus_probe/local_sim.json"
const LINE_PREFIX := "COOPPLUS_LOCAL_SIM"
const TITLE_SCENE := "res://ui/menus/title_screen/title_screen.tscn"
const KEYBOARD_DEVICE := 7
const DIRECTIONS := ["left", "right", "up", "down"]
const STEER_INTERVAL := 0.3
const SAMPLE_INTERVAL := 1.0
const EXTRA_TIMEOUT_SEC := 45.0
const CapacityPolicy = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/capacity_policy.gd")
const PlayerStatusStrip = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/player_status_strip.gd")
# --coopplus-local-sim-options-shot: on the title screen, the game's options
# menu on its Gameplay tab with this mod's list-scroll switch
# (ui/options_entry.gd): screenshot, then the switch off and on again, logging
# the saved scroll mode each time (local_sim.options).
const OPTIONS_SCENE := "res://ui/menus/pages/menu_options.tscn"
const OPTIONS_TABS_PATH := "Buttons/HBoxContainer3/TabContainer"
const OPTIONS_GAMEPLAY_BUTTON_PATH := "Buttons/HBoxContainer2/Gameplay_but"
const OPTIONS_SHOT_SEC := 1.5
# With the game's own wave lengths (-seconds=0): the longest wave, and how much
# slower than real time a heavy wave may run before it counts as stuck.
const LONGEST_WAVE_SEC := 90.0
const SLOW_WAVE_FACTOR := 8.0
const ACCEPT_INTERVAL := 0.6
const AFTER_BATTLE_SEC := 5.0
const SHOP_SCENE_FILE := "coop_shop.tscn"
const SHOP_WAIT_SEC := 3.0
const SHOP_TIMEOUT_SEC := 20.0
const SCREENSHOT_AT_SEC := 10.0
# After the first wave ends: battle screenshots and HUD rectangles while the
# pending-upgrade icons show and leftover materials fly to the bag.
const WAVE_END_SHOTS := [0.4, 1.5]
# --coopplus-local-sim-remove=<player number>: at the first shop, replay a
# Brotato Online player removal on the run data (host compaction and the
# client's roster rebuild, player_removal_manager.gd:273-283, 423-432) and
# rebuild the shop with one player fewer; -nofix leaves out the client fix
# (extensions/bo/player_removal_manager_ext.gd) to show the failure.
# --coopplus-local-sim-late-join (with -menus): the last player joins while
# character selection is open, the way an invited online player arrives;
# screenshots and the grid's place before and after.
# --coopplus-local-sim-late-join-silent: the same, but the player is added
# without connected_players_updated (online, a client's count or local slot can
# settle after the signal); the layout must still pick the new player up.
const LATE_JOIN_WAIT_SEC := 1.5
const SCROLL_PRESSES := 6
const REMOVAL_MANAGER_PATH := "/root/ModLoader/six666-BrotatoOnline/BrotatoOnlinePlayerRemovalManager"
# First wave only: hold the accepts until the co-op upgrade screen has been
# shown this long and captured, or give up after UPGRADES_SHOT_WAIT_SEC.
const UPGRADES_SHOT_AFTER_SEC := 0.8
const UPGRADES_SHOT_WAIT_SEC := 6.0
# Selection screens (--coopplus-local-sim-menus): screenshot after
# MENU_SHOT_SEC, accepts from MENU_ACCEPT_SEC, give up after MENU_TIMEOUT_SEC.
const MENU_SHOT_SEC := 1.5
const MENU_ACCEPT_SEC := 2.5
const MENU_TIMEOUT_SEC := 90.0
# Display checks on the first upgrade screen, the first shop and the
# end-of-run screen (D-011 row selection, D-012 display modes): one step every
# VIEW_STEP_SEC. "pad_*" sends ui_<dir>_<device> for P1 (the local player),
# "click_*" clicks a row the way CoopFix-OnlineMouseUI does (its own hit test
# when that mod is loaded), "key_v" presses the display-mode key, "stick_*"
# pushes and releases the right stick, "shot*" saves a screenshot; every step
# logs P1's focus, the shown player, the display mode and the window start.
# With more rows than the strip shows (nine players or more) the screens run
# VIEW_STEPS_WINDOWED first: "wheel_*" turns the mouse wheel over the strip,
# "rstick_*" pushes the right stick up/down, "set_row"/"set_page" switch the
# saved scroll mode (ui/options_entry.gd), and the strip's first shown row
# and shown players are logged.
const VIEW_STEP_SEC := 0.8
const VIEW_STEPS := {
	"upgrades": ["key_v", "shot_pages", "stick_right", "shot_pages_slid", "stick_left", "key_v", "check"],
	"character_selection": ["room_popup", "shot_room_popup", "room_popup_close",
			"room_lock", "room_popup", "shot_room_locked", "room_popup_close", "room_unlock", "key_v", "shot_pages", "stick_right", "shot_pages_slid", "stick_left", "key_v", "check"],
	"weapon_selection": ["key_v", "shot_pages", "stick_right", "shot_pages_slid", "stick_left", "key_v", "check"],
	"shop": ["shot", "pad_right", "pad_down", "pad_accept", "shot_view_pad", "click_last", "shot_view_click", "click_last", "check",
			"key_v", "shot_pages", "pad_right", "stick_right", "shot_pages_slid", "pad_left", "stick_left", "pad_left", "key_v", "check"],
	"coop_end_run": ["click_first", "shot_view_click", "click_first", "check",
			"key_v", "shot_pages", "stick_right", "shot_pages_slid", "stick_left", "key_v", "check"],
}
const VIEW_STEPS_WINDOWED := {
	"upgrades": ["shot_list", "wheel_down", "shot_wheel_page", "set_row", "rstick_up", "rstick_up", "shot_stick_row", "set_page", "wheel_up"],
	"character_selection": ["shot_list", "wheel_down", "shot_wheel_page", "set_row", "rstick_up", "shot_stick_row", "set_page", "wheel_up"],
	"weapon_selection": ["shot_list", "wheel_down", "shot_wheel_page", "wheel_up"],
	"shop": ["shot", "pad_right", "wheel_down", "shot_wheel_page", "wheel_down", "shot_wheel_page_end", "wheel_up", "wheel_up",
			"set_row", "rstick_down", "rstick_down", "shot_stick_row", "rstick_up", "rstick_up",
			"pad_down", "pad_down", "pad_down", "pad_down", "pad_down", "pad_down", "pad_down", "shot_pad_edge_row",
			"set_page", "pad_down", "pad_down", "pad_down", "pad_down", "pad_down", "pad_down", "shot_pad_edge_page", "pad_accept", "shot_view_pad"],
	"coop_end_run": ["shot_list", "wheel_down", "shot_wheel_page", "wheel_up"],
}
const MOUSE_ROUTER_PATH := "/root/ModLoader/CoopFix-OnlineMouseUI/MouseRouter"

var _players_wanted := 0
var _wave_seconds := 20
var _start_wave := 1
var _kit := ""
var _quit_after := false
var _rng := RandomNumberGenerator.new()
var _state := "wait_title"
var _elapsed := 0.0
var _steer_timer := 0.0
var _sample_timer := 0.0
var _devices := []
var _held := {}
var _samples := []
var _first_positions := {}
var _max_distance := {}
var _scenes_seen := []
var _setup := {}
var _finished := false
var _menu_mode := false
var _menu_entered_at := -1.0
var _accept_timer := 0.0
var _accepts_sent := 0
var _after_battle_left := 0.0
var _screenshot_done := false
var _waves_wanted := 1
var _waves_done := 0
var _wave_elapsed := 0.0
var _shop_left := 0.0
var _shop_pressed := false
var _player_data_log := []
var _mortal := false
var _on_loss := "end"
var _loss_handled := false
var _retry_from_scene_id := 0
var _losses := 0
var _after_battle_shot := false
var _pad := false
var _save := false
var _upgrades_shot := false
var _upgrades_visible_for := 0.0
var _pad_counts := {}
var _view_checks := {}
var _menus := false
var _options_shot := false
var _options_left := -1.0
var _options_menu: Node = null
var _room_prev_focus = null
var _continue := false
var _resume_seeded := false
var _menu_scene := ""
var _menu_scene_time := 0.0
var _menu_shot := false
var _menus_time := 0.0
var _wave_end_at := -1.0
var _wave_end_shots_done := 0
var _remove_player := 0
var _late_join := false
var _late_join_silent := false
var _dlc_missing := 0
var _zone_logged_wave := -1
var _late_join_state := ""
var _late_join_left := 0.0
var _late_join_before := {}
var _late_join_presses := 0
var _late_join_scroll_after := {}
var _late_join_saved_focus = null
var _remove_fix := true
var _removal_done := false
var _removal_scene_id := 0
var _removal_logged := false


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS
	_players_wanted = 1
	var seed_value := 1
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coopplus-local-sim="):
			_players_wanted = int(arg.substr("--coopplus-local-sim=".length()))
		elif arg.begins_with("--coopplus-local-sim-seconds="):
			_wave_seconds = int(arg.substr("--coopplus-local-sim-seconds=".length()))
		elif arg.begins_with("--coopplus-local-sim-on-loss="):
			_on_loss = arg.substr("--coopplus-local-sim-on-loss=".length())
		elif arg.begins_with("--coopplus-local-sim-waves="):
			_waves_wanted = int(clamp(int(arg.substr("--coopplus-local-sim-waves=".length())), 1, 20))
		elif arg.begins_with("--coopplus-local-sim-remove="):
			_remove_player = int(arg.substr("--coopplus-local-sim-remove=".length()))
		elif arg.begins_with("--coopplus-local-sim-seed="):
			seed_value = int(arg.substr("--coopplus-local-sim-seed=".length()))
		elif arg.begins_with("--coopplus-local-sim-start-wave="):
			_start_wave = int(clamp(int(arg.substr("--coopplus-local-sim-start-wave=".length())), 1, 20))
		elif arg.begins_with("--coopplus-local-sim-kit="):
			_kit = arg.substr("--coopplus-local-sim-kit=".length())
		elif arg.begins_with("--coopplus-local-sim-dlc-missing="):
			_dlc_missing = int(arg.substr("--coopplus-local-sim-dlc-missing=".length()))
	_quit_after = "--coopplus-probe-quit" in OS.get_cmdline_args()
	_pad = "--coopplus-local-sim-pad" in OS.get_cmdline_args()
	_mortal = "--coopplus-local-sim-mortal" in OS.get_cmdline_args()
	_save = "--coopplus-local-sim-save" in OS.get_cmdline_args()
	_menus = "--coopplus-local-sim-menus" in OS.get_cmdline_args()
	_continue = "--coopplus-local-sim-continue" in OS.get_cmdline_args()
	_remove_fix = not "--coopplus-local-sim-remove-nofix" in OS.get_cmdline_args()
	_late_join_silent = "--coopplus-local-sim-late-join-silent" in OS.get_cmdline_args()
	_late_join = _late_join_silent or "--coopplus-local-sim-late-join" in OS.get_cmdline_args()
	_options_shot = "--coopplus-local-sim-options-shot" in OS.get_cmdline_args()
	_players_wanted = int(clamp(_players_wanted, 1, CapacityPolicy.MAX_SUPPORTED_PLAYERS))
	_rng.seed = seed_value
	ProbeLog.event("local_sim._ready", {"players": _players_wanted, "wave_seconds": _wave_seconds, "seed": seed_value, "save": _save})
	print("%s waiting for the title screen (players=%d)" % [LINE_PREFIX, _players_wanted])


func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	var scene = get_tree().current_scene
	if _pad and _state != "wait_title":
		_pad_arrays(scene)
	var scene_file: String = scene.filename if scene != null else ""
	if _scenes_seen.empty() or _scenes_seen[_scenes_seen.size() - 1].scene != scene_file:
		_scenes_seen.append({"t": stepify(_elapsed, 0.01), "scene": scene_file})
		ProbeLog.event("local_sim.scene", {"scene": scene_file})
	match _state:
		"wait_title":
			if scene_file == TITLE_SCENE and _elapsed > 3.0:
				if _options_shot and _options_step(scene, delta):
					return
				if _continue:
					_start_continue(scene)
				else:
					_start_run()
		"in_run":
			_wave_elapsed += delta
			_guard_focus_pause(scene)
			if _zone_logged_wave != _waves_done and scene_file == MenuData.game_scene and ZoneService.current_zone != null:
				_zone_logged_wave = _waves_done
				ProbeLog.event("local_sim.zone", {"wave": _waves_done + 1, "width": ZoneService.current_zone.width,
						"height": ZoneService.current_zone.height, "players": RunData.get_player_count(),
						"rect": [ZoneService.current_zone_rect.size.x, ZoneService.current_zone_rect.size.y]})
			if scene_file != MenuData.game_scene and _wave_elapsed > 2.0:
				_waves_done += 1
				ProbeLog.event("local_sim.left_battle", {"scene": scene_file, "waves_done": _waves_done})
				if _waves_done < _waves_wanted and scene_file.get_file() == SHOP_SCENE_FILE:
					_state = "in_shop"
					_shop_left = SHOP_WAIT_SEC
					_shop_pressed = false
				else:
					# Stay a few seconds in the next scene so its setup problems,
					# if any, show up before the report.
					_state = "after_battle"
					_after_battle_left = AFTER_BATTLE_SEC
				return
			if not _menu_mode and _wave_over(scene):
				_menu_mode = true
				_menu_entered_at = _elapsed
				_release_all()
				ProbeLog.event("local_sim.wave_over", {"t": stepify(_elapsed, 0.01)})
				if _waves_done == 0:
					_wave_end_at = _elapsed
				_write_report("wave_over")
			if not _loss_handled and _retry_dialog_visible(scene):
				_answer_retry_dialog(scene)
			if _retry_from_scene_id != 0 and scene != null and scene.get_instance_id() != _retry_from_scene_id:
				# The retried wave is a fresh battle scene with the same file.
				_retry_from_scene_id = 0
				_start_next_wave()
			if _menu_mode and _hold_for_upgrades_shot(scene, delta):
				pass
			elif _menu_mode:
				_accept_timer -= delta
				if _accept_timer <= 0.0:
					_accept_timer = ACCEPT_INTERVAL
					_send_accepts()
			else:
				_steer_timer -= delta
				if _steer_timer <= 0.0:
					_steer_timer = STEER_INTERVAL
					_steer()
			_sample_timer -= delta
			if _sample_timer <= 0.0:
				_sample_timer = SAMPLE_INTERVAL
				_sample(scene)
			if not _screenshot_done and _elapsed > SCREENSHOT_AT_SEC:
				_screenshot_done = true
				_save_screenshot("battle_%dp.png" % _players_wanted)
			if _wave_end_at >= 0.0 and _wave_end_shots_done < WAVE_END_SHOTS.size() 					and _elapsed - _wave_end_at >= WAVE_END_SHOTS[_wave_end_shots_done]:
				_wave_end_shots_done += 1
				_save_screenshot("wave_end_%d_%dp.png" % [_wave_end_shots_done, _players_wanted])
				ProbeLog.event("local_sim.hud_layout", _hud_layout(scene))
			if _wave_elapsed > _wave_timeout():
				_finish("timeout_wave_%d" % (_waves_done + 1))
		"in_resume":
			_menus_time += delta
			if scene_file.get_file() == "coop_resume.tscn" and not _resume_seeded:
				_seed_resume()
			elif scene_file.get_file() == SHOP_SCENE_FILE:
				_resume_online(true)
				ProbeLog.event("local_sim.continue.shop", {"players": _player_data(), "shop": _shop_snapshot(scene)})
				_state = "in_shop"
				_waves_done = 2
				_shop_left = SHOP_WAIT_SEC
				_shop_pressed = false
			elif _menus_time > MENU_TIMEOUT_SEC:
				_finish("stuck_in_resume:%s" % scene_file.get_file())
		"in_menus":
			_menus_time += delta
			if scene_file == MenuData.game_scene:
				_setup["players"] = _player_data()
				ProbeLog.event("local_sim.menus_done", {"seconds": stepify(_menus_time, 0.01), "players": _setup["players"]})
				if _menus:
					ProbeLog.event("local_sim.dlc_run", {"enabled_dlcs": RunData.enabled_dlcs.duplicate(),
							"active_update_data_ids": RunData.active_update_data_ids.duplicate(),
							"zone": RunData.current_zone, "zone_dlc": ZoneService.get_zone_data(RunData.current_zone).dlc_id,
							"characters": _dlc_characters()})
				_state = "in_run"
				_wave_elapsed = 0.0
				return
			if scene_file != _menu_scene:
				_menu_scene = scene_file
				_menu_scene_time = 0.0
				_menu_shot = false
				_accept_timer = 0.0
			_menu_scene_time += delta
			if not _menu_shot and _menu_scene_time > MENU_SHOT_SEC:
				_menu_shot = true
				ProbeLog.event("local_sim.dlc", _dlc_state(scene))
				_save_screenshot("%s_%dp.png" % [scene_file.get_file().get_basename(), _players_wanted])
			var menu_name := scene_file.get_file().get_basename()
			if _menu_shot and menu_name == "character_selection" and _late_join_step(scene, delta):
				return
			if _menu_shot and VIEW_STEPS.has(menu_name) and _run_view_check(scene, menu_name, delta):
				return
			if _menu_shot and _menu_scene_time > MENU_ACCEPT_SEC:
				_accept_timer -= delta
				if _accept_timer <= 0.0:
					_accept_timer = ACCEPT_INTERVAL
					_send_accepts()
			if _menus_time > MENU_TIMEOUT_SEC:
				_finish("stuck_in_menus:%s" % scene_file.get_file())
		"in_shop":
			_guard_focus_pause(scene)
			_shop_left -= delta
			if _remove_player > 0 and _waves_done == 1:
				if not _removal_done and _shop_left <= SHOP_WAIT_SEC - 1.0:
					_removal_done = true
					_simulate_removal(scene)
					_shop_left = SHOP_WAIT_SEC + 2.0
					return
				if _removal_done and not _removal_logged and scene != null \
						and scene.get_instance_id() != _removal_scene_id and scene_file.get_file() == SHOP_SCENE_FILE:
					_removal_logged = true
					ProbeLog.event("local_sim.removal.shop", {"players": _player_data(), "shop": _shop_snapshot(scene),
							"locked_size": RunData.locked_shop_items.size(), "count": RunData.get_player_count()})
			if not _shop_pressed and _shop_left <= 0.0:
				if _waves_done == 1 and _run_view_check(scene, "shop", delta):
					return
				_shop_pressed = true
				# The timeout counts from the GO press, not from the display checks.
				_shop_left = 0.0
				if _waves_done == 1 and not _view_checks.get("shop", {}).get("ran", false):
					_save_screenshot("shop_%dp.png" % _players_wanted)
				_player_data_log.append({"after_wave": _waves_done, "players": _player_data()})
				_press_shop_go(scene)
			if _shop_pressed and scene_file == MenuData.game_scene:
				_start_next_wave()
			elif _shop_left < -SHOP_TIMEOUT_SEC:
				_finish("stuck_in_shop_after_wave_%d" % _waves_done)
		"after_battle":
			_after_battle_left -= delta
			if not _after_battle_shot and _after_battle_left < AFTER_BATTLE_SEC - 2.0:
				_after_battle_shot = true
				if scene_file.get_file() == SHOP_SCENE_FILE:
					ProbeLog.event("local_sim.final_shop", {"players": _player_data(), "shop": _shop_snapshot(scene)})
				_save_screenshot("%s_%dp.png" % [scene_file.get_file().get_basename(), _players_wanted])
			if _after_battle_shot and scene_file.get_file() == "coop_end_run.tscn" and _run_view_check(scene, "coop_end_run", delta):
				_after_battle_left = max(_after_battle_left, 0.5)
				return
			if _after_battle_left <= 0.0:
				_finish("reached:%s after %d waves" % [scene_file.get_file(), _waves_done])


# Brotato Online's managers our extensions take over: their scripts must be
# live (methods and constants), not only the extension on top.
func _log_bo_scripts() -> void:
	var out := {}
	for name in ["BrotatoOnlineSessionManager", "BrotatoOnlineLobbyBrowser", "BrotatoOnlineMenuSyncManager", "BrotatoOnlineStateSnapshot", "BrotatoOnlinePlayerRemovalManager"]:
		var node = get_node_or_null("/root/ModLoader/six666-BrotatoOnline/" + name)
		var info := {"found": node != null}
		if node != null and node.get_script() != null:
			var script = node.get_script()
			info["valid"] = script.can_instance()
			var levels := []
			var s = script
			while s != null:
				levels.append(str(s.resource_path).get_file())
				s = s.get_base_script()
			info["levels"] = levels
			info["protocol"] = str(node.get("NETWORK_PROTOCOL_VERSION"))
			info["methods"] = node.has_method("_ready") and node.has_method("get_script")
		out[name] = info
	ProbeLog.event("local_sim.bo_scripts", out)


func _start_run() -> void:
	_log_bo_scripts()
	_elapsed = 0.0
	# RunData.reset() copies DebugService.invulnerable into RunData (run_data.gd:566).
	DebugService.invulnerable = not _mortal
	DebugService.custom_wave_duration = _wave_seconds if _wave_seconds > 0 else -1
	DebugService.disable_saving = not _save
	DebugService.starting_wave = _start_wave

	_devices = [KEYBOARD_DEVICE]
	var virtual_ids: Array = RuntimeGate.virtual_device_ids()
	for i in range(_players_wanted - 1):
		if i < virtual_ids.size():
			_devices.append(int(virtual_ids[i]))
	_setup["gate"] = {"extended": RuntimeGate.is_extended(), "capacity": RuntimeGate.capacity(), "reasons": RuntimeGate.block_reasons()}
	if _devices.size() < _players_wanted:
		_setup["error"] = "not enough devices: gate offers %d virtual ids" % virtual_ids.size()
		_finish("setup_failed")
		return

	if _pad:
		_pad_arrays(null)
	_step("coop_clear")
	CoopService.clear()
	_step("add_player", {"device": KEYBOARD_DEVICE})
	CoopService._add_player(KEYBOARD_DEVICE, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	var seated := _devices.size() - 1 if _late_join and _menus and _devices.size() > 1 else _devices.size()
	for i in range(1, seated):
		_step("add_player", {"device": _devices[i], "index": i})
		CoopService._add_player(_devices[i], CoopService.PlayerType.GAMEPAD_XBOX)
	if seated < _devices.size():
		_late_join_state = "pending"
	_step("players_added")
	_setup["connected_players"] = CoopService.connected_players.duplicate(true)
	_setup["missing_actions"] = _missing_actions()

	_step("run_data_reset")
	RunData.reset()
	RunData.set_coop_run(_players_wanted > 1)
	RunData.invulnerable = not _mortal
	_step("set_player_count")
	RunData.set_player_count(_players_wanted if _late_join_state == "" else _players_wanted - 1, true)
	if _menus and _dlc_missing > 0:
		_setup_dlc_missing()
	if _menus:
		RunData.play_mode = RunData.PlayMode.COOP if _players_wanted > 1 else RunData.PlayMode.SOLO
		RunData.menu_selection_back = true
		ProbeLog.event("local_sim.start_menus", {"players": _players_wanted, "devices": _devices})
		_state = "in_menus"
		_setup["change_scene_error"] = get_tree().change_scene(MenuData.character_selection_scene)
		return
	var characters := _pick_characters(_players_wanted)
	var chosen := []
	for player_index in range(_players_wanted):
		var character = characters[player_index]
		_step("add_character", {"index": player_index, "id": character.my_id})
		RunData.add_character(character, player_index)
		var weapons: Array = ItemService.get_ordered_starting_weapons(character.starting_weapons)
		var weapon_id := ""
		if _kit == "perf" or _kit == "weapons" or _kit == "perf12":
			weapon_id = _add_perf_kit(player_index, _kit != "weapons", 12 if _kit == "perf12" else 6)
		elif not weapons.empty():
			var _w = RunData.add_weapon(weapons[0], player_index, true)
			weapon_id = weapons[0].my_id
		chosen.append({"player": player_index + 1, "character": character.my_id, "weapon": weapon_id, "device": _devices[player_index]})
	_step("starting_items")
	RunData.add_starting_items_and_weapons()
	_step("difficulty")
	RunData.current_difficulty = 0
	_step("elites")
	RunData.reset_elites_spawn()
	RunData.init_elites_spawn()
	_step("events")
	RunData.init_events_nightmare()
	RunData.enabled_dlcs = ProgressData.get_active_dlc_ids()
	_step("ban")
	for player_index in range(RunData.get_player_count()):
		var player_run_data = RunData.players_data[player_index]
		player_run_data.uses_ban = RunData.is_ban_mode_active
		player_run_data.remaining_ban_token = RunData.BAN_MAX_TOKEN
	_step("bosses")
	RunData.init_bosses_spawn()
	RunData.current_run_accessibility_settings = ProgressData.settings.enemy_scaling.duplicate()
	_step("setup_done")
	_setup["players"] = chosen
	_setup["run_data_player_count"] = RunData.get_player_count()
	ProbeLog.event("local_sim.start_run", {"players": _players_wanted, "devices": _devices})
	_state = "in_run"
	var err = get_tree().change_scene(MenuData.game_scene)
	_setup["change_scene_error"] = err


func _setup_dlc_missing() -> void:
	var roster = get_tree().root.get_node_or_null("ModLoader/CoopPlus-OnlineExtendedCoop/CoopPlusDlcRoster")
	if roster == null:
		_setup["dlc_error"] = "no roster"
		return
	roster.debug_set_owner(_dlc_missing - 1, [])
	# The first zone of a DLC: it must stay selected for the run.
	var zone_index := 0
	for zone_data in ZoneService.zones:
		if zone_data.dlc_id != "" and ProgressData.available_dlc_ids.has(zone_data.dlc_id):
			ProgressData.settings.zone_selected = zone_index
			ProgressData.settings.zone_is_random = false
			break
		if zone_data.dlc_id == "" or ProgressData.available_dlc_ids.has(zone_data.dlc_id):
			zone_index += 1
	_setup["dlc"] = {"missing_player": _dlc_missing, "available": ProgressData.available_dlc_ids.duplicate(),
			"zone_selected": ProgressData.settings.zone_selected}


func _dlc_state(scene) -> Dictionary:
	var out := {"scene": scene.filename.get_file() if scene != null else "", "available": ProgressData.available_dlc_ids.duplicate(),
			"active_update_data": ProgressData.active_update_data.duplicate()}
	var bar = scene.find_node("ItemSetBar", true, false) if scene != null else null
	if bar != null:
		var buttons := []
		for i in bar._buttons.size():
			buttons.append({"id": bar._updates[i].id, "disabled": bar._buttons[i].disabled, "pressed": bar._buttons[i].pressed})
		out["bar"] = buttons
	var zone_button = scene.get("_zone_selection_button") if scene != null else null
	if zone_button is OptionButton:
		var zones := []
		for i in zone_button.get_item_count():
			zones.append({"text": zone_button.get_item_text(i), "disabled": zone_button.is_item_disabled(i)})
		out["zones"] = zones
		out["zone_selected_index"] = zone_button.selected
		out["current_zone"] = RunData.current_zone
	var badges := []
	if scene != null:
		for node in _find_all(scene, "CoopPlusDlcBadges"):
			var icons := []
			for icon in node.get_children():
				icons.append(icon.modulate.a > 0.5)
			badges.append({"player": int(node.player_index) + 1, "visible": node.is_visible_in_tree(), "owned": icons})
	out["badges"] = badges
	# DLC characters on screen, and whether each is disabled.
	var chars := []
	if scene != null and scene.filename == MenuData.character_selection_scene:
		for element in _find_inventory_elements(scene):
			var item = element.get("item")
			if item is CharacterData:
				var update = _dlc_of_character(item, ProgressData.dlc_ids)
				if update != null:
					chars.append({"id": item.my_id, "dlc": update.id, "disabled": bool(element.get_meta("disabled_by_item_set", false)),
							"locked": bool(item.is_locked), "path": str(element.get_parent().name)})
		out["dlc_characters"] = chars
	return out


func _find_inventory_elements(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is InventoryElement:
			out.append(child)
		else:
			out.append_array(_find_inventory_elements(child))
	return out


func _dlc_of_character(character, dlc_ids: Array):
	for update in ItemService.update_data_list:
		if update != null and update.id in dlc_ids and update.item_set != null:
			for c in update.item_set.characters:
				if c != null and c.my_id == character.my_id:
					return update
	return null


func _find_all(node: Node, node_name: String) -> Array:
	var out := []
	for child in node.get_children():
		if child.name == node_name:
			out.append(child)
		out.append_array(_find_all(child, node_name))
	return out


func _dlc_characters() -> Array:
	var out := []
	for player_index in RunData.get_player_count():
		var character = RunData.get_player_character(player_index)
		var update = _dlc_of_character(character, ProgressData.dlc_ids) if character != null else null
		out.append({"player": player_index + 1, "id": character.my_id if character != null else "",
				"dlc": update.id if update != null else ""})
	return out


func _start_continue(scene) -> void:
	_elapsed = 0.0
	DebugService.invulnerable = not _mortal
	DebugService.custom_wave_duration = _wave_seconds
	DebugService.disable_saving = not _save
	_devices = [KEYBOARD_DEVICE]
	var virtual_ids: Array = RuntimeGate.virtual_device_ids()
	for i in range(_players_wanted - 1):
		if i < virtual_ids.size():
			_devices.append(int(virtual_ids[i]))
	var state: Dictionary = ProgressData.saved_run_state
	var menu = scene.get("_main_menu") if scene != null else null
	var button = menu.get("continue_button") if menu != null else null
	var loaded: Dictionary = ProgressData.get("coopplus_loaded_checkpoint") if ProgressData.get("coopplus_loaded_checkpoint") is Dictionary else {}
	var info := {
		"has_run_state": bool(state.get("has_run_state", false)),
		"players": state.get("players_data", []).size() if state.get("players_data") is Array else -1,
		"shop_lists": state.get("shop_items", []).size() if state.get("shop_items") is Array else -1,
		"continue_visible": button != null and button.visible,
		"checkpoint_id": str(loaded.get("checkpoint_id", "")),
		"identities": loaded.get("identities", {}).keys() if loaded.get("identities") is Dictionary else [],
	}
	ProbeLog.event("local_sim.continue.title", info)
	_setup["continue_title"] = info
	if not info.has_run_state or menu == null or not menu.has_method("_on_ContinueButton_pressed"):
		_finish("continue_unavailable")
		return
	menu._on_ContinueButton_pressed()
	RunData.invulnerable = not _mortal
	_state = "in_resume"


# Brotato Online's own offline switch (player_identity_manager.gd
# wants_offline_resume) before its 300 ms auto-lobby; its session manager is
# paused as well until the shop, so no lobby can be created from this test.
func _seed_resume() -> void:
	var identity = get_node_or_null("/root/ModLoader/six666-BrotatoOnline/BrotatoOnlinePlayerIdentityManager")
	if identity != null:
		identity.set("_offline_resume", true)
	_resume_online(false)
	_resume_seeded = true
	CoopService._add_player(KEYBOARD_DEVICE, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	for i in range(1, _devices.size()):
		CoopService._add_player(_devices[i], CoopService.PlayerType.GAMEPAD_XBOX)
	ProbeLog.event("local_sim.continue.seeded", {"devices": _devices, "connected": CoopService.connected_players.size()})


func _resume_online(enabled: bool) -> void:
	var session = get_node_or_null("/root/ModLoader/six666-BrotatoOnline/BrotatoOnlineSessionManager")
	if session != null:
		session.set_process(enabled)


# Item ids in each player's shop (and locked items) for comparing a save with
# its continue.
func _shop_snapshot(scene) -> Array:
	var out := []
	if scene == null or not scene.has_method("_get_shop_items_container"):
		return out
	for i in RunData.get_player_count():
		var ids := []
		var container = scene._get_shop_items_container(i)
		if container != null and "_shop_items" in container:
			for shop_item in container._shop_items:
				if is_instance_valid(shop_item) and shop_item.item_data != null:
					ids.append(str(shop_item.item_data.my_id))
		out.append(ids)
	return out


# Exploration aid only. Lists come from limits-audit DATA-01/02/04/05, BAT-03/04,
# BAT-15 and the scripts' own [x, x, x, x] initialisers.
func _pad_arrays(scene) -> void:
	_pad_object(RunData, ["remove_speed_effect_cache", "items_nb_cache", "different_items_nb_cache", "duplicate_items_cache",
		"max_consumable_stats_gained_this_wave", "tracked_item_effects", "_are_player_stats_dirty",
		"current_charmed_enemies", "steps_taken_this_wave", "locked_shop_items"])
	_pad_object(TempStats, ["player_stats", "are_player_stats_dirty"])
	_pad_object(LinkedStats, ["update_for_player_every_half_sec"])
	_pad_object(Utils, ["last_elt_selected", "_stat_caches", "_manual_aim_cache"])
	if scene != null and scene.filename == MenuData.game_scene:
		_pad_object(scene, ["_upgrades_to_process", "_consumables_to_process", "_proj_on_death_stat_caches", "_player_is_under_half_health"])
		if "_entity_spawner" in scene and scene._entity_spawner != null:
			_pad_object(scene._entity_spawner, ["lootworms", "queues_to_spawn_structures", "queues_to_spawn_pets"])


func _pad_object(obj: Object, names: Array) -> void:
	for name in names:
		if not name in obj:
			continue
		var arr = obj.get(name)
		if typeof(arr) != TYPE_ARRAY or arr.empty() or arr.size() >= 8:
			continue
		var template = arr[0]
		while arr.size() < 8:
			if name == "tracked_item_effects":
				arr.append(RunData.init_tracked_effects())
			elif typeof(template) == TYPE_ARRAY or typeof(template) == TYPE_DICTIONARY:
				arr.append(template.duplicate() if template.empty() else (([] if typeof(template) == TYPE_ARRAY else {})))
			else:
				arr.append(template if typeof(template) != TYPE_OBJECT else null)
		_pad_counts[name] = int(_pad_counts.get(name, 0)) + 1


# Per-player RunData summary: each slot must keep its own character, gold,
# level and gear across waves (AP-013 ownership check).
func _player_data() -> Array:
	var out := []
	for i in RunData.get_player_count():
		var character = RunData.get_player_character(i)
		out.append({
			"player": i + 1,
			"character": character.my_id if character != null else "",
			"gold": RunData.get_player_gold(i),
			"level": RunData.get_player_level(i),
			"xp": int(RunData.get_player_xp(i)),
			"items": RunData.get_player_items(i).size(),
			"weapons": RunData.get_player_weapons(i).size(),
		})
	return out


func _retry_dialog_visible(scene) -> bool:
	return scene != null and "_retry_wave" in scene and scene._retry_wave != null and scene._retry_wave.visible


# Everyone died: vanilla shows RetryWave (main.gd:1126) and waits for input.
func _answer_retry_dialog(scene) -> void:
	_loss_handled = true
	var dialog = scene._retry_wave
	ProbeLog.event("local_sim.run_lost", {"wave": RunData.current_wave, "answer": _on_loss, "player_data": _player_data()})
	_losses += 1
	if _on_loss == "retry" and dialog.has_method("_on_ConfirmButton_pressed"):
		_retry_from_scene_id = scene.get_instance_id()
		dialog._on_ConfirmButton_pressed()
	elif dialog.has_method("_on_CancelButton_pressed"):
		dialog._on_CancelButton_pressed()


# Every player presses GO through the shop's own handler (the buttons call it
# with the player index, base_shop.gd:177/298); the last press saves the run
# state and loads the next wave.
func _press_shop_go(scene) -> void:
	if scene == null or not scene.has_method("_on_GoButton_pressed"):
		ProbeLog.event("local_sim.shop.no_go_handler")
		return
	for player_index in RunData.get_player_count():
		ProbeLog.event("local_sim.shop.go", {"player_index": player_index})
		scene._on_GoButton_pressed(player_index)


func _start_next_wave() -> void:
	_state = "in_run"
	_wave_elapsed = 0.0
	_menu_mode = false
	_menu_entered_at = -1.0
	_accept_timer = 0.0
	_steer_timer = 0.0
	_screenshot_done = true
	_loss_handled = false
	ProbeLog.event("local_sim.wave_start", {"wave": RunData.current_wave, "players": RunData.get_player_count()})


# The test window is hidden, so any desktop focus change sends it a focus-out;
# vanilla then opens the pause menu (input_service.gd:91-96, main.gd:1706,
# coop_shop.gd:38) and the wave stops; a pause opened in the shop carries into
# the next wave. The harness drops those connections for its own runs.
func _guard_focus_pause(scene) -> void:
	if scene == null or not scene.has_method("_on_game_lost_focus"):
		return
	if InputService.is_connected("game_lost_focus", scene, "_on_game_lost_focus"):
		InputService.disconnect("game_lost_focus", scene, "_on_game_lost_focus")
		ProbeLog.event("local_sim.focus_pause_guard")


# Layout review of the co-op upgrade screen (AP-014, D-010) before anyone has
# chosen. True while the accepts must wait.
func _hold_for_upgrades_shot(scene, delta: float) -> bool:
	if _waves_done > 0:
		return false
	if _upgrades_shot:
		return _run_view_check(scene, "upgrades", delta)
	if _elapsed - _menu_entered_at > UPGRADES_SHOT_WAIT_SEC:
		_upgrades_shot = true
		ProbeLog.event("local_sim.upgrades_shot_skipped")
		return false
	var ui = scene._coop_upgrades_ui if scene != null and "_coop_upgrades_ui" in scene else null
	if ui == null or not ui.visible:
		return true
	_upgrades_visible_for += delta
	if _upgrades_visible_for < UPGRADES_SHOT_AFTER_SEC:
		return true
	_upgrades_shot = true
	_save_screenshot("upgrades_%dp.png" % _players_wanted)
	# Keep holding: the display checks run before anyone chooses (the first
	# accept round resolves the whole screen).
	return true


# Runs VIEW_STEPS[prefix] once per screen kind; true while steps remain.
func _run_view_check(scene, prefix: String, delta: float) -> bool:
	if not _view_checks.has(prefix):
		_view_checks[prefix] = {"step": 0, "timer": 0.0, "done": false, "ran": false}
	var check: Dictionary = _view_checks[prefix]
	if check.done:
		return false
	var strip = scene.find_node("CoopPlusPlayerStatusStrip", true, false) if scene != null else null
	if not check.has("entered"):
		check["entered"] = true
		ProbeLog.event("local_sim.view.%s.enter" % prefix, {"strip": strip != null, "scene": scene.filename if scene != null else ""})
	if strip == null or not strip.has_method("toggle_player"):
		check.done = true
		ProbeLog.event("local_sim.view.%s.no_strip" % prefix)
		return false
	check.timer -= delta
	if check.timer > 0.0:
		return true
	check.timer = VIEW_STEP_SEC
	var steps: Array = VIEW_STEPS[prefix]
	if strip.has_method("is_windowed") and strip.is_windowed():
		steps = VIEW_STEPS_WINDOWED.get(prefix, []) + steps
	if check.step >= steps.size():
		check.done = true
		return false
	var step: String = steps[check.step]
	check.step += 1
	check.ran = true
	var emulator = scene.get_node_or_null("FocusEmulator1")
	var detail := {"step": step}
	var rows: Array = strip._rows.keys()
	rows.sort()
	match step:
		"shot":
			_save_screenshot("%s_%dp.png" % [prefix, _players_wanted])
		"shot_view_pad", "shot_view_click", "shot_pages", "shot_pages_slid", "shot_list", "shot_wheel_page", "shot_wheel_page_end", "shot_stick_row", "shot_pad_edge_row", "shot_pad_edge_page":
			_save_screenshot("%s_%s_%dp.png" % [prefix, step.substr(5), _players_wanted])
		"wheel_down", "wheel_up":
			detail["wheel"] = _wheel_over(strip.get_parent(), BUTTON_WHEEL_DOWN if step == "wheel_down" else BUTTON_WHEEL_UP)
		"rstick_down", "rstick_up":
			for value in [1.0 if step == "rstick_down" else -1.0, 0.0]:
				var motion := InputEventJoypadMotion.new()
				motion.device = 0
				motion.axis = JOY_AXIS_3
				motion.axis_value = value
				Input.parse_input_event(motion)
		"set_row", "set_page":
			strip.save_scroll_mode(strip.SCROLL_ROW if step == "set_row" else strip.SCROLL_PAGE)
		"room_popup", "room_popup_close":
			detail["room"] = _room_popup(scene, step == "room_popup")
		"shot_room_popup", "shot_room_locked":
			_save_screenshot("%s_%s_%dp.png" % [prefix, step.substr(5), _players_wanted])
			var room_button = scene.find_node("CoopPlusRoomType", true, false)
			var hint = scene.find_node("CoopPlusRoomTypeHint", true, false)
			detail["room_state"] = {"list_open": room_button != null and room_button.get_popup().visible,
					"hint": hint != null and hint.visible, "alpha": room_button.modulate.a if room_button != null else -1.0}
		"room_lock", "room_unlock":
			# A room as if a lobby were open (the dropdown is locked then).
			if step == "room_lock":
				RuntimeGate.set_room_capacity(RuntimeGate.verified_capacity())
			else:
				RuntimeGate.clear_room()
		"pad_right", "pad_left", "pad_down", "pad_accept":
			_pad_press(emulator, "ui_" + step.substr(4))
		"key_v":
			for pressed in [true, false]:
				var key := InputEventKey.new()
				key.scancode = KEY_V
				key.physical_scancode = KEY_V
				key.pressed = pressed
				Input.parse_input_event(key)
		"stick_right", "stick_left":
			for value in [1.0 if step == "stick_right" else -1.0, 0.0]:
				var motion := InputEventJoypadMotion.new()
				motion.device = 0
				motion.axis = JOY_AXIS_2
				motion.axis_value = value
				Input.parse_input_event(motion)
		"click_first", "click_last":
			# Rows out of view cannot be clicked: the last one in view.
			var shown := []
			for player_index in rows:
				if strip._rows[player_index].panel.visible:
					shown.append(player_index)
			detail["click"] = _click_row(scene, strip, emulator, shown[0] if step == "click_first" else shown[shown.size() - 1])
	# The state reflects the previous step (events go through the input queue).
	detail["focus"] = _focus_name(emulator, strip)
	detail["viewed"] = strip.viewed_player()
	if "_first" in strip and strip.has_method("is_windowed") and strip.is_windowed():
		var in_view := []
		for player_index in strip._order:
			if strip._rows[player_index].panel.visible:
				in_view.append(player_index + 1)
		detail["list_first"] = strip._first
		detail["list_window"] = strip._window
		detail["list_shown"] = in_view
		detail["list_scroll"] = strip.load_scroll_mode()
	var controller = scene.find_node("CoopPlusPanelViewController", true, false)
	if controller != null:
		detail["mode"] = controller.display_mode()
		detail["start"] = controller.window_start()
	ProbeLog.event("local_sim.view." + prefix, detail)
	return true


# True while the options check runs (OPTIONS_SCENE above).
func _options_step(scene: Node, delta: float) -> bool:
	if _options_menu == null:
		_options_menu = load(OPTIONS_SCENE).instance()
		scene.add_child(_options_menu)
		# Through the tab's own button, so the tab row shows the Gameplay tab
		# as selected too (ui_better_tab_container.gd _change_tab).
		var tab_button = _options_menu.get_node_or_null(OPTIONS_GAMEPLAY_BUTTON_PATH)
		var tabs = _options_menu.get_node_or_null(OPTIONS_TABS_PATH)
		if tab_button is Button:
			tab_button.pressed = true
			tab_button.emit_signal("pressed")
		elif tabs is TabContainer and tabs.has_node("Gameplay_Container"):
			tabs.current_tab = tabs.get_node("Gameplay_Container").get_index()
		if _options_menu.has_method("init_values_from_progress_data"):
			_options_menu.init_values_from_progress_data()
		_options_left = OPTIONS_SHOT_SEC
		return true
	_options_left -= delta
	if _options_left > 0.0:
		return true
	var entry = _options_menu.find_node("CoopPlusListScrollButton", true, false)
	var detail := {"entry": entry != null}
	if entry is CheckButton:
		_save_screenshot("options_gameplay_%dp.png" % _players_wanted)
		var anchor = entry.get_parent().get_node_or_null("ShareCoopLootButton")
		detail["below_share_coop_loot"] = anchor != null and entry.get_index() == anchor.get_index() + 1
		detail["text"] = entry.text
		detail["pressed"] = entry.pressed
		detail["saved"] = PlayerStatusStrip.load_scroll_mode()
		entry.pressed = not entry.pressed
		detail["saved_after_toggle"] = PlayerStatusStrip.load_scroll_mode()
		entry.pressed = not entry.pressed
		detail["saved_after_second_toggle"] = PlayerStatusStrip.load_scroll_mode()
	ProbeLog.event("local_sim.options", detail)
	_options_menu.queue_free()
	_options_shot = false
	return true


# Opens (or closes) the room-type dropdown of the run options the way P1's
# cursor does (focus_emulator.gd _open_option_button); closing gives P1's
# cursor back to where it was, so the menu accepts carry on.
func _room_popup(scene: Node, open: bool) -> Dictionary:
	var button = scene.find_node("CoopPlusRoomType", true, false) if scene != null else null
	var emulator = scene.get_node_or_null("FocusEmulator1") if scene != null else null
	if not button is OptionButton or emulator == null or not emulator.has_method("_open_option_button"):
		return {"error": "no_room_button"}
	var popup: PopupMenu = button.get_popup()
	if not open:
		popup.hide()
		if is_instance_valid(_room_prev_focus):
			emulator._set_focused_control_with_style(_room_prev_focus, false)
		return {"closed": true}
	var items := []
	for i in button.get_item_count():
		items.append(button.get_item_text(i))
	_room_prev_focus = emulator.focused_control
	emulator._set_focused_control_with_style(button, false)
	emulator._open_option_button(button)
	return {"items": items, "selected": button.get_item_text(button.selected), "disabled": button.disabled,
			"popup_rect": [int(popup.rect_global_position.y), int(popup.rect_size.y)]}


# Moves the mouse to the middle of `control` and turns the wheel there once.
func _wheel_over(control: Control, button_index: int) -> Dictionary:
	if control == null:
		return {"error": "no_control"}
	var pos: Vector2 = control.get_global_transform_with_canvas().xform(control.rect_size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = button_index
		button.pressed = pressed
		button.position = pos
		button.global_position = pos
		Input.parse_input_event(button)
	return {"at": [stepify(pos.x, 1), stepify(pos.y, 1)]}


func _pad_press(emulator, action: String) -> void:
	if emulator == null:
		return
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = "%s_%s" % [action, emulator._device]
		ev.pressed = pressed
		Input.parse_input_event(ev)


# CoopFix-OnlineMouseUI only acts in an online session; offline the harness
# calls the same router functions a left click goes through (mouse_router.gd
# _input: _hit_test, _focus, _activate). Without that mod it does what
# _activate does: focus the button and send the emulator ui_accept.
func _click_row(scene, strip, emulator, player_index: int) -> Dictionary:
	var button = strip.select_button(player_index)
	if button == null or emulator == null:
		return {"error": "no_button"}
	var router = get_node_or_null(MOUSE_ROUTER_PATH)
	if router != null and router.has_method("_hit_test"):
		var pos: Vector2 = button.get_global_transform_with_canvas().xform(button.rect_size * 0.5)
		var hit: Array = router._hit_test(scene, pos, [emulator])
		var ok: bool = hit.size() == 2 and hit[0] == button and hit[1] == emulator
		if ok:
			router._focus(button, emulator)
			router._activate(button, emulator)
		return {"via": "coopfix", "player": player_index, "hit": ok, "hit_node": str(hit[0].get_path()) if not hit.empty() else ""}
	emulator._set_focused_control_with_style(button, true)
	var accept := InputEventAction.new()
	accept.action = "ui_accept_%s" % emulator._device
	accept.pressed = true
	var _handled = emulator._handle_input(accept)
	return {"via": "emulator", "player": player_index}


func _focus_name(emulator, strip) -> String:
	if emulator == null or not is_instance_valid(emulator.focused_control):
		return ""
	var control: Control = emulator.focused_control
	if strip.is_a_parent_of(control):
		return "strip/%s" % control.get_parent().name
	return str(control.name)


# Battle screenshot for layout review (HUD of P5..P8, AP-014).
func _save_screenshot(file_name: String) -> void:
	var image: Image = get_viewport().get_texture().get_data()
	image.flip_y()
	var dir := Directory.new()
	var _mk = dir.make_dir_recursive(REPORT_DIR)
	var err := image.save_png(REPORT_DIR.plus_file(file_name))
	ProbeLog.event("local_sim.screenshot", {"file": file_name, "error": err, "size": [image.get_width(), image.get_height()]})


# True while the late join is still running (holds the other menu steps).
func _late_join_step(scene, delta: float) -> bool:
	if _late_join_state == "pending":
		_late_join_before = _grid_layout(scene)
		_late_join_state = "joined"
		_late_join_left = LATE_JOIN_WAIT_SEC
		var device: int = _devices[_devices.size() - 1]
		ProbeLog.event("local_sim.late_join", {"device": device, "before": _late_join_before})
		if _late_join_silent:
			CoopService.connected_players.append([device, CoopService.PlayerType.GAMEPAD_XBOX])
			scene._on_connected_players_updated(CoopService.connected_players, false)
		else:
			CoopService._add_player(device, CoopService.PlayerType.GAMEPAD_XBOX)
		return true
	if _late_join_state == "joined":
		_late_join_left -= delta
		if _late_join_left > 0.0:
			return true
		_late_join_state = "scroll_remote"
		_late_join_presses = 0
		_save_screenshot("character_selection_joined_%dp.png" % _players_wanted)
		ProbeLog.event("local_sim.late_join.after", {"before": _late_join_before, "after": _grid_layout(scene),
				"count": RunData.get_player_count(), "view_key": scene.get("_coopplus_view_key")})
		_late_join_before = _grid_layout(scene)
		return true
	# A remote player's cursor (P2) moves down the shared grid, then P1's own.
	if _late_join_state == "scroll_remote" or _late_join_state == "scroll_local":
		_late_join_left -= delta
		if _late_join_left > 0.0:
			return true
		_late_join_left = 0.15
		var who := "FocusEmulator2" if _late_join_state == "scroll_remote" else "FocusEmulator1"
		var emulator = scene.get_node_or_null(who)
		if _late_join_presses == 0 and emulator != null:
			_late_join_saved_focus = emulator.focused_control
		if _late_join_presses < SCROLL_PRESSES:
			_late_join_presses += 1
			_pad_press(emulator, "ui_down")
			return true
		if _late_join_presses == SCROLL_PRESSES:
			_late_join_presses += 1
			_late_join_scroll_after = _grid_layout(scene)
			# Back where it was ("random"): locked cells cannot be picked.
			if emulator != null and is_instance_valid(_late_join_saved_focus):
				emulator.focused_control = _late_join_saved_focus
			return true
		var after: Dictionary = _late_join_scroll_after
		ProbeLog.event("local_sim.late_join." + _late_join_state, {"emulator": who, "before_scroll": _late_join_before.get("grid_scroll", -1),
				"after_scroll": after.get("grid_scroll", -1), "p1_focus": after.get("p1_focus", {}), "back_scroll": _grid_layout(scene).get("grid_scroll", -1)})
		_late_join_before = after
		_late_join_presses = 0
		_late_join_left = 0.3
		if _late_join_state == "scroll_remote":
			_late_join_state = "scroll_local"
		else:
			_late_join_state = "done"
			_menu_scene_time = MENU_SHOT_SEC
		return true
	return false


# The panel row and the character grid's scroll list, as P1's cursor finds it.
func _grid_layout(scene) -> Dictionary:
	var out := {}
	if scene == null:
		return out
	var row = scene.get_node_or_null("MarginContainer/VBoxContainer/DescriptionContainer")
	if row is Control:
		out["row"] = _rect_info(row)
	var emulator = scene.get_node_or_null("FocusEmulator1")
	var control = emulator.get("focused_control") if emulator != null else null
	if control is Control and is_instance_valid(control):
		out["p1_focus"] = _rect_info(control)
		var parent = control.get_parent()
		while parent != null and not parent is ScrollContainer:
			parent = parent.get_parent()
		if parent is ScrollContainer:
			out["grid"] = _rect_info(parent)
			out["grid_scroll"] = parent.scroll_vertical
	return out


func _simulate_removal(scene) -> void:
	var manager = get_node_or_null(REMOVAL_MANAGER_PATH)
	var count: int = RunData.get_player_count()
	var removed: int = _remove_player - 1
	if manager == null or scene == null or removed < 1 or removed >= count or not scene.has_method("get_player_shop_items"):
		ProbeLog.event("local_sim.removal.skipped", {"removed": _remove_player, "count": count, "manager": manager != null})
		return
	var kept := []
	for i in count:
		if i != removed:
			kept.append(i)
	var before := {"players": _player_data(), "shop": _shop_snapshot(scene)}
	var shop_save: Dictionary = ProgressData.get_run_state(scene.get("_shop_items"), scene.get("_reroll_count"),
			scene.get("_paid_reroll_count"), scene.get("_initial_free_rerolls"), scene.get("_free_rerolls"), scene.get("_item_steals"))
	var run_arrays: Array = manager.get("RUN_ARRAYS")
	var save_arrays: Array = manager.get("SAVE_ARRAYS")
	var path: String = scene.filename
	_removal_scene_id = scene.get_instance_id()
	# Brotato Online frees the old scene before compacting (:271), with its
	# exit hook disconnected; the same call here.
	manager._dispose_current_scene()
	# Host compaction (player_removal_manager.gd:273-283).
	RunData.players_data = manager._select_array(RunData.players_data, kept)
	for property in run_arrays:
		var value = RunData.get(property)
		if typeof(value) == TYPE_ARRAY:
			RunData.set(property, manager._select_array(value, kept, true))
	for key in save_arrays:
		var wave_value = RunData.start_wave_state.get(key, null)
		if typeof(wave_value) == TYPE_ARRAY:
			RunData.start_wave_state[key] = manager._select_array(wave_value, kept, key != "players_data")
		# The host then gives the rebuilt shop the kept players' shop states
		# (:322-332); compacting the saved shop arrays gives the same shops.
		var save_value = shop_save.get(key, null)
		if typeof(save_value) == TYPE_ARRAY:
			shop_save[key] = manager._select_array(save_value, kept, key != "players_data")
	var device: int = CoopService.connected_players[removed][0]
	CoopService._remove_player(device)
	# Client roster rebuild (:423 caches, :432 shop locks), then the fix.
	RunData.reset_run_caches()
	TempStats.reset()
	LinkedStats.reset()
	RunData.locked_shop_items = [[], [], [], []]
	if _remove_fix:
		RunData.call("coopplus_fit_per_player_arrays")
	ProgressData.saved_run_state = shop_save
	RunData.resumed_from_state_in_shop = true
	ProbeLog.event("local_sim.removal", {"removed": _remove_player, "kept": kept, "fix": _remove_fix, "before": before,
			"manager_script": str(manager.get_script().resource_path),
			"locked_size": RunData.locked_shop_items.size(), "count": RunData.get_player_count()})
	var _e = get_tree().change_scene_to(load(path))


func _hud_layout(scene) -> Dictionary:
	var out := {"players": []}
	if scene == null:
		return out
	for i in RunData.get_player_count():
		var n: int = i + 1
		var entry := {"player": n}
		var block = scene.get_node_or_null("%%LifeContainerP%d" % n)
		if block is Control:
			entry["block"] = _rect_info(block)
		var things = scene.get_node_or_null("%%UIThingsToProcessPlayerContainer%d" % n)
		if things is Control:
			entry["things"] = _rect_info(things)
		out.players.append(entry)
	var bonus = scene.get("_ui_bonus_gold")
	if bonus is Control and is_instance_valid(bonus):
		out["bonus_gold_parent"] = str(bonus.get_parent().name)
		out["bonus_gold"] = _rect_info(bonus)
	if "_gold_bag" in scene and is_instance_valid(scene._gold_bag):
		var bag: Vector2 = scene.get_viewport().get_canvas_transform().xform(scene._gold_bag.global_position)
		out["gold_bag_screen"] = [int(bag.x), int(bag.y)]
	return out


func _rect_info(control: Control) -> Dictionary:
	var r := control.get_global_rect()
	return {"visible": control.is_visible_in_tree(), "x": int(r.position.x), "y": int(r.position.y), "w": int(r.size.x), "h": int(r.size.y)}


# Durable breadcrumb (probe_log appends and closes per event): survives a hard crash.
func _step(name: String, detail := {}) -> void:
	ProbeLog.event("local_sim.step." + name, detail)


# The game's late-game performance kit (debug_service.gd _apply_perf_scenario).
# perf12: twelve guns, the widest weapon list a row can get (layout checks).
func _add_perf_kit(player_index: int, with_items: bool, weapon_count: int = 6) -> String:
	var weapon = load(DebugService.PERF_SCENARIO_WEAPON_PATH)
	for i in weapon_count:
		var _w = RunData.add_weapon(weapon, player_index)
	for entry in (DebugService.PERF_SCENARIO_ITEMS if with_items else []):
		var item = load(entry[0])
		for i in int(entry[1]):
			RunData.add_item(item, player_index)
	return "perf:%s" % weapon.my_id


func _wave_timeout() -> float:
	if _wave_seconds > 0:
		return _wave_seconds + EXTRA_TIMEOUT_SEC
	return LONGEST_WAVE_SEC * SLOW_WAVE_FACTOR + EXTRA_TIMEOUT_SEC


func _pick_characters(count: int) -> Array:
	var out := []
	for character in ItemService.characters:
		if character == null or character.starting_weapons.empty():
			continue
		out.append(character)
		if out.size() == count:
			return out
	# Fewer distinct characters than players: repeat them in order.
	var distinct := out.size()
	while distinct > 0 and out.size() < count:
		out.append(out[out.size() % distinct])
	return out


func _missing_actions() -> Array:
	var missing := []
	for device in _devices:
		for prefix in ["button_", "analog_"]:
			for dir in DIRECTIONS:
				var action := "%smove_%s_%s" % [prefix, dir, device]
				if not InputMap.has_action(action):
					missing.append(action)
	return missing


func _steer() -> void:
	for device in _devices:
		if _held.has(device):
			Input.action_release("button_move_%s_%s" % [_held[device], device])
		var dir: String = DIRECTIONS[_rng.randi_range(0, DIRECTIONS.size() - 1)]
		var action := "button_move_%s_%s" % [dir, device]
		if InputMap.has_action(action):
			Input.action_press(action, 1.0)
			_held[device] = dir


func _wave_over(scene) -> bool:
	if scene == null or not "_wave_timer" in scene or scene._wave_timer == null:
		return false
	return _wave_elapsed > 3.0 and scene._wave_timer.is_stopped()


func _send_accepts() -> void:
	for device in _devices:
		for pressed in [true, false]:
			var ev := InputEventAction.new()
			ev.action = "ui_accept_%s" % device
			ev.pressed = pressed
			ev.device = device
			Input.parse_input_event(ev)
	var direct := _choose_for_hidden_panels(get_tree().current_scene)
	_accepts_sent += 1
	if _accepts_sent <= 12:
		ProbeLog.event("local_sim.accept_round", {"round": _accepts_sent, "direct": direct})


# With one local player the "own panel large" layout hides the other panels
# (ui/local_focus_layout.gd) and FocusEmulator ignores ui_accept on hidden
# controls (focus_emulator.gd:146). Online, those players' choices arrive over
# the network and Brotato Online applies them through the container methods
# (menu_sync_manager.gd _apply_progression_select_action /
# _apply_progression_item_box_action); the harness does the same for hidden
# panels. Returns the player indices it acted for.
func _choose_for_hidden_panels(scene) -> Array:
	var acted := []
	if scene == null or not "_coop_upgrades_ui" in scene:
		return acted
	var ui = scene._coop_upgrades_ui
	if ui == null or not ui.visible or not "_player_is_choosing" in ui:
		return acted
	var choosing: Array = ui._player_is_choosing
	for player_index in min(choosing.size(), RunData.get_player_count()):
		if not bool(choosing[player_index]):
			continue
		var container = ui._get_player_container(player_index)
		if container == null or container.is_visible_in_tree():
			continue
		if container._items_container.visible:
			container._on_TakeButton_pressed()
			acted.append(player_index)
		elif container._upgrades_container.visible:
			for upgrade_ui in container._get_upgrade_uis():
				if upgrade_ui.visible and upgrade_ui.upgrade_data != null:
					container._on_choose_button_pressed(upgrade_ui.upgrade_data)
					acted.append(player_index)
					break
	return acted


func _release_all() -> void:
	for device in _held:
		Input.action_release("button_move_%s_%s" % [_held[device], device])
	_held.clear()


func _sample(scene) -> void:
	var players := []
	var hud := -1
	if scene != null and "_players" in scene:
		for i in scene._players.size():
			var p = scene._players[i]
			if not is_instance_valid(p):
				players.append({"index": i, "valid": false})
				continue
			var pos: Vector2 = p.global_position
			if not _first_positions.has(i):
				_first_positions[i] = pos
			_max_distance[i] = max(float(_max_distance.get(i, 0.0)), pos.distance_to(_first_positions[i]))
			var device := -1
			if "_movement_behavior" in p and p._movement_behavior != null:
				device = p._movement_behavior.device
			players.append({"index": i, "valid": true, "x": int(pos.x), "y": int(pos.y), "device": device, "dead": bool(p.dead) if "dead" in p else false})
		if "_players_ui" in scene:
			hud = scene._players_ui.size()
	var spawner = scene.get("_entity_spawner") if scene != null else null
	_samples.append({"t": stepify(_elapsed, 0.01), "players": players, "hud_entries": hud, "run_data_players": RunData.get_player_count(), "paused": get_tree().paused,
			"wave": RunData.current_wave, "fps": Engine.get_frames_per_second(),
			"process_ms": stepify(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
			"physics_ms": stepify(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
			"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"static_mb": stepify(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
			"enemies": spawner.enemies.size() if spawner != null and "enemies" in spawner else -1,
			"structures": spawner.structures.size() if spawner != null and "structures" in spawner else -1})


func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true
	_release_all()
	_write_report(reason)
	print("%s done reason=%s players=%d" % [LINE_PREFIX, reason, _players_wanted])
	if _quit_after:
		get_tree().quit()


# Also called at the end of the wave, so a crash in a later scene keeps the battle data.
func _write_report(reason: String) -> void:
	var spawned := 0
	var moved := 0
	var devices_seen := []
	if not _samples.empty():
		var last: Dictionary = _samples[_samples.size() - 1]
		for p in last.players:
			if p.valid:
				spawned += 1
				if not devices_seen.has(p.device):
					devices_seen.append(p.device)
	for i in _max_distance:
		if float(_max_distance[i]) > 30.0:
			moved += 1
	var report := {
		"reason": reason,
		"players_wanted": _players_wanted,
		"wave_seconds": _wave_seconds,
		"setup": _setup,
		"scenes": _scenes_seen,
		"summary": {
			"spawned_players": spawned,
			"players_that_moved": moved,
			"distinct_devices": devices_seen.size(),
			"max_distance": _max_distance,
			"samples": _samples.size(),
			"wave_over_at": stepify(_menu_entered_at, 0.01),
			"accept_rounds": _accepts_sent,
			"waves_done": _waves_done,
			"waves_wanted": _waves_wanted,
			"current_wave": RunData.current_wave,
			"mortal": _mortal,
			"losses": _losses,
			"player_data_by_shop_visit": _player_data_log,
			"player_data_now": _player_data(),
			"padded": _pad_counts,
		},
		"samples": _samples,
	}
	var dir := Directory.new()
	var _mk = dir.make_dir_recursive(REPORT_DIR)
	var f := File.new()
	if f.open(REPORT_PATH, File.WRITE) == OK:
		f.store_string(JSON.print(report, "\t"))
		f.close()
	ProbeLog.event("local_sim.report", {"reason": reason, "spawned": spawned, "moved": moved, "distinct_devices": devices_seen.size()})
	print("%s report reason=%s players=%d spawned=%d moved=%d" % [LINE_PREFIX, reason, _players_wanted, spawned, moved])
