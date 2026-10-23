extends RefCounted
## 场内角色绕过移动巨熊的临时路线；静态路径仍来自当前冰壁状态的导航。
var encounter: Node3D
var actor: CharacterBody3D
var _target := Vector3.INF
var _points: Array[Vector3] = []
var _refresh := 0.0

func direction(target: Vector3, delta: float) -> Vector3:
	_refresh -= delta
	if _refresh<=0 or _target==Vector3.INF or _target.distance_to(target)>1:
		_target = target
		_refresh = .5
		_build(target)
	while not _points.is_empty() and horizontal(actor.global_position,_points[0])<.3:
		_points.pop_front()
	if _points.is_empty(): return Vector3.ZERO
	var desired := (_points[0]-actor.global_position)*Vector3(1,0,1)
	# 路线生成之后巨熊仍可移动；下一轮重算前也不能穿入它的实体。
	if not clear(actor.global_position,actor.global_position+desired.normalized()*.4):
		_refresh = 0
		return Vector3.ZERO
	return desired.normalized()

func _build(target: Vector3) -> void:
	_points.clear()
	var start := actor.global_position
	var path := NavigationServer3D.map_get_path(encounter.player_map,start,target,true)
	if path.size()<2: return
	var nodes: Array[Vector3] = [start]
	for point: Vector3 in path:
		if horizontal(nodes[-1],point)>.3: nodes.append(point)
	if nodes.size()<2: return
	var finish := nodes.size()-1
	# 八个候选点包围当前朝向的身体；逐条胶囊扫掠检查真实墙、冰与角色。
	for offset: Vector3 in [Vector3(-3.3,0,-6.2),Vector3(0,0,-6.2),Vector3(3.3,0,-6.2),Vector3(3.3,0,0),Vector3(3.3,0,6.2),Vector3(0,0,6.2),Vector3(-3.3,0,6.2),Vector3(-3.3,0,0)]:
		var proposed: Vector3 = encounter.boss.global_position+encounter.boss.global_basis*offset
		var point := NavigationServer3D.map_get_closest_point(encounter.player_map,proposed)
		if horizontal(point,proposed)<.7 and encounter.local(point).z < -1:
			nodes.append(encounter.grounded(point))
	var costs: Array[float] = []
	var parents: Array[int] = []
	var visited: Array[int] = []
	for point in nodes:
		costs.append(INF)
		parents.append(-1)
	costs[0] = 0
	for iteration in range(nodes.size()):
		var nearest := -1
		for index in range(nodes.size()):
			if index not in visited and (nearest<0 or costs[index]<costs[nearest]): nearest = index
		if nearest<0 or costs[nearest]==INF: break
		if nearest==finish: break
		visited.append(nearest)
		for index in range(nodes.size()):
			if index in visited or index==nearest: continue
			var cost := costs[nearest]+horizontal(nodes[nearest],nodes[index])
			if cost<costs[index] and clear(nodes[nearest],nodes[index]):
				costs[index] = cost
				parents[index] = nearest
	if parents[finish]<0: return
	var index := finish
	while index>0:
		_points.push_front(nodes[index])
		index = parents[index]

func clear(from: Vector3, to: Vector3) -> bool:
	var shape: CollisionShape3D = actor.get_node("BodyCollision")
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape.shape
	query.transform = Transform3D(Basis.IDENTITY,encounter.grounded(from)+Vector3.UP*.75)
	query.motion = encounter.grounded(to)-encounter.grounded(from)
	query.collision_mask = 2|4|8
	query.exclude = [actor.get_rid()]
	var space := actor.get_world_3d().direct_space_state
	if not space.intersect_shape(query,1).is_empty(): return false
	return space.cast_motion(query)[0]>.99

static func horizontal(a: Vector3,b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()
