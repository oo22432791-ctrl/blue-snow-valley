extends Node3D
## 两个前置事件协调器：实体交互、阵风、检查点和明确失败回退，复用原角色能力。

const GEOMETRY = preload("res://scripts/v3/world/valley_event_geometry.gd")
const STATE = preload("res://scripts/v3/world/valley_event_state.gd")
var world: Node3D
var geometry: Node3D
var state: Dictionary = STATE.initial()
var fall_pending := {"p1":false,"p2":false}
var _requests: Dictionary = {}
var _angle_targets: Array[float] = []
var _phase_origin: float = 0.0
var _last_platform := {"p1":-1,"p2":-1}
var _save_requested: bool = false
var _deferred_save: int = -1
var _ai_goal: int = -1
var _ai_repath: float = 0.0
var _ai_stalled: float = 0.0
var _ai_event_active: bool = false
var falls_returned: int = 0
var dial_turns: int = 0


## 新场地在世界启动读档前一次装配，角色和库存始终使用现有两槽位。
func _ready() -> void:
	# 1. 暂停中仅完成待结算回退／保存，不推进阵风或接受玩法动作。
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -14
	geometry = GEOMETRY.new()
	geometry.world = world
	add_child(geometry)
	for id: String in geometry.targets:
		world.survival.targets[id] = geometry.targets[id]
	restore_state(STATE.initial(world.v3_progress))
	world.world_clock.advanced.connect(_advance)


## 存档使用相对阵风相位，不保存渲染动画或设备来源。
func capture_state() -> Dictionary:
	var result: Dictionary = state.duplicate(true)
	result.gust_phase = phase()
	return result


## 读档同步已提交盘面和门板；暂停期间不会补走机关动画。
func restore_state(value: Dictionary) -> void:
	# 1. 调用方已经完成语义和实际位置预检，此处不补猜缺失数据。
	state = value.duplicate(true)
	_phase_origin = world.world_clock.elapsed_seconds-float(state.gust_phase)
	_angle_targets.clear()
	for index in range(3):
		var angle := -float(state.discs[index])*PI*.5
		_angle_targets.append(angle)
		geometry.rotors[index].rotation.y = angle
	geometry.set_gate_fraction(1.0 if world.v3_progress.boss_unlocked else 0.0)
	geometry.lever.rotation.x = -.65 if world.v3_progress.exploration_event else 0.0
	fall_pending = {"p1":false,"p2":false}
	_last_platform = {"p1":-1,"p2":-1}
	_save_requested = false
	_deferred_save = -1
	cancel_transients()


## 世界钟是阵风唯一时间源，全局暂停自然冻结同一个相位。
func phase() -> float:
	return fposmod(world.world_clock.elapsed_seconds-_phase_origin,STATE.PERIOD)


## 旗帜预警2秒、强风4秒、平稳6秒，不依赖普通天气随机状态。
func gust_kind() -> String:
	var value := phase()
	return "warning" if value < 2 else ("strong" if value < 6 else "calm")


## 两名操作者各只有一个排队槽，权限代次在物理帧再次验证。
func request_interaction(actor: String, id: String) -> void:
	if not _requests.has(actor):
		_requests[actor] = {"id":id,"epoch":world.actor_registry.ownership_epoch}


## 实际距离和实体视线共用原生存模块契约，禁止隔墙或远程转盘。
func accessible(actor: String, id: String) -> bool:
	if not geometry.targets.has(id) or not world.rescue.can_act(actor):
		return false
	var target: Dictionary = geometry.targets[id]
	var body: CharacterBody3D = world.actor_registry.slots[actor].body
	var model: Node = world.survival if actor == "p1" else world.secondary_context.survival
	return body.position.distance_to(target.position) <= target.reach and model.clear_line(body.position+Vector3.UP*.95,target.position,target.body)


## 暂停、读档和切模式只撤销短期动作；不回滚已转石盘或已到平台。
func cancel_transients() -> void:
	_requests.clear()
	_ai_goal = -1
	_ai_repath = 0
	_ai_stalled = 0
	_ai_event_active = false
	for id: String in ["p1","p2"]:
		world.actor_registry.slots[id].body.event_wind_velocity = Vector3.ZERO


