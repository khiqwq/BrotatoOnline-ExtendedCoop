extends Reference
# Base class for rule tests. Assertions record failures instead of aborting, so
# one run reports every failing check. Test methods are named test_*; optional
# before_each()/after_each() run around each of them.

var _failures := []
var _checks := 0


func _reset() -> void:
	_failures = []
	_checks = 0


func get_failures() -> Array:
	return _failures


func get_check_count() -> int:
	return _checks


func fail(message: String) -> void:
	_checks += 1
	_failures.append(message)


func assert_true(value, message := "") -> void:
	_checks += 1
	if not value:
		_failures.append("expected true: %s" % message)


func assert_false(value, message := "") -> void:
	_checks += 1
	if value:
		_failures.append("expected false: %s" % message)


func assert_eq(actual, expected, message := "") -> void:
	_checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_failures.append("expected %s, got %s: %s" % [var2str(expected), var2str(actual), message])


func assert_ne(actual, unexpected, message := "") -> void:
	_checks += 1
	if typeof(actual) == typeof(unexpected) and actual == unexpected:
		_failures.append("did not expect %s: %s" % [var2str(actual), message])


func assert_null(value, message := "") -> void:
	_checks += 1
	if value != null:
		_failures.append("expected null, got %s: %s" % [var2str(value), message])


func assert_not_null(value, message := "") -> void:
	_checks += 1
	if value == null:
		_failures.append("expected a value: %s" % message)


func assert_has(container, value, message := "") -> void:
	_checks += 1
	if not container.has(value):
		_failures.append("expected %s to contain %s: %s" % [var2str(container), var2str(value), message])


func assert_not_has(container, value, message := "") -> void:
	_checks += 1
	if container.has(value):
		_failures.append("expected %s not to contain %s: %s" % [var2str(container), var2str(value), message])
