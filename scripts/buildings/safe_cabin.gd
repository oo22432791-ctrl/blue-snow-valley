extends Node3D
## M5三屋共用装配：独立外壳／家具、源清单碰撞与E控制的实体铰链门。

@export var model_scene: PackedScene = preload("res://assets/models/v2/safe_cabin.glb")
@export_file("*.json") var manifest_path: String = "res://assets/models/v2/safe_cabin_manifest.json"
var manifest: Dictionary
var model: Node3D
var structure: StaticBody3D
var door: AnimatableBody3D
var door_shape: BoxShape3D
var door_shape_at := Vector3.ZERO
var door_angle: float = 0.0
var target_open: bool = false
var door_blocked: bool = false
var inspection_cutaway: bool = false
var _materials: Dictionary[StringName, StandardMaterial3D] = {}
var _door_query_shape: BoxShape3D
var _dry_bounds := Rect2()
var _palette_bound: bool=false


## 按GLB与同源清单装配模型和碰撞，保留门的真实铰链原点。
func _ready() -> void:
	# 1. 可编辑Blender源是模型和碰撞清单的共同来源，不用整屋包络封住门口。
	manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	model = model_scene.instantiate()
	add_child(model)
	for record: Dictionary in manifest.dry_surfaces:
		var values: Array = record.rect
		_dry_bounds = _dry_bounds.merge(Rect2(float(values[0]), float(values[1]), float(values[2]), float(values[3])))
	structure = StaticBody3D.new()
	structure.name = "CabinStructure"
	add_child(structure)
	for record: Dictionary in manifest.collisions:
		_add_collision(record)
	# 2. 移动门扇和碰撞共享同一个AnimatableBody，不能只旋转画面。
	var pivot: Node3D = model.find_child("DoorPivot", true, false)
	assert(pivot != null, "Cabin door pivot missing")
	var hinge_transform := pivot.global_transform
	door = AnimatableBody3D.new()
	door.name = "SolidHingedDoor"
	door.sync_to_physics = false
	add_child(door)
	door.global_transform = hinge_transform
	pivot.reparent(door, true)
	door_shape = BoxShape3D.new()
	door_shape.size = _vector(manifest.door.size)
	door_shape_at = _vector(manifest.door.at)
	var collision := CollisionShape3D.new()
	collision.shape = door_shape
	collision.position = door_shape_at
	door.add_child(collision)
	# 3. 小幅收缩的查询体仅容忍接触边界，防止关门穿过人物或把人物夹进墙中。
	_door_query_shape = BoxShape3D.new()
	_door_query_shape.size = door_shape.size - Vector3(0.025, 0.025, 0.025)


## 以有限角速度转动实体门；扫到人物时停住，暂停由场景树统一冻结。
func _physics_process(delta: float) -> void:
	# 1. 分成不超过2度的小步检查门扇扫掠，不能在低帧率时直接跳到终点。
	var target := deg_to_rad(float(manifest.door.open_degrees)) if target_open else 0.0
	var desired := move_toward(door_angle, target, deg_to_rad(85.0) * minf(delta, 0.1))
	door_blocked = false
	while absf(desired-door_angle)>0.00001:
		var candidate := move_toward(door_angle, desired, deg_to_rad(2.0))
		var pose := global_transform * Transform3D(Basis(Vector3.UP, candidate), _vector(manifest.door.pivot))
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = _door_query_shape
		query.transform = pose * Transform3D(Basis.IDENTITY, door_shape_at)
		query.collision_mask = 1
		query.exclude = [door.get_rid(), structure.get_rid()]
		query.margin = 0.001
		var hits := get_world_3d().direct_space_state.intersect_shape(query, 16)
		for hit: Dictionary in hits:
			if hit.collider is CharacterBody3D:
				door_blocked = true
				break
		if door_blocked:
			break
		# 2. 接受后才同时移动可见门与物理门；保持铰链不漂移。
		door_angle = candidate
		door.transform = Transform3D(Basis(Vector3.UP, door_angle), _vector(manifest.door.pivot))


## 只接受门口两侧近距离E请求，远处不能开门。
func request_interact(actor: Node3D) -> bool:
	# 1. 世界输入路由负责暂停与GUI，本模块仍验证实际距离。
	if not can_interact(actor.global_position):
		return false
	# 2. 再按E可反转目标；受阻时也能主动重新打开。
	target_open = not target_open
	return true


