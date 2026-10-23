extends Node3D
## 轻度计分玩雪：鼠标投掷、低频电脑尝试、先到5分；行走始终保留控制。

const BALL_SCENE = preload("res://scenes/effects/snowball.tscn")
const FEEDBACK = preload("res://scripts/gameplay/snowball_feedback.gd")
const WIN_SCORE := 5
const MAX_BALLS := 12
const THROW_DELAY := 0.18
const PLAYER_COOLDOWN := 0.8
const AIM_RECT := Rect2(-8.3, -8.1, 16.6, 15.4)
signal ball_launched(ball: RigidBody3D)
signal score_changed(player_score: int, npc_score: int)
signal round_finished(winner: String)
signal impact_resolved(body: Node, thrower: CharacterBody3D, at: Vector3)
var world: Node3D
var player: CharacterBody3D
var companion: CharacterBody3D
var camera: Camera3D
var snow_surface: Node3D
var enabled: bool = true
var round_active: bool = true
var player_score: int = 0
var npc_score: int = 0
var winner: String = ""
var aim_position := Vector3.ZERO
var aim_valid: bool = false
var launched_count: int = 0
var impact_count: int = 0
var ai_attempts: int = 0
var _focused: bool = true
var _ai_remaining: float = 5.0
var _cooldown: float = 0.0
var _pending: Array[Dictionary] = []
var _balls: Array[RigidBody3D] = []
var _random := RandomNumberGenerator.new()
var _feedback: Node3D
var _marker: MeshInstance3D
var _canvas: CanvasLayer
var _score: Label
var _hint: Label
var _result: Label
var _restart: Button
var _mouse_position := Vector2.INF


## 建立回合控件与轻量反馈，投掷处理排在角色骨骼采样之后。
func _ready() -> void:
	# 1. 独立随机源不会改变电脑散步路线。
	process_physics_priority = 10
	_random.randomize()
	_ai_remaining = _random.randf_range(4.0, 7.0)
	_feedback = FEEDBACK.new()
	add_child(_feedback)
	# 2. 小圆环只标记雪面瞄准位置，不参与碰撞或遮挡脚印。
	_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.155
	ring.outer_radius = 0.20
	ring.rings = 20
	ring.ring_segments = 6
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.8, 0.92, 1.0)
	ring.material = material
	_marker.mesh = ring
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.visible = false
	add_child(_marker)
	_create_interface()
	get_tree().root.mouse_exited.connect(_on_mouse_exited)


## 更新鼠标圆环；实际发射点在固定物理帧读取骨骼。
func _process(_delta: float) -> void:
	# 1. 结束一局仍能走路，但隐藏瞄准圈以表达停止投掷。
	_update_aim(_mouse_position)
	_marker.visible = enabled and round_active and _focused and aim_valid and not world.get("_capturing")
	if _marker.visible:
		_marker.global_position = aim_position + Vector3.UP * 0.025


## 处理短蓄手、冷却和低频电脑投掷，不改写角色移动意图。
func _physics_process(delta: float) -> void:
	# 1. 失焦或固定构图采集不推进任何投掷计时。
	if not enabled or not round_active or not _focused or world.get("_capturing") or world.get("_closing"):
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	# 2. 先删除已到期的请求，再出手，避免同一请求生成两次。
	for index in range(_pending.size() - 1, -1, -1):
		_pending[index].delay -= delta
		if _pending[index].delay <= 0.0:
			var shot: Dictionary = _pending[index]
			_pending.remove_at(index)
			if is_instance_valid(shot.actor) and shot.actor.visible:
				_launch(shot.actor, shot.target)
	# 3. 每4–7秒尝试一次，太远、太近或被建筑阻挡时本次不投，不追击玩家。
	if companion.visible:
		_ai_remaining -= delta
		if _ai_remaining <= 0.0:
			ai_attempts += 1
			_ai_remaining = _random.randf_range(4.0, 7.0)
			var distance := companion.position.distance_to(player.position)
			if distance >= 1.25 and distance <= 9.5 and _has_sight(companion, player):
				var target := player.global_position
				target.x += _random.randf_range(-0.45, 0.45)
				target.z += _random.randf_range(-0.45, 0.45)
				request_throw(companion, target)


## 记录真实鼠标事件的位置，供圆环与投掷共用。
func _input(event: InputEvent) -> void:
	# 1. 记录事件的视口坐标，让瞄准圈和点击使用同一套拉伸后的坐标。
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_mouse_position = event.position


## 鼠标离开窗口后不保留最后一个瞄准圈。
func _on_mouse_exited() -> void:
	# 1. 下次更新使用真实窗口外位置，回到窗口后由新移动事件重新定位。
	_mouse_position = Vector2.INF


## 只在界面未消耗的点击中发射，保持计分按钮与配色控件可用。
func _unhandled_input(event: InputEvent) -> void:
	# 1. 截图、关闭、失焦和禁用期间不接受新请求。
	if not enabled or not _focused or world.get("_capturing") or world.get("_closing"):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_update_aim(event.position)
		if aim_valid and request_throw(player, aim_position):
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ENTER and not round_active:
		restart_round()
		get_viewport().set_input_as_handled()


