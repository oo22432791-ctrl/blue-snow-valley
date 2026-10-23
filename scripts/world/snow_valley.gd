extends Node3D
## 第二版装配入口：山谷基底、区域与地标各自管理，镜头和输入保留独立模块。

const SESSION=preload("res://scripts/session/valley_session.gd")
@export var session_enabled: bool=true
@export var save_directory: String="user://saves/v2"
@export var capture_directory: String="user://captures/v2"
var session: Node

const PLAYER_SCENE = preload("res://scenes/characters/valley_player.tscn")
const SNOW_SURFACE = preload("res://scripts/world/environment_surface.gd")
const TRACKS = preload("res://scripts/snow/valley_snow_tracks.gd")
const STEP_AUDIO = preload("res://scripts/audio/valley_footstep_audio.gd")
const POWDER = preload("res://scripts/snow/valley_snow_powder.gd")
const CAMERA_RIG = preload("res://scripts/camera/valley_camera.gd")
const INPUT_ROUTER = preload("res://scripts/session/valley_input_router.gd")
const DAY_PALETTE = preload("res://materials/palettes/clear_blue.tres")
const NIGHT_PALETTE = preload("res://materials/palettes/twilight_blue.tres")
const TERRAIN = preload("res://scripts/world/valley_terrain.gd")
const REGIONS = preload("res://scripts/world/valley_regions.gd")
const LANDMARKS = preload("res://scripts/world/valley_landmarks.gd")
const INTERIOR = preload("res://scripts/buildings/valley_interior.gd")
const ENVIRONMENT_ASSET = preload("res://scripts/world/valley_environment_asset.gd")
const ENVIRONMENT_NAVIGATION = preload("res://assets/environment/v2/corridor_navigation.res")
const CLOCK=preload("res://scripts/environment/valley_clock.gd")
const WEATHER=preload("res://scripts/environment/valley_weather.gd")
const WEATHER_VISUAL=preload("res://scripts/environment/valley_weather_visual.gd")
const SURVIVAL=preload("res://scripts/survival/valley_survival.gd")
const SURVIVAL_UI=preload("res://scripts/survival/valley_survival_ui.gd")
const HEAT_VISUAL=preload("res://scripts/survival/valley_heat_visual.gd")
const BEARS=preload("res://scripts/ai/valley_bears.gd")
const RIFLE=preload("res://scripts/weapons/valley_rifle.gd")
const SNOWBALL_GAME=preload("res://scripts/gameplay/valley_snowball_game.gd")
@export var weather_seed: int=0

var player: CharacterBody3D
var camera_rig: Node3D
var input_router: Node
var _objects: Dictionary[StringName, WeakRef] = {}
var _status: Label
var _resume_context: INPUT_ROUTER.Context = INPUT_ROUTER.Context.EXPLORATION
var aim_hit: Dictionary = {}
var _aim_screen: Vector2
var _has_pointer: bool = false
var _aim_marker: MeshInstance3D
var _environment: Environment
var _sun: DirectionalLight3D
var terrain: Node3D
var snow_surface: Node3D
var snow_tracks: Node
var step_audio: Node3D
var snow_powder: Node3D
var regions: Node3D
var landmarks: Node3D
var interior: Node
var _location_label: Label
var _character_materials: Dictionary[StringName, StandardMaterial3D] = {}
var _pause_overlay: Control
var _debug_label: Label
var _preview_night: bool = false
var _aim_exclusions: Array[RID] = []
var world_clock: Node
var weather: Node
var weather_visual: Node3D
var _current_palette: Resource=DAY_PALETTE
var _weather_label: Label
var survival: Node
var survival_ui: CanvasLayer
var heat_visual: Node3D
var bears: Node3D
var rifle: Node3D
var snowball_game: Node3D
var _controls_label: Label


