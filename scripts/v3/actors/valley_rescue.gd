extends Node
## M6角色生命状态与单次救援／返回事务；不持有第二套库存或世界时钟。

signal life_changed
signal returned(actor_ids: Array)
signal boss_retry_completed

const WAIT_SECONDS: float = 60.0
const RESCUE_SECONDS: float = 3.0
var world: Node3D
var life: Dictionary = {}
var progress: Dictionary = {"p1": 0.0, "p2": 0.0}
var boss_checkpoint: Dictionary = {}
var return_blocked: bool = false
var last_return_notice: String = ""
var _held: Dictionary = {"p1": false, "p2": false}
var _valid: Dictionary = {"p1": false, "p2": false}
var _deadlines: Dictionary = {}
var _shot_serials: Dictionary = {}
var _retry_requested: bool = false
var _retry_age: float = 0.0
var _boss_busy: bool = false
var _ai_owned: bool = false
var _ai_enabled_before: bool = false
var _ai_processing_before: bool = false
var _ai_avoidance_before: bool = true
var _ai_repath: float = 0.0
var _p2_control_suppressed: bool = false
var _p2_enabled_before_down: bool = false
var _p2_processing_before_down: bool = false
var _p2_avoidance_before_down: bool = false
var ai_status: String = ""
var _ai_stall: float = 0.0
var rescue_count: int = 0
var return_count: int = 0


## 两个固定槽位始终存在，暂停时仅允许明确返回重试，不推进计时。
func _ready() -> void:
	# 1. 生命状态在角色装配完成后初始化，旧存档随后显式迁移。
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -10
	for id: String in ["p1", "p2"]:
		life[id] = standing_life()
		_shot_serials[id] = weapon(id).shots_fired
	world.world_clock.advanced.connect(_advance)
	world.actor_registry.control_sources_changed.connect(_mode_changed)


## 存档只包含当前生命状态和剩余时间，不保存按钮、导航或救援进度。
func capture_life(id: String) -> Dictionary:
	# 1. 绝对截止时间转为剩余游戏秒，退出期间不补进度。
	var data: Dictionary = life[id].duplicate(true)
	if data.state == "downed":
		data.remaining = maxf(0.0, float(_deadlines[id]) - world.world_clock.elapsed_seconds)
	return data


## 原子状态的站立起点也用于旧格式明确迁移。
static func standing_life() -> Dictionary:
	# 1. 不含设备和控制模式，切换来源不会重新发物资。
	return {"state": "standing", "reason": "", "remaining": 0.0}


## 共用角色能力入口只允许站立角色移动、交互和使用枪械。
func can_act(id: String) -> bool:
	# 1. 世界装配早期不阻塞尚未建立的角色。
	if is_instance_valid(world.boss_encounter) and id in world.boss_encounter.retired:
		return false
	return not life.has(id) or life[id].state == "standing"


## 是否存在尚未完成救援或安全返回的角色。
func any_incapacitated() -> bool:
	# 1. 保存返回主菜单先结算这些角色，不能换模式免费复活。
	return not can_act("p1") or not can_act("p2")


## 全倒且返回点受阻时不允许Esc越过冻结屏障。
func blocks_resume() -> bool:
	# 1. 单人返回受阻也属于当前活动角色全倒。
	return return_blocked and _all_active_down()


## 两个失败来源共享逐角色一次性入口，不自动冻结仍有搭档的世界。
func fail_actor(id: String, reason: StringName) -> bool:
	# 1. 同一攻击、重复事件或恢复中的旧事件不能重置60秒或重复扣柴。
	if not world.session.local_authority or not world.session.session_ready or world.session.busy or not can_act(id):
		return false
	world.snowball_game.end_activity("downed", true)
	life[id] = {"state": "downed", "reason": String(reason), "remaining": WAIT_SECONDS}
	_deadlines[id] = world.world_clock.elapsed_seconds + WAIT_SECONDS
	model(id).failure_latched = true
	_freeze_actor(id)
	# 2. 待命／关闭AI不提供救援；全倒直接进入共同返回，不空等一分钟。
	if not _has_partner() or world.actor_registry.slots[id].source == "idle":
		request_return([id])
	elif _all_active_down():
		request_return(_active_ids())
	world.session._notice(id.to_upper() + " 已倒地 · 搭档可按住交互键3秒救援")
	life_changed.emit()
	return true


