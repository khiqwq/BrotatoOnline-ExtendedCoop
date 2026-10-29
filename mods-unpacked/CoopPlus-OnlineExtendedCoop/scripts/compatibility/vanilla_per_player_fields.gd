extends Reference
# Four-entry per-player arrays of vanilla scripts that several extensions grow
# (field specs for scripts/core/per_player_arrays.gd). Kept here because an
# extension script must never be preloaded by path: after Mod Loader installs
# it, that path resolves to the extended chain and the preload makes the
# script its own parent ("member already exists in a parent class").

const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")

# res://ui/menus/global/popup_manager.gd:11-15
const POPUP_MANAGER := [
	["_item_popups", PerPlayerArrays.KIND_VALUE, null],
	["_elements_hovered", PerPlayerArrays.KIND_VALUE, null],
	["_elements_focused", PerPlayerArrays.KIND_VALUE, null],
	["_elements_pressed", PerPlayerArrays.KIND_VALUE, null],
	["_stat_popups", PerPlayerArrays.KIND_VALUE, null],
]
