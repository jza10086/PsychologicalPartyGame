extends RefCounted
## Authoritative state. Keep this object on the host only.
## Call from one host thread; snapshots are detached copies, never raw state.
signal changed
signal voice_requested(command: Dictionary)
const Rules: Script = preload("res://games/minigame/godot_party_default_psychological_party/core/rules.gd")
const VOICE_ACK_TIMEOUT: float = 5.0
var _run_id: int = 0
var _command_id: int = 0
var _phase: String = "idle"
var _players: Array = []
var _config: Dictionary = {}
var _rounds: Array = []
var _round_index: int = -1
var _pairs: Array = []
var _choices: Dictionary = {}
var _results: Array = []
var _scores: Dictionary = {}
var _connected: Dictionary = {}
var _remaining: float = 0.0
var _pending: Dictionary = {}
var _pending_age: float = 0.0
var _queue: Array = []
var _error: String = ""
var _failed_command: Dictionary = {}
var _resume_phase: String = ""

func start_game(players: Array, config: Dictionary = {}) -> Dictionary:
	var validation: Variant = Rules.validate_config(config)
	if validation != "":
		return _reject(validation)
	if players.size() < 2 or players.size() > 8:
		return _reject("require_2_to_8_players")
	var ids: Array = []
	for player: Variant in players:
		if not player is Dictionary or not player.get("id") is String or player.id.strip_edges() == "":
			return _reject("invalid_player")
		if ids.has(player.id):
			return _reject("duplicate_player")
		ids.append(player.id)
	_run_id += 1
	_players = []
	for player: Variant in players:
		_players.append({"id": player.id, "name": str(player.get("name", player.id))})
	_config = Rules.normalized_config(config).duplicate(true)
	_rounds = Rules.schedule(ids)
	_round_index = -1
	_pairs = []
	_choices = {}
	_results = []
	_scores = {}
	_connected = {}
	for id: Variant in ids:
		_scores[id] = 0
		_connected[id] = true
	_remaining = 0.0
	_pending = {}
	_queue = []
	_failed_command = {}
	_error = ""
	_phase = "closing"
	_request_voice("close_all")
	changed.emit()
	return {"ok": true, "run_id": _run_id}

func submit_choice(player_id: String, run_id: int, round_index: int, choice: String) -> Dictionary:
	if not _scores.has(player_id):
		return _reject("unknown_player")
	if run_id != _run_id:
		return _reject("stale_run")
	if round_index != _round_index:
		return _reject("stale_round")
	if _phase != "playing" or _remaining <= 0.0:
		return _reject("round_not_open")
	if not _connected[player_id]:
		return _reject("disconnected")
	if choice not in ["cooperate", "defect"]:
		return _reject("invalid_choice")
	var pair: Variant = _pair_for(player_id)
	if pair.is_empty():
		return _reject("player_has_bye")
	if _choices.has(player_id):
		return _reject("already_locked")
	_choices[player_id] = {"choice": choice, "reason": "submitted"}
	_resolve_pair(pair)
	changed.emit()
	return {"ok": true}

