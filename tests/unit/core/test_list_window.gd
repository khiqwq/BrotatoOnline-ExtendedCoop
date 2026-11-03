extends "res://tests/runner/test_case.gd"

const ListWindow = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/list_window.gd")

const PAGE := ListWindow.MODE_PAGE
const ROW := ListWindow.MODE_ROW


func test_short_lists_never_move() -> void:
	for mode in [PAGE, ROW]:
		assert_eq(ListWindow.scrolled(0, 7, 7, 1, mode), 0, mode)
		assert_eq(ListWindow.scrolled(0, 3, 7, -1, mode), 0, mode)
		assert_eq(ListWindow.revealing(0, 7, 7, 6, mode), 0, mode)


# 16 players: 15 rows beside the local player, 7 shown.
func test_pages_show_only_new_rows() -> void:
	assert_eq(ListWindow.scrolled(0, 15, 7, 1, PAGE), 7)
	assert_eq(ListWindow.scrolled(7, 15, 7, 1, PAGE), 14)
	assert_eq(ListWindow.last_shown(14, 15, 7), 14, "the last page holds one row")
	assert_eq(ListWindow.scrolled(14, 15, 7, 1, PAGE), 14, "no page after the last")
	assert_eq(ListWindow.scrolled(14, 15, 7, -1, PAGE), 7)
	assert_eq(ListWindow.scrolled(0, 15, 7, -1, PAGE), 0)


func test_rows_move_one_at_a_time_and_keep_the_window_full() -> void:
	assert_eq(ListWindow.scrolled(0, 15, 7, 1, ROW), 1)
	assert_eq(ListWindow.scrolled(1, 15, 7, -1, ROW), 0)
	assert_eq(ListWindow.scrolled(8, 15, 7, 1, ROW), 8, "rows 8..14 is the last full window")
	assert_eq(ListWindow.last_shown(8, 15, 7), 14)


func test_switching_modes_mid_list() -> void:
	# Row mode left the window at 3: a page step goes to the page after the one holding row 3.
	assert_eq(ListWindow.scrolled(3, 15, 7, 1, PAGE), 7)
	assert_eq(ListWindow.scrolled(3, 15, 7, -1, PAGE), 0)
	# Page mode left the window at 14 (one row shown): row mode fills it back to 8..14.
	assert_eq(ListWindow.scrolled(14, 15, 7, -1, ROW), 7)
	assert_eq(ListWindow.scrolled(14, 15, 7, 1, ROW), 8)


func test_cursor_past_the_ends() -> void:
	assert_eq(ListWindow.revealing(0, 15, 7, 7, ROW), 1, "down from the last shown row")
	assert_eq(ListWindow.revealing(1, 15, 7, 0, ROW), 0, "up from the first shown row")
	assert_eq(ListWindow.revealing(0, 15, 7, 7, PAGE), 7)
	assert_eq(ListWindow.revealing(7, 15, 7, 6, PAGE), 0)
	assert_eq(ListWindow.revealing(7, 15, 7, 14, PAGE), 14)
	assert_eq(ListWindow.revealing(7, 15, 7, 10, PAGE), 7, "a shown row keeps the window")
	assert_eq(ListWindow.revealing(0, 15, 7, 20, ROW), 8, "past the end is the last row")
	assert_eq(ListWindow.revealing(14, 15, 7, 14, ROW), 14, "a window left by page mode stays while its row is shown")
