extends SceneTree
## Dependency-free authority and adversarial regression suite.
## Run: godot --headless --path . --script res://tests/run_tests.gd

const Rules = preload("res://core/rules.gd")
const Session = preload("res://core/session.gd")
const Host = preload("res://adapters/host_adapter.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	print("PsychologicalPartyGame authority tests / Godot ", Engine.get_version_info().string)
	_test_rules()
	_test_schedule()
	_test_validation()
	_test_voice_barriers()
	_test_choice_validation()
	_test_privacy_and_snapshot_isolation()
	_test_timeouts_and_connections()
	_test_route_failure_and_retries()
	_test_cancel_and_restart()
	_test_full_games()
	_test_synchronous_backend()
	_test_host_synchronous_backend()
	_test_host_external_backend()
	_test_peer_identity_and_reconnect()
	_test_leaderboard_ties()
	_test_mock_command_fencing()
	for failure in failures:
		printerr("FAIL: ", failure)
	print("RESULT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _players(count: int) -> Array:
	var result: Array = []
	for i in count:
		result.append({"id": "p%d" % i, "name": "Player %d" % i})
	return result

func _capture(session) -> Array:
	var commands: Array = []
	session.voice_requested.connect(func(command: Dictionary): commands.append(command.duplicate(true)))
	return commands

func _ack(session, command: Dictionary, success := true, message := "") -> bool:
	return session.acknowledge_voice(command.id, command.run_id, success, message)

func _begin(count := 4, config: Dictionary = {}) -> Dictionary:
	var session = Session.new()
	var commands := _capture(session)
	_check(session.start_game(_players(count), config).ok, "start valid %d-player match" % count)
	_check(commands.size() == 1, "start issues exactly one close barrier")
	_ack(session, commands[-1])
	_ack(session, commands[-1])
	_check(session.public_snapshot().phase == "playing", "begin helper reaches playing")
	return {"session": session, "commands": commands}

func _submit(session, id: String, choice := "cooperate") -> Dictionary:
	var snapshot: Dictionary = session.public_snapshot()
	return session.submit_choice(id, snapshot.run_id, snapshot.round_index, choice)

func _drain(session, commands: Array, limit := 100) -> void:
	# Commands already accepted simply return false. Reentrant commands append here.
	var next := 0
	while next < commands.size() and next < limit:
		_ack(session, commands[next])
		next += 1
	_check(next < limit, "voice drain remains bounded")

func _test_rules() -> void:
	_check(Rules.validate_config({}) == "", "default configuration is valid")
	_check(Rules.payoff("cooperate", "cooperate", {}) == [3, 3], "mutual cooperation payoff")
	_check(Rules.payoff("defect", "defect", {}) == [1, 1], "mutual defection payoff")
	_check(Rules.payoff("defect", "cooperate", {}) == [5, 0], "defector payoff")
	_check(Rules.payoff("cooperate", "defect", {}) == [0, 5], "sucker payoff")
	var custom := {"reward": 4.5, "temptation": 8.0, "punishment": 2.25, "sucker": -1.5}
	_check(Rules.validate_config(custom) == "", "finite fractional and negative payoffs are supported")
	_check(Rules.payoff("cooperate", "defect", custom) == [-1.5, 8.0], "custom payoffs applied")
	for invalid in [
		{"duration_seconds": 0}, {"duration_seconds": -1}, {"duration_seconds": 3601},
		{"duration_seconds": INF}, {"duration_seconds": NAN}, {"duration_seconds": "30"},
		{"reward": "3"}, {"temptation": INF}, {"punishment": NAN}, {"sucker": null},
		{"reward": 5}, {"punishment": 3}, {"sucker": 1}, {"reveal_mode": "public"}
	]:
		_check(Rules.validate_config(invalid) != "", "reject invalid configuration %s" % str(invalid))
	_check(Rules.validate_config({"duration_seconds": 0.01, "reveal_mode": "pair_complete"}) == "", "valid short duration and pair reveal")

func _test_schedule() -> void:
	for count in range(2, 9):
		var ids: Array = []
		for player in _players(count):
			ids.append(player.id)
		var original := ids.duplicate()
		var rounds: Array = Rules.schedule(ids)
		var seen := {}
		var byes := {}
		var pair_ids := {}
		_check(ids == original, "%d schedule does not mutate caller IDs" % count)
		_check(rounds.size() == (count - 1 if count % 2 == 0 else count), "%d correct round count" % count)
		for round_data in rounds:
			var present := {}
			_check(round_data.pairs.size() == floori(count / 2.0), "%d correct pairs per round" % count)
			for pair in round_data.pairs:
				_check(ids.has(pair.a) and ids.has(pair.b) and pair.a != pair.b, "%d valid distinct participants" % count)
				_check(not present.has(pair.a) and not present.has(pair.b), "%d each player appears at most once per round" % count)
				present[pair.a] = true
				present[pair.b] = true
				var key := "%s:%s" % [pair.a, pair.b] if pair.a < pair.b else "%s:%s" % [pair.b, pair.a]
				_check(not seen.has(key), "%d no repeated opponent pair" % count)
				_check(not pair_ids.has(pair.id), "%d globally unique pair identifiers" % count)
				seen[key] = true
				pair_ids[pair.id] = true
			if count % 2 == 1:
				_check(ids.has(round_data.bye) and not present.has(round_data.bye), "%d valid exclusive bye" % count)
				byes[round_data.bye] = byes.get(round_data.bye, 0) + 1
			else:
				_check(round_data.bye == "", "%d no bye in even schedule" % count)
		_check(seen.size() == count * (count - 1) / 2, "%d every unordered pairing covered" % count)
		if count % 2 == 1:
			for id in ids:
				_check(byes.get(id, 0) == 1, "%d player %s has exactly one bye" % [count, id])

func _test_validation() -> void:
	var session = Session.new()
	var commands := _capture(session)
	_check(session.public_snapshot().phase == "idle", "new session starts idle")
	for count in [0, 1, 9]:
		_check(not session.start_game(_players(count), {}).ok, "reject %d players" % count)
	for players in [
		[{"id": "p0"}, {"id": "p0"}], [{"id": ""}, {"id": "p1"}],
		[{"id": "  "}, {"id": "p1"}], [{"id": 7}, {"id": "p1"}],
		[{"name": "Missing ID"}, {"id": "p1"}], ["bad", {"id": "p1"}]
	]:
		_check(not session.start_game(players, {}).ok, "reject malformed or duplicate players")
	_check(not session.start_game(_players(2), {"reward": 5}).ok, "start rejects invalid payoff inequality")
	_check(commands.is_empty() and session.public_snapshot().phase == "idle", "validation rejection never requests voice or changes phase")
	_check(not session.private_snapshot("intruder").ok, "private snapshot rejects unknown identity")
	_check(not session.set_connected("intruder", false), "disconnect rejects unknown identity")
	_check(not session.retry_voice().ok, "retry rejects absence of failed routing")

func _test_voice_barriers() -> void:
	var session = Session.new()
	var commands := _capture(session)
	session.start_game(_players(4), {"duration_seconds": 30})
	var close: Dictionary = commands[-1]
	_check(close.action == "close_all", "first command closes all previous routes")
	_check(session.public_snapshot().phase == "closing", "closing while first barrier pending")
	session.advance(1.0)
	_check(commands.size() == 1 and session.public_snapshot().round_index == -1, "no round opened before close acknowledgment")
	_check(not session.acknowledge_voice(close.id + 1, close.run_id, true), "wrong command ID rejected")
	_check(not session.acknowledge_voice(close.id, close.run_id - 1, true), "wrong run acknowledgment rejected")
	_check(_ack(session, close), "first close acknowledged")
	var opening: Dictionary = commands[-1]
	_check(opening.action == "open_pairs" and opening.pairs.size() == 2, "open requests current pair routes")
	_check(session.public_snapshot().phase == "opening", "opening waits for backend")
	_check(not _submit(session, "p0").ok, "choice blocked before open acknowledgment")
	var remaining: float = session.public_snapshot().remaining_seconds
	session.advance(1.0)
	_check(session.public_snapshot().remaining_seconds == remaining, "countdown frozen before open acknowledgment")
	_check(_ack(session, opening), "opening acknowledged")
	_check(not _ack(session, opening), "duplicate acknowledgment ignored")
	var snapshot: Dictionary = session.public_snapshot()
	var first: Dictionary = snapshot.pairs[0]
	var second: Dictionary = snapshot.pairs[1]
	_submit(session, first.a)
	_check(commands.size() == 2, "single selection leaves pair audio open")
	_submit(session, first.b)
	_check(commands[-1].action == "close_pair" and commands[-1].pair_id == first.id, "second selection immediately requests pair-only close")
	var close_first: Dictionary = commands[-1]
	_submit(session, second.a)
	_submit(session, second.b)
	_check(commands.size() == 3, "pair close commands serialized pending acknowledgment")
	_check(session.public_snapshot().round_index == 0, "all selections cannot bypass close acknowledgment")
	_ack(session, close_first)
	_check(commands[-1].action == "close_pair" and commands[-1].pair_id == second.id, "queued pair close follows first acknowledgment")
	_ack(session, commands[-1])
	_check(commands[-1].action == "close_all" and session.public_snapshot().phase == "closing", "full barrier after all pair closes")
	_check(session.public_snapshot().round_index == 0, "round index stays old until full barrier")
	_ack(session, commands[-1])
	_check(commands[-1].action == "open_pairs" and session.public_snapshot().round_index == 1, "next routes open only after full barrier acknowledgment")
	_check(not _submit(session, commands[-1].pairs[0].a).ok, "new round choices blocked during opening")
	_ack(session, commands[-1])
	_check(session.public_snapshot().phase == "playing", "next round starts after open acknowledgment")

func _test_choice_validation() -> void:
	var context := _begin(3)
	var session = context.session
	var snapshot: Dictionary = session.public_snapshot()
	var pair: Dictionary = snapshot.pairs[0]
	_check(not _submit(session, "intruder").ok, "unknown player cannot choose")
	_check(not session.submit_choice(pair.a, snapshot.run_id - 1, snapshot.round_index, "cooperate").ok, "stale run selection rejected")
	_check(not session.submit_choice(pair.a, snapshot.run_id, snapshot.round_index + 1, "cooperate").ok, "wrong round selection rejected")
	_check(not _submit(session, pair.a, "invalid").ok, "invalid selection rejected")
	_check(not _submit(session, snapshot.bye).ok, "bye player cannot submit")
	_check(not session.private_snapshot(snapshot.bye).can_submit, "bye private status cannot submit")
	_check(session.private_snapshot(snapshot.bye).opponent_id == "", "bye has no opponent")
	_check(_submit(session, pair.a, "defect").ok, "first valid selection accepted")
	_check(not _submit(session, pair.a, "cooperate").ok, "duplicate or changed selection rejected")
	_check(session.private_snapshot(pair.a).self_choice == "defect", "first selection remains locked")
	_check(not session.private_snapshot(pair.a).can_submit, "submitted player cannot select twice")
	_check(session.private_snapshot(pair.b).can_submit, "partner can still select")
	_submit(session, pair.b)
	_check(not _submit(session, pair.b).ok, "completed pair rejects late selection")
	_drain(session, context.commands)
	_check(not session.submit_choice(pair.a, snapshot.run_id, snapshot.round_index, "cooperate").ok, "old-round message rejected after transition")

func _test_privacy_and_snapshot_isolation() -> void:
	for mode in ["game_end", "pair_complete"]:
		var context := _begin(4, {"reveal_mode": mode})
		var session = context.session
		var initial: Dictionary = session.public_snapshot()
		var own: Dictionary = initial.pairs[0]
		var other: Dictionary = initial.pairs[1]
		_submit(session, own.a, "defect")
		var public_view: Dictionary = session.public_snapshot()
		_check(public_view.results.is_empty() and public_view.leaderboard.is_empty(), "%s no public mid-game outcomes or scores" % mode)
		for pair_view in public_view.pairs:
			_check(pair_view.keys().size() == 4 and not pair_view.has("choice_a"), "%s public pair state contains no secret field" % mode)
		_check(session.private_snapshot(own.b).self_choice == "", "%s partner cannot see unsubmitted secret" % mode)
		_check(session.private_snapshot(own.b).results.is_empty(), "%s unresolved outcomes stay hidden" % mode)
		_submit(session, own.b, "cooperate")
		for id in [own.a, own.b]:
			var private_view: Dictionary = session.private_snapshot(id)
			_check(private_view.results.size() == (1 if mode == "pair_complete" else 0), "%s own completed result visibility" % mode)
			_check(private_view.leaderboard.is_empty(), "%s private running totals hidden" % mode)
		for id in [other.a, other.b]:
			_check(session.private_snapshot(id).results.is_empty(), "%s cross-pair outcomes stay private" % mode)
		_check(session.public_snapshot().results.is_empty(), "%s completed pair not broadcast publicly" % mode)
		public_view.players[0].name = "MUTATED"
		public_view.pairs[0].complete = false
		_check(session.public_snapshot().players[0].name != "MUTATED", "%s player snapshots detached" % mode)
		_check(session.public_snapshot().pairs[0].complete, "%s pair snapshots detached" % mode)
		if mode == "pair_complete":
			var private_view: Dictionary = session.private_snapshot(own.a)
			private_view.results[0].score_a = 99999
			_check(session.private_snapshot(own.a).results[0].score_a != 99999, "private outcome snapshots detached")
		_submit(session, other.a)
		_submit(session, other.b)
		_drain(session, context.commands)
		for player in _players(4):
			var private_view: Dictionary = session.private_snapshot(player.id)
			_check(private_view.self_choice == "", "%s old selection not reused in later round" % mode)
			for result in private_view.results:
				_check(player.id in [result.a, result.b], "%s historical private outcomes include own pairs only" % mode)

func _test_timeouts_and_connections() -> void:
	var context := _begin(4, {"duration_seconds": 10, "reveal_mode": "pair_complete"})
	var session = context.session
	var original: Dictionary = session.public_snapshot()
	var first: Dictionary = original.pairs[0]
	var second: Dictionary = original.pairs[1]
	_check(session.set_connected(first.b, false), "known player disconnect accepted")
	_check(not _submit(session, first.b).ok, "disconnected player cannot submit")
	_check(session.private_snapshot(first.b).self_choice == "", "disconnect does not immediately force choice")
	_check(session.public_snapshot().pairs == original.pairs, "disconnect never replaces scheduled opponent")
	_submit(session, first.a, "cooperate")
	session.advance(-1.0)
	session.advance(NAN)
	session.advance(INF)
	_check(session.public_snapshot().remaining_seconds == 10.0, "invalid deltas do not alter countdown")
	session.advance(9.999)
	_check(not session.public_snapshot().pairs[0].complete, "no timeout before deadline")
	session.advance(0.0011)
	_check(session.public_snapshot().remaining_seconds == 0.0, "deadline clamps remaining time to zero")
	_check(not _submit(session, second.a).ok, "selection rejected at expired deadline")
	var first_result: Dictionary = session.private_snapshot(first.a).results[0]
	_check(first_result.choice_a == "cooperate" and first_result.choice_b == "defect", "timeout preserves submitted choice and defaults missing choice")
	_check(first_result.reason_a == "submitted" and first_result.reason_b == "disconnected_timeout", "disconnected timeout reason distinguished")
	var second_result: Dictionary = session.private_snapshot(second.a).results[0]
	_check(second_result.choice_a == "defect" and second_result.choice_b == "defect", "both absent choices default to defect")
	_check(second_result.reason_a == "timeout" and second_result.reason_b == "timeout", "connected non-submitters recorded as timeout")
	_check(context.commands[-1].action == "close_pair", "timeout requests pair route shutdown")
	_check(session.set_connected(first.b, true), "reconnect accepted")
	_drain(session, context.commands)
	_check(session.public_snapshot().round_index == 1, "timeouts finish round after route acknowledgment")
	_check(session.private_snapshot(first.b).can_submit, "reconnected participant may choose in next round")

func _test_route_failure_and_retries() -> void:
	for action in ["close_all", "open_pairs", "close_pair"]:
		var session = Session.new()
		var commands := _capture(session)
		session.start_game(_players(4), {})
		if action != "close_all":
			_ack(session, commands[-1])
		if action == "close_pair":
			_ack(session, commands[-1])
			var pair: Dictionary = session.public_snapshot().pairs[0]
			_submit(session, pair.a)
			_submit(session, pair.b)
		var failed: Dictionary = commands[-1]
		_check(failed.action == action, "prepare %s failure" % action)
		_check(_ack(session, failed, false, "backend_denied"), "%s failure acknowledgment accepted" % action)
		var frozen: Dictionary = session.public_snapshot()
		_check(frozen.phase == "route_error" and frozen.error == "backend_denied", "%s error surfaced fail-closed" % action)
		_check(not _submit(session, "p0").ok, "%s failure blocks choices" % action)
		session.advance(100.0)
		_check(session.public_snapshot().round_index == frozen.round_index and session.public_snapshot().remaining_seconds == frozen.remaining_seconds, "%s failure freezes progression" % action)
		var count := commands.size()
		_check(not _ack(session, failed), "%s failed command cannot later be accepted" % action)
		_check(commands.size() == count, "%s stale acknowledgment does not emit routes" % action)
		_check(session.retry_voice().ok, "%s retry accepted" % action)
		var retry: Dictionary = commands[-1]
		_check(retry.id != failed.id and retry.action == action and retry.run_id == failed.run_id, "%s retry uses fresh ID, same scope and run" % action)
		_check(not _ack(session, failed), "%s original acknowledgment rejected during retry" % action)
		_check(_ack(session, retry), "%s retry succeeds" % action)
		_check(session.public_snapshot().phase != "route_error" and session.public_snapshot().error == "", "%s successful retry clears error" % action)
		_check(not session.retry_voice().ok, "%s duplicate retry rejected" % action)
	var context := _begin(4)
	var session = context.session
	var pair: Dictionary = session.public_snapshot().pairs[0]
	_submit(session, pair.a)
	_submit(session, pair.b)
	session.advance(4.999)
	_check(session.public_snapshot().phase == "playing", "route remains pending before five-second deadline")
	session.advance(0.0011)
	_check(session.public_snapshot().phase == "route_error" and session.public_snapshot().error == "voice_ack_timeout", "five-second unacknowledged route fails closed")
	var before: Dictionary = session.public_snapshot()
	session.advance(1000.0)
	_check(session.public_snapshot() == before, "timed-out route state remains frozen")

func _test_cancel_and_restart() -> void:
	var context := _begin(4)
	var session = context.session
	var commands: Array = context.commands
	var first: Dictionary = session.public_snapshot().pairs[0]
	_submit(session, first.a)
	_submit(session, first.b)
	var stale: Dictionary = commands[-1]
	var old_run: int = session.public_snapshot().run_id
	var input_players := _players(3)
	var input_config := {"duration_seconds": 12}
	_check(session.start_game(input_players, input_config).ok, "active game restart accepted")
	input_players[0].name = "MUTATED"
	input_config.duration_seconds = 999
	_check(session.public_snapshot().players[0].name != "MUTATED", "session owns a copy of player input")
	_check(session.public_snapshot().run_id > old_run and commands[-1].action == "close_all", "restart invalidates run and closes all old routes")
	_check(not _ack(session, stale), "old-run acknowledgment rejected after restart")
	_check(not session.submit_choice(first.a, old_run, 0, "cooperate").ok, "old-run choice rejected after restart")
	_ack(session, commands[-1])
	_check(session.public_snapshot().remaining_seconds == 12, "session owns a copy of configuration input")
	var restart_open: Dictionary = commands[-1]
	session.cancel_game()
	var cancel_close: Dictionary = commands[-1]
	_check(cancel_close.action == "close_all" and session.public_snapshot().phase == "cancelling", "cancel immediately requests all-route close")
	_check(not _ack(session, restart_open), "cancellation invalidates pending opening acknowledgment")
	_check(not _submit(session, "p0").ok, "cancel blocks selection")
	_ack(session, cancel_close, false, "cancel_close_failed")
	_check(session.public_snapshot().phase == "route_error", "cancel cannot claim completion after route failure")
	_check(session.retry_voice().ok, "cancel close can retry")
	_ack(session, commands[-1])
	_check(session.public_snapshot().phase == "cancelled", "cancelled only after successful close acknowledgment")
	var count := commands.size()
	session.advance(100.0)
	_check(session.public_snapshot().phase == "cancelled" and commands.size() == count, "cancelled session stays stopped")
	_check(session.public_snapshot().results.is_empty() and session.public_snapshot().leaderboard.is_empty(), "cancel does not publish unfinished scoreboard")
	_check(session.start_game(_players(2), {}).ok, "new game may start after cancellation")
	_check(commands[-1].action == "close_all", "new game still requires reset barrier")

func _test_full_games() -> void:
	for count in range(2, 9):
		for mode in ["game_end", "pair_complete"]:
			var context := _begin(count, {"reveal_mode": mode})
			var session = context.session
			var expected := {}
			for player in _players(count):
				expected[player.id] = 0
			var rounds_played := 0
			while session.public_snapshot().phase == "playing" and rounds_played < 10:
				var snapshot: Dictionary = session.public_snapshot()
				for pair in snapshot.pairs:
					var a_choice := "cooperate" if (int(pair.a.substr(1)) + snapshot.round_index) % 2 == 0 else "defect"
					var b_choice := "cooperate" if (int(pair.b.substr(1)) + snapshot.round_index) % 3 == 0 else "defect"
					var points: Array = Rules.payoff(a_choice, b_choice, {})
					expected[pair.a] += points[0]
					expected[pair.b] += points[1]
					_check(_submit(session, pair.a, a_choice).ok, "%d %s full match first choice" % [count, mode])
					_check(_submit(session, pair.b, b_choice).ok, "%d %s full match second choice" % [count, mode])
					_check(session.public_snapshot().results.is_empty(), "%d %s public outcomes hidden until final barrier" % [count, mode])
				_drain(session, context.commands)
				rounds_played += 1
			var final_view: Dictionary = session.public_snapshot()
			_check(final_view.phase == "finished", "%d %s match reaches finished" % [count, mode])
			_check(rounds_played == (count - 1 if count % 2 == 0 else count), "%d %s all scheduled rounds played" % [count, mode])
			_check(final_view.results.size() == count * (count - 1) / 2, "%d %s exactly one result for every pair" % [count, mode])
			_check(final_view.leaderboard.size() == count, "%d %s final leaderboard has every player" % [count, mode])
			var previous_score := INF
			for row in final_view.leaderboard:
				_check(row.score == expected[row.player_id], "%d %s accumulated score correct for %s" % [count, mode, row.player_id])
				_check(row.score <= previous_score, "%d %s descending leaderboard" % [count, mode])
				previous_score = row.score
			for player in _players(count):
				_check(session.private_snapshot(player.id).results == final_view.results, "%d %s final outcomes available to every player" % [count, mode])
				_check(not session.private_snapshot(player.id).can_submit, "%d %s finished session prevents submissions" % [count, mode])
			_check(context.commands[-1].action == "close_all", "%d %s game ends with all routes closed" % [count, mode])
			_check(not _submit(session, "p0").ok, "%d %s post-game submission rejected" % [count, mode])

func _test_synchronous_backend() -> void:
	# The demo adapter may acknowledge from inside voice_requested. Exercise recursion.
	var session = Session.new()
	var commands: Array = []
	var reference: WeakRef = weakref(session)
	session.voice_requested.connect(func(command: Dictionary):
		commands.append(command.duplicate(true))
		var live = reference.get_ref()
		if live != null:
			live.acknowledge_voice(command.id, command.run_id, true)
	)
	session.start_game(_players(8), {"duration_seconds": 1})
	_check(session.public_snapshot().phase == "playing", "synchronous adapter may complete initial barriers")
	for round_number in 7:
		_check(session.public_snapshot().round_index == round_number, "synchronous timeout starts correct round")
		session.advance(1.0)
	var final_view: Dictionary = session.public_snapshot()
	_check(final_view.phase == "finished", "synchronous timeout adapter completes match")
	_check(final_view.results.size() == 28, "synchronous timeout resolution produces all 28 pair results")
	for result in final_view.results:
		_check(result.choice_a == "defect" and result.choice_b == "defect", "synchronous callback does not drop timeout defaults")
	for row in final_view.leaderboard:
		_check(row.score == 7, "synchronous timeout scores each pairing once")
	var expected_actions: Array = ["close_all"]
	for unused in 7:
		expected_actions.append("open_pairs")
		for pair_number in 4:
			expected_actions.append("close_pair")
		expected_actions.append("close_all")
	var actual_actions: Array = []
	for command in commands:
		actual_actions.append(command.action)
	_check(actual_actions == expected_actions, "synchronous backend preserves exact close/open barrier ordering")

func _test_host_synchronous_backend() -> void:
	for count in range(2, 9):
		var host = Host.new()
		_check(host.start_game(_players(count), {"duration_seconds": 1}).ok, "host starts %d-player match" % count)
		var total_rounds: int = host.public_snapshot().round_count
		for round_number in total_rounds:
			_check(host.public_snapshot().phase == "playing" and host.public_snapshot().round_index == round_number, "host synchronous callback opens correct round")
			_check(host.mock_voice.active_pairs.size() == count / 2, "host mock route count matches current pairs")
			# The real mock calls HostAdapter.acknowledge_voice, which refreshes the
			# host clock and may reenter Session.advance while timeout resolution runs.
			host.session.advance(1.0)
		var final_view: Dictionary = host.public_snapshot()
		_check(final_view.phase == "finished", "host synchronous timeout finishes %d players" % count)
		_check(final_view.results.size() == count * (count - 1) / 2, "host reentrant timeouts retain every result")
		for row in final_view.leaderboard:
			_check(row.score == count - 1, "host reentrant callback scores every match once")
		_check(host.mock_voice.active_pairs.is_empty(), "host finishes with zero active voice routes")
		var expected_actions: Array = ["close_all"]
		for unused in total_rounds:
			expected_actions.append("open_pairs")
			for pair_number in count / 2:
				expected_actions.append("close_pair")
			expected_actions.append("close_all")
		var actions: Array = []
		for command in host.mock_voice.command_log:
			actions.append(command.action)
		_check(actions == expected_actions, "host reentrant route ordering remains serialized")
		host.free()
	var host = Host.new()
	host.start_game(_players(2), {"duration_seconds": 1})
	var before: Dictionary = host.public_snapshot()
	host._last_tick_usec -= 1000001
	_check(not host.submit_choice("p0", before.run_id, before.round_index, "cooperate").ok, "host refreshes monotonic clock before late between-frame submission")
	_check(host.public_snapshot().phase == "finished", "host late submission processes deadline first")
	_check(host.public_snapshot().results[0].choice_a == "defect", "host deadline default wins over late cooperation")
	host.free()

func _test_host_external_backend() -> void:
	var host = Host.new()
	var commands: Array = []
	host.voice_command_requested.connect(func(command: Dictionary): commands.append(command.duplicate(true)))
	_check(host.configure_voice_backend(false).ok, "external voice may be selected while idle")
	host.start_game(_players(4), {})
	_check(commands.size() == 1 and commands[0].action == "close_all", "external provider receives initial route command")
	_check(host.mock_voice.command_log.is_empty(), "external mode never silently invokes mock")
	_check(not host.configure_voice_backend(true).ok, "cannot change provider with pending close barrier")
	var original: Dictionary = commands[-1]
	_check(host.acknowledge_voice(original.id, original.run_id, true), "external close acknowledgment accepted")
	var opening: Dictionary = commands[-1]
	_check(host.public_snapshot().phase == "opening", "external session waits asynchronously for open")
	_check(not host.configure_voice_backend(true).ok, "cannot change provider while opening")
	_check(host.acknowledge_voice(opening.id, opening.run_id, true), "external open acknowledgment accepted")
	_check(host.public_snapshot().phase == "playing", "external open acknowledgment begins play")
	_check(not host.configure_voice_backend(true).ok, "cannot change provider during play")
	var pair: Dictionary = host.public_snapshot().pairs[0]
	var snapshot: Dictionary = host.public_snapshot()
	host.submit_choice(pair.a, snapshot.run_id, snapshot.round_index, "cooperate")
	host.submit_choice(pair.b, snapshot.run_id, snapshot.round_index, "defect")
	var old_pair_close: Dictionary = commands[-1]
	host.start_game(_players(3), {})
	var restart_close: Dictionary = commands[-1]
	_check(restart_close.action == "close_all" and restart_close.run_id > old_pair_close.run_id, "external restart fences and resets old route")
	_check(not host.acknowledge_voice(old_pair_close.id, old_pair_close.run_id, true), "external restart rejects late old pair-close acknowledgment")
	host.acknowledge_voice(restart_close.id, restart_close.run_id, true)
	var old_open: Dictionary = commands[-1]
	host.cancel_game()
	var cancel_close: Dictionary = commands[-1]
	_check(not host.acknowledge_voice(old_open.id, old_open.run_id, true), "external cancellation rejects late old open acknowledgment")
	_check(not host.configure_voice_backend(true).ok, "cannot switch providers before cancelled route closes")
	host.acknowledge_voice(cancel_close.id, cancel_close.run_id, true)
	_check(host.public_snapshot().phase == "cancelled", "external cancellation waits for acknowledged close")
	_check(host.configure_voice_backend(true).ok, "provider may change after confirmed cancellation")
	host.free()
	# No provider connected: fail closed at the exact acknowledgment timeout.
	host = Host.new()
	host.configure_voice_backend(false)
	host.start_game(_players(2), {})
	host._last_tick_usec -= 5000001
	host._sync_clock()
	_check(host.public_snapshot().phase == "route_error" and host.public_snapshot().error == "voice_ack_timeout", "unconnected external provider fails closed after five seconds")
	_check(host.mock_voice.command_log.is_empty(), "unconnected provider failure does not fall back to mock")
	_check(not host.configure_voice_backend(true).ok, "route failure cannot bypass barrier by changing provider")
	host.free()
	# An acknowledgment arriving beyond its deadline cannot revive a command.
	host = Host.new()
	commands = []
	host.voice_command_requested.connect(func(command: Dictionary): commands.append(command.duplicate(true)))
	host.configure_voice_backend(false)
	host.start_game(_players(2), {})
	var late: Dictionary = commands[-1]
	host._last_tick_usec -= 5000001
	_check(not host.acknowledge_voice(late.id, late.run_id, true), "late external acknowledgment is rejected after clock refresh")
	_check(host.public_snapshot().phase == "route_error", "late external acknowledgment keeps route error")
	_check(host.retry_voice().ok, "external timeout permits explicit retry")
	var retry: Dictionary = commands[-1]
	_check(retry.id > late.id, "external retry issues fresh command identifier")
	host.acknowledge_voice(retry.id, retry.run_id, true)
	_check(host.public_snapshot().phase == "opening", "external retry resumes barrier sequence")
	host.free()

func _test_peer_identity_and_reconnect() -> void:
	var host = Host.new()
	host.start_game(_players(2), {"duration_seconds": 30})
	var snapshot: Dictionary = host.public_snapshot()
	_check(not host.submit_from_peer(999, snapshot.run_id, snapshot.round_index, "defect").ok, "unknown transport peer cannot submit")
	_check(not host.snapshot_for_peer(999).ok, "unknown transport peer cannot request private snapshot")
	host.bind_authenticated_peer(10, "p0")
	host.bind_authenticated_peer(11, "p1")
	_check(host.snapshot_for_peer(10).opponent_id == "p1", "authenticated peer resolves only its own identity")
	_check(host.submit_from_peer(10, snapshot.run_id, snapshot.round_index, "defect").ok, "bound peer may submit")
	_check(host.snapshot_for_peer(10).self_choice == "defect", "bound peer sees its own choice")
	_check(host.snapshot_for_peer(11).self_choice == "", "other bound peer cannot read secret selection")
	host.unbind_peer(11)
	_check(not host.submit_from_peer(11, snapshot.run_id, snapshot.round_index, "cooperate").ok, "unbound peer loses submission authority")
	_check(not host.private_snapshot("p1").connected, "unbind records disconnect without replacing player")
	_check(host.private_snapshot("p1").self_choice == "", "disconnect never preemptively submits choice")
	host.bind_authenticated_peer(12, "p1")
	# Authenticated lobby explicitly restores connectivity when rebinding a returning player.
	host.set_connected("p1", true)
	_check(host.snapshot_for_peer(12).can_submit, "rebound and reconnected participant can still choose before deadline")
	_check(not host.snapshot_for_peer(11).ok, "old peer stays unauthorized after reconnect")
	_check(host.submit_from_peer(12, snapshot.run_id, snapshot.round_index, "cooperate").ok, "new authenticated peer may finish original pairing")
	_check(host.public_snapshot().phase == "finished", "reconnected match completes")
	host.free()

func _test_leaderboard_ties() -> void:
	var context := _begin(4)
	var session = context.session
	for unused in 3:
		var pairs: Array = session.public_snapshot().pairs
		for pair in pairs:
			_submit(session, pair.a)
			_submit(session, pair.b)
		_drain(session, context.commands)
	var final_view: Dictionary = session.public_snapshot()
	for row in final_view.leaderboard:
		_check(row.score == 9 and row.rank == 1, "ties share competition rank")
	var ids: Array = []
	for row in final_view.leaderboard:
		ids.append(row.player_id)
	_check(ids == ["p0", "p1", "p2", "p3"], "tied leaderboard order deterministic by player ID")
	final_view.results[0].score_a = 9000
	final_view.leaderboard[0].score = 9000
	_check(session.public_snapshot().results[0].score_a == 3, "final results detached from authority")
	_check(session.public_snapshot().leaderboard[0].score == 9, "final leaderboard detached from authority")

func _test_mock_command_fencing() -> void:
	var host = Host.new()
	var acknowledgments: Array = []
	host.mock_voice.acknowledged.connect(func(id: int, run_id: int, success: bool, message: String):
		acknowledgments.append({"id": id, "run_id": run_id, "success": success, "message": message})
	)
	host.start_game(_players(2), {})
	var stale_open: Dictionary = host.mock_voice.command_log[1].duplicate(true)
	var snapshot: Dictionary = host.public_snapshot()
	host.submit_choice("p0", snapshot.run_id, snapshot.round_index, "cooperate")
	host.submit_choice("p1", snapshot.run_id, snapshot.round_index, "cooperate")
	_check(host.public_snapshot().phase == "finished" and host.mock_voice.active_pairs.is_empty(), "mock replay regression starts fully closed")
	host.mock_voice.request(stale_open)
	_check(host.mock_voice.active_pairs.is_empty(), "same-run stale open cannot revive a closed route")
	_check(not acknowledgments[-1].success and acknowledgments[-1].message == "stale_voice_command", "same-run stale command is explicitly rejected")
	_check(host.public_snapshot().phase == "finished", "replayed command acknowledgment cannot alter finished authority")
	var last_close: Dictionary = host.mock_voice.command_log[3].duplicate(true)
	host.mock_voice.request(last_close)
	_check(not acknowledgments[-1].success and acknowledgments[-1].message == "stale_voice_command", "duplicate latest command rejected")
	host.start_game(_players(2), {})
	var newer_snapshot: Dictionary = host.public_snapshot()
	var current_routes: Array = host.mock_voice.active_pairs.duplicate(true)
	host.mock_voice.request(stale_open)
	_check(not acknowledgments[-1].success and acknowledgments[-1].message == "stale_voice_run", "prior-run command rejected by backend")
	_check(host.mock_voice.active_pairs == current_routes and host.public_snapshot().run_id == newer_snapshot.run_id, "old-run replay preserves current pair routes and state")
	host.cancel_game()
	host.mock_voice.fail_next = true
	host.start_game(_players(2), {})
	var failed: Dictionary = host.mock_voice.command_log[-1].duplicate(true)
	_check(host.public_snapshot().phase == "route_error", "injected mock failure surfaces on host")
	host.mock_voice.request(failed)
	_check(not acknowledgments[-1].success and acknowledgments[-1].message == "stale_voice_command", "failed command also fences duplicate replay")
	_check(host.public_snapshot().phase == "route_error", "replayed failed command cannot silently clear error")
	_check(host.retry_voice().ok, "mock failure can explicitly retry")
	_check(host.public_snapshot().phase == "playing", "fresh-ID retry succeeds and opens requested round")
	var retry_close: Dictionary = host.mock_voice.command_log[-2]
	_check(retry_close.action == failed.action and retry_close.id > failed.id, "mock retry preserves action with newer sequence")
	host.free()
