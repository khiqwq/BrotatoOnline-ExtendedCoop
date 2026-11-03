extends Reference
# Which rows of a long player list are in view (D-015, ui/player_status_strip.gd).
# `first` is the position of the first shown row, `count` the rows in the
# list, `size` how many are shown at once.
#   page  pages start at multiples of `size`; moving shows a whole page of
#         rows not shown before (the last page may be shorter)
#   row   one row at a time: the row at one end leaves as the next comes in;
#         the window stays full
# Pure rules: no autoloads, no scene tree.

const MODE_PAGE := "page"
const MODE_ROW := "row"


static func last_shown(first: int, count: int, size: int) -> int:
	return int(min(first + size, count)) - 1


# First row after moving towards the end (dir 1) or the start (-1). A first
# row left over from the other mode is taken as it is (page: the page that
# holds it; row: the full window that ends at the list's end).
static func scrolled(first: int, count: int, size: int, dir: int, mode: String) -> int:
	if count <= size or size <= 0 or dir == 0:
		return 0
	if mode == MODE_PAGE:
		var page_first := int(first / size) * size + int(sign(dir)) * size
		return int(clamp(page_first, 0, int((count - 1) / size) * size))
	var base := int(min(first, count - size))
	return int(clamp(base + int(sign(dir)), 0, count - size))


# First row that brings row `to` into view, moving from `first` (the cursor
# going past the first or last shown row). Unchanged when `to` is shown.
static func revealing(first: int, count: int, size: int, to: int, mode: String) -> int:
	if count <= size or size <= 0:
		return 0
	to = int(clamp(to, 0, count - 1))
	if to >= first and to <= last_shown(first, count, size):
		return first
	if mode == MODE_PAGE:
		return int(to / size) * size
	if to < first:
		return to
	return int(clamp(to - size + 1, 0, count - size))