## E／Enter／A只开启物理帧已确认的近距救援，不能在GUI回调查询射线。
func interact_pressed(id: String) -> bool:
	# 1. 普通伙伴赠送与救援只有一个入口，倒地同伴不会打开赠送菜单。
	var other := peer(id)
	if not can_act(id) or life[other].state != "downed":
		return not can_act(id)
	if _valid[id]:
		_held[id] = true
		weapon(id).cancel_reload()
		return true
	return false


## 松手、暂停、读档与失焦撤销本人的施救意图，已完成事务不回滚。
func release(id: String) -> void:
	if is_instance_valid(world.boss_encounter): world.boss_encounter.release(id)
	# 1. 阶段进度是临时状态，下一次连续施救从零开始。
	_held[id] = false
	progress[id] = 0.0
	_valid[id] = false


## 射击等明确动作中断正在进行的救援，不能边开枪边累积时间。
func interrupt(id: String) -> void:
	# 1. 保留仍按下的交互键，但本帧不积分，停下后才能从零重新开始。
	progress[id] = 0.0
	_valid[id] = false


## 根输入监听释放事件，不消费GUI按下，也不把另一台设备当作救援者。
func observe_release(event: InputEvent) -> void:
	# 1. 改键沿用同机动作映射，单人E仍使用相同默认物理键。
	if event is InputEventKey and not event.pressed:
		var translated: InputEventKey = world.local_controls.key_map.translate(event)
		if translated != null:
			var key: int = translated.physical_keycode if translated.physical_keycode != 0 else translated.keycode
			if key == KEY_E:
				release("p1")
			elif key == KEY_ENTER and world.local_controls.active and world.local_controls.scheme == "keyboard":
				release("p2")



## 返回请求只改变状态，搜索和位置／扣柴提交统一在物理帧执行。
func request_return(ids: Array) -> void:
	# 1. 重复请求不会预扣柴，全部返回角色先找到互不重叠的站位。
	if not world.session.local_authority:
		return
	for id: String in ids:
		if can_act(id):
			continue
		life[id].state = "return_pending"
		life[id].remaining = 0.0
		_freeze_actor(id)
	_retry_requested = true
	life_changed.emit()


## UI重试只排队，不临时移走家具、同伴或墙体。
func retry_returns() -> void:
	# 1. 场景暂停仍可明确重试，世界钟与救援倒计时保持冻结。
	_retry_requested = true


## 生命倒计时和连续施救消费同一游戏秒数；实际射线由物理帧缓存。
func _advance(delta: float, _elapsed: float) -> void:
	# 1. 施救只积分截止前的有效秒数；恰好在截止时完成仍属于等待期内。
	if not world.session.local_authority:
		return
	var frame_start: float = world.world_clock.elapsed_seconds - delta
	for id: String in life:
		if _held[id] and _valid[id] and can_act(id) and life[peer(id)].state == "downed" and weapon(id).shots_fired == _shot_serials[id]:
			progress[id] += minf(delta, maxf(0.0, float(_deadlines[peer(id)]) - frame_start))
			if progress[id] >= RESCUE_SECONDS:
				_revive(peer(id), id)
		else:
			progress[id] = 0.0
		_shot_serials[id] = weapon(id).shots_fired
	# 2. 超时仍未救起的角色进入返回，已成功复活者不会再被扣柴。
	for id: String in life:
		if life[id].state == "downed" and world.world_clock.elapsed_seconds >= float(_deadlines[id]):
			request_return([id])


## 物理空间唯一决定可救范围、AI路径和返回站位，渲染帧不查询碰撞。
func _physics_process(delta: float) -> void:
	# 1. 保存／恢复提交期间不与原子快照交错改变角色。
	if world.session.busy or world.session._boot_fault or world.session.main_menu.visible or _boss_busy:
		return
	if not world.session.local_authority:
		for id: String in life:
			_update_pose(id)
		return
	if not get_tree().paused:
		_update_ai(delta)
		for id: String in life:
			_valid[id] = _can_rescue(id)
			if not _valid[id]:
				progress[id] = 0.0
			_update_pose(id)
			if life[id].state == "downed" and (not _has_partner() or world.actor_registry.slots[id].source == "idle"):
				request_return([id])
		if _all_active_down() and (life.p1.state == "downed" or (_has_partner() and life.p2.state == "downed")):
			request_return(_active_ids())
		_retry_age -= delta
	# 2. 活着的同伴可以腾位置；全倒暂停时仅由明确重试再次搜索。
	if _retry_requested or (not get_tree().paused and _retry_age <= 0 and _has_pending_return()):
		_retry_requested = false
		_retry_age = 1.0
		_attempt_returns()


