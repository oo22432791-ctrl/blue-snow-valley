extends Node3D
## M12独立场地：临时角色、同源碰撞和手动动作，不读写探索存档。
const PLAYER_SCENE = preload("res://scenes/v3/valley_recovery_player.tscn")
const PLAYER_SCRIPT = preload("res://scripts/v3/boss/valley_arena_player.gd")
const SETTINGS = preload("res://scripts/v3/input/valley_control_settings.gd")
var ground: Node3D
var geometry: Node3D
var boss: CharacterBody3D
var players: Array[CharacterBody3D] = []
var ui: CanvasLayer
var settings = SETTINGS.new()
var player_map := RID()
var boss_map := RID()
var player_region: NavigationRegion3D
var boss_region: NavigationRegion3D
var companion_agent: NavigationAgent3D
var mode := 0
var pad_id := -1
var selecting := false
var target := Vector3(2,0,-4)
var target_marker: MeshInstance3D
var telegraph: MeshInstance3D
var last_boss_powder := 0.0
var elapsed := 0.0
var pending_command := ""
var pending_reset := false
var _keys: Dictionary = {}
var _axes: Dictionary = {}
var _pad_held: Dictionary = {}
var _drag := false
var _ai_moving := false
var _ai_refresh := 0.0
var _ai_side := 1.0
var _p2_target := false
var _p2_free_yaw := 0.0
var _pick := Vector2(-1,-1)
var _notice_age := 0.0
var _move_powder := [Vector3.ZERO,Vector3.ZERO]

## 只装配场地与临时能力，正式会话和311快照不在此依赖图内。
func _ready() -> void:
	process_physics_priority = -20
	settings.load_local()
	_environment()
	ground = load("res://scripts/v3/boss/valley_arena_ground.gd").new()
	add_child(ground)
	geometry = load("res://scripts/v3/boss/valley_arena_geometry.gd").new()
	add_child(geometry)
	_setup_navigation()
	for index in range(2):
		var actor: CharacterBody3D = PLAYER_SCENE.instantiate()
		actor.get_node("FootstepEmitter").free()
		actor.set_script(PLAYER_SCRIPT)
		actor.name = "PreviewP%d" % (index+1)
		actor.snow_surface = ground
		actor.position = grounded(Vector3(-2+index*3,0,3))
		add_child(actor)
		players.append(actor)
		var label := Label3D.new()
		label.text = "P%d" % (index+1)
		label.position.y = 1.9
		label.font_size = 32
		label.pixel_size = .006
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		actor.add_child(label)
		_move_powder[index] = actor.position
	_p2_free_yaw = players[1].weapon.aim_yaw()
	companion_agent = NavigationAgent3D.new()
	companion_agent.path_desired_distance = .5
	companion_agent.target_desired_distance = 1.0
	players[1].add_child(companion_agent)
	companion_agent.set_navigation_map(player_map)
	boss = load("res://scripts/v3/boss/valley_arena_boss.gd").new()
	boss.stage = self
	boss.position = grounded(Vector3(2,0,-12))
	add_child(boss)
	target = grounded(target)
	target_marker = _disc(.35,Color("e3cc72"))
	target_marker.position = target+Vector3.UP*.04
	telegraph = MeshInstance3D.new()
	telegraph.mesh = ImmediateMesh.new()
	telegraph.material_override = _unshaded(Color("d8671c"))
	telegraph.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED
	telegraph.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(telegraph)
	ui = load("res://scripts/v3/boss/valley_arena_views.gd").new()
	ui.stage = self
	add_child(ui)
	geometry.walls_changed.connect(_change_navigation)
	Input.joy_connection_changed.connect(_pad_connection)
	if "--m12-arena-capture" in OS.get_cmdline_user_args():
		_capture.call_deferred()

## 保留雪谷的蓝白色调及实体阴影，不引入新的性能监视器。
func _environment() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("9cb7ce")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("bcd7ed")
	world.environment.ambient_light_energy = .65
	world.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55,-30,0)
	light.shadow_enabled = true
	light.light_energy = 1.2
	add_child(light)

