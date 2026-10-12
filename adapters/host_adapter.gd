extends Node
## Framework seam. This demo uses a trusted local process, NOT a multiplayer RPC implementation.
## In production bind transport peer identity to player_id on the server; never trust a payload id.
signal state_changed
signal voice_command_requested(command: Dictionary)
const Session = preload("res://core/session.gd")
const MockVoice = preload("res://adapters/mock_voice_router.gd")
var session = Session.new()
var mock_voice = MockVoice.new()
var _last_tick_usec := 0
var _peer_players: Dictionary = {}
var _use_mock_voice := true

func _init() -> void:
	session.changed.connect(func(): state_changed.emit())
	session.voice_requested.connect(_request_voice)
	mock_voice.acknowledged.connect(_acknowledge_voice)
	_last_tick_usec = Time.get_ticks_usec()

func _process(_delta: float) -> void:
	_sync_clock()

func _sync_clock() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := float(now - _last_tick_usec) / 1000000.0
	_last_tick_usec = now
	session.advance(elapsed)

func start_game(players: Array, config: Dictionary = {}) -> Dictionary:
	_sync_clock()
	var result: Dictionary = session.start_game(players, config)
	_last_tick_usec = Time.get_ticks_usec()
	return result

func submit_choice(player_id: String, run_id: int, round_index: int, choice: String) -> Dictionary:
	# Refresh monotonic host time before accepting a message, including between frames.
	_sync_clock()
	return session.submit_choice(player_id, run_id, round_index, choice)

func public_snapshot() -> Dictionary:
	return session.public_snapshot()

func private_snapshot(player_id: String) -> Dictionary:
	return session.private_snapshot(player_id)

func cancel_game() -> void:
	_sync_clock()
	session.cancel_game()

func retry_voice() -> Dictionary:
	_sync_clock()
	return session.retry_voice()

func set_connected(player_id: String, connected: bool) -> bool:
	_sync_clock()
	return session.set_connected(player_id, connected)

## Server-only binding seam. Call from your authenticated lobby, never expose as client RPC.
func bind_authenticated_peer(peer_id: int, player_id: String) -> void:
	_peer_players[peer_id] = player_id

func unbind_peer(peer_id: int) -> void:
	if _peer_players.has(peer_id):
		set_connected(_peer_players[peer_id], false)
	_peer_players.erase(peer_id)

## Pass the transport's verified sender ID (not an ID supplied inside a client message).
func submit_from_peer(peer_id: int, run_id: int, round_index: int, choice: String) -> Dictionary:
	if not _peer_players.has(peer_id):
		return {"ok": false, "error": "unauthenticated_peer"}
	return submit_choice(_peer_players[peer_id], run_id, round_index, choice)

func snapshot_for_peer(peer_id: int) -> Dictionary:
	if not _peer_players.has(peer_id):
		return {"ok": false, "error": "unauthenticated_peer"}
	return private_snapshot(_peer_players[peer_id])

## Select before starting. Cancel and wait for closure before changing providers.
func configure_voice_backend(use_mock: bool) -> Dictionary:
	if public_snapshot().phase not in ["idle", "cancelled", "finished"]:
		return {"ok": false, "error": "voice_backend_change_requires_closed_session"}
	_use_mock_voice = use_mock
	return {"ok": true}

## Your external voice provider calls this on the host main thread after actual completion.
func acknowledge_voice(command_id: int, run_id: int, success: bool, message: String = "") -> bool:
	_sync_clock()
	return session.acknowledge_voice(command_id, run_id, success, message)

func _request_voice(command: Dictionary) -> void:
	if _use_mock_voice:
		mock_voice.request(command)
	else:
		voice_command_requested.emit(command.duplicate(true))

func _acknowledge_voice(command_id: int, run_id: int, success: bool, message: String) -> void:
	acknowledge_voice(command_id, run_id, success, message)