## 仅真实可见近距站立搭档可以救援，移动／菜单／射击动作都会中断。
func _can_rescue(id: String) -> bool:
	# 1. 同屋墙体和门使用真实射线，人物胶囊自身从查询中排除。
	if not can_act(id) or life[peer(id)].state != "downed" or not _has_partner():
		return false
	var actor: CharacterBody3D = body(id)
	var target: CharacterBody3D = body(peer(id))
	if actor.global_position.distance_to(target.global_position) > 2.0 or actor.horizontal_speed > .05 or _movement_requested(id) or weapon(id).reloading() or weapon(id)._pending_fire:
		return false
	var endpoint: Node = world.input_router if id == "p1" else world.secondary_context.input_router
	if world.actor_registry.slots[id].source == "local" and not endpoint.allows_gameplay_input():
		return false
	var query := PhysicsRayQueryParameters3D.create(actor.global_position + Vector3.UP * .9, target.global_position + Vector3.UP * .45, 1, [actor.get_rid(), target.get_rid()])
	return world.get_world_3d().direct_space_state.intersect_ray(query).is_empty() and _stand_clear(target.global_position, [target.get_rid()])


## 看输入意图而不只看位移，顶住墙时按移动也不能继续施救。
func _movement_requested(id: String) -> bool:
	# 1. P1单人使用原动作，双人和AI使用各自真实外部方向。
	if id == "p1" and not world.local_controls.active:
		return not Input.get_vector("move_left", "move_right", "move_forward", "move_back").is_zero_approx()
	return not body(id)._external_direction.is_zero_approx()


## 完成救援只恢复目标暖意与保护，不创造柴火或弹药。
func _revive(id: String, rescuer: String) -> void:
	# 1. 状态先提交为站立，随后同帧再次回调也无法重复救起。
	if life[id].state != "downed":
		return
	life[id] = standing_life()
	model(id).reset_failure(50.0)
	model(id).protection_until = world.world_clock.elapsed_seconds + 10.0
	_deadlines.erase(id)
	_unfreeze_actor(id)
	release(rescuer)
	rescue_count += 1
	_stop_ai()
	world.session._notice(id.to_upper() + " 已被救起 · 暖意50 · 保护10秒")
	life_changed.emit()


## 一批返回先完成全部空间查询，再一次提交移动、恢复与扣柴。
func _attempt_returns() -> void:
	if is_instance_valid(world.journey) and world.journey.ending_pending():
		settle_victory()
		return
	# 1. Boss重试恢复完整入场世界，由会话层做语义与物理预检。
	var ids: Array = []
	for id: String in life:
		if life[id].state == "return_pending":
			ids.append(id)
	if ids.is_empty():
		return
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.handle_returns(ids):
		return
	if not boss_checkpoint.is_empty():
		_boss_busy = true
		world.session.retry_boss_entry()
		return
	var positions: Dictionary = _return_positions(ids)
	if positions.size() != ids.size():
		return_blocked = true
		if _all_active_down():
			world.set_session_paused(true)
		world.session._notice("安全屋室内站位受阻 · 尚未移动或扣柴，请腾出位置后重试")
		life_changed.emit()
		return
	# 2. 查询全部通过后，扣损与恢复只随状态的一次转移发生。
	var losses: Array[String] = []
	for id: String in ids:
		var actor: CharacterBody3D = body(id)
		var survival: Node = model(id)
		var lost: int = floori(survival.carried * .2)
		survival.carried -= lost
		losses.append(id.to_upper() + "返回，损失%d根柴火" % lost)
		survival.reset_failure(100.0)
		survival.protection_until = world.world_clock.elapsed_seconds + 10.0
		actor.global_position = positions[id]
		actor.velocity = Vector3.ZERO
		actor.horizontal_speed = 0
		actor._phase = 0
		actor.get_node("FootstepEmitter").reset_tracking()
		life[id] = standing_life()
		_deadlines.erase(id)
		_unfreeze_actor(id)
		survival.last_thermal = survival.thermal_at(actor.global_position)
		return_count += 1
	world.actor_registry.returning_home = false if "p2" in ids else world.actor_registry.returning_home
	if "p2" in ids and world.actor_registry.slots.p2.source == "idle":
		world.actor_registry.standby_reached = false
		world.actor_registry.returning_home = true
		body("p2").get_node("NavigationAgent3D").target_position = world.actor_registry.home
	if "p1" in ids:
		world.session._skip_entry = &"house.safe"
	world.regions.update_regions()
	world.interior.sync_rooms()
	for binding: Dictionary in world.view_manager.views.values():
		binding.rig.snap_to_actor()
	return_blocked = false
	_stop_ai()
	last_return_notice = "；".join(losses) + " · 暖意100／保护10秒"
	world.session._notice(last_return_notice)
	life_changed.emit()
	returned.emit(ids)