func advance(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	# Fail closed when the voice backend stops acknowledging. No new round is opened.
	if not _pending.is_empty():
		_pending_age += delta
		if _pending_age >= VOICE_ACK_TIMEOUT:
			acknowledge_voice(_pending.id, _pending.run_id, false, "voice_ack_timeout")
	if _phase != "playing":
		return
	_remaining = maxf(0.0, _remaining - delta)
	if _remaining == 0.0:
		# Commit all defaults before resolving any pair (callbacks can advance the round).
		for pair: Variant in _pairs:
			for id: Variant in [pair.a, pair.b]:
				if not _choices.has(id):
					_choices[id] = {"choice": "defect", "reason": "timeout" if _connected[id] else "disconnected_timeout"}
		var current: Variant = _pairs.duplicate()
		for pair: Variant in current:
			_resolve_pair(pair)
	changed.emit()

func set_connected(player_id: String, connected: bool) -> bool:
	if not _connected.has(player_id):
		return false
	_connected[player_id] = connected
	changed.emit()
	return true

func acknowledge_voice(command_id: int, run_id: int, success: bool, message: String = "") -> bool:
	if _pending.is_empty() or _pending.id != command_id or run_id != _run_id:
		return false
	var command: Variant = _pending
	_pending = {}
	if not success:
		_failed_command = command
		_resume_phase = _phase
		_phase = "route_error"
		_error = message if message != "" else "voice_route_failed"
		changed.emit()
		return true
	match command.action:
		"close_all":
			if _phase == "cancelling":
				_phase = "cancelled"
			elif _round_index + 1 >= _rounds.size():
				_phase = "finished"
			else:
				_round_index += 1
				_pairs = _rounds[_round_index].pairs.duplicate(true)
				_choices = {}
				for pair: Variant in _pairs:
					pair.complete = false
				_remaining = float(_config.duration_seconds)
				_phase = "opening"
				_request_voice("open_pairs", {"pairs": _pairs.duplicate(true)})
		"open_pairs":
			_phase = "playing"
		"close_pair":
			_flush_voice_queue()
			_try_end_round()
	changed.emit()
	return true

func retry_voice() -> Dictionary:
	if _phase != "route_error" or _failed_command.is_empty():
		return _reject("no_failed_route")
	var command: Variant = _failed_command.duplicate(true)
	_failed_command = {}
	_error = ""
	_phase = _resume_phase
	_request_voice(command.action, command)
	changed.emit()
	return {"ok": true}

func cancel_game() -> void:
	_run_id += 1
	_pending = {}
	_queue = []
	_failed_command = {}
	_error = ""
	_remaining = 0.0
	_phase = "cancelling"
	_request_voice("close_all")
	changed.emit()

func public_snapshot() -> Dictionary:
	var pair_status: Array = []
	for pair: Variant in _pairs:
		pair_status.append({"id": pair.id, "a": pair.a, "b": pair.b, "complete": pair.complete})
	return {
		"run_id": _run_id, "phase": _phase, "round_index": _round_index,
		"round_count": _rounds.size(), "remaining_seconds": _remaining,
		"players": _players.duplicate(true), "pairs": pair_status,
		"bye": _rounds[_round_index].bye if _round_index >= 0 else "",
		"results": _results.duplicate(true) if _phase == "finished" else [],
		"leaderboard": _leaderboard() if _phase == "finished" else [],
		"error": _error
	}

func private_snapshot(player_id: String) -> Dictionary:
	if not _scores.has(player_id):
		return {"ok": false, "error": "unknown_player"}
	var snapshot: Variant = public_snapshot()
	var pair: Variant = _pair_for(player_id)
	snapshot["self_choice"] = _choices.get(player_id, {}).get("choice", "")
	snapshot["opponent_id"] = "" if pair.is_empty() else (pair.b if pair.a == player_id else pair.a)
	snapshot["can_submit"] = _phase == "playing" and _remaining > 0.0 and not pair.is_empty() and not _choices.has(player_id) and _connected[player_id]
	snapshot["connected"] = _connected[player_id]
	if _phase != "finished":
		snapshot.results = []
		if _config.get("reveal_mode") == "pair_complete":
			for result: Variant in _results:
				if player_id in [result.a, result.b]:
					snapshot.results.append(result.duplicate(true))
	return snapshot

func _resolve_pair(pair: Dictionary) -> void:
	if pair.complete or not (_choices.has(pair.a) and _choices.has(pair.b)):
		return
	pair.complete = true
	var a: Dictionary = _choices[pair.a]
	var b: Dictionary = _choices[pair.b]
	var points: Variant = Rules.payoff(a.choice, b.choice, _config)
	_scores[pair.a] += points[0]
	_scores[pair.b] += points[1]
	_results.append({"round_index": _round_index, "pair_id": pair.id,
		"a": pair.a, "b": pair.b, "choice_a": a.choice, "choice_b": b.choice,
		"reason_a": a.reason, "reason_b": b.reason, "score_a": points[0], "score_b": points[1]})
	_queue.append({"action": "close_pair", "pair_id": pair.id})
	_flush_voice_queue()

func _flush_voice_queue() -> void:
	if _pending.is_empty() and _phase == "playing" and not _queue.is_empty():
		var command: Dictionary = _queue.pop_front()
		_request_voice(command.action, command)

func _try_end_round() -> void:
	if _phase != "playing" or not _pending.is_empty() or not _queue.is_empty():
		return
	for pair: Variant in _pairs:
		if not pair.complete:
			return
	_phase = "closing"
	_request_voice("close_all")

func _request_voice(action: String, data: Dictionary = {}) -> void:
	_command_id += 1
	_pending = {"id": _command_id, "run_id": _run_id, "action": action,
		"pairs": data.get("pairs", []).duplicate(true), "pair_id": data.get("pair_id", "")}
	_pending_age = 0.0
	voice_requested.emit(_pending.duplicate(true))

func _pair_for(player_id: String) -> Dictionary:
	for pair: Variant in _pairs:
		if player_id in [pair.a, pair.b]:
			return pair
	return {}

func _leaderboard() -> Array:
	var result: Array = []
	for player: Variant in _players:
		result.append({"player_id": player.id, "name": player.name, "score": _scores[player.id]})
	result.sort_custom(func(a: Variant, b: Variant) -> Variant: return a.score > b.score if a.score != b.score else a.player_id < b.player_id)
	for i: Variant in range(result.size()):
		result[i]["rank"] = result[i - 1].rank if i > 0 and result[i].score == result[i - 1].score else i + 1
	return result

func _reject(error: String) -> Dictionary:
	return {"ok": false, "error": error}