## 固定物理帧消费意图、检查支撑并施加真实侧风，渲染帧不查询物理。
func _physics_process(delta: float) -> void:
	if world.session.busy or not world.session.session_ready or world.session.main_menu.visible:
		return
	# 1. 即使玩家已暂停，也先完成已经触发的失败回退，未找到位置时保留等待。
	for id: String in ["p1","p2"]:
		var body: CharacterBody3D = world.actor_registry.slots[id].body
		body.event_wind_velocity = Vector3.ZERO
		_detect_fall(id)
		if fall_pending[id]:
			_try_return(id)
	if not get_tree().paused:
		for id: String in ["p1","p2"]:
			if _requests.has(id):
				_commit_interaction(id,_requests[id])
		_requests.clear()
		for id: String in ["p1","p2"]:
			_update_checkpoint(id)
			var body: CharacterBody3D = world.actor_registry.slots[id].body
			if _wind_exposed(id):
				body.event_wind_velocity = Vector3(0,0,1.55)
		if not is_instance_valid(world.boss_encounter) or world.boss_encounter.status!="fighting":
			geometry.set_gate_fraction(move_toward(geometry.gate_open,1.0 if world.v3_progress.boss_unlocked else 0.0,delta))
	# 2. 自动保存合并至安全物理状态，失败回退没有完成前不捕获半途快照。
	if _deferred_save >= 0 and ready_for_save():
		var automatic: bool = _deferred_save == 1
		_deferred_save = -1
		world.session.resume_event_save(automatic)
	elif _save_requested and ready_for_save() and not world.session._save_queued:
		_save_requested = false
		world.session.request_save(true)


## 盘面与旗帜仅更新可见姿态；门板碰撞由物理帧同步。
func _process(delta: float) -> void:
	if not is_instance_valid(geometry) or get_tree().paused:
		return
	for index in range(3):
		geometry.rotors[index].rotation.y = move_toward(geometry.rotors[index].rotation.y,_angle_targets[index],delta*4.5)
	for index in range(3):
		var flag: Node3D = geometry.flags[index]
		flag.rotation.x = (.15*sin(phase()*12+index) if gust_kind() == "strong" else (.3*sin(phase()*7+index) if gust_kind() == "warning" else .8))


## 同一盘动画未结束时不接受第二次转动，双方同时按下也只提交一次。
func _commit_interaction(actor: String, request: Dictionary) -> void:
	if request.epoch != world.actor_registry.ownership_epoch or world.actor_registry.slots[actor].source not in ["local","remote"] or not accessible(actor,request.id):
		return
	var endpoint: Node = world.input_router if actor == "p1" else world.secondary_context.input_router
	if not endpoint.allows_gameplay_input():
		return
	var id: String = request.id
	if id.begins_with("event.dial."):
		if world.v3_progress.exploration_event:
			_notice(actor,"机关已完成，石盘锁定。")
			return
		var index: int = id.get_slice(".",2).to_int()
		if absf(geometry.rotors[index].rotation.y-_angle_targets[index]) > .01:
			return
		state.discs[index] = (int(state.discs[index])+1)%4
		_angle_targets[index] -= PI*.5
		dial_turns += 1
	elif id.begins_with("event.clue."):
		_notice(actor,"石刻一：一道刻痕对应太阳。机关不耗柴弹。" if id.ends_with("0") else "石刻二：两道刻痕对应松树，三道刻痕对应山峰。")
	elif id == "event.lever":
		if world.v3_progress.exploration_event:
			_notice(actor,"石盘机关已完成。")
			return
		for index in range(3):
			if absf(geometry.rotors[index].rotation.y-_angle_targets[index]) > .01:
				_notice(actor,"石盘还在转动，请稍等。")
				return
		if not STATE.aligned(state.discs):
			_notice(actor,"图案尚未对齐，可再观察两处石刻。")
			return
		world.v3_progress.exploration_event = true
		geometry.lever.rotation.x = -.65
		_notice(actor,"石刻机关完成 · 山门第一道锁扣解除。")
		_complete_event()
	elif id == "event.gate":
		_notice(actor,"山门已开放。" if world.v3_progress.boss_unlocked else "山门锁扣：石刻%s · 栈道%s" % ["已完成" if world.v3_progress.exploration_event else "未完成","已完成" if world.v3_progress.traversal_event else "未完成"])


