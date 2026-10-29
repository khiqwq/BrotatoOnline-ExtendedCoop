extends "res://ui/menus/shop/coop_shop.gd"
# Co-op shop for P5..P8 (AP-015; R01, R08; UI-09, MENU-03, INP-08). The scene
# (coop_shop.tscn) has four player containers, four stat popups and
# FocusEmulator1..4, the accessors index four-entry literals
# (coop_shop.gd:104, :108), and BaseShop keeps twelve four-entry per-player
# arrays (base_shop.gd:8-20) that its _ready writes for every player. Entering
# the shop with five players crashed the release engine (local simulation,
# EV-0019). In _enter_tree, before BaseShop/CoopShop _ready run, the arrays
# grow to the player count and panels, popups and focus emulators 5..N are
# cloned (ui/extra_player_panels.gd); the accessors return the clones. Only
# while the gate is extended and the run has more than four players; otherwise
# every override is the parent's (R08). Callbacks never call their parent
# versions (ADR-001 rule 1). With one local player the screen uses the "own
# panel large" layout (ui/local_focus_layout.gd).

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const ExtraPlayerPanels = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/extra_player_panels.gd")
const LocalFocusLayout = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/ui/local_focus_layout.gd")

const COOPPLUS_MOD_ID := "CoopPlus-OnlineExtendedCoop"
const COOPPLUS_BASE_SHOP_FIELDS := [
	["_shop_items", PerPlayerArrays.KIND_ARRAY],
	["_focused_shop_item", PerPlayerArrays.KIND_VALUE, null],
	["_latest_focused_shop_item", PerPlayerArrays.KIND_VALUE, null],
	["_player_pressed_go_button", PerPlayerArrays.KIND_VALUE, false],
	["_has_bonus_free_reroll", PerPlayerArrays.KIND_VALUE, false],
	["_reroll_price", PerPlayerArrays.KIND_VALUE, 0],
	["_initial_free_rerolls", PerPlayerArrays.KIND_VALUE, 0],
	["_free_rerolls", PerPlayerArrays.KIND_VALUE, 0],
	["_item_steals", PerPlayerArrays.KIND_VALUE, 0],
	["_reroll_count", PerPlayerArrays.KIND_VALUE, 0],
	["_paid_reroll_count", PerPlayerArrays.KIND_VALUE, 0],
	["_reroll_discount", PerPlayerArrays.KIND_VALUE, 0],
]

# Index 0 belongs to player_index 4.
var _coopplus_extra_containers := []
var _coopplus_extra_stat_popups := []


func _enter_tree() -> void:
	if not RuntimeGate.is_extended() or not _coopplus_extra_containers.empty():
		return
	var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
	if size <= PerPlayerArrays.VANILLA_SLOTS:
		return
	var grown: Dictionary = PerPlayerArrays.grow_fields(self, COOPPLUS_BASE_SHOP_FIELDS, size)
	if not grown.skipped.empty():
		ModLoaderLog.warning("shop: per-player arrays missing (%s)" % ",".join(PoolStringArray(grown.skipped)), COOPPLUS_MOD_ID)
	var cloned: Dictionary = ExtraPlayerPanels.clone(self, size, "Content/HBoxContainer2", "CoopShopPlayerContainer", "Content")
	if not bool(cloned.ok):
		ModLoaderLog.error("shop: no P5+ panels (%s)" % cloned.reason, COOPPLUS_MOD_ID)
		return
	_coopplus_extra_containers = cloned.containers
	_coopplus_extra_stat_popups = cloned.popups


# Runs after BaseShop/CoopShop _ready set up every player's panel.
func _ready() -> void:
	if _coopplus_extra_containers.empty():
		return
	var panels := []
	for i in RunData.get_player_count():
		panels.append(_get_coop_player_container(i))
	var _strip = LocalFocusLayout.apply(self, get_node("Content/HBoxContainer2"), panels, "shop")


# Parent: coop_shop.gd:102 (four-entry literal indexed by player).
func _get_coop_player_container(player_index: int) -> CoopShopPlayerContainer:
	var extra := player_index - PerPlayerArrays.VANILLA_SLOTS
	if extra >= 0 and extra < _coopplus_extra_containers.size():
		return _coopplus_extra_containers[extra]
	return ._get_coop_player_container(player_index)


# Parent: coop_shop.gd:107.
func _get_stat_popup(player_index: int) -> StatPopup:
	var extra := player_index - PerPlayerArrays.VANILLA_SLOTS
	if extra >= 0 and extra < _coopplus_extra_stat_popups.size():
		return _coopplus_extra_stat_popups[extra]
	return ._get_stat_popup(player_index)
