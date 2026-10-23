extends Node3D
## 同源雪院、M11山门与可碎冰壁：物理状态和可见状态在同一延迟提交中改变。
signal walls_changed(mask: int)
const DIRECTORY := "res://assets/models/v3/boss/"
var model: Node3D
var gate: Node3D
var floor_mesh: MeshInstance3D
var walls: Array[Dictionary] = []
var broken_mask := 0

## 模型只装配一次，真实凸碰撞读取原生源导出的顶点。
func _ready() -> void:
	model = load(DIRECTORY+"ice_courtyard.glb").instantiate()
	add_child(model)
	floor_mesh = model.find_child("CourtyardSnow",true,false)
	var floor_body := StaticBody3D.new()
	floor_body.name = "ArenaGround"
	floor_body.collision_layer = 1
	add_child(floor_body)
	var support := CollisionShape3D.new()
	support.shape = floor_mesh.mesh.create_trimesh_shape()
	support.transform = floor_mesh.transform
	floor_body.add_child(support)
	var record: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY+"ice_courtyard_manifest.json"))
	var boundary := StaticBody3D.new()
	boundary.name = "VisibleSnowBanks"
	boundary.collision_layer = 4
	add_child(boundary)
	for obstacle: Dictionary in record.obstacles:
		var convex := ConvexPolygonShape3D.new()
		var points := PackedVector3Array()
		for value: Array in obstacle.points:
			points.append(point(value))
		convex.points = points
		var shape := CollisionShape3D.new()
		shape.shape = convex
		boundary.add_child(shape)
	for item: Dictionary in record.walls:
		var body := StaticBody3D.new()
		body.name = item.name
		body.collision_layer = 4
		body.collision_mask = 2|8
		body.position = point(item.at)
		body.set_meta("ice_wall",walls.size())
		add_child(body)
		var visual: Node3D = model.find_child(item.name,true,false)
		visual.reparent(body,true)
		var shapes: Array[CollisionShape3D] = []
		var pivots: Array[Node3D] = []
		for part: Dictionary in item.parts:
			var shape := CollisionShape3D.new()
			var convex := ConvexPolygonShape3D.new()
			var points := PackedVector3Array()
			for value: Array in part.points:
				points.append(point(value))
			convex.points = points
			shape.shape = convex
			body.add_child(shape)
			shapes.append(shape)
			var mesh: MeshInstance3D = visual.find_child(part.name,true,false)
			var pivot := Node3D.new()
			pivot.position = mesh.get_aabb().get_center()
			visual.add_child(pivot)
			mesh.reparent(pivot,true)
			pivot.set_meta("rest",pivot.transform)
			pivots.append(pivot)
		walls.append({"body":body,"shapes":shapes,"pivots":pivots,"broken":false,"pending":false,"tween":null})
	# 1. 保留现有围院和山门，门板实际升起，不移除门的碰撞。
	gate = load("res://assets/models/v3/events/mountain_gate.glb").instantiate()
	add_child(gate)
	var gate_record: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v3/events/mountain_gate_manifest.json"))
	var helper: Node3D = load("res://scripts/v3/world/valley_event_geometry.gd").new()
	var fixed := StaticBody3D.new()
	fixed.collision_layer = 4
	gate.add_child(fixed)
	var panel := StaticBody3D.new()
	panel.collision_layer = 4
	gate.add_child(panel)
	gate.find_child("GatePanel",true,false).reparent(panel,true)
	for collision: Dictionary in gate_record.collisions:
		helper.add_collision(panel if collision.has("dynamic") else fixed,collision)
	panel.position.y = 3.4
	helper.free()

## 冲撞只请求一次，在安全物理提交点同步碎裂画面与碰撞移除。
func break_wall(index: int) -> void:
	if index < 0 or index >= walls.size() or walls[index].broken or walls[index].pending:
		return
	walls[index].pending = true
	_commit_break.call_deferred(index)

## 冰块保留原生几何并飞散，碎片不再承担完整墙体的阻挡。
func _commit_break(index: int) -> void:
	var wall: Dictionary = walls[index]
	wall.pending = false
	wall.broken = true
	for shape: CollisionShape3D in wall.shapes:
		shape.disabled = true
	var tween := create_tween().set_parallel(true)
	wall.tween = tween
	for i in range(wall.pivots.size()):
		var pivot: Node3D = wall.pivots[i]
		var rest: Transform3D = pivot.get_meta("rest")
		tween.tween_property(pivot,"position",rest.origin+Vector3((i-3)*.38,.45,1.4 if i%2==0 else -1.4),1.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(pivot,"rotation",Vector3(.5+i*.12,.25,-.4+i*.11),1.0)
	tween.chain().tween_callback(func() -> void:
		for pivot: Node3D in wall.pivots:
			pivot.hide())
	broken_mask |= 1 << index
	walls_changed.emit(broken_mask)

## 有人或雪熊占着冰壁原体积时拒绝复原，不能把角色瞬移出去。
func can_reset(index: int) -> bool:
	var wall: Dictionary = walls[index]
	for shape: CollisionShape3D in wall.shapes:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = shape.global_transform
		query.collision_mask = 2|8
		if not get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():
			return false
	return not wall.pending

## 重置只改变可复原的冰壁，不重置角色、雪熊位置或相机。
func reset_walls() -> bool:
	for i in range(walls.size()):
		if walls[i].broken and not can_reset(i):
			return false
	_commit_reset.call_deferred()
	return true

## 延迟提交前再次检查占位，碎片动画与显示姿态一并复原。
func _commit_reset() -> void:
	for i in range(walls.size()):
		if walls[i].broken and not can_reset(i):
			return
	for wall: Dictionary in walls:
		if wall.tween != null and wall.tween.is_valid():
			wall.tween.kill()
		for pivot: Node3D in wall.pivots:
			pivot.transform = pivot.get_meta("rest")
			pivot.show()
		for shape: CollisionShape3D in wall.shapes:
			shape.disabled = false
		wall.broken = false
	broken_mask = 0
	walls_changed.emit(0)

## 源清单三元组统一转为局部米制坐标。
static func point(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])
