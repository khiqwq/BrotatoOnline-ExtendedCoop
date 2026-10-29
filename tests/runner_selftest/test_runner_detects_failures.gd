extends "res://tests/runner/test_case.gd"
# Fixtures for tools/test.ps1 -Suite RunnerSelfTest: both tests must be reported
# as failures, proving the runner does not turn broken tests into PASS.


func test_failing_assertion_is_reported() -> void:
	assert_eq(1, 2, "deliberate failure")


func test_without_assertions_is_reported() -> void:
	pass
