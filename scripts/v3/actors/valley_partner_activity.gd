extends "res://scripts/gameplay/valley_snowball_game.gd"
## V3固定P2使用已有十一骨骼探索者模型，沿用伙伴配色与活动生命周期。

const PARTNER = preload("res://scenes/v3/valley_partner.tscn")
const MATCH_UI = preload("res://scripts/v3/views/valley_snowball_ui.gd")
var previous_equipment_p2: int = 2
var invitation: Dictionary = {}
var _answer: Dictionary = {}
var _p2_throw: bool = false
var _p2_cycle: bool = false
var _p2_locked: bool = false
var _p2_cooldown: float = 0
var _invitation_serial: int = 0
var match_ui: CanvasLayer


## 腕骨和枪械动作来自原生GLB，不给旧七骨骼模型伪造握点。
func _create_companion() -> CharacterBody3D:
	# 1. P2仍只有一个实体；模式切换不会再次创建人物。
	return PARTNER.instantiate()


## 固定P2读档由会话逐角色验真实胶囊，不把高架P1附近再塞一个临时NPC。
func find_restore_point(near: Vector3) -> Vector3:
	# 1. 仅冻结预检期间返回待验P2位置，后续附加预检仍验证墙体与支撑。
	if is_instance_valid(world.session) and world.session.preflight_actor_position.is_finite():
		return world.session.preflight_actor_position
	return super.find_restore_point(near)


## 保留原生抛物线、雪面碰撞与计分，只扩展双角色会话和输入。
func _ready() -> void:
	# 1. 父类负责唯一P2、音效和场地；P2输入在其上下文装配后绑定。
	super._ready()
	call_deferred("_bind_secondary")


## 两人用自己的主操作投掷，枪械仍自行拒绝小游戏上下文。
func _bind_secondary() -> void:
	world.secondary_context.input_router.primary_requested.connect(func(_point: Vector2) -> void: _p2_throw = participating and world.local_controls.active)


## 旧单人入口也经过明确主动邀请，不自动开局。
func start_match() -> bool:
	return invite("p1")


## GUI／伙伴菜单只排队邀请，接受后在物理帧重新校验场地和拥有权。
func invite(id: String) -> bool:
	# 1. 房主拥有世界规则；当前有效本地角色才可邀请。
	if id not in ["p1", "p2"] or not world.session.local_authority or get_tree().paused or world.session.busy or not _focused or not invitation.is_empty() or not _both_ready() or (participating and round_active):
		return false
	if world.actor_registry.slots[id].source != "local":
		return false
	if world.actor_registry.slots.p2.source not in ["ai","idle","local"]:
		return false
	if not participating and player.global_position.distance_to(companion.global_position) > 2:
		return false
	if world.local_controls.active:
		_invitation_serial += 1
		invitation = {"from":id,"to":"p2" if id == "p1" else "p1","epoch":world.actor_registry.ownership_epoch,"serial":_invitation_serial,"restart":participating}
		_close_actor_menus()
		_endpoint(invitation.to).set_context(world.input_router.Context.UI)
	else:
		_answer = {"auto":true,"epoch":world.actor_registry.ownership_epoch}
	return true


## 确认消息携带邀请序号，旧按钮或另一玩家不能替接收者同意。
func answer_invitation(id: String, accepted: bool) -> bool:
	if invitation.is_empty() or id != invitation.to or get_tree().paused or not _focused or world.actor_registry.slots[id].source != "local":
		return false
	_answer = {"actor":id,"accepted":accepted,"serial":invitation.serial,"epoch":invitation.epoch}
	return true


## P2确认／关闭键属于自己，不经过P1的GUI焦点。
func handle_owned_action(action: String) -> bool:
	# 1. 邀请优先于常规交互，比赛时Enter可发起重开，Backspace可退出。
	if not invitation.is_empty() and invitation.to == "p2":
		if action in ["confirm","close"]:
			answer_invitation("p2", action == "confirm")
		return true
	if not participating:
		return false
	if action == "close":
		request_exit("p2")
	elif action == "confirm" and not round_active:
		invite("p2")
	return action in ["close","confirm"]


## Tab／LB只选择对手，实际视线与前方锥在下一物理帧核验。
func cycle_secondary_target() -> void:
	_p2_cycle = participating and world.local_controls.active


## 任一参与者都能结束活动，暂停不能消费旧退出按钮。
func request_exit(id: String) -> void:
	if participating and id in ["p1","p2"] and not get_tree().paused and world.actor_registry.slots[id].source == "local":
		_requested_exit = true