## 两种体型使用各自预烘焙地图，门口与所有冰壁状态都有真实导航。
func _setup_navigation() -> void:
	player_map = NavigationServer3D.map_create()
	boss_map = NavigationServer3D.map_create()
	for map: RID in [player_map,boss_map]:
		NavigationServer3D.map_set_active(map,true)
		NavigationServer3D.map_set_cell_size(map,.2)
		NavigationServer3D.map_set_cell_height(map,.1)
		NavigationServer3D.map_set_merge_rasterizer_cell_scale(map,.01)
	player_region = NavigationRegion3D.new()
	boss_region = NavigationRegion3D.new()
	player_region.set_navigation_map(player_map)
	boss_region.set_navigation_map(boss_map)
	add_child(player_region)
	add_child(boss_region)
	_change_navigation(0)

## 碎裂与复原只切换相应原生几何状态的地图，不加穿墙导航链接。
func _change_navigation(mask: int) -> void:
	player_region.navigation_mesh = load("res://assets/environment/v3/m12_arena_player_nav_%d.res" % mask)
	boss_region.navigation_mesh = load("res://assets/environment/v3/m12_arena_boss_nav_%d.res" % mask)
	_ai_refresh = 0
	if is_instance_valid(boss) and boss.state in ["Walk","Run"]:
		boss.agent.target_position = boss.goal

## 初始落地和目标标记查询，不用于角色运动或碰撞返回。
func grounded(at: Vector3) -> Vector3:
	return Vector3(at.x,ground.ground(at),at.z)

## 动作按钮只排队，实际占位查询在物理帧进行。
func boss_command(value: String) -> void:
	pending_command = value

## 冰壁原地复原请求同样交给物理事务，不推动占位者。
func reset_walls() -> void:
	pending_reset = true

## 只改变临时P2来源；实体手柄缺失时保留当前来源并提示。
func set_mode(value: int) -> void:
	if value == 2 and Input.get_connected_joypads().is_empty():
		ui.mode.select(mode)
		notice("没有检测到手柄，可先使用P2键盘或AI。")
		return
	mode = value
	ui.mode.select(mode)
	pad_id = Input.get_connected_joypads()[0] if mode == 2 else -1
	_keys.clear()
	_axes.clear()
	_pad_held.clear()
	players[1].set_external_direction(Vector3.ZERO)
	players[1].velocity = Vector3.ZERO
	_ai_moving = false
	_p2_target = false
	ui.apply_camera_settings()
	if mode in [1,2] and not ui.split:
		ui.toggle_split()

## 统一暂停冻结角色、雪熊、碎片与雪粉，菜单仍可恢复。
func toggle_pause() -> void:
	if get_tree().paused and mode == 2 and pad_id < 0:
		notice("手柄已断开，请重新选择已连接手柄或改用键盘／AI。")
		return
	_keys.clear()
	_axes.clear()
	_pad_held.clear()
	_drag = false
	get_tree().paused = not get_tree().paused
	for actor: CharacterBody3D in players:
		actor.velocity = Vector3.ZERO
		actor.set_external_direction(Vector3.ZERO)
		actor.weapon.pending = false
		actor.weapon.view.set_paused(get_tree().paused)

## 退出丢弃临时小样，正常主菜单入口按原流程继续探索。
func return_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred("res://scenes/v3/snow_valley_v3.tscn")

## 短通知不常驻堆叠，状态栏持续显示动作与冰壁状态。
func notice(value: String) -> void:
	if is_instance_valid(ui):
		ui.status.text = value
		_notice_age = 4.0

## 鼠标可改键，小样提示也读取同一份已生效映射。
func default_hint() -> String:
	var labels := {1:"左键",2:"右键",3:"中键",8:"侧键1",9:"侧键2"}
	return "使用已保存键位 · "+labels[int(settings.data.mouse.fire)]+"练习射击 · "+labels[int(settings.data.mouse.orbit)]+"镜头 · 动作无伤害、不扣补给"