## 每人检查点独立；必须从入口经中央平台到出口，AI不单独完成世界任务。
func _update_checkpoint(id: String) -> void:
	if not world.rescue.can_act(id) or fall_pending[id] or not world.actor_registry.is_effective(id):
		return
	var body: CharacterBody3D = world.actor_registry.slots[id].body
	var index := platform_at(body.position)
	if index == _last_platform[id]:
		return
	_last_platform[id] = index
	if index < 0:
		return
	var data: Dictionary = state.actors[id]
	data.checkpoint = index
	if (int(data.visited)&(1 << index)) == 0:
		data.visited = int(data.visited)|(1 << index)
		_save_requested = true
		if index == 0 and world.actor_registry.slots[id].source in ["local","remote"]:
			_notice(id,"风口：看旗等风；柴火取暖、弹药防熊，通行不耗材。")
	if index == 0:
		data.route_step = 0
	elif index == 1 and data.route_step == 0:
		data.route_step = 1
	elif index == 2 and data.route_step == 1:
		data.route_step = 2
		if world.actor_registry.slots[id].source in ["local","remote"] and not world.v3_progress.traversal_event:
			world.v3_progress.traversal_event = true
			_notice(id,"风口栈道完成 · 山门第二道锁扣解除。")
			_complete_event()


## 平台判定同时要求实际高度和中心安全范围，地面绕行不能冒充经过平台。
func platform_at(at: Vector3) -> int:
	var local: Vector3 = at-geometry.bridge_origin
	if absf(local.y-.04) > .16 or absf(local.z) > 1.1:
		return -1
	for index in range(3):
		if absf(local.x-index*11.0) <= 1.05:
			return index
	return -1


## 风只影响暴露栈道，平台实际挡风板的射线可阻挡侧风。
func _wind_exposed(id: String) -> bool:
	if gust_kind() != "strong" or not world.rescue.can_act(id) or fall_pending[id] or not world.actor_registry.is_effective(id):
		return false
	var body: CharacterBody3D = world.actor_registry.slots[id].body
	var local: Vector3 = body.position-geometry.bridge_origin
	if local.x < -1.5 or local.x > 23.5 or absf(local.z) > 3 or absf(local.y) > .35:
		return false
	var point := body.position+Vector3.UP*.8
	var query := PhysicsRayQueryParameters3D.create(point-Vector3(0,0,4),point,1,[body.get_rid()])
	return world.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## 真实离开支撑并开始下落后才进入失败回退，不用触发器替代碰撞通行。
func _detect_fall(id: String) -> void:
	if fall_pending[id] or state.actors[id].checkpoint < 0 or not world.rescue.can_act(id):
		return
	var body: CharacterBody3D = world.actor_registry.slots[id].body
	var local: Vector3 = body.position-geometry.bridge_origin
	if local.x >= -1.7 and local.x <= 23.7 and absf(local.z) < 5 and local.y < -.12 and not body.is_on_floor():
		fall_pending[id] = true
		world.local_controls.clear_actor(id)
		_notice(id,"失足 · 正在返回最近安全平台。")


## 搜索多处真实站位，受阻时不扣暖、不挪同伴，继续等待空位。
func _try_return(id: String) -> void:
	var body: CharacterBody3D = world.actor_registry.slots[id].body
	var best: int = -1
	var distance: float = INF
	for index in range(3):
		if (int(state.actors[id].visited)&(1 << index)) == 0:
			continue
		var gap := body.position.distance_squared_to(geometry.checkpoint(index))
		if gap < distance:
			distance = gap
			best = index
	if best < 0:
		return
	var at := safe_platform_point(best,id)
	if not at.is_finite():
		body.set_external_direction(Vector3.ZERO)
		return
	# 1. 位置和扣暖在同一物理提交中完成；每次摔落只扣一次。
	body.position = at
	body.velocity = Vector3.ZERO
	body.set_external_direction(Vector3.ZERO)
	body.event_wind_velocity = Vector3.ZERO
	body.get_node("FootstepEmitter").reset_tracking()
	state.actors[id].checkpoint = best
	fall_pending[id] = false
	_last_platform[id] = best
	var model: Node = world.survival if id == "p1" else world.secondary_context.survival
	var weapon: Node3D = world.rifle if id == "p1" else world.secondary_context.rifle
	weapon.cancel_reload()
	weapon._pending_fire = false
	model.warmth = maxf(0,model.warmth-10)
	model.protection_until = world.world_clock.elapsed_seconds+(3.0 if model.warmth > 0 else 0.0)
	falls_returned += 1
	world.interior.sync_rooms()
	world.view_manager.views["view."+id].rig.snap_to_actor()
	_notice(id,"已回安全平台 · 暖意扣10，柴火和弹药保留。")
	if model.warmth <= 0:
		world.rescue.fail_actor(id,&"hypothermia")