## 按环境、碰撞、角色、输入的顺序装配第二版，保持第一版场景独立。
func _ready() -> void:
	# 1. 地形只读取离线资源；不实例化第一版世界或自动开启雪球比赛。
	_create_environment()
	world_clock=CLOCK.new();world_clock.name="WorldClock";add_child(world_clock)
	register_world_object(&"world.clock",world_clock)
	terrain = TERRAIN.new()
	terrain.navigation_override=ENVIRONMENT_NAVIGATION
	terrain.name = "ValleyTerrain"
	add_child(terrain)
	if terrain.manifest.is_empty():
		return
	player = _create_player()
	player.name = "Player"
	var spawn: Array = terrain.manifest.route[0]
	player.position = Vector3(spawn[0],spawn[1]+0.1,spawn[2])
	snow_surface = _create_snow_surface()
	snow_surface.name = "ValleySnowSurface"
	snow_surface.terrain = terrain
	snow_surface.player = player
	# 雪场先就绪，角色初始化即可查询压实支撑。
	player.snow_surface = snow_surface
	add_child(snow_surface)
	_apply_palette_materials(player)
	add_child(player)
	register_world_object(&"actor.player", player)
	_aim_exclusions.append(player.get_rid())
	camera_rig = _create_camera()
	camera_rig.name = "CameraRig"
	camera_rig.tracked_actor = player
	camera_rig.snow_surface = snow_surface
	add_child(camera_rig)
	player.movement_camera = camera_rig.camera
	# 脚印先写入，声音和雪粉再消费同一个真实接触事件，固定池不随步数增长。
	snow_tracks = _create_snow_tracks()
	snow_tracks.name = "ValleySnowTracks"
	snow_tracks.snow_surface = snow_surface
	snow_tracks.world_clock=world_clock
	add_child(snow_tracks)
	step_audio = STEP_AUDIO.new()
	step_audio.snow_surface = snow_surface
	add_child(step_audio)
	snow_powder = POWDER.new()
	snow_powder.snow_surface = snow_surface
	add_child(snow_powder)
	var emitter := player.get_node("FootstepEmitter")
	emitter.foot_landed.connect(_on_foot_landed)
	emitter.foot_dragged.connect(snow_tracks.on_foot_dragged)
	# 2. 地标常驻，附近树林通过滞后邻域加载；地面碰撞不随道具卸载。
	landmarks = LANDMARKS.new()
	landmarks.name = "ValleyLandmarks"
	landmarks.terrain = terrain
	landmarks.register_object = register_world_object
	landmarks.bind_palette = _apply_palette_materials
	add_child(landmarks)
	snow_surface.cabins.assign(landmarks.cabins)
	regions = _create_regions()
	regions.name = "ValleyRegions"
	regions.terrain = terrain
	regions.player = player
	regions.register_object = register_world_object
	regions.bind_palette = _apply_palette_materials
	add_child(regions)
	# 室内独立消费角色位置，只改变外壳显示并发布遮蔽／进入事件。
	interior=_create_interior()
	interior.name="ValleyInterior"
	interior.player=player
	interior.camera_rig=camera_rig
	interior.regions=regions
	interior.cabins.assign(landmarks.cabins)
	add_child(interior)
	# 3. 输入路由发布互斥请求，武器和磁盘存档由后续独立模块消费。
	input_router = _create_input_router()
	input_router.name = "InputRouter"
	input_router.controlled_actor = player
	add_child(input_router)
	_create_interface()
	_create_aim_marker()
	input_router.zoom_requested.connect(camera_rig.request_zoom)
	input_router.aim_moved.connect(_on_aim_moved)
	input_router.primary_requested.connect(_on_aim_moved)
	input_router.pause_requested.connect(_on_pause_requested)
	input_router.interact_requested.connect(_on_interact_requested)
	# 4. 天气先消费统一时钟，足迹随后消费同一delta；风雪不重置世界时间或痕迹。
	weather=WEATHER.new();weather.name="ValleyWeather";weather.clock=world_clock
	weather.snow_tracks=snow_tracks;weather.interior=interior;weather.seed_value=weather_seed;add_child(weather)
	register_world_object(&"world.weather",weather)
	weather.palette_changed.connect(_apply_live_palette)
	weather_visual=WEATHER_VISUAL.new();weather_visual.name="WeatherVisual"
	weather_visual.weather=weather;weather_visual.clock=world_clock;weather_visual.player=player
	weather_visual.cabins.assign(landmarks.cabins);weather_visual.camps.assign(landmarks.camps_by_id.values());add_child(weather_visual)
	world_clock.advanced.connect(func(delta: float,_elapsed: float) -> void:snow_tracks.advance_game_time(delta))
	set_preview_night(false)
	# 5. 冷暖、燃料与资源订阅相同世界秒数，交互菜单不直接修改库存。
	survival=_create_survival();survival.name="ValleySurvival";survival.world=self;add_child(survival)
	register_world_object(&"world.survival",survival)
	survival_ui=_create_survival_ui();survival_ui.name="SurvivalUI";survival_ui.world=self;survival_ui.survival=survival;add_child(survival_ui)
	heat_visual=HEAT_VISUAL.new();heat_visual.name="HeatVisual";heat_visual.world=self;heat_visual.survival=survival;add_child(heat_visual)
	# 6. 熊消费独立导航与同一雪面／失败入口，枪械与会话随后装配。
	bears=_create_bears();bears.name="ValleyBears";bears.world=self;add_child(bears)
	register_world_object(&"world.bears",bears)
	# 7. 猎枪消费已隔离的V2输入；伤害、装填、补给由武器模块负责，V1不装配。
	rifle=_create_rifle();rifle.name="ValleyRifle";rifle.world=self;add_child(rifle)
	register_world_object(&"world.rifle",rifle)
	# M13只装配局部活动；明确开局之前电脑散步但不投球、不显示比分。
	snowball_game=_create_snowball_game();snowball_game.name="SnowballActivity";snowball_game.world=self;add_child(snowball_game)
	register_world_object(&"activity.snowball",snowball_game)
	# 8. 会话最后装配，待稳定对象就绪后恢复；验证场景可显式隔离磁盘生命周期。
	if session_enabled:
		session=_create_session();session.name="ValleySession";session.world=self;add_child(session)
		session.state_restored.connect(func() -> void:snowball_game.end_activity("load",false))