## 用户可读的动作名，正式阶段战数值没有在小样中定案。
func action_name() -> String:
	if boss.state == "ChargeWarning":
		return "冲撞预警 %.1f秒" % maxf(0,1.4-boss.age) if boss.charge_locked else "安全转向"
	return {"Idle":"待机","Walk":"行走","Run":"奔跑","ChargeWarning":"冲撞预警","Charge":"冲撞","Stop":"停步","Slam":"拍地预警／落掌","Hit":"受击","Fall":"侧倒"}.get(boss.state,boss.state)

## GUI前统一记录释放和P2设备；不会调用正式世界输入路由。
func handle_event(event: InputEvent) -> void:
	if event is InputEventKey and not event.echo:
		if event.physical_keycode == KEY_F12 and event.pressed:
			_capture_user()
			return
		var translated: InputEventKey = settings.keyboard.translate(event)
		if event.pressed and (event.physical_keycode == KEY_ESCAPE or (translated != null and translated.physical_keycode in [KEY_ESCAPE,KEY_PAUSE])):
			toggle_pause()
			get_viewport().set_input_as_handled()
			return
		if translated == null:
			return
		var token := int(translated.physical_keycode)+(int(translated.location)<<32 if translated.physical_keycode in [KEY_CTRL,KEY_SHIFT] else 0)
		_keys[token] = translated.pressed
		if event.pressed and not get_tree().paused:
			if translated.physical_keycode == KEY_HOME:
				_reset_camera(0)
			if translated.physical_keycode == KEY_P:
				_reset_camera(1)
			if mode == 1 and translated.physical_keycode == KEY_TAB:
				_p2_target = _acquire_target()
			if mode == 1 and translated.physical_keycode == KEY_CTRL and translated.location == KEY_LOCATION_RIGHT:
				players[1].weapon.pending = true
		get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_pad_event(event)
		return
	if get_tree().paused:
		return
	if event is InputEventMouseButton:
		if event.button_index == int(settings.data.mouse.orbit):
			_drag = event.pressed and ui.containers[0].get_global_rect().has_point(event.position)
			if _drag:
				players[0].weapon.pending = false
		if not event.pressed:
			return
		if _inside_views(event.position):
			if selecting and event.button_index == int(settings.data.mouse.fire):
				_pick = event.position
			elif event.button_index == int(settings.data.mouse.fire) and not _drag and ui.containers[0].get_global_rect().has_point(event.position):
				players[0].weapon.pending = true
			elif event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
				ui.rigs[0].request_zoom(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
	if event is InputEventMouseMotion and _drag:
		ui.rigs[0].orbit(event.relative)

## 手柄按钮／扳机读M10映射，Menu保留全局暂停出口。
func _pad_event(event: InputEvent) -> void:
	if mode != 2 or event.device != pad_id:
		return
	if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START and event.pressed:
		toggle_pause()
		return
	if event is InputEventJoypadMotion:
		_axes[event.axis] = event.axis_value
	var token: int = event.button_index if event is InputEventJoypadButton else (100+event.axis if event.axis in [JOY_AXIS_TRIGGER_LEFT,JOY_AXIS_TRIGGER_RIGHT] else -1)
	var pressed: bool = event.pressed if event is InputEventJoypadButton else event.axis_value > .55
	if event is InputEventJoypadMotion and event.axis_value >= .2 and event.axis_value <= .55:
		return
	for action: String in settings.data.gamepad:
		if settings.data.gamepad[action] != token:
			continue
		var was: bool = _pad_held.get(action,false)
		_pad_held[action] = pressed
		if pressed and not was and not get_tree().paused:
			match action:
				"fire": players[1].weapon.pending = true
				"target": _p2_target = _acquire_target()
				"reset": _reset_camera(1)

## 手柄拔出冻结世界，不能自动切回AI替真人行动。
func _pad_connection(device: int, connected: bool) -> void:
	if mode == 2 and not connected and device == pad_id:
		pad_id = -1
		if not get_tree().paused:
			toggle_pause()
		notice("手柄已断开；重新选择设备后继续。")

## 画面复位保持已确认角度范围，场地起始视野取18米。
func _reset_camera(index: int) -> void:
	ui.rigs[index].reset_view()
	ui.rigs[index].desired_size = 18
	ui.rigs[index].camera.size = 18

## 仅子视口矩形接收场景操作，点动作按钮不会额外开枪。
func _inside_views(at: Vector2) -> bool:
	return ui.containers[0].get_global_rect().has_point(at) or (ui.split and ui.containers[1].get_global_rect().has_point(at))

## P2主动选择沿用40米、前方90度和实际视线规则。
func _acquire_target() -> bool:
	var actor: CharacterBody3D = players[1]
	var offset := boss.global_position-actor.global_position
	var horizontal := Vector3(offset.x,0,offset.z)
	var yaw: float = actor.weapon.aim_yaw()
	if horizontal.length() > 40 or Vector3(sin(yaw),0,cos(yaw)).dot(horizontal.normalized()) < .707:
		return false
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(actor.global_position+Vector3.UP*1.2,boss.global_position+Vector3.UP*2.8,2|4|8,[actor.get_rid()]))
	return not hit.is_empty() and hit.collider == boss