## 使用多处真实室内站位，不把传送目标放到家具或另一个人身上。
func _return_positions(ids: Array) -> Dictionary:
	# 1. 本批返回者的旧胶囊排除，存活同伴与实际家具仍参与碰撞。
	var excluded: Array[RID] = []
	for id: String in ids:
		excluded.append(body(id).get_rid())
	var result: Dictionary = {}
	var cabin: Node3D = world.landmarks.safe_cabin
	for id: String in ids:
		for z: float in [0.0, .7, -.7, 1.4, -1.4, 2.1, -2.1]:
			for x: float in [0.0, .7, -.7, 1.4, -1.4, 2.1, -2.1]:
				var at: Vector3 = cabin.to_global(Vector3(x, float(cabin.manifest.floor_y) + .04, z))
				if not cabin.contains_interior(at) or not _stand_clear(at, excluded):
					continue
				var separate := true
				for reserved: Vector3 in result.values():
					if reserved.distance_to(at) < .65:
						separate = false
				if separate:
					result[id] = at
					break
			if result.has(id):
				break
	return result


## 首胜先救起倒地者；空间查询全部通过后才提交，胜利返回不扣柴。
func settle_victory() -> bool:
	var positions: Dictionary = {}
	var fallback: Array = []
	for id: String in life:
		if can_act(id): continue
		if _stand_clear(body(id).global_position,[body(id).get_rid()]):
			positions[id] = body(id).global_position
		else: fallback.append(id)
	var homes := _return_positions(fallback)
	if homes.size()!=fallback.size():
		var newly_blocked: bool = not return_blocked
		return_blocked = true
		if _all_active_down(): world.set_session_paused(true)
		if newly_blocked: life_changed.emit()
		return false
	positions.merge(homes)
	for id: String in positions:
		life[id] = standing_life()
		_deadlines.erase(id)
		model(id).reset_failure(100 if id in fallback else 50)
		model(id).protection_until = world.world_clock.elapsed_seconds+10
		if id in fallback:
			body(id).global_position = positions[id]
			body(id).get_node("FootstepEmitter").reset_tracking()
			if id=="p1": world.session._skip_entry = &"house.safe"
		_unfreeze_actor(id)
		model(id).last_thermal = model(id).thermal_at(body(id).global_position)
	for id: String in life: release(id)
	_stop_ai()
	return_blocked = false
	_retry_requested = false
	if not positions.is_empty():
		world.regions.update_regions()
		world.interior.sync_rooms()
		life_changed.emit()
	return true


## 返回使用站立胶囊与脚下支撑，不关闭碰撞来制造成功。
func _stand_clear(at: Vector3, excluded: Array[RID]) -> bool:
	# 1. 胶囊略微缩小只容忍地板接触，墙、门和家具仍阻挡。
	var shape := CapsuleShape3D.new()
	shape.radius = .28
	shape.height = 1.46
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * .75)
	query.collision_mask = 1
	query.exclude = excluded
	query.margin = 0
	var space := world.get_world_3d().direct_space_state
	if not space.intersect_shape(query, 1).is_empty():
		return false
	return not space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * .15, at - Vector3.UP * .4, 1, excluded)).is_empty()


