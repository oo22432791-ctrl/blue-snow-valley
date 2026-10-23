extends "res://scripts/gameplay/snowball_game.gd"
## M13主动雪球活动：继承原命中计分，局部适配山谷、装备和会话生命周期。

const CLEARING := preload("res://scripts/world/valley_layout.gd").SNOWBALL_CLEARING
const COMPANION := preload("res://scenes/characters/valley_snow_companion.tscn")
const WANDER := preload("res://scripts/ai/valley_snow_companion.gd")
const VALLEY_BALL := preload("res://scripts/gameplay/valley_snowball.gd")
const TARGET_ID: String = "activity.snowball"
const NAVIGATION = preload("res://assets/environment/v2/snowball_navigation.res")
var navigation_map := RID()
var navigation_region: NavigationRegion3D
var participating: bool = false
var previous_equipment: int = 2
var rounds_started: int = 0
var exits: int = 0
var last_exit: String = ""
var controller: Node
var _exit: Button
var _throw_screen := Vector2.INF
var _requested_restart: bool = false
var _requested_exit: bool = false
var _clothes: Dictionary = {}
var _bounds: MultiMeshInstance3D


## 装配第一版电脑原造型，默认只散步，不开启计分或投球。
func _ready() -> void:
	# 1. 人物使用V2步态与雪面，原始GLB及Blender源不变。
	player = world.player; camera = world.camera_rig.camera; snow_surface = world.snow_surface
	# 离线局部导航使用独立地图，避免与主路网格重叠或修改原路线。
	navigation_map = NavigationServer3D.map_create(); NavigationServer3D.map_set_active(navigation_map,true)
	NavigationServer3D.map_set_cell_size(navigation_map,.2); NavigationServer3D.map_set_cell_height(navigation_map,.1)
	navigation_region = NavigationRegion3D.new(); navigation_region.set_navigation_map(navigation_map); navigation_region.navigation_mesh = NAVIGATION; add_child(navigation_region)
	companion = _create_companion(); companion.name = "SnowCompanion"
	companion.position = Vector3(-94, world.terrain.get_ground_height(Vector2(-94, 160)) + 0.04, 160)
	companion.snow_surface = snow_surface; add_child(companion)
	companion.get_node("NavigationAgent3D").set_navigation_map(navigation_map)
	controller = WANDER.new(); controller.activity = self; controller.player = player
	controller.process_physics_priority = -10; companion.add_child(controller)
	companion.get_node("FootstepEmitter").foot_landed.connect(world._on_foot_landed)
	companion.get_node("FootstepEmitter").foot_dragged.connect(world.snow_tracks.on_foot_dragged)
	world.register_world_object(&"actor.snow_companion", companion)
	_bind_clothes(companion)
	# 2. 复用命中反馈池和瞄准圈，计分界面由本类替换。
	round_active = false
	super._ready()
	_create_bounds()
	_canvas.visible = false
	world.survival.targets[TARGET_ID] = {"id":TARGET_ID,"site":"","name":"雪球伙伴","kind":"snowball","position":companion.position + Vector3.UP * 0.9,"reach":2.1}
	world.input_router.primary_requested.connect(_request_primary)
	world.survival.failed.connect(func(_reason: StringName) -> void: end_activity("failure"))
	world.interior.entered.connect(func(_id: StringName) -> void: end_activity("shelter"))
	apply_environment_palette(world._current_palette)


## 默认装配原伙伴场景，扩展版本可提供不同骨架的同槽位实体。
func _create_companion() -> CharacterBody3D:
	# 1. 默认仍装配原伙伴，扩展版本可以替换可编辑角色场景。
	return COMPANION.instantiate()


## 原模型只在当前实例复制语义材质，冬衣与玩家区分。
func _bind_clothes(node: Node) -> void:
	# 1. 原导入资源只读，换色不影响第一版或其他人物实例。
	if node is MeshInstance3D:
		for index in range(node.mesh.get_surface_count()):
			var source: Material = node.mesh.surface_get_material(index)
			if source == null: continue
			var key := String(source.resource_name)
			# 动态手持雪球没有语义材质名，保留其原白色，不送入冬衣调色表。
			if key.is_empty(): continue
			if not _clothes.has(key):
				var material := StandardMaterial3D.new(); material.roughness = 0.9; _clothes[key] = material
			node.set_surface_override_material(index, _clothes[key])
	# 2. 每个语义颜色在昼夜变化时统一更新。
	for child: Node in node.get_children(): _bind_clothes(child)


