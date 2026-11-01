extends Control
## Host-only secret state, per-player snapshots, and explicit pair voice routing.
const Session: Script = preload("res://games/minigame/godot_party_default_psychological_party/core/session.gd")
var api: PartyAPI
var request: Dictionary
var players: Array[Dictionary] = []
var local_id: String = ""
var session: RefCounted
var snapshot: Dictionary = {}
var running: bool = false
var clock: float = 0.0
var groups: Dictionary = {}
var pairs: Dictionary = {}
var voice_bus: String = ""
var microphone: bool = false
var title_label: Label
var status_label: Label
var detail_label: Label
var cooperate_button: Button
var defect_button: Button
var voice_button: Button
var message_label: Label

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
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if api == null:
		push_error("请从 GodotParty 大厅启动小游戏")
		return
	if request.get("mode") != "standard":
		api.fail("unsupported_request", "心理博弈仅支持普通局")
		return
	var background: ColorRect = ColorRect.new()
	background.color = Color("#152b39")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column: VBoxContainer = VBoxContainer.new()
	column.custom_minimum_size.x = 900
	column.add_theme_constant_override("separation", 24)
	center.add_child(column)
	title_label = _label(column, "心理博弈 · 合作还是背叛", 42)
	_label(column, "每位玩家都会遇见其他人一次。选择一经提交便锁定。\n合作 / 合作：3 / 3；背叛 / 合作：5 / 0；背叛 / 背叛：1 / 1。\n超时默认背叛，整局结束统一揭晓。", 24)
	status_label = _label(column, "等待所有玩家准备", 28)
	detail_label = _label(column, "", 24)
	var row: HBoxContainer = HBoxContainer.new()
	column.add_child(row)
	cooperate_button = _button(row, "合作", _choose.bind("cooperate"))
	defect_button = _button(row, "背叛", _choose.bind("defect"))
	cooperate_button.disabled = true
	defect_button.disabled = true
	voice_button = _button(column, "开启麦克风（仅当前搭档可听）", _toggle_microphone)
	message_label = _label(column, "可保持静音游玩；麦克风需要系统设置中的授权。", 20)
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
	api.mark_ready()

func _label(parent: Node, text_value: String, font_size: int) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label

func _button(parent: Node, text_value: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(240, 64)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

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
	running = true
	if api.is_host():
		var roster: Array = []
		for player: Dictionary in players:
			roster.append({"id": player.player_id, "name": player.name})
		var report: Dictionary = session.start_game(roster, {"duration_seconds": float(api.get_settings().get("duration", 30))})
		if not report.ok:
			api.fail("rules_start", str(report.error))
			return
		_send_snapshots()

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
	if not running or not api.is_host():
		return
	session.advance(delta)
	clock += delta
	var public: Dictionary = session.public_snapshot()
	if public.phase == "route_error":
		api.fail("voice_route", str(public.error))
		running = false
		return
	if public.phase == "finished":
		_send_snapshots()
		_finish(public)
	elif clock >= 0.25:
		clock = 0.0
		_send_snapshots()

## Acknowledgement means the host routing API accepted the policy, not device audibility.
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

func _send_snapshots() -> void:
	for player: Dictionary in api.get_room_players():
		if not player.connected:
			continue
		var value: Dictionary = session.private_snapshot(player.player_id) if _participant(player.player_id) else session.public_snapshot()
		api.net.send_to_player(player.player_id, &"view", value)

func _participant(id: String) -> bool:
	for player: Dictionary in players:
		if player.player_id == id:
			return true
	return false

func _choose(choice: String) -> void:
	if not running or local_id.is_empty() or not snapshot.get("can_submit", false):
		return
	api.net.send_to_host(&"choice", {"choice": choice, "run_id": snapshot.run_id, "round_index": snapshot.round_index})
	cooperate_button.disabled = true
	defect_button.disabled = true

func _message(sender: Dictionary, topic: StringName, payload: Variant) -> void:
	if not running or not payload is Dictionary:
		return
	if topic == &"view" and int(sender.get("peer_id", 0)) == 1:
		snapshot = payload
		_render()
	elif topic == &"choice" and api.is_host():
		if not payload.get("run_id") is int or not payload.get("round_index") is int or payload.get("choice") not in ["cooperate", "defect"]:
			return
		for player: Dictionary in api.get_players():
			if player.connected and player.player_id in sender.get("player_ids", []):
				session.submit_choice(player.player_id, payload.run_id, payload.round_index, payload.choice)
				_send_snapshots()
				break

func _render() -> void:
	status_label.text = "第 %d / %d 轮 · 剩余 %d 秒%s" % [int(snapshot.get("round_index", -1)) + 1, snapshot.get("round_count", 0), ceili(snapshot.get("remaining_seconds", 0)), " · 观战" if local_id.is_empty() else ""]
	var opponent: String = str(snapshot.get("opponent_id", ""))
	detail_label.text = "本轮轮空，等待其他配对" if opponent.is_empty() else "当前搭档：" + _name(opponent)
	if not str(snapshot.get("self_choice", "")).is_empty():
		detail_label.text += " · 已锁定：" + ("合作" if snapshot.self_choice == "cooperate" else "背叛")
	cooperate_button.disabled = not snapshot.get("can_submit", false)
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
	var error: Error = api.finish({"request_id": request.request_id, "reason": "completed", "rankings": rows, "columns": [{"key": "score", "title": "总收益", "format": "integer"}], "game_data": {"pairs": public.results}})
	if error != OK:
		api.fail("result_rejected", error_string(error))
