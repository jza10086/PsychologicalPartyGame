extends Control
## Scene-based local debugging UI. Uses the same public/private adapter boundary
## a real host would expose, but this process can impersonate every local player.
## This is deliberately NOT a network client, security boundary, or audio system.

@export_group("演示默认值")
@export_range(2, 8, 1) var default_player_count: int = 4
@export_range(1.0, 300.0, 1.0) var default_duration_seconds: float = 30.0
@export var default_immediate_reveal: bool = false
@export_group("收益矩阵")
@export var reward: int = 3
@export var temptation: int = 5
@export var punishment: int = 1
@export var sucker: int = 0
@export_group("调试界面")
@export_range(0.05, 1.0, 0.05) var refresh_interval: float = 0.1
@export_range(0.1, 2.0, 0.1) var auto_play_interval: float = 0.4

@onready var host: Node = $HostAdapter
@onready var player_count: SpinBox = %PlayerCount
@onready var duration: SpinBox = %Duration
@onready var immediate_reveal: CheckBox = %ImmediateReveal
@onready var perspective: OptionButton = %Perspective
@onready var phase_label: Label = %PhaseLabel
@onready var round_label: Label = %RoundLabel
@onready var timer_label: Label = %TimerLabel
@onready var route_label: Label = %RouteLabel
@onready var pairs_text: Label = %PairsText
@onready var private_title: Label = %PrivateTitle
@onready var private_text: Label = %PrivateText
@onready var private_results: Label = %PrivateResults
@onready var leaderboard_text: Label = %LeaderboardText
@onready var results_text: Label = %ResultsText
@onready var feedback_label: Label = %FeedbackLabel
@onready var log_text: RichTextLabel = %LogText
@onready var cooperate: Button = %Cooperate
@onready var defect: Button = %Defect
@onready var cancel: Button = %Cancel
@onready var retry: Button = %Retry
@onready var fail_next: CheckBox = %FailNext
@onready var auto_play: CheckBox = %AutoPlay

const PHASE_LABELS: Dictionary = {
	"idle": "尚未开始", "closing": "正在关闭旧路由", "opening": "正在建立新路由",
	"playing": "选择进行中", "route_error": "路由失败 · 已暂停",
	"finished": "游戏结束", "cancelling": "正在取消", "cancelled": "已取消"
}
var _refresh_elapsed: float = 0.0
var _auto_elapsed: float = 0.0
var _players: Array = []
var _last_state_key: String = ""
var _log_lines: Array[String] = []
var _refreshing: bool = false

func _ready() -> void:
	player_count.value = default_player_count
	duration.value = default_duration_seconds
	immediate_reveal.button_pressed = default_immediate_reveal
	%Payoffs.text = "收益：合作 / 合作 %d:%d    背叛 / 合作 %d:%d    背叛 / 背叛 %d:%d" % [reward, reward, temptation, sucker, punishment, punishment]
	%Start.pressed.connect(_start_game)
	cancel.pressed.connect(_cancel_game)
	retry.pressed.connect(_retry_route)
	cooperate.pressed.connect(_submit.bind("cooperate"))
	defect.pressed.connect(_submit.bind("defect"))
	perspective.item_selected.connect(_on_perspective_changed)
	player_count.value_changed.connect(_on_player_count_changed)
	fail_next.toggled.connect(_on_fail_next_toggled)
	auto_play.toggled.connect(_on_auto_play_toggled)
	host.state_changed.connect(_refresh)
	_rebuild_perspectives(_new_players(int(player_count.value)))
	_log("界面已就绪。先开始游戏，再切换玩家视角提交选择。")
	_refresh()

func _process(delta: float) -> void:
	_refresh_elapsed += delta
	_auto_elapsed += delta
	if _refresh_elapsed >= refresh_interval:
		_refresh_elapsed = 0.0
		_refresh()
	if auto_play.button_pressed and _auto_elapsed >= auto_play_interval:
		_auto_elapsed = 0.0
		_auto_play_step()

func _new_players(count: int) -> Array:
	var players: Array = []
	for index in range(count):
		players.append({"id": "p%d" % (index + 1), "name": "玩家 %d" % (index + 1)})
	return players

func _start_game() -> void:
	var players := _new_players(int(player_count.value))
	var config: Dictionary = {
		"duration_seconds": duration.value,
		"reveal_mode": "pair_complete" if immediate_reveal.button_pressed else "game_end",
		"reward": reward, "temptation": temptation, "punishment": punishment, "sucker": sucker
	}
	_rebuild_perspectives(players)
	_log("开始 / 重开：%d 人，每轮 %.0f 秒，%s。" % [players.size(), duration.value, "本配对完成后向双方揭晓" if immediate_reveal.button_pressed else "终局统一揭晓"])
	var result: Dictionary = host.start_game(players, config)
	_show_result(result, "新游戏请求已提交。")
	_refresh()

func _cancel_game() -> void:
	auto_play.button_pressed = false
	host.cancel_game()
	feedback_label.text = "取消请求已提交，正在确认模拟路由全部关闭。"
	_log(feedback_label.text)
	_refresh()

