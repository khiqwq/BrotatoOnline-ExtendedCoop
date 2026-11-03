extends "res://tests/runner/test_case.gd"

const DlcRule = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/dlc_rule.gd")


func test_nothing_blocked_when_everyone_has_it() -> void:
	var owners := {0: ["abyssal_terrors"], 1: ["abyssal_terrors"], 2: ["abyssal_terrors", "other"]}
	assert_eq(DlcRule.blocked(["abyssal_terrors"], owners, 3).size(), 0)


func test_missing_players_are_listed_in_order() -> void:
	var owners := {0: ["abyssal_terrors"], 1: [], 2: ["abyssal_terrors"], 4: []}
	var blocked := DlcRule.blocked(["abyssal_terrors"], owners, 5)
	assert_eq(var2str(blocked), var2str({"abyssal_terrors": [1, 3, 4]}), "P2 lacks it, P4 has not reported, P5 lacks it")


func test_players_outside_the_room_do_not_count() -> void:
	var owners := {0: ["d"], 1: ["d"], 5: []}
	assert_eq(DlcRule.blocked(["d"], owners, 2).size(), 0)


func test_each_dlc_is_judged_on_its_own() -> void:
	var owners := {0: ["a", "b"], 1: ["a"]}
	assert_eq(var2str(DlcRule.blocked(["a", "b"], owners, 2)), var2str({"b": [1]}))


func test_players_text() -> void:
	assert_eq(DlcRule.players_text([2, 4], "、"), "P3、P5")
	assert_eq(DlcRule.players_text([0], ", "), "P1")


func test_clean_ids_keeps_strings_only() -> void:
	assert_eq(DlcRule.clean_ids(["a", 3, "", "a", null, "b"]), ["a", "b"])
	assert_eq(DlcRule.clean_ids("a"), [])
	assert_eq(DlcRule.clean_ids(["a", "b", "c"], 2), ["a", "b"])
