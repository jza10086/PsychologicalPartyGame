## Business-owned setting defaults, constraints and UI hierarchy. No runtime side effects.
extends RefCounted

static func schema() -> Dictionary:
	return {
		"schema_format": 3,
		"settings_version": 1,
		"fields": {
			"duration": {
				"type": "int",
				"default": 30,
				"title": "每轮沟通与选择秒数",
				"audience": "room",
				"apply": "next_round",
				"min": 5,
				"max": 120,
				"control": "number"
			}
		},
		"layout": [
			{
				"id": "room",
				"title": "游戏规则",
				"expanded": true,
				"children": [
					{
						"field": "duration"
					}
				]
			}
		]
	}
