extends Control

## Content-owned gameplay rules, independent of package compatibility.
static func party_definition() -> Dictionary:
	return {"player_counts": [2, 3, 4, 5, 6, 7, 8], "tags": ["original"]}

## Host rules and pair voice routing; reliable phase and owner-only choice changes.
const Session: Script = preload("res://games/minigame/gp_psych_party/core/session.gd")
const Pages = preload("res://games/protocols/godot_party_default_protocol/round_pages.gd")
@export var pages: Pages
var api: PartyAPI
var request: Dictionary
var players: Array[Dictionary] = []
var local_id: String = ""
var session: RefCounted
var snapshot: Dictionary = {}
var running: bool = false
var _published_public: Dictionary = {}
var _published_private: Dictionary = {}
var _phase_key: String = ""
var _end_msec: int = -1
var _choice_pending: bool = false
var groups: Dictionary = {}
var pairs: Dictionary = {}
var voice_bus: String = ""
var microphone: bool = false
@onready var title_label: Label = %TitleLabel
@onready var status_label: Label = %StatusLabel
@onready var detail_label: Label = %DetailLabel
@onready var cooperate_button: Button = %CooperateButton
@onready var defect_button: Button = %DefectButton
@onready var voice_button: Button = %VoiceButton
@onready var message_label: Label = %MessageLabel

func party_setup(value: PartyAPI, config: Dictionary) -> void:
	api = value
	request = config.duplicate(true)
	players = api.get_players()
	for player: Dictionary in players:
		if player.is_local:
			local_id = player.player_id
	api.net.message_received.connect(_message)
	api.players_changed.connect(_players_changed)

func _ready() -> void:
	cooperate_button.pressed.connect(_choose.bind("cooperate"))
	defect_button.pressed.connect(_choose.bind("defect"))
	voice_button.pressed.connect(_toggle_microphone)
	status_label.text = "等待所有玩家准备"
	detail_label.text = ""
	if api == null:
		# F6 previews only the meeting space and HUD, without voice or a simulated match.
		voice_button.disabled = true
		status_label.text = "画面预览"
		detail_label.text = "合作 · 还是背叛"
		return
	if request.get("mode") != "standard":
		api.fail("unsupported_request", "心理博弈仅支持普通局")
		return
	voice_bus = "party." + api.scope_id + ".psychological." + str(api.net.get_multiplayer_api().get_unique_id())
	AudioServer.add_bus()
	AudioServer.set_bus_name(AudioServer.bus_count - 1, voice_bus)
	var error: Error = api.voice.register_playback_bus(voice_bus)
	if error == OK:
		error = _configure_voice()
	if error != OK:
		api.fail("voice_setup", error_string(error))
		return
	if api.is_host():
		session = Session.new()
		session.voice_requested.connect(_route_voice)
	assert(pages != null, "Assign ProtocolPages in the game scene")
	var ready_error: Error = pages.prepare(self, api, request, _start_gameplay)
	if ready_error != OK:
		api.fail("load_failed", error_string(ready_error))

func _configure_voice() -> Error:
	return api.voice.configure_local_endpoint({"capture_requested": microphone, "transmit_requested": microphone, "receive_requested": true, "playback_bus": voice_bus})

func _toggle_microphone() -> void:
	microphone = not microphone
	var error: Error = _configure_voice()
	if error != OK:
		microphone = false
		message_label.text = "语音未开启：" + error_string(error)
	else:
		voice_button.text = "关闭麦克风" if microphone else "开启麦克风（仅当前搭档可听）"
		message_label.text = "语音状态：" + str(api.voice.get_status())

func party_start() -> void:
	pages.transport_started()

func _start_gameplay() -> void:
	running = true
	if api.is_host():
		var roster: Array = []
		for player: Dictionary in players:
			roster.append({"id": player.player_id, "name": player.name})
		var report: Dictionary = session.start_game(roster, {"duration_seconds": float(api.get_settings().get("duration", 30))})
		if not report.ok:
			api.fail("rules_start", str(report.error))
			return
		_publish_changes()

func party_stop(_reason: StringName) -> void:
	running = false
	if api != null and api.voice != null:
		api.voice.configure_local_endpoint({"capture_requested": false, "transmit_requested": false, "receive_requested": false, "playback_bus": voice_bus})
		if api.is_host():
			api.voice.set_policy({"mode": "off"})
	var index: int = AudioServer.get_bus_index(voice_bus)
	if index >= 0:
		AudioServer.remove_bus(index)

func _process(delta: float) -> void:
	if not running:
		return
	if api.is_host():
		session.advance(delta)
		var public: Dictionary = session.public_snapshot()
		if public.phase == "route_error":
			running = false
			api.fail("voice_route", str(public.error))
			return
		_publish_changes()
		if not running:
			return
		if public.phase == "finished":
			_finish(public)
	if not snapshot.is_empty():
		_render()

func _route_voice(command: Dictionary) -> void:
	var error: Error = OK
	match command.action:
		"close_all":
			groups.clear()
			pairs.clear()
			error = api.voice.set_policy({"mode": "off"})
		"open_pairs":
			for pair: Dictionary in command.pairs:
				pairs[pair.id] = [pair.a, pair.b]
				groups[pair.a] = {"group": pair.id}
				groups[pair.b] = {"group": pair.id}
			error = api.voice.update_entities(groups)
			if error == OK:
				error = api.voice.set_policy({"mode": "group"})
		"close_pair":
			for id: String in pairs.get(command.pair_id, []):
				groups[id] = {"group": "closed/" + id}
			error = api.voice.update_entities(groups)
	_acknowledge_route.call_deferred(int(command.id), int(command.run_id), error)

