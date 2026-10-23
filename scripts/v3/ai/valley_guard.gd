extends Node
## 固定P2的护卫意图；移动、取柴、枪械与救援仍通过真实角色能力结算。

var world: Node3D
var enabled: bool = false
var command: String = "follow"
var wait_position := Vector3.ZERO
var fire_allowed: bool = true
var combat_target: CharacterBody3D
var status: String = "跟随"
var _actor: CharacterBody3D
var _agent: NavigationAgent3D
var _assisting: bool = false
var _wood_id: String = ""
var _catching_up: bool = false
var _repath: float = 0
var _stalled: float = 0
var _requested: String = ""
var _request_epoch: int = -1
var wood_collected: int = 0


## 所有控制来源共用一个实体和导航，旧散步控制器由装配层释放。
func _ready() -> void:
	# 1. 救援协调器在本节点之后接管，防止同帧旧跟随覆盖施救意图。
	process_physics_priority = -12
	_actor = world.snowball_game.companion
	_agent = _actor.get_node("NavigationAgent3D")
	wait_position = _actor.global_position
	_agent.set_navigation_map(world.companion_navigation.get_navigation_map())
	_agent.avoidance_enabled = false
	world.actor_registry.control_sources_changed.connect(_mode_changed)
	world.rescue.returned.connect(_returned)
	set_enabled(false)


## 模式切换和救援只暂停意图，不重置库存或已保存的玩家指令。
func set_enabled(value: bool) -> void:
	# 1. 新接管必须重新求路，不能沿用旧演员的目的地或待发子弹。
	enabled = value
	set_physics_process(value)
	_repath = 0
	combat_target = null
	if is_instance_valid(_actor):
		_actor.set_external_direction(Vector3.ZERO)
		_actor.velocity = Vector3.ZERO
		_agent.avoidance_enabled = false
	if not value and is_instance_valid(world.secondary_context):
		reset_transient_task()
		world.secondary_context.rifle._pending_fire = false
	elif value and is_instance_valid(world.secondary_context) and world.actor_registry.slots.p2.source == "ai":
		# 从已倒地存档救起后，也重新接回真实枪械物理与上身动画。
		world.secondary_context.set_controlled(true)


## 只允许当前AI槽位的本地主玩家下令，GUI请求在物理帧消费。
func request_command(value: String) -> bool:
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.ongoing() and value in ["follow","wait","assist"]:
		world.session._notice("挑战期间使用战斗协助，结束后恢复原指令；仍可切换禁火。")
		return false
	# 1. 人类P2或过期面板不能给已经换人的角色留下AI操作。
	if value not in ["follow", "wait", "assist", "fire", "cease"] or not world.session.local_authority or get_tree().paused or world.session.busy or world.actor_registry.slots.p2.source != "ai" or not world.rescue.can_act("p1"):
		return false
	_requested = value
	_request_epoch = world.actor_registry.ownership_epoch
	return true


## 暂停与失焦只撤销未消费按钮，不清除已经提交的等待／禁火策略。
func cancel_requests() -> void:
	_requested = ""


## 救援接管或雪球入场取消旧临时协助，完成后恢复持久跟随／等待指令。
func reset_transient_task() -> void:
	_requested = ""
	_assisting = false
	_wood_id = ""
	combat_target = null
	_repath = 0