## 校验投掷请求并播放上身蓄手，目标在点击时确定，给对手躲开的时间。
func request_throw(actor: CharacterBody3D, target: Vector3) -> bool:
	# 1. 发射数量有界，玩家点按冷却0.8秒，按住鼠标不自动连发。
	if not enabled or not round_active or not _focused or not actor.visible or _balls.size() + _pending.size() >= MAX_BALLS:
		return false
	if actor != player and actor != companion:
		return false
	if actor == player and _cooldown > 0.0:
		return false
	for shot in _pending:
		if shot.actor == actor:
			return false
	# 2. 水平射程最多10米，近身零向量不产生不确定的速度。
	var offset := Vector3(target.x - actor.position.x, 0, target.z - actor.position.z)
	if offset.length() < 0.6:
		return false
	target = actor.global_position + offset.limit_length(10.0)
	target.y = snow_surface.get_height_at(target)
	if actor.horizontal_speed < 0.025:
		actor.get_node("Visual").rotation.y = atan2(offset.x, offset.z)
	actor.get_node("Visual").play_snow_action("Throw")
	_pending.append({"actor": actor, "target": target, "delay": THROW_DELAY})
	if actor == player:
		_cooldown = PLAYER_COOLDOWN
	return true


## 从实际手套位置发射带重力抛物线的球，球不与发射者碰撞。
func _launch(actor: CharacterBody3D, target: Vector3) -> void:
	# 1. 球体留在世界空间，绝不挂到正在移动的角色下面。
	var ball: RigidBody3D = BALL_SCENE.instantiate()
	ball.game = self
	ball.thrower = actor
	ball.position = actor.get_node("Visual").get_throw_position()
	ball.add_collision_exception_with(actor)
	add_child(ball)
	# 2. 目标取雪面上0.8米的身体位置；实际命中仍由物理接触决定。
	var offset := target + Vector3.UP * 0.8 - ball.global_position
	var distance := Vector2(offset.x, offset.z).length()
	var flight_time := clampf(distance / 10.0, 0.16, 1.0)
	ball.linear_velocity = Vector3(offset.x / flight_time, offset.y / flight_time + 4.9 * flight_time, offset.z / flight_time)
	_balls.append(ball)
	launched_count += 1
	ball_launched.emit(ball)


## 结算一次真实碰撞；环境命中只扬雪，角色命中才给投掷方加分。
func resolve_impact(ball: RigidBody3D, body: Node, at: Vector3) -> void:
	# 1. 先锁住此球，物理同帧的多接触与雪面检测不能重复计分。
	if ball.spent:
		return
	var actor_hit: bool = (body == player or body == companion) and body != ball.thrower and body.visible
	retire_ball(ball)
	impact_count += 1
	impact_resolved.emit(body, ball.thrower, at)
	_feedback.play_impact(at, actor_hit)
	if not round_active or not actor_hit:
		return
	# 2. 短受击只作用于上身，不清空输入、不击退、不减速。
	body.get_node("Visual").play_snow_action("Hit")
	if ball.thrower == player:
		player_score += 1
	else:
		npc_score += 1
	score_changed.emit(player_score, npc_score)
	# 3. 首个到5分的有效命中结束本局，随后取消在途球，避免胜负后继续加分。
	if player_score >= WIN_SCORE or npc_score >= WIN_SCORE:
		round_active = false
		winner = "player" if player_score >= WIN_SCORE else "npc"
		_clear_projectiles()
		round_finished.emit(winner)
		# 结束局面仍显示最后一次受击，不中断角色继续行走。
		body.get_node("Visual").play_snow_action("Hit")
	_update_interface()


## 安全回收实体，队列删除避免在物理接触回调中修改场景结构。
func retire_ball(ball: RigidBody3D) -> void:
	# 1. spent在queue_free之前设置，重复信号立即失效。
	if ball.spent:
		return
	ball.spent = true
	ball.visible = false
	ball.set_physics_process(false)
	_balls.erase(ball)
	ball.queue_free()


## 再来一局只清计分和在途雪球，保留站位、速度与30秒恢复中的脚印。
func restart_round() -> void:
	# 1. 清掉旧回合的动作和发射请求，避免新局突然收到旧球得分。
	_clear_projectiles()
	player_score = 0
	npc_score = 0
	winner = ""
	round_active = true
	_cooldown = 0.0
	_ai_remaining = _random.randf_range(4.0, 7.0)
	score_changed.emit(0, 0)
	_update_interface()


## 暂停电脑时取消其尚未出手与在途的球，不允许隐形角色继续攻击。
func on_companion_enabled(value: bool) -> void:
	# 1. 开关不清比分，也不改变玩家的在途球和操作。
	_ai_remaining = _random.randf_range(4.0, 7.0)
	if not value:
		_pending = _pending.filter(func(shot: Dictionary) -> bool: return shot.actor != companion)
		for ball in _balls.duplicate():
			if ball.thrower == companion:
				retire_ball(ball)
		companion.get_node("Visual").clear_snow_actions()
	_update_interface()


