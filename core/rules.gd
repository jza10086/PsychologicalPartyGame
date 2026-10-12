extends RefCounted
## Pure rules. No clocks, players' secrets, transport, or voice dependency.

const DEFAULT_CONFIG := {
	"duration_seconds": 30.0, "reveal_mode": "game_end",
	"reward": 3, "temptation": 5, "punishment": 1, "sucker": 0
}

static func normalized_config(config: Dictionary) -> Dictionary:
	var result := DEFAULT_CONFIG.duplicate(true)
	result.merge(config, true)
	return result

static func validate_config(config: Dictionary) -> String:
	var c := normalized_config(config)
	for key in ["duration_seconds", "reward", "temptation", "punishment", "sucker"]:
		if not (c[key] is int or c[key] is float) or not is_finite(float(c[key])):
			return "invalid_number:%s" % key
	if c.duration_seconds <= 0.0 or c.duration_seconds > 3600.0:
		return "duration_out_of_range"
	if c.reveal_mode not in ["game_end", "pair_complete"]:
		return "invalid_reveal_mode"
	if not (c.temptation > c.reward and c.reward > c.punishment and c.punishment > c.sucker):
		return "require_temptation_gt_reward_gt_punishment_gt_sucker"
	return ""

static func schedule(player_ids: Array) -> Array:
	var ring := player_ids.duplicate()
	if ring.size() % 2 == 1:
		ring.append("")
	var rounds: Array = []
	for r in range(ring.size() - 1):
		var pairs: Array = []
		var bye := ""
		for i in range(ring.size() / 2):
			var a: String = ring[i]
			var b: String = ring[ring.size() - 1 - i]
			if a == "" or b == "":
				bye = b if a == "" else a
			else:
				pairs.append({"id": "r%d_p%d" % [r, i], "a": a, "b": b})
		rounds.append({"pairs": pairs, "bye": bye})
		var last = ring.pop_back()
		ring.insert(1, last)
	return rounds

static func payoff(a: String, b: String, config: Dictionary) -> Array:
	var c := normalized_config(config)
	if a == "cooperate" and b == "cooperate":
		return [c.reward, c.reward]
	if a == "defect" and b == "defect":
		return [c.punishment, c.punishment]
	return [c.temptation, c.sucker] if a == "defect" else [c.sucker, c.temptation]