## 伙伴用灰绿冬衣和浅褐围巾，与玩家蓝衣区分且沿用场景昼夜光照。
func apply_environment_palette(palette: Resource) -> void:
	# 1. 只有本活动自己的材质，不能改写世界角色共享调色表。
	for key: String in _clothes:
		var color: Color = Color("d6d7dc") if key == "skin" else palette.get(key)
		if key == "coat": color = Color("526f68")
		if key == "scarf": color = Color("b69a72")
		_clothes[key].albedo_color = color
	# 2. 尚未初始化反馈池时只更新人物颜色。
	if is_instance_valid(_feedback): apply_palette(palette.snow)


## GUI请求在生存模块物理帧通过单次令牌后才允许开局。
func start_match() -> bool:
	# 1. 不允许远程、过期、失败、暂停或探索脚本直接绕过交互。
	if participating or get_tree().paused or world.survival.failure_latched: return false
	if not enabled or not _focused or not world.input_router._focused: return false
	if world.input_router.context != world.input_router.Context.UI or world.survival._session_id != TARGET_ID: return false
	if not world.survival.target_accessible(TARGET_ID) or not _inside(): return false
	# 2. 保存进入前装备，清理未完成装填和待发枪械，临时锁定雪球。
	previous_equipment = world.rifle.equipped
	world.rifle.cancel_reload(); world.rifle._pending_fire = false; world.rifle.view.reset_feedback()
	world.survival_ui.close(); world.rifle.equipped = 1
	participating = true; _canvas.visible = true
	_bounds.show()
	world.input_router.set_context(world.input_router.Context.SNOWBALL)
	restart_round()
	return true


## 暂停恢复保留比赛；退出统一清理在途球、计时、按钮请求并恢复原装备。
func end_activity(reason: String = "button", restore_equipment: bool = true) -> void:
	# 1. 即使没有比赛，读档也撤销可能仍排队的旧UI和鼠标请求。
	_throw_screen = Vector2.INF; _requested_restart = false; _requested_exit = false
	if not participating: return
	participating = false; round_active = false; _clear_projectiles()
	_feedback.set_feedback(false, false); _marker.hide(); _canvas.hide()
	_bounds.hide()
	player_score = 0; npc_score = 0; winner = ""; _cooldown = 0; _ai_remaining = 0
	last_exit = reason; exits += 1
	# 2. 读档已提交保存装备，不允许活动旧装备覆盖新快照。
	if restore_equipment: world.rifle.equipped = previous_equipment
	world._resume_context = world.input_router.Context.EXPLORATION
	if not get_tree().paused: world.input_router.set_context(world.input_router.Context.EXPLORATION)
	if reason == "boundary": world.rifle.notice("已离开雪球空地 · 恢复探索")
	_update_interface()


## 回合内重开保留真实站位与脚印，所有重开必须在活动区内。
func restart_round() -> void:
	# 1. 暂停或探索状态下的旧按钮不能新开回合。
	if not participating or not _can_play() or not _inside(): return
	_throw_screen = Vector2.INF
	_feedback.set_feedback(true, true)
	super.restart_round(); rounds_started += 1


## 调试关闭活动也走完整退出，不使用第一版专有的脚步音频节点字段。
func set_enabled(value: bool) -> void:
	# 1. 关闭清理比赛与装备；恢复只允许重新主动开局。
	if not value: end_activity("disabled")
	enabled = value
	if is_instance_valid(_feedback): _feedback.set_feedback(value,value)


## 暂停保留已出手雪球和已提交蓄手，但撤销尚未消费的鼠标及按钮点击。
func set_paused(value: bool) -> void:
	# 1. 与枪械一致，暂停菜单点击不带回游戏形成一次迟到的主操作。
	if value:
		_throw_screen = Vector2.INF; _requested_restart = false; _requested_exit = false
	# 2. 冻结命中声音尾部；物理与电脑计时由场景树冻结。
	for voice: AudioStreamPlayer3D in _feedback._voices: voice.stream_paused = value