## 默认保留V2单角色雪面，扩展版本可提供第二视图窗口。
func _create_snow_surface() -> Node3D:
	# 1. 物理和共享雪深仍由原生资源提供。
	return SNOW_SURFACE.new()


## 默认保留V2原脚印容量，合作版本按两个窗口配置固定缓存。
func _create_snow_tracks() -> Node:
	# 1. 世界脚印仍只有一份历史，不按玩家复制。
	return TRACKS.new()


## 默认使用原雪球活动，扩展版本可选择支持枪械的伙伴场景。
func _create_snowball_game() -> Node3D:
	# 1. V2保持七骨骼伙伴，V3可注入支持持枪的原生角色场景。
	return SNOWBALL_GAME.new()


## 默认使用既有V2交互界面，后续版本可替换对应视图的菜单。
func _create_survival_ui() -> CanvasLayer:
	# 1. 默认继续使用原全屏交互，V3可把菜单限定到操作者视图。
	return SURVIVAL_UI.new()


## 默认创建既有V2会话，后续版本可替换协调器而不复制山谷装配逻辑。
func _create_session() -> Node:
	# 1. V1不使用本入口；V2仍使用原来的保存格式与恢复规则。
	return SESSION.new()


## 默认保留V2枪械，允许后续版本扩展世界补给容量而不改旧版规则。
func _create_rifle() -> Node3D:
	# 1. 装配契约与原枪械一致，输入和视图仍由对应武器实例管理。
	return RIFLE.new()


## 默认沿用V2单玩家驻留，扩展版本可登记附加角色关注点。
func _create_regions() -> Node3D:
	# 1. 旧版保持原加载与卸载范围。
	return REGIONS.new()


## 默认使用V2固定镜头，后续版本可在相同装配契约下替换。
func _create_camera() -> Node3D:
	# 1. 玩家、雪面和当前镜头引用仍由世界按原顺序绑定。
	return CAMERA_RIG.new()


## 默认使用V2单视图室内模块，物理和房间事件契约保持稳定。
func _create_interior() -> Node:
	# 1. 扩展版本只替换显示策略，不复制小屋碰撞和取暖规则。
	return INTERIOR.new()