## 开始和重开只清比赛状态，双方位置、暖意与真实库存保持原值。
func _start_round() -> void:
	world.guard.reset_transient_task()
	# 1. 首次入场记住两人各自装备，重开不能把临时雪球装备误存为原装备。
	if not participating:
		previous_equipment = world.rifle.equipped
		previous_equipment_p2 = world.secondary_context.rifle.equipped
	_close_actor_menus()
	participating = true
	round_active = true
	for id: String in ["p1","p2"]:
		var weapon: Node = world.rifle if id == "p1" else world.secondary_context.rifle
		var actor: CharacterBody3D = player if id == "p1" else companion
		weapon.cancel_reload()
		weapon._pending_fire = false
		weapon.equipped = 1
		weapon.view.reset_feedback()
		actor.set_external_direction(Vector3.ZERO)
		actor.velocity = Vector3.ZERO
		_endpoint(id).set_context(world.input_router.Context.SNOWBALL)
	_clear_projectiles()
	player_score = 0
	npc_score = 0
	winner = ""
	_cooldown = 0
	_p2_cooldown = 0
	_ai_remaining = _random.randf_range(4,7)
	_throw_screen = Vector2.INF
	_p2_throw = false
	_p2_locked = false
	world._resume_context = world.input_router.Context.SNOWBALL
	_bounds.show()
	_feedback.set_feedback(true,true)
	rounds_started += 1
	score_changed.emit(0,0)
	_update_interface()


## 旧重开方法也走真人双方同意，不能由遗留按钮直接清分。
func restart_round() -> void:
	if participating and not round_active:
		invite("p1")


## 保存、读档、失温和模式切换共用双方装备与投掷清理。
func end_activity(reason: String = "button", restore_equipment: bool = true) -> void:
	# 1. 即使尚未开局也撤销未接受邀请，避免跨读档的迟到同意。
	_cancel_invitation()
	_answer.clear()
	_p2_throw = false
	_p2_cycle = false
	_p2_locked = false
	var was_participating := participating
	super.end_activity(reason, restore_equipment)
	if not was_participating:
		return
	world.session._toast.position = Vector2(520,154)
	world.secondary_context.rifle._pending_fire = false
	world.secondary_context.rifle.cancel_reload()
	if restore_equipment:
		world.secondary_context.rifle.equipped = previous_equipment_p2
	world.secondary_context.selected_target = null
	world.secondary_context.input_router.set_context(world.input_router.Context.EXPLORATION)
	player._visual.clear_snow_actions()
	companion._visual.clear_snow_actions()


## 实际物理步依次处理危险、邀请、双方投掷和实体发射。
func _physics_process(delta: float) -> void:
	# 1. 启动时固定角色还未建立，不接受旧UI请求。
	if not is_instance_valid(world.actor_registry) or not is_instance_valid(world.rescue):
		return
	world.survival.targets[TARGET_ID].position = companion.global_position + Vector3.UP * .9
	if participating and (not _both_ready() or _danger_nearby()):
		end_activity("danger_or_boundary")
		return
	if _requested_exit:
		end_activity("button")
		return
	if not invitation.is_empty() and (not _both_ready() or invitation.epoch != world.actor_registry.ownership_epoch):
		_cancel_invitation()
	if not _answer.is_empty():
		var reply := _answer.duplicate()
		_answer.clear()
		if reply.get("epoch") == world.actor_registry.ownership_epoch and _both_ready():
			if reply.get("auto",false) and not world.local_controls.active:
				_start_round()
			elif not invitation.is_empty() and reply.get("serial") == invitation.serial and reply.get("actor") == invitation.to:
				var accept: bool = reply.accepted
				_cancel_invitation()
				if accept:
					_start_round()
	if not _can_play():
		return
	_cooldown = maxf(0,_cooldown-delta)
	_p2_cooldown = maxf(0,_p2_cooldown-delta)
	if _requested_restart:
		_requested_restart = false
		invite("p1")
	_update_aim(world._aim_screen if world._has_pointer else Vector2.INF)
	if _p2_cycle:
		_p2_cycle = false
		_p2_locked = _secondary_target_visible(true)
	if _p2_locked and not _secondary_target_visible(false):
		_p2_locked = false
	if _throw_screen.is_finite():
		var screen := _throw_screen
		_throw_screen = Vector2.INF
		_update_aim(screen)
		if aim_valid:
			request_throw(player, aim_position)
	if _p2_throw:
		_p2_throw = false
		var toward := Vector3(sin(world.secondary_context.aim_yaw),0,cos(world.secondary_context.aim_yaw))
		request_throw(companion, player.global_position if _p2_locked else companion.global_position+toward*10)
	# 2. 每个已提交请求只发射一次，原GLB手套锚点和真实重力球继续使用。
	for index in range(_pending.size()-1,-1,-1):
		_pending[index].delay -= delta
		if _pending[index].delay <= 0:
			var shot: Dictionary = _pending[index]
			_pending.remove_at(index)
			if is_instance_valid(shot.actor):
				_launch(shot.actor, shot.target)
	if round_active and not world.local_controls.active:
		_ai_remaining -= delta
		if _ai_remaining <= 0:
			_ai_remaining = _random.randf_range(4,7)
			ai_attempts += 1
			var distance := companion.global_position.distance_to(player.global_position)
			if distance >= 1.25 and distance <= 9.5 and _has_sight(companion,player):
				request_throw(companion, player.global_position + Vector3(_random.randf_range(-.45,.45),0,_random.randf_range(-.45,.45)))


