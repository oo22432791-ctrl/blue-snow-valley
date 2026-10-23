extends "res://scripts/player/player.gd"
## 小样角色复用原角色碰撞、移动和蒙皮；没有库存或存档服务。
var player: CharacterBody3D
var aim_hit: Dictionary = {}
var weapon: Node3D

## 保留现有模型和枪械握持层，只替换独立控制来源。
func _ready() -> void:
	player = self
	external_control = true
	collision_layer = 2
	collision_mask = 1|2|4|8
	floor_snap_length = .4
	super._ready()
	weapon = load("res://scripts/v3/boss/valley_arena_rifle.gd").new()
	weapon.actor = self
	add_child(weapon)