func _retry_route() -> void:
	host.retry_voice()
	feedback_label.text = "重试路由。仅在关闭旧配对并确认新路由成功后恢复。"
	_log(feedback_label.text)
	_refresh()

func _on_fail_next_toggled(enabled: bool) -> void:
	host.mock_voice.fail_next = enabled
	if enabled:
		_log("已注入一次故障：下一次模拟路由操作将失败。")
	_refresh()

func _on_auto_play_toggled(enabled: bool) -> void:
	if enabled:
		_log("开启本机自动选择：为全部可操作玩家交替提交合作 / 背叛。")
	else:
		_log("关闭本机自动选择。")

func _on_perspective_changed(_index: int) -> void:
	_refresh()

func _on_player_count_changed(value: float) -> void:
	var snapshot: Dictionary = host.public_snapshot()
	if str(snapshot.get("phase", "idle")) == "idle":
		_rebuild_perspectives(_new_players(int(value)))
		_refresh()

func _rebuild_perspectives(players: Array) -> void:
	var selected_id := _selected_player_id()
	_players = players.duplicate(true)
	perspective.clear()
	for player in _players:
		perspective.add_item(str(player.get("name", player.get("id", ""))))
		perspective.set_item_metadata(perspective.item_count - 1, str(player.get("id", "")))
		if str(player.get("id", "")) == selected_id:
			perspective.select(perspective.item_count - 1)
	if perspective.selected < 0 and perspective.item_count > 0:
		perspective.select(0)

func _selected_player_id() -> String:
	if perspective == null or perspective.selected < 0:
		return ""
	return str(perspective.get_item_metadata(perspective.selected))

func _player_name(player_id: String) -> String:
	if player_id.is_empty():
		return "—"
	for player in _players:
		if str(player.get("id", "")) == player_id:
			return str(player.get("name", player_id))
	return player_id

func _submit(choice: String) -> void:
	var snapshot: Dictionary = host.public_snapshot()
	var player_id := _selected_player_id()
	var result: Dictionary = host.submit_choice(player_id, int(snapshot.get("run_id", 0)), int(snapshot.get("round_index", -1)), choice)
	_show_result(result, "%s已锁定本轮选择，不能修改。" % _player_name(player_id))
	_refresh()

func _auto_play_step() -> void:
	var snapshot: Dictionary = host.public_snapshot()
	if str(snapshot.get("phase", "")) != "playing":
		return
	var run_id := int(snapshot.get("run_id", 0))
	var round_index := int(snapshot.get("round_index", -1))
	for index in range(_players.size()):
		var player_id: String = str(_players[index].get("id", ""))
		var own: Dictionary = host.private_snapshot(player_id)
		if bool(own.get("can_submit", false)):
			var choice := "cooperate" if (index + round_index) % 2 == 0 else "defect"
			host.submit_choice(player_id, run_id, round_index, choice)
			var latest: Dictionary = host.public_snapshot()
			if int(latest.get("run_id", -1)) != run_id or int(latest.get("round_index", -1)) != round_index:
				break
	_refresh()

func _refresh() -> void:
	if not is_node_ready() or _refreshing:
		return
	_refreshing = true
	var public: Dictionary = host.public_snapshot()
	var public_players: Array = public.get("players", [])
	if not public_players.is_empty() and public_players != _players:
		_rebuild_perspectives(public_players)
	var phase: String = str(public.get("phase", "idle"))
	var round_index := int(public.get("round_index", -1))
	var round_count := int(public.get("round_count", 0))
	var run_id := int(public.get("run_id", 0))
	phase_label.text = str(PHASE_LABELS.get(phase, phase))
	round_label.text = "局号 %d  ·  第 %d / %d 轮" % [run_id, maxi(0, round_index + 1), round_count]
	timer_label.text = "已结束" if phase == "finished" else ("已取消" if phase == "cancelled" else "剩余 %.1f 秒" % maxf(0.0, float(public.get("remaining_seconds", 0.0))))
	cancel.disabled = phase in ["idle", "cancelled", "finished", "cancelling"]
	retry.disabled = phase != "route_error"
	fail_next.set_pressed_no_signal(bool(host.mock_voice.fail_next))
	var error: String = str(public.get("error", ""))
	%ErrorLabel.text = "路由错误：%s\n点“重试路由”继续，或取消游戏。" % error if not error.is_empty() else ""
	%ErrorLabel.visible = not error.is_empty()
	_render_public(public)
	_render_private(public)
	_render_results(public)
	var state_key := "%d:%d:%s" % [run_id, round_index, phase]
	if state_key != _last_state_key:
		_last_state_key = state_key
		_log("局 %d / 轮 %d：%s" % [run_id, maxi(0, round_index + 1), phase_label.text])
	_refreshing = false