## 默认使用V2输入路由，不在项目设置中注册新版临时操作。
func _create_input_router() -> Node:
	# 1. 设备焦点、暂停和场景退出继续由对应路由实例负责。
	return INPUT_ROUTER.new()


## 户外保留统一踩雪事件，真实木地板与门廊不刷雪印或发出压雪声。
func _on_foot_landed(at: Vector3, yaw: float, left: bool, speed: float) -> void:
	# 1. 铺装和脚骨支撑共用同一个提供器，不用独立定时器判断室内。
	if snow_surface.is_dry_surface(at):
		return
	# 2. 同一真实落脚顺序交给脚印、声音和雪粉，保持M4同步边界。
	snow_tracks.on_foot_landed(at,yaw,left,speed)
	step_audio.on_foot_landed(at,yaw,left,speed)
	snow_powder.on_foot_landed(at,yaw,left,speed)


## E请求在下一物理帧选择唯一最近对象，门与库存操作不会同时触发。
func _on_interact_requested() -> void:
	# 1. 原门自身仍做距离校验，其他对象通过一次性菜单令牌提交事务。
	if is_instance_valid(survival):survival.request_interact()


## Esc先关闭对象菜单，再由统一入口暂停；暂停不会把UI上下文遗留给角色。
func _on_pause_requested() -> void:
	# 0. 启动／恢复屏障不允许Esc越过完整校验。
	if is_instance_valid(session) and (session.busy or session._boot_fault or session._return_pending):return
	# 1. 菜单关闭与暂停是两次明确操作，避免关闭菜单同时误恢复世界。
	if is_instance_valid(survival_ui) and survival_ui.opened:
		survival_ui.close()
		return
	set_session_paused(not get_tree().paused)


## 注册跨存档稳定ID；拒绝空ID、失效对象及重复绑定。
func register_world_object(stable_id: StringName, object: Node) -> Error:
	# 1. ID由设计数据给定，不使用运行时实例编号或节点路径。
	if stable_id == &"" or not is_instance_valid(object):
		return ERR_INVALID_PARAMETER
	if _objects.has(stable_id) and _objects[stable_id].get_ref() != null:
		return ERR_ALREADY_EXISTS
	# 2. 仅登记成功的实例，并暴露元数据供场景检查。
	_objects[stable_id] = weakref(object)
	object.set_meta("stable_id", stable_id)
	return OK


## 按稳定ID查询当前实例；已经卸载的对象视为不存在。
func find_world_object(stable_id: StringName) -> Node:
	# 1. 区域卸载不留下可用的悬空引用，后续可用同ID重新登记。
	return _objects[stable_id].get_ref() if _objects.has(stable_id) else null


## 统一暂停场景模拟并把输入交给界面，Esc与继续按钮共用此入口。
func set_session_paused(value: bool) -> void:
	# 0. 所有继续入口共用屏障，按钮和Esc均不能越过正在提交的恢复。
	if not value and is_instance_valid(session) and (session.busy or session._boot_fault or session._return_pending):return
	# 1. 重复请求不覆盖暂停前上下文，小游戏／界面恢复时仍保留输入归属。
	if value == get_tree().paused:
		return
	if value:
		_resume_context = input_router.context
	# 2. 清除角色惯性和持续按键，避免恢复后出现误移动或误射。
	input_router.set_context(INPUT_ROUTER.Context.PAUSED if value else _resume_context)
	player.velocity = Vector3.ZERO
	# 3. 使用场景树暂停，让后续物理、时钟与燃料共享同一冻结边界。
	get_tree().paused = value
	if is_instance_valid(weather_visual):weather_visual.set_paused(value)
	if is_instance_valid(bears):bears.set_paused(value)
	if is_instance_valid(rifle):rifle.set_paused(value)
	# 命中声音随暂停冻结；投掷和在途球由场景树共享冻结边界。
	if is_instance_valid(snowball_game):snowball_game.set_paused(value)
	_pause_overlay.visible = value
	if value:
		_aim_marker.visible = false


