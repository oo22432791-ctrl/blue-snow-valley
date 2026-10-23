extends "res://scripts/ai/snow_companion.gd"
## V2电脑保留原散步节奏；目标使用山谷坐标、地形高度和离线导航。

const CLEARING := preload("res://scripts/world/valley_layout.gd").SNOWBALL_CLEARING
var activity: Node3D


## 对话期间站定，其他时候按原共享角色物理与深雪阻力散步。
func _physics_process(delta: float) -> void:
	# 1. 菜单不暂停世界，电脑停止意图以便近处玩家明确开局。
	if activity.world.survival._session_id == activity.TARGET_ID:
		_stop_motion()
		return
	# 2. 窗口焦点、停留、阻挡重选及避让继续交给原控制器。
	super._physics_process(delta)


## 在活动空地内选可达点，不把世界Y误认成原场景零高度。
func _choose_destination(map: RID) -> void:
	# 1. 有限采样，候选必须离边界至少1米，避免身体反复越界。
	var area := CLEARING.grow(-1.0)
	for attempt in range(16):
		var angle := _random.randf_range(-PI, PI)
		var radius := _random.randf_range(2.0, 5.0)
		var candidate := _actor.global_position + Vector3(cos(angle), 0, sin(angle)) * radius
		if not area.has_point(Vector2(candidate.x, candidate.z)): continue
		candidate.y = activity.world.terrain.get_ground_height(Vector2(candidate.x, candidate.z))
		var ground := NavigationServer3D.map_get_closest_point(map, candidate)
		if ground.distance_to(candidate) > 0.7 or ground.distance_to(_actor.global_position) < 1.25: continue
		if not area.has_point(Vector2(ground.x, ground.z)) or ground.distance_to(player.global_position) < 1.0: continue
		# 2. 确认整段导航不离开空地，不能借绕远路径穿过安全屋。
		var path := NavigationServer3D.map_get_path(map, _actor.global_position, ground, true)
		if path.size() < 2 or path[-1].distance_to(ground) > 0.3: continue
		var inside := true
		for point: Vector3 in path:
			if not CLEARING.has_point(Vector2(point.x, point.z)): inside = false; break
		if not inside: continue
		target = ground; _agent.target_position = ground; state = &"walking"
		trips_started += 1; _stalled_seconds = 0; _trip_seconds = 0
		return
	# 3. 没有可达点时稍后再试，禁止瞬移或直接穿过障碍。
	_wait_remaining = 0.8
