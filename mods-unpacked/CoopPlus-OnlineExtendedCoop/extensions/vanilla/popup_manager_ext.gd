extends "res://ui/menus/global/popup_manager.gd"
# Popup slots for P5..P8 (AP-015; R01, R08; UI-10). PopupManager keeps one
# entry per player in five four-entry arrays (popup_manager.gd:11-15) that the
# upgrade and shop screens write by player index. On the release engine a write
# past the end is silently dropped and a later read gives null, so P5+ popups
# would vanish or crash on first use. The arrays grow in _enter_tree, before
# any owner's _ready registers popups; only while the gate is extended and the
# run has more than four players, so 1..4 player screens are untouched (R08).
# Never calls the parent's callbacks (ADR-001 rule 1); vanilla has no
# _enter_tree.

const RuntimeGate = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/runtime_gate.gd")
const PerPlayerArrays = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/per_player_arrays.gd")
const VanillaFields = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/compatibility/vanilla_per_player_fields.gd")


func _enter_tree() -> void:
	if not RuntimeGate.is_extended():
		return
	var size := PerPlayerArrays.target_size(RunData.get_player_count(), RuntimeGate.capacity())
	if size > PerPlayerArrays.VANILLA_SLOTS:
		var _r = PerPlayerArrays.grow_fields(self, VanillaFields.POPUP_MANAGER, size)