## 回退和AI目标都验证实际胶囊与脚下支撑，不使用无碰撞的备用点。
func safe_platform_point(index: int, id: String) -> Vector3:
	var body: CharacterBody3D = world.actor_registry.slots[id].body
	for offset: Vector3 in [Vector3.ZERO,Vector3(-.6,0,.7),Vector3(.6,0,.7),Vector3(-.6,0,-.65),Vector3(.6,0,-.65)]:
		var at: Vector3 = geometry.checkpoint(index)+offset
		var shape := CapsuleShape3D.new()
		shape.radius = .3
		shape.height = 1.46
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.transform = Transform3D(Basis.IDENTITY,at+Vector3.UP*.75)
		query.exclude = [body.get_rid()]
		query.collision_mask = 1
		query.margin = 0
		var space := world.get_world_3d().direct_space_state
		if not space.intersect_shape(query,1).is_empty():
			continue
		var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*.15,at-Vector3.UP*.4,1,[body.get_rid()])
		if not space.intersect_ray(ray).is_empty():
			return at
	return Vector3.INF


## 已触发摔落先结算；桥面半空或边缘无支撑时等待下一物理状态再保存。
func ready_for_save() -> bool:
	for id: String in ["p1","p2"]:
		if fall_pending[id]:
			return false
		var body: CharacterBody3D = world.actor_registry.slots[id].body
		var local: Vector3 = body.position-geometry.bridge_origin
		if state.actors[id].checkpoint >= 0 and local.x >= -1.5 and local.x <= 23.5 and absf(local.z) < 5 and local.y > -2:
			if absf(local.y) > .16:
				return false
			var half_width: float = 1.5 if absf(local.x) <= 1.5 or absf(local.x-11) <= 1.5 or absf(local.x-22) <= 1.5 else .9
			if absf(local.z) > half_width:
				return false
	return true


## 延后保存保持原请求性质，手动请求优先于自动保存反馈。
func defer_save(automatic: bool) -> void:
	_deferred_save = mini(_deferred_save,1 if automatic else 0) if _deferred_save >= 0 else (1 if automatic else 0)


## 两项进度原子派生山门状态，不消耗个人柴弹或代替真实Boss结算。
func _complete_event() -> void:
	world.v3_progress.boss_unlocked = world.v3_progress.exploration_event and world.v3_progress.traversal_event
	_save_requested = true
	if world.v3_progress.boss_unlocked:
		world.session._notice("两道锁扣解除 · 林间小屋后方的山门开放。")


## 进度和阵风属于局部情境提示，不常驻完整操作说明。
func status_for(id: String) -> String:
	var local: Vector3 = world.actor_registry.slots[id].body.position-geometry.bridge_origin
	if local.x < -14 or local.x > 36 or absf(local.z) > 5:
		return ""
	if fall_pending[id]:
		return "平台站位受阻 · 等待空位后重试"
	return {"warning":"旗帜预警","strong":"强阵风","calm":"风势平稳"}[gust_kind()]+" · 安全平台%d / 3" % (int(state.actors[id].checkpoint)+1)


## 资源、冷暖与阵风使用同一游戏秒数，无单独现实计时器。
func _advance(_delta: float, _elapsed: float) -> void:
	state.gust_phase = phase()


## 事件通知借原角色临时提示展示，物资状态只从原能力读取。
func _notice(id: String, message: String) -> void:
	var weapon: Node3D = world.rifle if id == "p1" else world.secondary_context.rifle
	weapon.notice(message)