## AI救援暂时独占原伙伴导航意图，不让散步和施救同时驱动实体。
func _update_ai(delta: float) -> void:
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.status=="fighting":
		world.boss_encounter.drive_ai(delta)
		return
	# 1. 仅启用的AI可自动救P1；待命或真人P2不读取AI意图。
	if world.actor_registry.slots.p2.source != "ai" or not can_act("p2") or life.p1.state != "downed":
		_stop_ai()
		return
	var controller: Node = world.snowball_game.controller
	var agent: NavigationAgent3D = body("p2").get_node("NavigationAgent3D")
	if not _ai_owned:
		_ai_owned = true
		_ai_enabled_before = controller.enabled
		_ai_processing_before = controller.is_physics_processing()
		_ai_avoidance_before = agent.avoidance_enabled
		controller.set_enabled(false)
		controller.set_physics_process(false)
		agent.avoidance_enabled = false
		_ai_repath = 0
		_ai_stall = 0
	_ai_repath -= delta
	# 2. 靠近后先停止实际动作，再由同一距离／视线接口累积三秒。
	var sight := PhysicsRayQueryParameters3D.create(body("p2").global_position + Vector3.UP * .9, body("p1").global_position + Vector3.UP * .45, 1, [body("p1").get_rid(), body("p2").get_rid()])
	if body("p2").global_position.distance_to(body("p1").global_position) <= 1.5 and world.get_world_3d().direct_space_state.intersect_ray(sight).is_empty():
		body("p2").set_external_direction(Vector3.ZERO)
		_held.p2 = true
		ai_status = "AI已靠近，正在尝试救援"
		return
	_held.p2 = false
	if is_instance_valid(world.events) and world.events.drive_ai(body("p1").global_position,delta):
		ai_status = world.guard.status
		return
	if NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) == 0:
		return
	if _ai_repath <= 0:
		agent.target_position = body("p1").global_position
		_ai_repath = .4
	var next := agent.get_next_path_position()
	if is_instance_valid(world.guard):
		world.guard.open_path_door(next)
	var direction: Vector3 = (next - body("p2").global_position) * Vector3(1, 0, 1)
	body("p2").set_external_direction(direction if not agent.is_navigation_finished() else Vector3.ZERO)
	_ai_stall = _ai_stall + delta if body("p2").horizontal_speed < .08 else 0.0
	# 3. 导航只能抵达室外近似终点时也明确提示受阻，不能用仍在行走掩盖不可达。
	ai_status = "AI路径受阻，仍在尝试" if not agent.is_target_reachable() or _ai_stall > 2.0 or agent.is_navigation_finished() else "AI正在沿可达路线赶来"


## 释放救援控制后恢复原控制来源，不自动开启护卫或替AI创造弹药。
func _stop_ai() -> void:
	# 1. 关闭AI／读档时也必须释放避让回调，防止旧路径残留。
	if not _ai_owned:
		return
	_ai_owned = false
	ai_status = ""
	body("p2").set_external_direction(Vector3.ZERO)
	var agent: NavigationAgent3D = body("p2").get_node("NavigationAgent3D")
	var still_ai: bool = world.actor_registry.slots.p2.source == "ai" and can_act("p2")
	world.snowball_game.controller.set_enabled(_ai_enabled_before and still_ai)
	world.snowball_game.controller.set_physics_process(_ai_processing_before and still_ai)
	agent.avoidance_enabled = _ai_avoidance_before and still_ai
	release("p2")


## 完整恢复持续生命状态，临时施救进度、旧按钮和导航请求全部清空。
func restore_state(actors: Dictionary, checkpoint: Dictionary) -> void:
	# 1. 原子恢复期间角色控制来源仍由当前本地主菜单选择决定。
	_stop_ai()
	boss_checkpoint = checkpoint.duplicate(true)
	return_blocked = false
	last_return_notice = ""
	_retry_requested = false
	_boss_busy = false
	_deadlines.clear()
	for id: String in ["p1", "p2"]:
		life[id] = actors[id].life.duplicate(true)
		model(id).warmth = actors[id].warmth
		model(id).failure_latched = not can_act(id)
		release(id)
		_shot_serials[id] = weapon(id).shots_fired
		if life[id].state == "downed":
			_deadlines[id] = world.world_clock.elapsed_seconds + float(life[id].remaining)
		if can_act(id):
			_unfreeze_actor(id)
		else:
			_freeze_actor(id)
	life_changed.emit()


## 从原菜单切来源时清掉施救，不变更持续库存或倒地剩余时间。
func _mode_changed(_mode: String, _epoch: int) -> void:
	# 1. 关闭AI不能留下仍在赶路的救援控制器。
	_stop_ai()
	for id: String in life:
		release(id)
	# 2. 主菜单读入倒地P2后再启用AI，也必须撤销刚开启的散步控制。
	if not can_act("p2") and world.actor_registry.slots.p2.source == "ai":
		_freeze_actor("p2")


