extends Node3D
## 熊的角色视角只替换玩家与生存引用，其余仍指向唯一山谷。

var shared_world: Node3D
var target_actor_id: String = "p1"
var player: CharacterBody3D:
	get:
		return shared_world.player if target_actor_id == "p1" else shared_world.snowball_game.companion
var survival: Node:
	get:
		return shared_world.survival if target_actor_id == "p1" else shared_world.secondary_context.survival
var interior: Node
var world_clock: Node
var snow_surface: Node3D
var terrain: Node3D


## 世界能力均使用同一实例，不创建独立时钟或物理世界。
func _ready() -> void:
	# 1. 原熊行为可继续通过world读取既有接口。
	interior = shared_world.interior
	world_clock = shared_world.world_clock
	snow_surface = shared_world.snow_surface
	terrain = shared_world.terrain