## 配置与第一版一致的白天色彩来源，不复制或改写历史资源。
func _create_environment() -> void:
	# 1. 显式配置环境补光和背景，保证独立运行时可见。
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.ssao_enabled = true
	_environment.ssao_radius = 0.5
	_environment.ssao_intensity = 0.8
	var world_environment := WorldEnvironment.new()
	world_environment.environment = _environment
	add_child(world_environment)
	# 2. 原方向光参数用于基线，完整昼夜留给M8。
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-31.0, -48.0, 0.0)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 75.0
	add_child(_sun)


## 绑定角色与地标的语义颜色，不改变GLB、骨架、动作与源文件。
func _apply_palette_materials(node: Node) -> void:
	# M7环境使用自己的材质角色，不能送入第一版角色调色表。
	if node.has_method("apply_environment_palette"):
		node.apply_environment_palette(_current_palette)
		return
	# 0. V2安全屋使用独立语义表，不能把未知家具材质送入第一版调色资源。
	if node.has_method("apply_cabin_palette"):
		node.apply_cabin_palette(_current_palette)
		return
	# 1. 每个表面按材质名着色，皮肤使用第一版既有浅色。
	if node is MeshInstance3D:
		for index in range(node.mesh.get_surface_count()):
			var source: Material = node.mesh.surface_get_material(index)
			if source == null:
				continue
			var key := StringName(source.resource_name)
			if not _character_materials.has(key):
				var material := StandardMaterial3D.new()
				material.roughness = 0.9
				_character_materials[key] = material
			node.set_surface_override_material(index, _character_materials[key])
	# 2. 递归仅修改本实例材质，不保存回导入资产。
	for child in node.get_children():
		_apply_palette_materials(child)


## 显示探索信息与统一暂停入口，会话模块追加存读档操作。
func _create_interface() -> void:
	# 1. 非交互文本不抢占鼠标，不装入第一版配色和自动比赛UI。
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	_controls_label=label
	label.position = Vector2(28.0, 20.0)
	label.text = "蓝色雪境 · 山谷探索\nWASD / 方向键移动 · Shift跑步 · 滚轮缩放 · Esc暂停 · F12截图\nE开关门、拾取与存取 · 1/2切换雪球与猎枪 · 左键射击 · R装填"
	label.add_theme_color_override("font_color", Color("213b58"))
	label.add_theme_font_size_override("font_size", 22)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(label)
	_status = Label.new()
	_status.position = Vector2(28.0, 215.0)
	_status.add_theme_color_override("font_color", Color("213b58"))
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_status)
	_location_label = Label.new()
	_location_label.position = Vector2(28.0,140.0)
	_location_label.add_theme_color_override("font_color",Color("213b58"))
	_location_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_location_label)
	_weather_label=Label.new();_weather_label.position=Vector2(28,180)
	_weather_label.add_theme_color_override("font_color",Color("213b58"));_weather_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	layer.add_child(_weather_label)
	# 2. 技术参数仅放在可收起调试区，配色预览不占用装备输入。
	_debug_label = Label.new()
	_debug_label.position = Vector2(28.0, 255.0)
	_debug_label.add_theme_color_override("font_color", Color("f0f7ff"))
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_label.visible = false
	layer.add_child(_debug_label)
	# 3. 暂停遮罩负责拦截UI输入；保存和恢复菜单由M12会话模块追加。
	_pause_overlay = Control.new()
	_pause_overlay.name = "PauseOverlay"
	_pause_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_overlay.visible = false
	layer.add_child(_pause_overlay)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.04, 0.09, 0.17, 0.7)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.add_child(center)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 20)
	center.add_child(content)
	var paused_label := Label.new()
	paused_label.text = "已暂停"
	paused_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paused_label.add_theme_font_size_override("font_size", 32)
	content.add_child(paused_label)
	var resume := Button.new()
	resume.name = "ResumeButton"
	resume.text = "继续探索（Esc）"
	resume.custom_minimum_size = Vector2(280.0, 64.0)
	resume.pressed.connect(func() -> void: set_session_paused(false))
	content.add_child(resume)