func _acknowledge_route(command_id: int, run_id: int, error: Error) -> void:
	if running:
		session.acknowledge_voice(command_id, run_id, error == OK, error_string(error))

func _publish_changes() -> void:
	var public: Dictionary = session.public_snapshot()
	var key: String = "%s/%s/%s" % [public.run_id, public.round_index, public.phase]
	if key != _phase_key:
		_phase_key = key
		_end_msec = api.net.host_time_msec() + roundi(float(public.remaining_seconds) * 1000.0) if public.phase == "playing" else -1
	var phase_data: Dictionary = {"run_id": public.run_id, "round_index": public.round_index,
		"phase": public.phase, "round_count": public.round_count, "end_msec": _end_msec}
	if phase_data != _published_public:
		var error: Error = api.net.broadcast(&"phase", phase_data)
		if error != OK:
			running = false
			api.fail("phase_send_failed", error_string(error))
			return
		_published_public = phase_data
	for player: Dictionary in players:
		if not player.connected:
			continue
		var source: Dictionary = session.private_snapshot(player.player_id)
		var personal: Dictionary = {}
		for field: String in ["self_choice", "opponent_id", "can_submit", "connected"]:
			personal[field] = source[field]
		var previous: Dictionary = _published_private.get(player.player_id, {})
		var changed: Dictionary = {}
		for field: String in personal:
			if not previous.has(field) or previous[field] != personal[field]:
				changed[field] = personal[field]
		if changed.is_empty():
			continue
		var error: Error = api.net.send_to_player(player.player_id, &"choice_state", changed)
		if error != OK:
			running = false
			api.fail("choice_state_failed", error_string(error))
			return
		_published_private[player.player_id] = personal

func _participant(id: String) -> bool:
	for player: Dictionary in players:
		if player.player_id == id:
			return true
	return false

func _choose(choice: String) -> void:
	if not running or _choice_pending or api.input.input_blocked or local_id.is_empty() or not snapshot.get("can_submit", false):
		return
	_choice_pending = true
	var error: Error = api.net.send_to_host(&"choice", {"choice": choice, "run_id": snapshot.run_id, "round_index": snapshot.round_index})
	if error != OK:
		running = false
		api.fail("choice_send_failed", error_string(error))
		return
	cooperate_button.disabled = true
	defect_button.disabled = true

func _message(sender: Dictionary, topic: StringName, payload: Variant) -> void:
	if not running or not payload is Dictionary:
		return
	if topic in [&"phase", &"choice_state"] and int(sender.get("peer_id", 0)) == 1:
		if topic == &"phase":
			if not payload.get("run_id") is int or not payload.get("round_index") is int or not payload.get("round_count") is int or not payload.get("phase") is String or not payload.get("end_msec") is int:
				return
			_choice_pending = false
			snapshot["can_submit"] = false
		else:
			for key: String in payload:
				if key in ["can_submit", "connected"]:
					if not payload[key] is bool:
						return
				elif key not in ["self_choice", "opponent_id"] or not payload[key] is String:
					return
			_choice_pending = false
		snapshot.merge(payload, true)
		_render()
	elif topic == &"choice" and api.is_host():
		if not payload.get("run_id") is int or not payload.get("round_index") is int or payload.get("choice") not in ["cooperate", "defect"]:
			return
		for player: Dictionary in api.get_players():
			if player.connected and player.player_id in sender.get("player_ids", []):
				session.submit_choice(player.player_id, payload.run_id, payload.round_index, payload.choice)
				_publish_changes()
				break

func _render() -> void:
	status_label.text = api.i18n.text(&"hud.round", {"round": int(snapshot.get("round_index", -1)) + 1, "total": snapshot.get("round_count", 0), "time": ceili(maxf(0.0, float(snapshot.end_msec - api.net.host_time_msec()) / 1000.0)), "spectator": " · 观战" if local_id.is_empty() else ""})
	var opponent: String = str(snapshot.get("opponent_id", ""))
	detail_label.text = "本轮轮空，等待其他配对" if opponent.is_empty() else api.i18n.text(&"hud.partner", {"player": _name(opponent)})
	if not str(snapshot.get("self_choice", "")).is_empty():
		detail_label.text += " · 已锁定：" + ("合作" if snapshot.self_choice == "cooperate" else "背叛")
	cooperate_button.disabled = _choice_pending or not snapshot.get("can_submit", false)
	defect_button.disabled = cooperate_button.disabled

func _name(id: String) -> String:
	for player: Dictionary in players:
		if player.player_id == id:
			return player.name
	return id

func _players_changed() -> void:
	if api.is_host() and session != null:
		for player: Dictionary in api.get_players():
			session.set_connected(player.player_id, player.connected)

func _finish(public: Dictionary) -> void:
	running = false
	var rows: Array[Dictionary] = []
	for row: Dictionary in public.leaderboard:
		var connected: bool = false
		for player: Dictionary in api.get_players():
			if player.player_id == row.player_id:
				connected = player.connected
		rows.append({"player_id": row.player_id, "rank": row.rank if connected else 0, "status": "completed" if connected else "withdrawn", "metrics": {"score": row.score}})
	var error: Error = pages.present({"request_id": request.request_id, "reason": "completed", "rankings": rows, "columns": [{"key": "score", "title": "总收益", "format": "integer"}], "game_data": {"pairs": public.results}})
	if error != OK:
		api.fail("result_rejected", error_string(error))
