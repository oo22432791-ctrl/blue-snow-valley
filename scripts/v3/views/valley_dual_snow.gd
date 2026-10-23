extends "res://scripts/world/environment_surface.gd"
## 两个视图各自精细雪面窗口；雪深、真实碰撞和脚印历史仍共享。

var secondary_player: CharacterBody3D
var second_enabled: bool = false
var second_bounds: Vector4
var _second_center := Vector2i(2147483647,2147483647)
var _second_tiles: Array[MeshInstance3D] = []


## 复用原共享网格和材质，额外九个显示实例只进入P2相机层。
func _ready() -> void:
	# 1. 源地形和碰撞不复制，原九块只进入P1层。
	super._ready()
	for tile: MeshInstance3D in _tiles:
		tile.layers = 2
		var copy := tile.duplicate() as MeshInstance3D
		copy.name = "P2" + String(tile.name)
		copy.layers = 4
		copy.visible = false
		add_child(copy)
		_second_tiles.append(copy)
	for material: ShaderMaterial in [far_material, fine_material]:
		material.set_shader_parameter("dual_view_detail", true)


## 两处窗口分别跨块更新，关闭右视图时不额外绘制其网格。
func _process(delta: float) -> void:
	# 1. 原实现负责P1，新增显示只跟随固定P2实体。
	super._process(delta)
	_update_second_window()


## 分屏与观察入口共用该开关，不修改任何雪深或历史数据。
func set_second_view(enabled: bool) -> void:
	# 1. 缓存关注点随显示需求变化，不因为隐藏视图清空CPU脚印。
	second_enabled = enabled
	for tile: MeshInstance3D in _second_tiles:
		tile.visible = enabled
	_update_second_window()


## 两个局部窗口的并集供唯一脚印页表选择驻留块。
func get_detail_windows() -> Array[Vector4]:
	# 1. 未绑定角色时仍保持正常单人入口。
	var result: Array[Vector4] = [detail_bounds]
	if second_enabled and is_instance_valid(secondary_player):
		result.append(second_bounds)
	return result


## P2近脚环境支撑沿用原射线与干燥铺装规则。
func _support_actors() -> Array[CharacterBody3D]:
	# 1. 待命和返程也使用同一物理角色，避免脚踩岩石时陷入地面。
	var result: Array[CharacterBody3D] = [player]
	if is_instance_valid(secondary_player):
		result.append(secondary_player)
	return result


## 更新P2九块世界坐标及真实地形包围盒，不跟随P1位置。
func _update_second_window() -> void:
	# 1. 只有跨16米块才搬动显示实例。
	if not second_enabled or not is_instance_valid(secondary_player):
		return
	var at := secondary_player.global_position
	var center := Vector2i(floori(at.x / TILE_SIZE), floori(at.z / TILE_SIZE))
	if center == _second_center:
		return
	_second_center = center
	var start := Vector2(center - Vector2i.ONE) * TILE_SIZE
	second_bounds = Vector4(start.x, start.y, start.x + 48, start.y + 48)
	for z in range(3):
		for x in range(3):
			var tile: MeshInstance3D = _second_tiles[z * 3 + x]
			tile.position = Vector3(start.x + x * TILE_SIZE + 8, 0, start.y + z * TILE_SIZE + 8)
			var minimum := INF
			var maximum := -INF
			for iz in range(9):
				for ix in range(9):
					var height: float = terrain.get_ground_height(Vector2(start.x + x * TILE_SIZE + ix * 2, start.y + z * TILE_SIZE + iz * 2))
					minimum = minf(minimum, height)
					maximum = maxf(maximum, height)
			tile.custom_aabb = AABB(Vector3(-8, minimum - .1, -8), Vector3(16, maximum - minimum + .6, 16))
	for material: ShaderMaterial in [far_material, fine_material]:
		material.set_shader_parameter("detail_bounds_p2", second_bounds)