## 护卫、救援和关闭AI后的返程共用真实栈道路径，不跳过危险段。
func drive_ai(target: Vector3, delta: float) -> bool:
	var body: CharacterBody3D = world.snowball_game.companion
	var local: Vector3 = body.position-geometry.bridge_origin
	var target_local: Vector3 = target-geometry.bridge_origin
	var actor_on: bool = _on_structure(body.position)
	var target_on: bool = _on_structure(target)
	# 地面目标可位于桥下；先选真实坡道出口，不能在中央平台沿侧边直下。
	if not target_on:
		var west: Vector3 = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[0])
		var east: Vector3 = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[1])
		target_local.x = -15.0 if target.distance_squared_to(west) < target.distance_squared_to(east) else 37.0
	if not actor_on and not target_on:
		if _ai_event_active:
			world.guard.reset_transient_task()
		_ai_event_active = false
		_ai_goal = -1
		return false
	# 1. 临时停止拾柴和护卫，持久跟随／等待／禁火指令保持原样。
	if not _ai_event_active:
		world.guard.reset_transient_task()
		_ai_event_active = true
	if fall_pending.p2 or not world.rescue.can_act("p2"):
		body.set_external_direction(Vector3.ZERO)
		return true
	_ai_repath -= delta
	_ai_stalled = _ai_stalled+delta if body.horizontal_speed < .08 else 0.0
	var platform := platform_at(body.position)
	var destination := Vector3.INF
	# 2. 原来就在坡道／地面时先走到可达入口，不把地下直线当高架路径。
	if not actor_on:
		_ai_goal = 0 if local.x < 11 else 2
		destination = safe_platform_point(_ai_goal,"p2")
	elif local.x < -1.05 and target_local.x < -1.5:
		destination = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[0])
	elif local.x > 23.05 and target_local.x > 23.5:
		destination = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[1])
	elif local.x > 23.5:
		_ai_goal = 2
		destination = safe_platform_point(2,"p2")
	elif platform >= 0:
		_ai_goal = -1
		var direction: int = 1 if target_local.x > platform*11+2 else (-1 if target_local.x < platform*11-2 else 0)
		# 已到出口后沿实际下坡离场，原跟随或返程将在离开结构后接回。
		if platform == 2 and direction > 0:
			destination = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[1])
		elif platform == 0 and direction < 0:
			destination = geometry.bridge_origin+GEOMETRY.vector(geometry.bridge_manifest.ramp_ends[0])
		elif direction == 0:
			body.set_external_direction(Vector3.ZERO)
			world.guard.status = "栈道安全平台待命"
			return true
		else:
			# 两个平台中心相距11米；考虑雪速与起步，只在足够长的平稳窗口出发。
			if gust_kind() != "calm" or STATE.PERIOD-phase() < 4.6:
				body.set_external_direction(Vector3.ZERO)
				world.guard.status = "观察旗帜 · 等待平稳风窗"
				return true
			_ai_goal = clampi(platform+direction,0,2)
			destination = safe_platform_point(_ai_goal,"p2")
	else:
		if _ai_goal < 0:
			_ai_goal = clampi(ceili(local.x/11.0) if target_local.x >= local.x else floori(local.x/11.0),0,2)
		destination = safe_platform_point(_ai_goal,"p2")
	if not destination.is_finite():
		body.set_external_direction(Vector3.ZERO)
		world.guard.status = "安全平台受阻 · 等待腾位"
		return true
	# 3. NavigationAgent消费包含实际坡道、窄桥和挡风板的新导航，胶囊继续碰撞。
	var agent: NavigationAgent3D = body.get_node("NavigationAgent3D")
	if NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) == 0:
		body.set_external_direction(Vector3.ZERO)
		return true
	if _ai_repath <= 0 or agent.target_position.distance_to(destination) > .6:
		agent.target_position = destination
		_ai_repath = .3
	var next := agent.get_next_path_position()
	# AI可能尚在屋内；沿用近门实际开门规则后，才能走向栈道坡道。
	world.guard.open_path_door(next)
	# 向内开启的门不能穿过站在门后的AI；实际后退让开扫掠区再等待开足。
	for cabin: Node3D in world.landmarks.cabins:
		if not cabin.target_open or cabin.door_angle >= deg_to_rad(float(cabin.manifest.door.open_degrees))-0.02 or not cabin.contains_interior(body.position):
			continue
		var from: Vector3 = cabin.to_local(body.position)
		var door_z: float = cabin.manifest.door.pivot[2]
		if absf(from.x) < float(cabin.manifest.door.opening_width)*.5+.35 and from.z > door_z-2.2:
			var back: Vector3 = cabin.to_global(Vector3(from.x,from.y,door_z-2.05))-body.position
			body.set_external_direction(back.normalized() if back.length() > .1 else Vector3.ZERO)
			world.guard.status = "为门扇让位 · 等待实际开足"
			return true
	var movement := (next-body.position)*Vector3(1,0,1)
	body.set_external_direction(movement.normalized() if not agent.is_navigation_finished() else Vector3.ZERO,true)
	world.guard.status = "栈道路径受阻 · 正在重试" if not agent.is_target_reachable() or _ai_stalled > 2 else "沿栈道跟随"
	return true


## 只有高于原地面的真实栈道／坡道站位接管AI，桥下正常探索不被误判。
func _on_structure(at: Vector3) -> bool:
	var local: Vector3 = at-geometry.bridge_origin
	return local.x >= -14 and local.x <= 36 and absf(local.z) < 3 and at.y > world.terrain.get_ground_height(Vector2(at.x,at.z))+.15
