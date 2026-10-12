extends SceneTree
var checks := 0
var failures := 0
var ui: Control

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)
	else:
		print("PASS: " + message)

func select_player(id: String) -> void:
	var select: OptionButton = ui.get_node("%Perspective")
	for i in range(select.item_count):
		if str(select.get_item_metadata(i)) == id:
			select.select(i)
			select.item_selected.emit(i)
			return

func run() -> void:
	ui = load("res://demo/main.tscn").instantiate()
	root.add_child(ui)
	await process_frame
	check(ui.player_count.value == 4 and ui.duration.value == 30, "default four players / 30 seconds")
	check(ui.cooperate.disabled and ui.defect.disabled, "idle choice buttons disabled")
	ui.get_node("%Start").pressed.emit()
	check(ui.host.public_snapshot().phase == "playing", "start reaches playing through host routing")
	check(ui.perspective.item_count == 4, "four local perspectives built")
	check(not ui.cooperate.disabled, "current paired player can submit")
	ui.cooperate.pressed.emit()
	check(ui.cooperate.disabled and ui.defect.disabled, "first submission locks both buttons")
	check(ui.private_text.text.contains("合作 · 已锁定"), "own selected choice visible")
	check(not ui.feedback_label.text.contains("合作"), "cross-perspective feedback does not expose choice")
	select_player("p2")
	check(not ui.private_text.text.contains("合作 · 已锁定"), "changing perspective clears other player's choice")
	check(ui.host.public_snapshot().results.is_empty(), "public results hidden before final")
	for i in range(12):
		ui._auto_play_step()
	check(ui.host.public_snapshot().phase == "finished", "auto-play completes four-player game")
	check(ui.host.public_snapshot().results.size() == 6, "all six unique encounters visible at final")
	check(ui.leaderboard_text.text.contains("第 1 名"), "final leaderboard rendered")
	check(ui.timer_label.text == "已结束", "finished timer does not show stale remaining seconds")
	check(ui.host.mock_voice.active_pairs.is_empty(), "final route panel reports no active pairs")
	ui.player_count.value = 3
	ui.immediate_reveal.button_pressed = true
	ui.get_node("%Start").pressed.emit()
	var snap: Dictionary = ui.host.public_snapshot()
	check(snap.round_count == 3 and snap.bye != "", "odd-player demo creates bye")
	select_player(snap.bye)
	check(ui.cooperate.disabled and ui.private_text.text.contains("轮空"), "bye perspective cannot submit")
	for i in range(8):
		ui._auto_play_step()
	check(ui.host.public_snapshot().phase == "finished", "odd-player auto-play reaches final")
	ui.player_count.value = 8
	ui.immediate_reveal.button_pressed = true
	ui.get_node("%Start").pressed.emit()
	snap = ui.host.public_snapshot()
	var pair: Dictionary = snap.pairs[0]
	select_player(pair.a)
	ui.cooperate.pressed.emit()
	select_player(pair.b)
	ui.defect.pressed.emit()
	check(ui.private_results.text.contains("第 1 轮"), "pair-complete result rendered for involved player")
	check(ui.host.public_snapshot().results.is_empty(), "immediate reveal still withheld from public board")
	var other: String = snap.pairs[1].a
	select_player(other)
	check(ui.private_results.text.contains("暂无可公开结果"), "uninvolved perspective cannot see resolved pair")
	ui.fail_next.button_pressed = true
	ui.get_node("%Cancel").pressed.emit()
	check(ui.host.public_snapshot().phase == "route_error", "cancel route failure is visible")
	check(not ui.retry.disabled and ui.cooperate.disabled, "route error enables retry and blocks submissions")
	ui.retry.pressed.emit()
	check(ui.host.public_snapshot().phase == "cancelled", "retry finishes failed cancellation")
	check(ui.host.mock_voice.active_pairs.is_empty(), "cancel cleanup closes all routes")
	ui.fail_next.button_pressed = true
	ui.get_node("%Start").pressed.emit()
	check(ui.host.public_snapshot().phase == "route_error", "startup route failure is visible")
	ui.retry.pressed.emit()
	check(ui.host.public_snapshot().phase == "playing", "retry recovers startup")
	var old_run: int = ui.host.public_snapshot().run_id
	ui.get_node("%Start").pressed.emit()
	check(ui.host.public_snapshot().run_id > old_run, "restart gets fresh run id")
	for i in range(16):
		ui._auto_play_step()
	check(ui.host.public_snapshot().phase == "finished" and ui.host.public_snapshot().results.size() == 28, "eight-player auto-play produces 28 encounter results")
	print("UI_CHECKS: %d passed, %d failed" % [checks - failures, failures])
	ui.queue_free()
	await process_frame
	quit(1 if failures else 0)