## 物理帧先更新意图，既有CharacterBody随后做真实碰撞移动。
func _physics_process(delta: float) -> void:
	elapsed += delta
	_notice_age -= delta
	if _notice_age <= 0:
		ui.status.text = default_hint()
	if pending_reset:
		pending_reset = false
		if not geometry.reset_walls():
			notice("冰壁原位置被角色或雪熊占用，腾空后再重置。")
	if not pending_command.is_empty():
		boss.command(pending_command,target)
		pending_command = ""
	if _pick.x >= 0:
		var index := 1 if ui.split and ui.containers[1].get_global_rect().has_point(_pick) else 0
		var hit := _aim(index,_pick,1)
		_pick = Vector2(-1,-1)
		if not hit.is_empty():
			target = hit.position
			target_marker.position = target+Vector3.UP*.04
			selecting = false
	var first := Vector2(_held(KEY_D)-_held(KEY_A),_held(KEY_S)-_held(KEY_W)).limit_length()
	players[0].set_external_direction(players[0]._world_direction(first),_held(KEY_SHIFT,KEY_LOCATION_LEFT)>0)
	if not _drag and ui.containers[0].get_global_rect().has_point(get_viewport().get_mouse_position()):
		var aim := _aim(0,get_viewport().get_mouse_position(),1|2|4|8,[players[0].get_rid()])
		if not aim.is_empty():
			players[0].aim_hit = aim
	_drive_p2(delta)
	if _p2_target and not _acquire_target():
		_p2_target = false
	if _p2_target:
		players[1].aim_hit = {"position":boss.global_position+Vector3.UP*2.8}
	else:
		if players[1].horizontal_speed > .03:
			_p2_free_yaw = atan2(players[1].velocity.x,players[1].velocity.z)
		players[1].aim_hit = {"position":players[1].global_position+Vector3.UP+Vector3(sin(_p2_free_yaw),0,cos(_p2_free_yaw))*30}
	_draw_warning()
	for index in range(2):
		if players[index].global_position.distance_to(_move_powder[index]) > .85:
			powder(players[index].global_position,5)
			_move_powder[index] = players[index].global_position