## 双方冷却对称，目标在按下时固定，不以锁定状态代替碰撞命中。
func request_throw(actor: CharacterBody3D, target: Vector3) -> bool:
	if actor == companion and _p2_cooldown > 0:
		return false
	if not super.request_throw(actor,target):
		return false
	if actor == companion:
		_p2_cooldown = PLAYER_COOLDOWN
	return true


## 活动许可独立于P1是否打开某个菜单，世界暂停仍冻结双方。
func _can_play() -> bool:
	return participating and enabled and _focused and not get_tree().paused and is_instance_valid(world.rescue) and world.rescue.can_act("p1") and world.rescue.can_act("p2") and world.session.local_authority


## 开局和比赛全过程都要求双方实际处在空地，既不传送也不加隐形围墙。
func _both_ready() -> bool:
	if not is_instance_valid(world.rescue) or not world.rescue.can_act("p1") or not world.rescue.can_act("p2"):
		return false
	for actor: CharacterBody3D in [player,companion]:
		if not CLEARING.has_point(Vector2(actor.global_position.x,actor.global_position.z)) or world.interior.shelter_at(actor.global_position).building_id != &"":
			return false
	return true


## 只让实际正在威胁参与者且在10米内的熊打断活动。
func _danger_nearby() -> bool:
	for bear: CharacterBody3D in world.bears.bears:
		if bear.health > 0 and bear.state in [&"warning",&"chase",&"attack",&"recover"] and minf(bear.global_position.distance_to(player.global_position),bear.global_position.distance_to(companion.global_position)) <= 10:
			return true
	return false


## 辅助选择限10米、前方90度与实际遮挡，选择本身不投掷。
func _secondary_target_visible(check_cone: bool) -> bool:
	var offset := player.global_position - companion.global_position
	if offset.length() > 10:
		return false
	if check_cone and Vector3(sin(world.secondary_context.aim_yaw),0,cos(world.secondary_context.aim_yaw)).dot(Vector3(offset.x,0,offset.z).normalized()) < cos(PI/4):
		return false
	return _has_sight(companion,player)


## 单人Enter重开保留原习惯，同机Enter只属于P2，不替P1同意。
func _unhandled_input(event: InputEvent) -> void:
	if not world.local_controls.active:
		super._unhandled_input(event)


## 暂停不清回合，但清除尚未消费的投掷和确认边沿。
func set_paused(value: bool) -> void:
	super.set_paused(value)
	if value:
		_p2_throw = false
		_p2_cycle = false
		_answer.clear()


## 单屏和左右视图均由同一比赛状态驱动实际按钮。
func _create_interface() -> void:
	match_ui = MATCH_UI.new()
	match_ui.game = self
	match_ui.world = world
	_canvas = match_ui
	add_child(match_ui)


## 计分变化只通知界面，不创建另一份比分。
func _update_interface() -> void:
	if is_instance_valid(match_ui):
		match_ui.refresh()


## 根视图准星仍来自最近一次实际瞄准，菜单点击不会重新发球。
func _process(_delta: float) -> void:
	_marker.visible = _can_play() and round_active and aim_valid and world.input_router.drag_view.is_empty()
	if _marker.visible:
		_marker.global_position = aim_position + Vector3.UP * .025
	_canvas.visible = participating or not invitation.is_empty()
	if participating or not invitation.is_empty():
		world.session._toast.position = Vector2(24,get_viewport().get_visible_rect().size.y-38)


## 清邀请时只恢复接收者上下文，不影响正在进行的暂停或读档。
func _cancel_invitation() -> void:
	if not invitation.is_empty():
		var id: String = invitation.to
		invitation.clear()
		_endpoint(id).set_context(world.input_router.Context.SNOWBALL if participating else world.input_router.Context.EXPLORATION)
		if not participating:
			world.session._toast.position = Vector2(520,154)


## 开局前撤销双方伙伴菜单，避免其完成回调覆盖活动上下文。
func _close_actor_menus() -> void:
	world.survival_ui.close()
	for menu: CanvasLayer in world.local_controls.menus.values():
		if menu.opened:
			menu.close()
	world.survival.close_session()
	world.secondary_context.survival.close_session()


## 固定角色输入引用避免把P2确认当作P1鼠标按钮。
func _endpoint(id: String) -> Node:
	return world.input_router if id == "p1" else world.secondary_context.input_router