## 球与电脑尝试沿用真实物理秒，不受调试世界钟加速影响。
func _physics_process(delta: float) -> void:
	# 1. 动态交互锚点跟随电脑；离场优先于旧点击、发球和计分。
	world.survival.targets[TARGET_ID].position = companion.global_position + Vector3.UP * 0.9
	if participating and not _inside(): end_activity("boundary"); return
	if _requested_exit: end_activity("button"); return
	if not _can_play(): return
	if _requested_restart: _requested_restart = false; restart_round()
	_update_aim(world._aim_screen if world._has_pointer else Vector2.INF)
	if _throw_screen.is_finite():
		var screen := _throw_screen; _throw_screen = Vector2.INF; _update_aim(screen)
		if aim_valid: request_throw(player, aim_position)
	if not round_active: return
	_cooldown = maxf(0, _cooldown - delta)
	# 2. 待出手请求先取出再生成球，同一请求只能产生一次实体。
	for index in range(_pending.size() - 1, -1, -1):
		_pending[index].delay -= delta
		if _pending[index].delay <= 0:
			var shot: Dictionary = _pending[index]; _pending.remove_at(index)
			if is_instance_valid(shot.actor): _launch(shot.actor, shot.target)
	# 3. 原电脑每4–7秒尝试，不追击；无遮挡且距离合适才投掷。
	_ai_remaining -= delta
	if _ai_remaining <= 0:
		ai_attempts += 1; _ai_remaining = _random.randf_range(4, 7)
		var distance := companion.global_position.distance_to(player.global_position)
		if distance >= 1.25 and distance <= 9.5 and _has_sight(companion, player):
			var target := player.global_position + Vector3(_random.randf_range(-0.45, 0.45), 0, _random.randf_range(-0.45, 0.45))
			request_throw(companion, target)


## 渲染只读取最近一次物理瞄准，暂停或探索时不显示比赛准星。
func _process(_delta: float) -> void:
	# 1. 射线只在物理帧查询，UI点击不会触发发球。
	_marker.visible = _can_play() and round_active and aim_valid
	if _marker.visible: _marker.global_position = aim_position + Vector3.UP * 0.025
	_canvas.visible = participating


## 统一路由只记录一次投掷点击，下一物理帧才校验并提交。
func _request_primary(screen: Vector2) -> void:
	# 1. 结束界面、GUI、暂停、失焦和探索均不能投球。
	if _can_play() and round_active: _throw_screen = screen


## 不再订阅第一版原始鼠标入口，所有主操作经过V2路由。
func _input(_event: InputEvent) -> void:
	# 1. V2世界保存真实鼠标事件位置，本模块只消费路由信号。
	pass


## Enter仅在本活动结束后重开，按钮仍由GUI优先消费。
func _unhandled_input(event: InputEvent) -> void:
	# 1. 排队到物理帧执行，避免输入回调中访问空间状态。
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ENTER and _can_play() and not round_active:
		_requested_restart = true; get_viewport().set_input_as_handled()


## 瞄准使用原相机真实碰撞查询，雪球目标只接受活动空地。
func _update_aim(mouse: Vector2 = Vector2.INF) -> void:
	# 1. 窗口外或无地面命中不保留旧准星。
	aim_valid = false
	if not mouse.is_finite() or not get_viewport().get_visible_rect().has_point(mouse): return
	var excluded: Array[RID] = [player.get_rid()]
	var hit: Dictionary = world.camera_rig.query_aim(mouse, excluded)
	if hit.is_empty(): return
	var target: Vector3 = hit.position
	if not CLEARING.has_point(Vector2(target.x, target.z)): return
	# 2. 水平射程与第一版一致，世界雪面高度单独重采样。
	var offset := Vector3(target.x - player.global_position.x, 0, target.z - player.global_position.z).limit_length(10)
	aim_position = player.global_position + offset
	aim_position.y = snow_surface.get_surface_height_at(aim_position)
	aim_valid = offset.length() >= 0.6


