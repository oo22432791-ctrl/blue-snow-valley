extends Node
## 场内散步与短暂停留；导航只给移动意图，落脚和厚雪仍由共享角色处理。

const WANDER_RECT := Rect2(-7.5, -7.3, 15.0, 14.1)
var enabled: bool = true
var state: StringName = &"idle"
var destinations_reached: int = 0
var blocked_repaths: int = 0
var trips_started: int = 0
var target: Vector3 = Vector3.ZERO
var player: CharacterBody3D
var _actor: CharacterBody3D
var _agent: NavigationAgent3D
var _random := RandomNumberGenerator.new()
var _wait_remaining: float = 1.5
var _stalled_seconds: float = 0.0
var _trip_seconds: float = 0.0


## 连接避让结果，每个角色实例持有自己的状态与动画。
func _ready() -> void:
	# 1. 继承角色场景只复用结构，不共享控制器状态。
	_actor = get_parent()
	_agent = $"../NavigationAgent3D"
	_random.randomize()
	# 2. 安全速度随后交回角色，禁止导航直接改角色位置。
	_agent.velocity_computed.connect(_apply_safe_velocity)


## 在已同步的导航地图中散步；停留期间不推进脚步。
func _physics_process(delta: float) -> void:
	# 1. 停用或窗口失焦时立即清空指令，等待地图首次同步再查询路径。
	if not enabled or not _actor.is_control_active():
		_stop_motion()
		return
	var map := _agent.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	# 2. 到点后短暂停留，结束后有限次采样新目标。
	if state == &"idle":
		_stop_motion()
		_wait_remaining -= delta
		if _wait_remaining <= 0.0:
			_choose_destination(map)
		return
	# 3. 每物理帧推进导航路径，再将地面方向交给避让器。
	var next := _agent.get_next_path_position()
	if _agent.is_navigation_finished():
		destinations_reached += 1
		_begin_idle()
		return
	var direction := next - _actor.global_position
	direction.y = 0.0
	_agent.velocity = direction.normalized() * _actor.walk_speed * _actor.snow_speed_scale
	# 4. 被玩家或障碍持续挡住时放弃本趟，短暂停留后换目标，避免原地抖动。
	_trip_seconds += delta
	_stalled_seconds = _stalled_seconds + delta if _actor.horizontal_speed < 0.08 else 0.0
	if _stalled_seconds > 1.4 or _trip_seconds > 22.0:
		blocked_repaths += 1
		_begin_idle()


## 从当前位置附近选可到达地面点，避开玩家脚下和屋顶等高处。
func _choose_destination(map: RID) -> void:
	# 1. 采样次数有上限；不可达点不触发无界重试或穿墙移动。
	for attempt in range(16):
		var angle := _random.randf_range(-PI, PI)
		var radius := _random.randf_range(2.0, 5.0)
		var candidate := _actor.global_position + Vector3(cos(angle), 0.0, sin(angle)) * radius
		if not WANDER_RECT.has_point(Vector2(candidate.x, candidate.z)):
			continue
		var ground := NavigationServer3D.map_get_closest_point(map, candidate)
		if absf(ground.y) > 0.25 or ground.distance_to(candidate) > 0.7 or ground.distance_to(_actor.global_position) < 1.25:
			continue
		if is_instance_valid(player) and ground.distance_to(player.global_position) < 1.0:
			continue
		# 2. 先确认全路径终点接近采样点，避免选择隔离导航岛。
		var path := NavigationServer3D.map_get_path(map, _actor.global_position, ground, true)
		if path.size() < 2 or path[path.size() - 1].distance_to(ground) > 0.3:
			continue
		target = ground
		_agent.target_position = ground
		state = &"walking"
		trips_started += 1
		_stalled_seconds = 0.0
		_trip_seconds = 0.0
		return
	# 3. 暂时没有合适位置时稍后再试，不挤向玩家。
	_wait_remaining = 0.8


## 进入短暂停留，清掉避让器中上一趟的速度。
func _begin_idle() -> void:
	# 1. 停留采用轻微随机变化，避免机械循环。
	state = &"idle"
	_wait_remaining = _random.randf_range(1.4, 3.5)
	_stop_motion()


## 把避让后的速度转换成原控制器的模拟输入幅度。
func _apply_safe_velocity(safe_velocity: Vector3) -> void:
	# 1. 异步避让回调也检查停用、停留和焦点，避免旧结果恢复移动。
	if not enabled or state != &"walking" or not _actor.is_control_active():
		_actor.set_external_direction(Vector3.ZERO)
		return
	# 2. 深雪速度在角色内统一计算，这里只保留避让产生的减速比例。
	var speed := maxf(0.1, _actor.walk_speed * _actor.snow_speed_scale)
	_actor.set_external_direction(safe_velocity / speed)


## 停止移动意图，不重置距离相位、足迹或已有反馈。
func _stop_motion() -> void:
	# 1. 角色在下一物理步使用原有制动逻辑自然停下。
	_agent.velocity = Vector3.ZERO
	_actor.set_external_direction(Vector3.ZERO)


## 供场景开关、截图和关闭流程安全暂停或恢复电脑行为。
func set_enabled(value: bool) -> void:
	# 1. 停止旧目标并关闭无用避让计算，恢复后重新散步。
	enabled = value
	set_physics_process(value)
	_agent.avoidance_enabled = value
	_agent.set_velocity_forced(Vector3.ZERO)
	_begin_idle()
	_actor.velocity = Vector3.ZERO
	_actor.horizontal_speed = 0.0


## 返回有界诊断值，验收无需保存逐帧历史或进入AI内部数组。
func get_status() -> Dictionary:
	# 1. 所有累计项仅为计数，不随运行时间分配列表。
	return {"enabled": enabled, "state": state, "target": target, "wait_seconds": _wait_remaining,
		"trips_started": trips_started, "destinations_reached": destinations_reached,
		"blocked_repaths": blocked_repaths, "stalled_seconds": _stalled_seconds}
