extends "res://scripts/world/valley_regions.gd"
## 两角色驻留并集，恢复预检也能加载两个保存位置附近的真实环境碰撞。

var additional_actors: Array[CharacterBody3D] = []
var preview_positions: Array[Vector3] = []
var _signature: String = ""


## 所有持久角色附近共同驻留，不以主玩家远离为理由删除P2脚下道具。
func update_regions() -> void:
	# 1. 预检坐标只影响加载边界，不移动人物或改写库存。
	var positions: Array[Vector3] = [player.position]
	for actor: CharacterBody3D in additional_actors:
		if is_instance_valid(actor):
			positions.append(actor.position)
	positions.append_array(preview_positions)
	var keys: Array[Vector2i] = []
	for at: Vector3 in positions:
		var key := Vector2i(floori((at.x - LAYOUT.ORIGIN.x) / 32.0), floori((at.z - LAYOUT.ORIGIN.y) / 32.0))
		if key not in keys:
			keys.append(key)
	var signature := str(keys)
	if signature == _signature:
		return
	_signature = signature
	current_region = keys[0]
	# 2. 复用真实模型、碰撞与稳定ID装配，不只加载空标记。
	for key: Vector2i in keys:
		for z in range(key.y - ACTIVE_RADIUS, key.y + ACTIVE_RADIUS + 1):
			for x in range(key.x - ACTIVE_RADIUS, key.x + ACTIVE_RADIUS + 1):
				var candidate := Vector2i(x, z)
				if x >= 0 and x < 14 and z >= 0 and z < 16 and not _resident.has(candidate):
					_load_region(candidate)
	# 3. 超出全部角色保留圈才卸载，同一对象不因两个关注点重复生成。
	for old: Vector2i in _resident.keys():
		var retained := false
		for key: Vector2i in keys:
			if maxi(absi(old.x - key.x), absi(old.y - key.y)) <= RETAIN_RADIUS:
				retained = true
		if not retained:
			_resident[old].queue_free()
			_resident.erase(old)
			unload_count += 1
			region_unloaded.emit(old)


## 两边道具都按最近角色选择已有LOD，不记录性能指标。
func _process(delta: float) -> void:
	# 1. 驻留在区域变化时更新，细节选择仍为低频有限循环。
	update_regions()
	_detail_timer -= delta
	if _detail_timer > 0.0:
		return
	_detail_timer = 0.25
	for root: Node3D in _resident.values():
		for asset: Node3D in root.get_children():
			var distance := Vector2(asset.position.x - player.position.x, asset.position.z - player.position.z).length()
			for actor: CharacterBody3D in additional_actors:
				if is_instance_valid(actor):
					distance = minf(distance, Vector2(asset.position.x - actor.position.x, asset.position.z - actor.position.z).length())
			asset.update_detail(distance)
