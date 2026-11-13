## Lightweight catalog data. Do not load gameplay scenes or scripts here.
extends RefCounted

static func party_definition() -> Dictionary:
	return {"player_counts": [2, 3, 4, 5, 6, 7, 8], "tags": ["original"]}