## 倒地／返回中立即撤销角色动作，外观与碰撞交给V3实体适配。
func _freeze_actor(id: String) -> void:
	# 1. 关闭本人菜单不冻结另一个人的输入。
	if id == "p2" and world.actor_registry.slots.p2.source == "ai":
		if not _p2_control_suppressed:
			_p2_enabled_before_down = _ai_enabled_before if _ai_owned else world.snowball_game.controller.enabled
			_p2_processing_before_down = _ai_processing_before if _ai_owned else world.snowball_game.controller.is_physics_processing()
			_p2_avoidance_before_down = _ai_avoidance_before if _ai_owned else body("p2").get_node("NavigationAgent3D").avoidance_enabled
			_p2_control_suppressed = true
		world.snowball_game.controller.set_enabled(false)
	world.local_controls.clear_actor(id)
	model(id).close_session()
	model(id)._interact_pending = false
	model(id).interaction_closed.emit()
	if id == "p1":
		world.survival_ui.close()
	weapon(id).cancel_reload()
	weapon(id)._pending_fire = false
	body(id).set_meta("life_blocked", true)
	body(id).velocity = Vector3.ZERO
	body(id).horizontal_speed = 0
	_update_pose(id)


## 恢复后仍使用原身体和装备，脚底采样不跨位置拖拽。
func _unfreeze_actor(id: String) -> void:
	# 1. 装填在倒地时已取消，不额外补发膛内弹。
	body(id).set_meta("life_blocked", false)
	_update_pose(id)
	body(id)._visual.reset_session_pose()
	body(id).get_node("FootstepEmitter").reset_tracking()
	if id == "p2" and _p2_control_suppressed:
		if world.actor_registry.slots.p2.source == "ai":
			world.snowball_game.controller.set_enabled(_p2_enabled_before_down)
			world.snowball_game.controller.set_physics_process(_p2_processing_before_down)
			body("p2").get_node("NavigationAgent3D").avoidance_enabled = _p2_avoidance_before_down
		_p2_control_suppressed = false


## 倒地与施救是完整姿态，不能继续叠加持枪或行走动画。
func _update_pose(id: String) -> void:
	# 1. 两种控制来源共用现有蒙皮，P2在单人时仍隐藏枪械。
	var spectator: bool = is_instance_valid(world.boss_encounter) and id in world.boss_encounter.retired
	var clip := "" if spectator else ("Downed" if not can_act(id) else ("Rescue" if progress[id] > 0 else ""))
	if clip == "Rescue":
		var toward: Vector3 = body(peer(id)).global_position - body(id).global_position
		body(id)._visual.rotation.y = atan2(toward.x, toward.z)
	body(id)._visual.set_life_pose(clip)
	weapon(id).visible = clip.is_empty() and not world.snowball_game.participating and (id == "p1" or world.local_controls.active or world.actor_registry.slots.p2.source == "ai")


## 固定角色访问只指向真实世界能力，避免缓存另一份物资。
func body(id: String) -> CharacterBody3D:
	return world.actor_registry.slots[id].body


## 获取本人的真实冷暖与行囊。
func model(id: String) -> Node:
	return world.survival if id == "p1" else world.secondary_context.survival


## 获取本人的实际枪械。
func weapon(id: String) -> Node3D:
	return world.rifle if id == "p1" else world.secondary_context.rifle


## 固定双角色只有一个伙伴，不随昵称或设备变化。
func peer(id: String) -> String:
	return "p2" if id == "p1" else "p1"


## M8可提交受固定角色来源与交接代次约束的救援意图，当前不建立网络连接。
func set_rescue_intent(id: String, held: bool, source: String, epoch: int) -> bool:
	# 1. 客人不能本地结算，过期来源不能接管已经交接的角色。
	if not world.session.local_authority or not world.actor_registry.accepts_intent(id, source, epoch):
		return false
	if held:
		return interact_pressed(id)
	release(id)
	return true


## 只有启用的真人／AI角色可以提供救援。
func _has_partner() -> bool:
	return world.actor_registry.slots.p2.source in ["local", "ai", "remote"]


## 当前活动角色集合用于全倒判断，关闭AI的待命伙伴不参与。
func _active_ids() -> Array:
	return ["p1", "p2"] if _has_partner() else ["p1"]


## 全倒不等待满60秒，转入共同返回或Boss场外重试。
func _all_active_down() -> bool:
	for id: String in _active_ids():
		if can_act(id):
			return false
	return true


## 待返回事务由物理帧明确重试，已恢复角色不再参加扣损。
func _has_pending_return() -> bool:
	for row: Dictionary in life.values():
		if row.state == "return_pending":
			return true
	return false