## 保留截图入口，1／2／R只经过第二版路由，不切换配色或复位镜头。
func _unhandled_input(event: InputEvent) -> void:
	# 1. 截图不会驱动模拟或武器，暂停时由输入路由与遮罩统一处理。
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		_save_capture()
		get_viewport().set_input_as_handled()
	# 2. 调试只接受独立功能键，不与装备和换弹共享热键。
	if event is InputEventKey and event.pressed and not event.echo and input_router.allows_gameplay_input():
		if event.keycode == KEY_F6:
			_debug_label.visible = not _debug_label.visible
		elif event.keycode == KEY_F7 and _debug_label.visible:
			set_preview_night(not _preview_night)
		elif event.keycode == KEY_F8 and _debug_label.visible:
			camera_rig.reset_view()
		elif event.keycode == KEY_F9 and _debug_label.visible:
			weather.debug_start_storm()


## 在物理帧中读取真实瞄准碰撞，并更新可收起的调试信息。
func _physics_process(_delta: float) -> void:
	# M13活动内显示当前操作，避免探索的猎枪提示与锁定雪球冲突。
	if is_instance_valid(snowball_game):
		_controls_label.text="蓝色雪境 · 山谷探索\nWASD / 方向键移动 · Shift跑步 · 滚轮缩放 · Esc暂停 · F12截图\n"+("雪球比赛 · 左键投掷 · 虚线内活动 · 退出恢复原装备" if snowball_game.participating else "E开关门、拾取与存取 · 1/2切换雪球与猎枪 · 左键射击 · R装填")
	# 1. GUI、暂停、失焦时隐藏瞄准，不把旧屏幕坐标当作新的操作。
	_aim_marker.visible = _has_pointer and input_router.allows_gameplay_input() and input_router.context==input_router.Context.EXPLORATION
	if _aim_marker.visible:
		aim_hit = camera_rig.query_aim(_aim_screen, _aim_exclusions)
		_aim_marker.visible = not aim_hit.is_empty()
		if _aim_marker.visible:
			_aim_marker.global_position = aim_hit.position + aim_hit.normal * 0.025
	else:
		aim_hit = {}
	# 2. 正式状态只提示时段与天气，调度时刻／恢复倍率留在F6调试区。
	if _debug_label.visible:
		_debug_label.text="相机40° / 视野%.2f米 · 世界%.1f秒 / 日内%.1f秒\n雪印恢复×%.2f · 风雪%.2f · 下场%.1f秒\nF7：昼夜调试；F8：恢复镜头；F9：调试风雪" % [camera_rig.camera.size,world_clock.elapsed_seconds,world_clock.get_day_seconds(),snow_tracks.weather_recovery_multiplier,weather.intensity,weather.next_storm_at]
		if is_instance_valid(survival):_debug_label.text+="\n暖意%.2f / 100 · 每秒%+.3f · 世界时间×%.1f" % [survival.warmth,float(survival.last_thermal.get("rate",0)),world_clock.debug_rate]
	var phase_label: String={&"dawn":"清晨",&"day":"白天",&"dusk":"黄昏",&"night":"夜晚"}[world_clock.get_phase()]
	_weather_label.text=phase_label+" · "+("风雪" if weather.state==&"storm" else "晴静")
	# 3. 只提示附近真实地点，不在正式HUD显示纹理块和加载实现细节。
	var nearest_label := "沿浅色山路探索山谷"
	var nearest_distance := 18.0
	for site: Dictionary in terrain.manifest.sites:
		var distance := Vector2(player.position.x-float(site.entry[0]),player.position.z-float(site.entry[2])).length()
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_label = "附近：%s" % site.label
			if site.kind!="house" and is_instance_valid(survival):nearest_label+=" · 营火"+("燃烧中" if survival.heaters[String(site.id)+".heat"].fuel_seconds>0 else "未点燃")
	for cabin: Node3D in landmarks.cabins:
		# 门口与桌面弹药可能同时可达，提示也必须服从E实际选中的唯一最近目标。
		var door_selected: bool=not is_instance_valid(survival) or (survival.nearest.get("kind","")=="door" and survival.nearest.get("site","")==String(cabin.get_meta("building_id")))
		if cabin.can_interact(player.global_position) and door_selected:
			nearest_label = "门被挡住，请让开门扇范围（E反向开关）" if cabin.door_blocked else "E：%s%s的门" % ["关闭" if cabin.target_open else "打开",cabin.get_meta("display_name")]
			break
	if is_instance_valid(interior.current_cabin):
		nearest_label+=" · 屋内"
	_location_label.text = nearest_label