## 三种控制来源只生成方向，角色脚步、雪粉与碰撞始终使用真实位移。
func _drive_p2(delta: float) -> void:
	var actor: CharacterBody3D = players[1]
	var direction := Vector3.ZERO
	var running := false
	if mode == 0:
		var distance := actor.global_position.distance_to(players[0].global_position)
		_ai_moving = distance > 4 if not _ai_moving else distance > 2.2
		_ai_refresh -= delta
		if _ai_refresh <= 0:
			companion_agent.target_position = players[0].global_position
			_ai_refresh = .35
		if _ai_moving and not companion_agent.is_navigation_finished():
			direction = companion_agent.get_next_path_position()-actor.global_position
			direction.y = 0
			direction = _avoid_boss(direction.normalized())
			running = distance > 8
	elif mode == 1:
		var vector := Vector2(_held(KEY_RIGHT)-_held(KEY_LEFT),_held(KEY_DOWN)-_held(KEY_UP)).limit_length()
		direction = actor._world_direction(vector)
		running = _held(KEY_SHIFT,KEY_LOCATION_RIGHT)>0
		ui.rigs[1].orbit(Vector2(_held(KEY_L)-_held(KEY_J),_held(KEY_K)-_held(KEY_I))*delta*180)
		ui.rigs[1].request_zoom((_held(KEY_O)-_held(KEY_U))*delta*4)
	elif mode == 2 and pad_id >= 0:
		direction = actor._world_direction(_stick(JOY_AXIS_LEFT_X,JOY_AXIS_LEFT_Y))
		running = _pad_held.get("sprint",false)
		ui.rigs[1].orbit(_stick(JOY_AXIS_RIGHT_X,JOY_AXIS_RIGHT_Y)*delta*300)
		ui.rigs[1].request_zoom((float(_pad_held.get("zoom_out",false))-float(_pad_held.get("zoom_in",false)))*delta*4)
	actor.set_external_direction(direction,running)

## 动态巨熊不写入静态网格；AI在真实胶囊扫掠可行的方向中绕行。
func _avoid_boss(desired: Vector3) -> Vector3:
	var shape: CollisionShape3D = players[1].get_node("BodyCollision")
	var space := get_world_3d().direct_space_state
	for angle: float in [0.0,_ai_side*.65,_ai_side*1.2,_ai_side*1.57,-_ai_side*.65,-_ai_side*1.2]:
		var direction := desired.rotated(Vector3.UP,angle)
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = shape.global_transform
		query.motion = direction*1.4
		query.collision_mask = 4|8
		query.exclude = [players[1].get_rid()]
		var fraction := space.cast_motion(query)
		if fraction[0] > .95:
			if absf(angle)>0:
				_ai_side = signf(angle)
			return direction
	return Vector3.ZERO

## 连续手柄输入使用已保存死区，避免设备静置时角色自行漂移。
func _stick(x: int, y: int) -> Vector2:
	var value := Vector2(float(_axes.get(x,0)),float(_axes.get(y,0))).limit_length()
	var deadzone: float = settings.data.cameras["p2.gamepad"].deadzone
	return value.normalized()*remap(value.length(),deadzone,1,0,1) if value.length()>deadzone else Vector2.ZERO

## 同一规范键支持M10左右修饰键映射。
func _held(key: int, location: int = 0) -> float:
	return 1.0 if _keys.get(key+(location<<32),false) else 0.0

## 射线来自对应视口的真正相机，不能拿全窗坐标代替半屏坐标。
func _aim(index: int, screen: Vector2, mask: int, excluded: Array[RID] = []) -> Dictionary:
	var camera: Camera3D = ui.rigs[index].camera
	var local: Vector2 = ui.local_screen(index,screen)
	var from := camera.project_ray_origin(local)
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,from+camera.project_ray_normal(local)*200,mask,excluded))

## 橙色路径和落掌范围贴合真实地面，只是无伤害审阅提示。
func _draw_warning() -> void:
	var mesh: ImmediateMesh = telegraph.mesh
	mesh.clear_surfaces()
	if boss.state not in ["ChargeWarning","Charge","Slam"]:
		return
	if boss.state == "ChargeWarning" and not boss.charge_locked:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var at := boss.global_position
	if boss.state == "Slam":
		var center := at+boss.global_basis*Vector3(-1.4,0,2.2)
		for index in range(40):
			var a := index*TAU/40
			var b := (index+1)*TAU/40
			_warning_ribbon(mesh,center+Vector3(cos(a),0,sin(a))*2.1,center+Vector3(cos(b),0,sin(b))*2.1,.14)
	else:
		var direction: Vector3 = boss.global_basis.z
		var right: Vector3 = boss.global_basis.x
		var length := 12.0
		# 真实扫掠预估停止点，提示不会画成能穿过完整冰壁的冲撞。
		for shape: CollisionShape3D in boss.shapes:
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform
			query.motion = direction*12
			query.collision_mask = 2|4
			query.exclude = [boss.get_rid()]
			length = minf(length,12*get_world_3d().direct_space_state.cast_motion(query)[0])
		# 扫掠距离描述根部位移，提示还须包含前方头身长度，避免全藏在腹下。
		var front := at+direction*(4.85+length)
		for sign_value: float in [-1.0,1.0]:
			var start := at+right*2.1*sign_value
			_warning_ribbon(mesh,start,front+right*2.1*sign_value,.14)
		_warning_ribbon(mesh,front-right*2.1,front+right*2.1,.14)
		for side: float in [-1.0,1.0]:
			_warning_ribbon(mesh,front-direction*.3,front-direction*1.1+right*.75*side,.18)
	mesh.surface_end()

