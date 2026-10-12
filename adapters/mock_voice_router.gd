extends RefCounted
## Local protocol mock only. Does not capture, send, or restrict real audio.
signal acknowledged(command_id: int, run_id: int, success: bool, message: String)
var active_pairs: Array = []
var fail_next := false
var command_log: Array = []
var _latest_run := -1
var _latest_command_id := -1

func request(command: Dictionary) -> void:
	command_log.append(command.duplicate(true))
	if command.run_id < _latest_run:
		acknowledged.emit(command.id, command.run_id, false, "stale_voice_run")
		return
	if command.id <= _latest_command_id:
		acknowledged.emit(command.id, command.run_id, false, "stale_voice_command")
		return
	_latest_run = command.run_id
	_latest_command_id = command.id
	if fail_next:
		fail_next = false
		acknowledged.emit(command.id, command.run_id, false, "mock_injected_failure")
		return
	match command.action:
		"close_all":
			active_pairs.clear()
		"open_pairs":
			if not active_pairs.is_empty():
				acknowledged.emit(command.id, command.run_id, false, "old_routes_still_open")
				return
			active_pairs = command.pairs.duplicate(true)
		"close_pair":
			active_pairs = active_pairs.filter(func(pair): return pair.id != command.pair_id)
		_:
			acknowledged.emit(command.id, command.run_id, false, "unknown_voice_action")
			return
	acknowledged.emit(command.id, command.run_id, true, "")