## 投掷沿用冷却、短蓄手和真实手套出手点，目标使用世界雪高。
func request_throw(actor: CharacterBody3D, target: Vector3) -> bool:
	# 1. 直接方法也必须通过比赛、焦点、数量和演员身份检查。
	if not _can_play() or not round_active or not actor.visible or actor not in [player, companion]: return false
	if _balls.size() + _pending.size() >= MAX_BALLS or (actor == player and _cooldown > 0): return false
	for shot: Dictionary in _pending:
		if shot.actor == actor: return false
	var offset := Vector3(target.x - actor.global_position.x, 0, target.z - actor.global_position.z)
	if offset.length() < 0.6: return false
	target = actor.global_position + offset.limit_length(10)
	if not CLEARING.has_point(Vector2(target.x, target.z)): return false
	target.y = snow_surface.get_surface_height_at(target)
	# 2. 静止演员面对投掷方向，移动时保留原控制与脚骨。
	if actor.horizontal_speed < 0.025: actor.get_node("Visual").rotation.y = atan2(offset.x, offset.z)
	actor.get_node("Visual").play_snow_action("Throw")
	_pending.append({"actor":actor,"target":target,"delay":THROW_DELAY})
	if actor == player: _cooldown = PLAYER_COOLDOWN
	return true


## 复用原物理球资源与抛物线，只替换V2雪面／边界脚本。
func _launch(actor: CharacterBody3D, target: Vector3) -> void:
	# 1. 球从真实手套出发，排除发射者，碰撞结算仍由原父类负责。
	var ball: RigidBody3D = BALL_SCENE.instantiate(); ball.set_script(VALLEY_BALL)
	ball.game = self; ball.thrower = actor; ball.position = actor.get_node("Visual").get_throw_position()
	ball.add_collision_exception_with(actor); add_child(ball)
	# 2. 与第一版相同的重力、速度和目标身体高度。
	var offset := target + Vector3.UP * 0.8 - ball.global_position
	var flight_time := clampf(Vector2(offset.x, offset.z).length() / 10, 0.16, 1)
	ball.linear_velocity = Vector3(offset.x / flight_time, offset.y / flight_time + 4.9 * flight_time, offset.z / flight_time)
	_balls.append(ball); launched_count += 1; ball_launched.emit(ball)


## 所有入口共用同一玩法许可，不让暂停或失败后的旧请求生效。
func _can_play() -> bool:
	# 1. 角色能移动与能投球都服从同一个输入上下文。
	return participating and enabled and _focused and world.input_router.allows_gameplay_input() and world.input_router.context == world.input_router.Context.SNOWBALL and not world.survival.failure_latched


## 玩家离开空地或进入任意小屋即退出，冷暖规则不变。
func _inside() -> bool:
	# 1. 以真实世界XZ和已有房间查询判断，不使用临时传送或隐形墙。
	return CLEARING.has_point(Vector2(player.global_position.x, player.global_position.z)) and world.interior.shelter_at(player.global_position).building_id == &""


## 读档前为非持久电脑选不占玩家位置的真实空地，保留所有实体碰撞校验。
func find_restore_point(player_at: Vector3) -> Vector3:
	# 1. 当前站位不冲突时保持原位；否则有限采样现有空地，不把电脑塞入屋内。
	if companion.position.distance_to(player_at) >= 1.25: return companion.position
	var shape := CapsuleShape3D.new(); shape.radius = .3; shape.height = 1.5
	var space := get_world_3d().direct_space_state
	for z: float in [157.0,161.0,165.0,169.0]:
		for x: float in [-96.5,-92.5,-88.5,-84.5,-80.5]:
			var at := Vector3(x,world.terrain.get_ground_height(Vector2(x,z))+.035,z)
			if at.distance_to(player_at) < 1.25: continue
			var query := PhysicsShapeQueryParameters3D.new(); query.shape = shape; query.transform = Transform3D(Basis.IDENTITY,at+Vector3.UP*.75)
			query.collision_mask = 1; query.exclude = [player.get_rid(),companion.get_rid()]; query.margin = 0
			if not space.intersect_shape(query,1).is_empty(): continue
			# 2. 胶囊和脚下支撑都有效才返回，找不到时由会话拒绝本次恢复。
			var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*.15,at-Vector3.UP*.4,1,[player.get_rid(),companion.get_rid()])
			if not space.intersect_ray(ray).is_empty(): return at
	return Vector3.INF


## 仅在会话完整验证成功后提交电脑站位，丢弃旧导航和足骨锚点。
func restore_companion(at: Vector3) -> void:
	# 1. 不恢复比分、路径或电脑随机进度；电脑不是持久世界库存。
	companion.position = at; companion.velocity = Vector3.ZERO; companion.horizontal_speed = 0
	controller.set_enabled(controller.enabled)
	companion.get_node("FootstepEmitter").reset_tracking(); companion._visual.reset_session_pose()
	world.survival.targets[TARGET_ID].position = at + Vector3.UP*.9


