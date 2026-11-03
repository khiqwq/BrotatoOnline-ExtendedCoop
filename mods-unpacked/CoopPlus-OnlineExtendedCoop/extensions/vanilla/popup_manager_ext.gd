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


# Whose popup an event belongs to (reported from online play, 2026-11-02:
# another player's purchase closed the local player's popup, and on entering
# the shop the popup showed an item the cursor was not on). The parent takes
# the player from FocusEmulatorSignal, which only knows a control an emulator
# focused in the current frame, and gives everything else (native focus from
# an inventory rebuild after a weapon combine, mouse) to player 0, i.e. P1's
# popup (popup_manager.gd:147-154). In extended rooms an unattributed event
# goes to the player whose focus base holds the control, and is dropped when
# no player's does: an index of -1 would address the last slot (P8).
# Parent: popup_manager.gd:147.
func _get_player_index_for_control(control: Control) -> int:
	if not RuntimeGate.is_extended() or not RunData.is_coop_run:
		return ._get_player_index_for_control(control)
	var player_index: int = FocusEmulatorSignal.get_player_index(control)
	if player_index >= 0:
		return player_index
	return _coopplus_owner_of(control)


func _coopplus_owner_of(control) -> int:
	if control == null or not is_instance_valid(control):
		return -1
	for i in RunData.get_player_count():
		var emulator = Utils.get_focus_emulator(i)
		if emulator != null and is_instance_valid(emulator) and emulator._find_control_base_data(control) != null:
			return i
	return -1


func _coopplus_unowned(control) -> bool:
	return RuntimeGate.is_extended() and RunData.is_coop_run and _get_player_index_for_control(control) < 0


# Parents: popup_manager.gd:56-144.
func _on_element_hovered(element: InventoryElement) -> void:
	if not _coopplus_unowned(element):
		._on_element_hovered(element)


func _on_element_unhovered(element: InventoryElement) -> void:
	if not _coopplus_unowned(element):
		._on_element_unhovered(element)


func _on_element_focused(element: InventoryElement) -> void:
	if not _coopplus_unowned(element):
		._on_element_focused(element)


func _on_element_unfocused(element: InventoryElement) -> void:
	if not _coopplus_unowned(element):
		._on_element_unfocused(element)


func _on_element_pressed(element: InventoryElement) -> void:
	if not _coopplus_unowned(element):
		._on_element_pressed(element)


func _on_shop_item_focused(shop_item: ShopItem):
	if not _coopplus_unowned(shop_item._button):
		._on_shop_item_focused(shop_item)


func _on_shop_item_unfocused(shop_item: ShopItem):
	if not _coopplus_unowned(shop_item._button):
		._on_shop_item_unfocused(shop_item)