## 返回门前后可触及范围，不根据镜头画面距离判断。
func can_interact(at: Vector3) -> bool:
	# 1. 矩形范围覆盖门内与门廊，排除后墙及侧墙另一端。
	var local := to_local(at)
	var hinge := _vector(manifest.door.pivot)
	var center_x := hinge.x + float(manifest.door.at[0])
	return absf(local.x-center_x)<float(manifest.door.opening_width)*0.5+0.9 and absf(local.z-hinge.z)<2.0 and absf(local.y-float(manifest.floor_y))<1.6


## 从同源清单查询地板、门廊与可见斜坡的世界支撑高度。
func dry_height_at(at: Vector3) -> float:
	# 1. 只覆盖真实铺装范围，屋旁雪地继续使用原雪深与脚印。
	var local := to_local(at)
	# 三屋的雪场查询频繁，先用缓存包络排除远处点，再读取铺装分段。
	if not _dry_bounds.has_point(Vector2(local.x, local.z)):
		return INF
	for record: Dictionary in manifest.dry_surfaces:
		var values: Array = record.rect
		var rect := Rect2(float(values[0]), float(values[1]), float(values[2]), float(values[3]))
		if rect.has_point(Vector2(local.x, local.z)):
			var height := float(record.y)
			if record.has("end_y"):
				height = lerpf(height, float(record.end_y), (local.z-rect.position.y)/rect.size.y)
			return to_global(Vector3(local.x, height, local.z)).y
	return INF


## 用有迟滞的实体内框判断进入／离开；门廊的干燥支撑不等同室内。
func contains_interior(at: Vector3, already_inside: bool = false) -> bool:
	# 1. 门口内退18厘米才进入，出门越过外框10厘米才离开，抑制门槛抖动。
	var local := to_local(at)
	var margin := -0.10 if already_inside else 0.18
	var half_width := float(manifest.footprint[0])*0.5-margin
	var half_depth := float(manifest.footprint[1])*0.5-margin
	# 2. 高度也有限制，屋顶上方或地板下方不被当作房内角色。
	return absf(local.x)<half_width and absf(local.z)<half_depth and local.y>float(manifest.floor_y)-0.25 and local.y<float(manifest.floor_y)+2.5


## 返回真实封闭房间的遮蔽范围，不读取淡出或门扇的可见性。
func shelters_point(at: Vector3) -> bool:
	# 1. 遮蔽使用物理房间边界，不把门口迟滞带或露天铺装算作完整遮蔽。
	var local := to_local(at)
	return absf(local.x)<float(manifest.footprint[0])*0.5-0.1 and absf(local.z)<float(manifest.footprint[1])*0.5-0.1 and local.y>=float(manifest.floor_y)-0.1 and local.y<float(manifest.floor_y)+2.5


## 室内选择射线从房内可见体积起算，物理墙／屋顶继续阻挡真实枪口射线。
func clip_interior_view_ray(origin: Vector3, direction: Vector3) -> Vector3:
	# 1. 仅在鼠标投影的地板点属于本屋时裁剪；屋外瞄准仍查询完整碰撞。
	var local_origin := to_local(origin)
	var local_direction := global_basis.inverse()*direction
	if local_direction.y>=-0.0001:
		return origin
	var floor_y := float(manifest.floor_y)+0.03
	var floor_at := local_origin+local_direction*((floor_y-local_origin.y)/local_direction.y)
	var half_width := float(manifest.footprint[0])*0.5-0.22
	var half_depth := float(manifest.footprint[1])*0.5-0.22
	if absf(floor_at.x)>half_width or absf(floor_at.z)>half_depth:
		return origin
	# 2. 用轴向区间裁剪到房间内部，避免相机先击中已淡出的近墙或屋顶。
	var minimum := Vector3(-half_width,floor_y,-half_depth)
	var maximum := Vector3(half_width,float(manifest.floor_y)+2.45,half_depth)
	var entry := 0.0
	var exit := 200.0
	for axis in range(3):
		if absf(local_direction[axis])<0.00001:
			if local_origin[axis]<minimum[axis] or local_origin[axis]>maximum[axis]:
				return origin
			continue
		var a: float = (minimum[axis]-local_origin[axis])/local_direction[axis]
		var b: float = (maximum[axis]-local_origin[axis])/local_direction[axis]
		entry=maxf(entry,minf(a,b))
		exit=minf(exit,maxf(a,b))
	if entry>=exit:
		return origin
	return origin+direction*(entry+0.025)


