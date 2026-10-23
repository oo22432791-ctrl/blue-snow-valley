extends Node3D
## 小样只读取原地形格；支撑来自同源原生场地网格，不启动探索世界。
var query: Node3D
var origin := Vector3(112, 11.769204, -166)

## 原三角格查询不创建旧场景、存档、天气或全谷导航。
func _ready() -> void:
	var record: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v3/boss/ice_courtyard_manifest.json"))
	origin = Vector3(record.world_origin[0],record.world_origin[1],record.world_origin[2])
	query = load("res://scripts/world/valley_terrain.gd").new()
	query.manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/terrain/v2/manifest.json"))
	var file := FileAccess.open("res://assets/terrain/v2/height_grid.bin",FileAccess.READ)
	query.heights = file.get_buffer(file.get_length()).to_float32_array()

## 地形高度使用山门局部坐标，与雪院原生源保持一致。
func ground(at: Vector3) -> float:
	return query.get_ground_height(Vector2(at.x+origin.x,at.z+origin.z))-origin.y

## 原角色的视觉偏移是积雪相对厚度，不能把世界高度重复加一次。
func get_height_at(_at: Vector3) -> float:
	return 0.0

## 靴底仍按实际三角支撑落地。
func get_support_height_at(at: Vector3) -> float:
	return ground(at)

## 小样不改变个人移动能力或虚构深雪减速。
func get_speed_scale_at(_at: Vector3) -> float:
	return 1.0

## 薄雪只影响角色已有抬脚适配，不是新增生存规则。
func get_fresh_depth_at(_at: Vector3) -> float:
	return .06

## 未入树的地形查询随独立小样释放。
func _exit_tree() -> void:
	if is_instance_valid(query):
		query.free()