## 每步仅提供一个动作，救援、雪球和倒地优先于普通护卫。
func _physics_process(delta: float) -> void:
	# 1. 原子读档、主菜单或其他来源持有角色时，清掉而非积累意图。
	if not enabled or not world.session.session_ready or world.session.busy or world.session.main_menu.visible or world.actor_registry.slots.p2.source != "ai" or not world.rescue.can_act("p2"):
		_actor.set_external_direction(Vector3.ZERO)
		return
	if not _requested.is_empty():
		if _request_epoch == world.actor_registry.ownership_epoch:
			_apply_command(_requested)
		_requested = ""
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.status in ["entering","fighting"]:
		return
	if world.snowball_game.participating or world.rescue.life.p1.state == "downed":
		combat_target = null
		return
	if not world.input_router._focused:
		_actor.set_external_direction(Vector3.ZERO)
		return
	# 栈道接管同一角色的移动，暂不拾柴或开火，离场后恢复原持久指令。
	if is_instance_valid(world.events) and world.events.drive_ai(world.player.position if command == "follow" else wait_position,delta):
		combat_target = null
		return
	_repath -= delta
	_stalled = _stalled + delta if _actor.horizontal_speed < .08 else 0.0
	# 2. 等待只允许原地支援，跟随超距先回玩家身边，不为熊离开有效庇护。
	combat_target = _find_threat() if fire_allowed else null
	var distance := _actor.global_position.distance_to(world.player.global_position)
	if is_instance_valid(combat_target) and (command == "wait" or distance <= 12):
		_actor.set_external_direction(Vector3.ZERO)
		status = "护卫战斗"
		var weapon: Node = world.secondary_context.rifle
		world.secondary_context.aim_yaw = _direction_yaw(combat_target.global_position)
		if weapon.equipped != 2:
			weapon.equip(2)
		if weapon.chamber == 0:
			if weapon.reserve > 0:
				weapon.request_reload()
			else:
				status = "缺弹 · 可近距赠送备用弹"
		elif not weapon.reloading():
			weapon._request_fire(Vector2.ZERO)
		return
	combat_target = null
	# 3. 一次协助或跟随中的近距拾柴都使用实际容量、路径和单次库存事务。
	if command == "follow":
		var different_room: bool = world.interior.shelter_at(_actor.global_position).building_id != world.interior.shelter_at(world.player.global_position).building_id
		# 墙两侧的直线距离不能冒充已跟进室内；同室后才按2／4米停走。
		_catching_up = true if distance > 4 or different_room else (false if distance <= 2 else _catching_up)
	if not _assisting and command == "follow" and _catching_up:
		_wood_id = ""
		move_to(world.player.global_position, "跟随", delta)
	elif _assisting or command == "follow":
		if _wood_id.is_empty():
			_wood_id = _find_wood()
		if not _wood_id.is_empty():
			_gather(delta)
		else:
			_assisting = false
			_idle_or_wait(delta)
	else:
		_idle_or_wait(delta)


## 跟随使用2／4米滞回，等待或一次协助结束后回到原等待站位。
func _idle_or_wait(delta: float) -> void:
	# 1. 移动只走真实胶囊，不因落后或路线受阻直接改位置。
	if command == "wait" and _actor.global_position.distance_to(wait_position) > .45:
		move_to(wait_position, "返回等待点", delta)
	else:
		_actor.set_external_direction(Vector3.ZERO)
		status = "原地等待" if command == "wait" else "跟随待命"


## 真NavigationAgent求路；门只在路径经过门口且角色实际够得着时开启。
func move_to(target: Vector3, label: String, _delta: float) -> void:
	# 1. 地图尚未同步时等待，不拿默认零向量当路径点。
	if NavigationServer3D.map_get_iteration_id(_agent.get_navigation_map()) == 0:
		_actor.set_external_direction(Vector3.ZERO)
		return
	if _repath <= 0 or _agent.target_position.distance_to(target) > 1:
		_agent.target_position = target
		_repath = .4
	var next := _agent.get_next_path_position()
	open_path_door(next)
	var direction := (next - _actor.global_position) * Vector3(1,0,1)
	_actor.set_external_direction(direction.normalized() if not _agent.is_navigation_finished() else Vector3.ZERO, command == "follow" and _actor.global_position.distance_to(world.player.global_position) > 6)
	status = label + " · 路径受阻，正在重试" if not _agent.is_target_reachable() or _stalled > 2 else label


## 救援也调用同一个真实门口开门入口，不旋转穿过站在门扇中的人。
func open_path_door(next: Vector3) -> void:
	# 1. 只在移动线段要穿过门所在平面时开门，靠近后墙不会远程开门。
	for cabin: Node3D in world.landmarks.cabins:
		if cabin.target_open or not cabin.can_interact(_actor.global_position):
			continue
		var from: Vector3 = cabin.to_local(_actor.global_position)
		var to: Vector3 = cabin.to_local(next)
		var door_z: float = cabin.manifest.door.pivot[2]
		if (from.z - door_z) * (to.z - door_z) <= 0 or absf(from.z - door_z) < .7:
			cabin.request_interact(_actor)


## 候选只来自实际威胁和P1真实命中，不因为远处熊可见就擅自耗弹。
func _find_threat() -> CharacterBody3D:
	# 1. 消费原枪械历史的成功伤害记录，墙壁或同伴挡枪不会激活远处熊。
	var hit_ids: Array[String] = []
	for shot: Dictionary in world.rifle.shot_history:
		if shot.get("damage", {}).get("accepted", false):
			hit_ids.append(String(shot.collision_id))
	var best: CharacterBody3D
	var nearest := 10.001
	for bear: CharacterBody3D in world.bears.bears:
		var distance := _actor.global_position.distance_to(bear.global_position)
		if bear.health <= 0 or distance > 10 or distance >= nearest:
			continue
		# 已交战熊的短硬直不是脱战，不能因此每次命中都丢掉装填意图。
		var ongoing: bool = bear == combat_target and bear.state == &"stagger"
		if bear.state not in [&"warning", &"chase", &"attack", &"recover"] and not ongoing and bear.stable_id not in hit_ids:
			continue
		var ray := PhysicsRayQueryParameters3D.create(_actor.global_position + Vector3.UP * 1.1, bear.global_position + Vector3.UP * .85, 1, [_actor.get_rid()])
		var hit := world.get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty() and hit.collider != bear:
			continue
		best = bear
		nearest = distance
	return best