func _render_public(snapshot: Dictionary) -> void:
	var lines: Array[String] = []
	var pairs: Array = snapshot.get("pairs", [])
	for index in range(pairs.size()):
		var pair: Dictionary = pairs[index]
		var status: String = "双方已锁定" if bool(pair.get("complete", false)) else "等待选择"
		lines.append("%02d   %s  ↔  %s\n        %s" % [index + 1, _player_name(str(pair.get("a", ""))), _player_name(str(pair.get("b", ""))), status])
	var bye: String = str(snapshot.get("bye", ""))
	if not bye.is_empty():
		lines.append("轮空   %s · 无对手，不计分" % _player_name(bye))
	pairs_text.text = "\n\n".join(lines) if not lines.is_empty() else "开始游戏后，这里显示本轮全部配对。"
	var active_pairs: Array = host.mock_voice.active_pairs
	var route_names: Array[String] = []
	for pair in active_pairs:
		if pair is Dictionary:
			route_names.append("%s ↔ %s" % [_player_name(str(pair.get("a", ""))), _player_name(str(pair.get("b", "")))])
		else:
			route_names.append(str(pair))
	route_label.text = "模拟路由：" + (" / ".join(route_names) if not route_names.is_empty() else "全部关闭")

func _render_private(public: Dictionary) -> void:
	var player_id := _selected_player_id()
	var own: Dictionary = host.private_snapshot(player_id)
	var phase: String = str(public.get("phase", "idle"))
	var choice: String = str(own.get("self_choice", ""))
	var opponent_id: String = str(own.get("opponent_id", ""))
	var is_bye := str(public.get("bye", "")) == player_id and not player_id.is_empty()
	private_title.text = "%s的本机视角" % _player_name(player_id)
	var lines: Array[String] = []
	if phase == "idle":
		lines.append("准备就绪。开始后可在上方切换玩家。")
	elif is_bye and phase == "playing":
		lines.append("本轮轮空，等待其他配对完成。")
	else:
		lines.append("当前对手：%s" % _player_name(opponent_id))
		lines.append("我的选择：%s" % ("尚未提交" if choice.is_empty() else _choice_name(choice) + " · 已锁定"))
		lines.append("对手选择：仅在规则允许揭晓时显示")
	private_text.text = "\n".join(lines)
	var can_submit := bool(own.get("can_submit", false))
	cooperate.disabled = not can_submit
	defect.disabled = not can_submit
	var authorized: Array = own.get("results", [])
	var result_lines: Array[String] = []
	for result in authorized:
		result_lines.append(_format_result(result))
	private_results.text = "\n\n".join(result_lines) if not result_lines.is_empty() else "此视角暂无可公开结果。\n默认终局揭晓；即时揭晓仅限该配对双方。"

func _render_results(snapshot: Dictionary) -> void:
	var board: Array = snapshot.get("leaderboard", [])
	var board_lines: Array[String] = []
	for row in board:
		board_lines.append("第 %d 名   %s   %s 分" % [int(row.get("rank", 0)), str(row.get("name", _player_name(str(row.get("player_id", ""))))), str(row.get("score", 0))])
	leaderboard_text.text = "\n".join(board_lines) if not board_lines.is_empty() else "游戏结束后统一公布总分与排名。"
	var result_lines: Array[String] = []
	for result in snapshot.get("results", []):
		result_lines.append(_format_result(result))
	results_text.text = "\n\n".join(result_lines) if not result_lines.is_empty() else "终局前不显示公开对局明细。\n每一对玩家恰好相遇一次；轮空不计分。"

func _format_result(result: Dictionary) -> String:
	var a: String = str(result.get("a", ""))
	var b: String = str(result.get("b", ""))
	var reason_a := _reason_name(str(result.get("reason_a", "")))
	var reason_b := _reason_name(str(result.get("reason_b", "")))
	return "第 %d 轮 · %s / %s\n%s%s +%s  |  %s%s +%s" % [int(result.get("round_index", -1)) + 1, _player_name(a), _player_name(b), _choice_name(str(result.get("choice_a", ""))), reason_a, str(result.get("score_a", 0)), _choice_name(str(result.get("choice_b", ""))), reason_b, str(result.get("score_b", 0))]

func _choice_name(choice: String) -> String:
	return {"cooperate": "合作", "defect": "背叛", "": "未提交"}.get(choice, choice)

func _reason_name(reason: String) -> String:
	if reason == "disconnected_timeout":
		return "（断线超时默认）"
	if reason in ["timeout", "timeout_default", "default_timeout"]:
		return "（超时默认）"
	if reason in ["", "submitted", "manual", "player"]:
		return ""
	return "（%s）" % reason

func _show_result(result: Dictionary, success: String) -> void:
	if result.has("ok") and not bool(result["ok"]):
		feedback_label.text = "请求未接受：%s" % str(result.get("error", result.get("reason", result.get("message", "请检查当前状态"))))
	else:
		feedback_label.text = success
	_log(feedback_label.text)

func _log(message: String) -> void:
	_log_lines.append("[%s] %s" % [Time.get_time_string_from_system(), message])
	if _log_lines.size() > 80:
		_log_lines.pop_front()
	if is_instance_valid(log_text):
		log_text.text = "\n".join(_log_lines)