## 统一接收视口事件坐标，鼠标点击和移动使用同一条瞄准链。
func _on_aim_moved(screen_position: Vector2) -> void:
	# 1. 只记下坐标，物理查询留到固定物理步，避免在GUI回调中访问物理状态。
	_aim_screen = screen_position
	_has_pointer = true


## 创建无碰撞瞄准环，未来装备复用真实射线结果而非环的位置。
func _create_aim_marker() -> void:
	# 1. 小环只提供方向反馈，不参与受击、物理遮挡或计分。
	_aim_marker = MeshInstance3D.new()
	_aim_marker.name = "AimMarker"
	var ring := TorusMesh.new()
	ring.inner_radius = 0.105
	ring.outer_radius = 0.14
	ring.rings = 24
	ring.ring_segments = 8
	_aim_marker.mesh = ring
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("dcefff")
	_aim_marker.material_override = material
	_aim_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aim_marker.visible = false
	add_child(_aim_marker)


## 调试定位昼夜端点，保留累计世界时间、天气调度及足迹寿命。
func set_preview_night(enabled: bool) -> void:
	# 1. 只调整日内位置，不快进世界模拟，已有检视接口保持可用。
	_preview_night = enabled
	world_clock.debug_set_day_seconds(1200.0 if enabled else 120.0)
	weather.refresh_palette()


## 连续光照更新只修改运行时共享材质，保留树LOD、室内淡出和原端点资源。
func _apply_live_palette(palette: Resource,sun_rotation: Vector3) -> void:
	# 1. 新加载区域也读取当前插值色，不能退回白天或夜晚的离散快照。
	_current_palette=palette
	_preview_night=world_clock.get_daylight()<.5
	_environment.background_color = palette.ambient
	_environment.ambient_light_color = palette.ambient
	_environment.ambient_light_energy = palette.ambient_energy
	_sun.light_color = palette.sunlight
	_sun.light_energy = palette.light_energy
	_sun.rotation_degrees=sun_rotation
	terrain.ground_material.set_shader_parameter("snow_color",palette.snow)
	terrain.ground_material.set_shader_parameter("path_color",palette.snow.lightened(0.35))
	snow_surface.set_palette(palette.snow,palette.snow.lightened(0.35))
	snow_powder.apply_color(palette.snow)
	if is_instance_valid(snowball_game):snowball_game.apply_environment_palette(palette)
	for cabin: Node3D in landmarks.cabins:
		cabin.apply_cabin_palette(palette)
	ENVIRONMENT_ASSET.update_shared_palette(palette)
	# 2. 仅替换当前实例材质颜色，保留相机、角色位置和骨骼动作。
	for key in _character_materials:
		_character_materials[key].albedo_color = Color("d6d7dc") if key == &"skin" else palette.get(key)
	interior.refresh_palette()


## 把实际渲染写到既有user目录下的独立截图子目录。
func _save_capture() -> void:
	# 1. 等待渲染完成并检查目录错误，不覆盖既有截图。
	await RenderingServer.frame_post_draw
	var directory := capture_directory
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if error == OK:
		var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
		var path := directory.path_join("%s_%d.png" % [timestamp, Time.get_ticks_msec()])
		error = get_viewport().get_texture().get_image().save_png(path)
		_status.text = "画面已保存：" + ProjectSettings.globalize_path(path) if error == OK else "截图失败：%d" % error
	else:
		_status.text = "截图目录创建失败：%d" % error


## 生存扩展保留旧版单角色默认实现。
func _create_survival() -> Node:
	# 1. 只有V3工厂替换双角色协调逻辑。
	return SURVIVAL.new()


## 动物扩展保留旧版单目标默认实现。
func _create_bears() -> Node3D:
	# 1. 导航、资产和旧版攻击规则继续复用。
	return BEARS.new()


## 默认角色仍为原版场景，V3可独立接入生命动作。
func _create_player() -> CharacterBody3D:
	# 1. 旧版模型和移动实现不受扩展影响。
	return PLAYER_SCENE.instantiate()