## 外观检视可独立隐藏外壳，碰撞保持；仅由验收场景调用，不是M6自动淡出。
func set_inspection_cutaway(enabled: bool) -> void:
	# 1. 固定相机位于东南侧，检视时仅隐藏这两面墙和上盖。
	inspection_cutaway = enabled
	for part in ["Roof", "Wall_Front", "Wall_East", "DoorFrame", "Chimney"]:
		var node := model.find_child(part, true, false) as Node3D
		if node != null:
			node.visible = not enabled
	# 2. 实体门仍能测试碰撞，开门状态与任何材质不会因检视而重置。


## 使用独立材质语义映射蓝色配色，原GLB和第一版材质均不改写。
func apply_cabin_palette(palette: Resource) -> void:
	# 1. 冷色木板和石基有轻微层次；玻璃保持双面不透明，不能透视家具。
	var colors: Dictionary = {
		"timber": palette.wood.lightened(0.08), "boards": palette.wall,
		"boards_light": palette.wall.lightened(0.08), "floor": palette.wood.lightened(0.22),
		"stone": palette.shadow.darkened(0.15), "stone_light": palette.shadow.lightened(0.08),
		"roof": palette.roof, "snow": palette.snow, "iron": palette.roof.darkened(0.12),
		"glass": palette.warm, "linen": palette.snow.lightened(0.25),
		"blanket": palette.coat.lightened(0.10), "rug": palette.scarf.lerp(palette.wall, 0.3),
		"fire": palette.warm,
	}
	# 2. M8连续调色只更新共享角色材质，避免20Hz遍历网格或重新绑定正在淡出的表面。
	for role: StringName in colors:
		if not _materials.has(role):
			var created:=StandardMaterial3D.new()
			created.resource_name="cabin_"+String(role);created.roughness=.88
			created.cull_mode=BaseMaterial3D.CULL_DISABLED;_materials[role]=created
		var material: StandardMaterial3D=_materials[role]
		material.albedo_color=colors[role];material.emission_enabled=role in [&"glass",&"fire"]
		if material.emission_enabled:
			material.emission=colors[role]
			material.emission_energy_multiplier=float(palette.get_meta("window_glow",.35)) if role==&"glass" else .35
	# 3. 源表面只在首次装配时按语义绑定，后续外壳／家具保留原材质身份和碰撞。
	if not _palette_bound:
		for mesh_node: MeshInstance3D in find_children("*","MeshInstance3D",true,false):
			for index in range(mesh_node.mesh.get_surface_count()):
				var source: Material=mesh_node.mesh.surface_get_material(index)
				var role:=StringName(String(source.resource_name).trim_prefix("cabin_"))
				assert(colors.has(role),"Unknown cabin palette role: "+String(role))
				mesh_node.set_surface_override_material(index,_materials[role])
		_palette_bound=true


## 将同源碰撞记录转为Godot物理形状，斜坡保留实际顶面而非盒形挡板。
func _add_collision(record: Dictionary) -> void:
	# 1. 简单墙和家具使用盒体，屋顶与斜坡使用作者给定的凸体。
	var collision := CollisionShape3D.new()
	collision.name = String(record.name)+"_%d" % structure.get_child_count()
	if record.kind == "box":
		var shape := BoxShape3D.new()
		shape.size = _vector(record.size)
		collision.shape = shape
		collision.position = _vector(record.at)
	else:
		var shape := ConvexPolygonShape3D.new()
		var points := PackedVector3Array()
		for value: Array in record.points:
			points.append(_vector(value))
		shape.points = points
		collision.shape = shape
	# 2. 碰撞节点独立于外壳显示，检视隐藏不会打开墙或移走家具。
	structure.add_child(collision)


## 从米制JSON数组构建向量，不使用导入节点顺序推断坐标。
func _vector(values: Array) -> Vector3:
	# 1. 清单坐标始终是Godot XYZ，转换只发生在Blender作者工具中。
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
