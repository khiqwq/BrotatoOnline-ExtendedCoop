extends "res://tests/runner/test_case.gd"

const DlcRule = preload("res://mods-unpacked/CoopPlus-OnlineExtendedCoop/scripts/core/dlc_rule.gd")


func test_clean_ids_keeps_strings_only() -> void:
	assert_eq(DlcRule.clean_ids(["a", 3, "", "a", null, "b"]), ["a", "b"])
	assert_eq(DlcRule.clean_ids("a"), [])
	assert_eq(DlcRule.clean_ids(["a", "b", "c"], 2), ["a", "b"])