## 宽线带逐段采样原三角地面，远景与分屏都能辨认且不穿越坡面。
func _warning_ribbon(mesh: ImmediateMesh, start: Vector3, end: Vector3, width: float) -> void:
	var direction := end-start
	var side := Vector3(direction.z,0,-direction.x).normalized()*width*.5
	var count := maxi(1,ceili(direction.length()/.5))
	for index in range(count):
		var a := start.lerp(end,float(index)/count)
		var b := start.lerp(end,float(index+1)/count)
		for point: Vector3 in [a-side,a+side,b+side,a-side,b+side,b-side]:
			mesh.surface_add_vertex(grounded(point)+Vector3.UP*.08)

## 标记使用小型地面圆盘，不承载碰撞或触发结算。
func _disc(radius: float, color: Color) -> MeshInstance3D:
	var mark := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = .025
	mark.mesh = cylinder
	mark.material_override = _unshaded(color)
	add_child(mark)
	return mark

## 短提示用独立材质，不修改源资产调色。
func _unshaded(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material

## 真实脚步和撞击产生有限雪粉，结束后释放，暂停会冻结粒子生命周期。
func powder(at: Vector3, amount: int) -> void:
	var particles := GPUParticles3D.new()
	particles.position = at+Vector3.UP*.1
	particles.amount = amount
	particles.lifetime = .8
	particles.one_shot = true
	particles.explosiveness = 1
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 65
	process.initial_velocity_min = .6
	process.initial_velocity_max = 2.0
	process.gravity = Vector3(0,-4,0)
	process.scale_min = .045
	process.scale_max = .13
	particles.process_material = process
	var mesh := SphereMesh.new()
	mesh.radius = .5
	mesh.height = 1
	mesh.radial_segments = 6
	mesh.rings = 3
	particles.draw_pass_1 = mesh
	particles.material_override = _unshaded(Color("d9eaf4"))
	add_child(particles)
	particles.emitting = true
	get_tree().create_timer(1.6,false).timeout.connect(particles.queue_free)

## 失焦时暂停并清理持续动作，恢复焦点不会自行继续冲撞。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(ui) and not get_tree().paused:
		toggle_pause()

## 独立导航地图随小样释放，不残留到正常探索世界。
func _exit_tree() -> void:
	for map: RID in [player_map,boss_map]:
		if map.is_valid():
			NavigationServer3D.map_set_active(map,false)
			NavigationServer3D.free_rid(map)

## 自动取证只走当前小样入口，不读取探索存档。
func _capture() -> void:
	for frame in range(60):
		await get_tree().physics_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://docs/validation/v3/m12_arena_initial.png")
	ui.toggle_split()
	for frame in range(5):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://docs/validation/v3/m12_arena_split_initial.png")
	get_tree().quit()

## 延续正式游戏F12截图入口，图片与探索存档目录分开。
func _capture_user() -> void:
	await RenderingServer.frame_post_draw
	var directory := "user://captures/v3"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var stamp := Time.get_datetime_string_from_system().replace(":","-")
	var path := directory.path_join("m12_"+stamp+".png")
	get_viewport().get_texture().get_image().save_png(path)
	notice("截图已保存："+ProjectSettings.globalize_path(path))