## 比赛期间显示少量浅色虚线，让立即离场的边界可见，不添加永久围栏。
func _create_bounds() -> void:
	# 1. 一个有界MultiMesh绘制72个短标记，探索时完全隐藏且没有碰撞。
	_bounds = MultiMeshInstance3D.new(); _bounds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := BoxMesh.new(); mesh.size = Vector3(.48,.025,.055)
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; material.albedo_color = Color("bad5ee"); mesh.material = material
	var batch := MultiMesh.new(); batch.transform_format = MultiMesh.TRANSFORM_3D; batch.mesh = mesh; batch.instance_count = 72
	var index := 0
	for edge in range(4):
		var count := 20 if edge < 2 else 16
		for i in range(count):
			var at := Vector3(CLEARING.position.x+i+.5,0,CLEARING.position.y if edge==0 else CLEARING.end.y) if edge<2 else Vector3(CLEARING.position.x if edge==2 else CLEARING.end.x,0,CLEARING.position.y+i+.5)
			at.y = snow_surface.get_surface_height_at(at)+.018
			batch.set_instance_transform(index,Transform3D(Basis(Vector3.UP,0 if edge<2 else PI/2),at)); index += 1
	_bounds.multimesh = batch; add_child(_bounds); _bounds.hide()


## 计分面板占用原枪械HUD位置，活动结束仍可重开或退出。
func _create_interface() -> void:
	# 1. 所有按钮只排队，控件拦截点击不传给玩法。
	_canvas = CanvasLayer.new(); _canvas.layer = 5; add_child(_canvas)
	var panel := PanelContainer.new(); panel.position = Vector2(1020, 22); panel.custom_minimum_size = Vector2(390, 0); _canvas.add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["margin_left","margin_right","margin_top","margin_bottom"]: margin.add_theme_constant_override(side, 14)
	panel.add_child(margin)
	var column := VBoxContainer.new(); column.add_theme_constant_override("separation", 10); margin.add_child(column)
	_score = Label.new(); _score.add_theme_font_size_override("font_size", 25); column.add_child(_score)
	_hint = Label.new(); _hint.add_theme_font_size_override("font_size", 19); column.add_child(_hint)
	_result = Label.new(); _result.add_theme_font_size_override("font_size", 21); column.add_child(_result)
	_restart = Button.new(); _restart.text = "再玩一局（Enter）"; _restart.custom_minimum_size.y = 44; _restart.focus_mode = Control.FOCUS_NONE
	_restart.pressed.connect(func() -> void: if _can_play(): _requested_restart = true)
	column.add_child(_restart)
	_exit = Button.new(); _exit.text = "退出比赛"; _exit.custom_minimum_size.y = 44; _exit.focus_mode = Control.FOCUS_NONE
	_exit.pressed.connect(func() -> void: if _can_play(): _requested_exit = true)
	column.add_child(_exit); _update_interface()


## 只在回合状态变化时更新比分，不向探索显示持续比分。
func _update_interface() -> void:
	# 1. 回合结束不冻结移动，玩家仍可退出活动回安全屋取暖。
	if not is_instance_valid(_score): return
	_score.text = "你  %d : %d  伙伴" % [player_score, npc_score]
	_hint.text = "鼠标瞄准 · 左键投掷\n先到5分 · 仍可走跑\n离开空地即退出 · 冷暖照常"
	_result.text = "你先到5分，赢啦" if winner == "player" else "伙伴先到5分啦"
	_result.visible = participating and not round_active; _restart.visible = participating and not round_active


## 失焦取消未消费点击并冻结在途球，恢复后等待新输入。
func _notification(what: int) -> void:
	# 1. 原父类负责每个球保存与恢复实际速度。
	super._notification(what)
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_throw_screen = Vector2.INF; _requested_restart = false; _requested_exit = false


## 场景结束释放独立地图，避免多次进入山谷积累服务器RID。
func _exit_tree() -> void:
	# 1. 先断开地区再释放地图，父类反馈池自行停止音频。
	if navigation_map.is_valid():
		if is_instance_valid(navigation_region): NavigationServer3D.region_set_map(navigation_region.get_rid(),RID())
		NavigationServer3D.free_rid(navigation_map)