## 采集或旧功能回归时关闭本模块，普通试玩始终默认开启。
func set_enabled(value: bool) -> void:
	# 1. 关闭时清理在途球与动作，不改变已压实雪面或角色移动。
	enabled = value
	_canvas.visible = value
	_marker.visible = false
	if not value:
		_clear_projectiles()
		_feedback.set_feedback(false, false)
	else:
		_feedback.set_feedback(world.get("_footstep_audio").enabled, world.get("_snow_powder").enabled)


## 同步已有M/P开关，声音和粒子保留独立控制。
func set_feedback(sound: bool, powder: bool) -> void:
	# 1. 不修改落脚模块的计数或音频总线。
	_feedback.set_feedback(sound and enabled, powder and enabled)


## 将命中雪粉同步到当前昼夜雪色。
func apply_palette(color: Color) -> void:
	# 1. 使用现有冷蓝色关系，瞄准圈保持小面积明亮。
	_feedback.apply_color(color)
	_marker.mesh.material.albedo_color = color.lerp(Color.WHITE, 0.65)


## 求鼠标射线与可见雪面相交，圆环不会吸附到屋顶。
func _update_aim(mouse: Vector2 = Vector2.INF) -> void:
	# 1. 窗口外坐标、无地面交点、活动边界之外均不接受投掷。
	if not mouse.is_finite():
		mouse = get_viewport().get_mouse_position()
	aim_valid = false
	if not get_viewport().get_visible_rect().has_point(mouse):
		return
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var point: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if point == null or not AIM_RECT.has_point(Vector2(point.x, point.z)):
		return
	# 2. 再用一次实际雪高修正投影，避免瞄准圈埋进厚雪。
	var height: float = snow_surface.get_height_at(point)
	point = Plane(Vector3.UP, height).intersects_ray(origin, direction)
	if point == null:
		return
	var offset := Vector3(point.x - player.position.x, 0, point.z - player.position.z).limit_length(10.0)
	aim_position = player.global_position + offset
	aim_position.y = snow_surface.get_height_at(aim_position)
	aim_valid = offset.length() >= 0.6


## 电脑只在无遮挡时尝试投球，不计算追击或预判玩家未来位置。
func _has_sight(from: CharacterBody3D, to: CharacterBody3D) -> bool:
	# 1. 只检查实体角色与环境，忽略其他雪球的第二碰撞层。
	var query := PhysicsRayQueryParameters3D.create(from.global_position + Vector3.UP * 0.9, to.global_position + Vector3.UP * 0.9, 1, [from.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty() and hit.collider == to


## 取消旧请求与实体，同时结束仅上身动作。
func _clear_projectiles() -> void:
	# 1. 复制有界列表后回收，避免遍历中删除元素漏掉球。
	_pending.clear()
	for ball in _balls.duplicate():
		retire_ball(ball)
	for actor in [player, companion]:
		actor.get_node("Visual").clear_snow_actions()


## 在右上角显示轻量计分与结束结果，不遮挡主要踩雪区。
func _create_interface() -> void:
	# 1. 独立高层画布保证按钮接收点击，不把UI点击当成投掷。
	_canvas = CanvasLayer.new()
	_canvas.layer = 2
	add_child(_canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -320
	panel.offset_right = -35
	panel.offset_top = 32
	panel.offset_bottom = 180
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.17, 0.29, 0.88)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	_canvas.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	_score = Label.new()
	_score.add_theme_font_size_override("font_size", 22)
	column.add_child(_score)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 15)
	column.add_child(_hint)
	_result = Label.new()
	column.add_child(_result)
	_restart = Button.new()
	_restart.text = "Enter  再玩一局"
	_restart.focus_mode = Control.FOCUS_NONE
	_restart.pressed.connect(restart_round)
	column.add_child(_restart)
	_update_interface()


## 只在比分、电脑开关或回合变化时更新文字。
func _update_interface() -> void:
	# 1. 回合结束只暂停投掷；提示明确告知可以继续踩雪。
	_score.text = "你  %d : %d  电脑" % [player_score, npc_score]
	_hint.text = "鼠标瞄准 · 左键投掷\n先到5分 · 命中不打断移动" if companion.visible else "电脑已暂停 · N 继续\n鼠标瞄准 · 左键投掷"
	_result.text = ("你先到5分，赢啦" if winner == "player" else "电脑先到5分啦") + "\n可以继续踩雪，或再玩一局"
	_result.visible = not round_active
	_restart.visible = not round_active


## 失焦冻结在途雪球；恢复后保留原来的抛物线速度。
func _notification(what: int) -> void:
	# 1. 场景尚未完成初始化时只有空列表，不访问UI或雪面。
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = what == NOTIFICATION_APPLICATION_FOCUS_IN
		for ball in _balls:
			ball.set_suspended(not _focused)