## 拾柴候选限定当前5米和真实导航终点，不能为物资远征或从墙外收取。
func _find_wood() -> String:
	# 1. 容量满不改变世界数量，跟随玩家优先于继续寻找下一堆柴。
	var model: Node = world.secondary_context.survival
	if model.carried >= model.CARRY_CAPACITY:
		return ""
	var best := ""
	var distance := 5.001
	for id: String in model.resources:
		var item: Dictionary = model.resources[id]
		var point: Vector3 = model.targets[id].position
		var gap := _actor.global_position.distance_to(point)
		if item.quantity <= 0 or gap > 5 or gap >= distance:
			continue
		var path := NavigationServer3D.map_get_path(_agent.get_navigation_map(), _actor.global_position, point, true)
		if path.size() < 2 or path[-1].distance_to(point) > 1.0:
			continue
		best = id
		distance = gap
	return best


## 接近后调用生存模块的单次真实转移，完成协助后恢复原模式。
func _gather(delta: float) -> void:
	# 1. 公共木柴可能已经被P1拿走，重新检查而非使用缓存数量。
	var model: Node = world.secondary_context.survival
	if model.resources[_wood_id].quantity <= 0 or model.carried >= model.CARRY_CAPACITY:
		_wood_id = ""
		_assisting = false
		return
	if model.target_accessible(_wood_id):
		_actor.set_external_direction(Vector3.ZERO)
		var count: int = model.pickup_for_ai(_wood_id)
		wood_collected += count
		_wood_id = ""
		_assisting = false
		status = "拾柴完成" if count > 0 else "木柴当前不可取"
	else:
		move_to(model.targets[_wood_id].position, "协助拾柴", delta)
		if _agent.is_navigation_finished() or _stalled > 3:
			_wood_id = ""
			_assisting = false


## 消费最新代次的明确指令，关闭面板不直接更改物资。
func _apply_command(value: String) -> void:
	# 1. 等待记录AI当前实际位置，一次协助不覆盖这个锚点。
	match value:
		"follow", "wait":
			command = value
			wait_position = _actor.global_position
			_assisting = false
			_wood_id = ""
		"assist": _assisting = true
		"fire": fire_allowed = true
		"cease":
			fire_allowed = false
			world.secondary_context.rifle._pending_fire = false
	_repath = 0
	_stalled = 0


## 持久策略独立于设备来源；临时协助和战斗不进入存档。
func capture_policy() -> Dictionary:
	return {"command": command, "wait_position": [wait_position.x,wait_position.y,wait_position.z], "fire_allowed": fire_allowed}


## 完整快照校验后恢复策略，清理旧命令和临时导航。
func restore_policy(data: Dictionary) -> void:
	# 1. 读取不自动确认旧雪球邀请，也不继续半次拾取。
	command = data.command
	wait_position = Vector3(data.wait_position[0],data.wait_position[1],data.wait_position[2])
	fire_allowed = data.fire_allowed
	_requested = ""
	_assisting = false
	_wood_id = ""
	_catching_up = false
	_repath = 0
	_stalled = 0


## 控制交接释放旧待命，不更改玩家保存的跟随和禁火选择。
func _mode_changed(_mode: String, _epoch: int) -> void:
	_requested = ""
	_assisting = false
	_wood_id = ""
	var active: bool = world.actor_registry.slots.p2.source == "ai" and world.rescue.can_act("p2")
	set_enabled(active)
	world.secondary_context.set_controlled(active or world.actor_registry.slots.p2.source == "local")


## 安全返回不能让等待者立刻走回发生失败的旧位置。
func _returned(ids: Array) -> void:
	if "p2" in ids and command == "wait":
		wait_position = _actor.global_position
	_assisting = false
	_wood_id = ""


## 真实世界目标方向供原枪械上身与枪口适配使用。
func _direction_yaw(point: Vector3) -> float:
	var direction := point - _actor.global_position
	return atan2(direction.x, direction.z)
