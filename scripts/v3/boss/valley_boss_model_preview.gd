extends Node3D
## M12原生模型审阅台；只采样GLB动作，不接探索状态、存档或Boss战斗。

const ORBIT = preload("res://scripts/v3/camera/valley_orbit_camera.gd")
const MODEL := "res://assets/models/v3/boss/ice_ridge_bear.glb"
const LABELS := {"Idle":"待机", "Walk":"行走", "Run":"奔跑", "ChargeWarning":"冲撞预警", "Charge":"冲撞步态", "Stop":"停步", "Slam":"单掌拍地", "Hit":"受击", "Fall":"侧倒"}
const LOOPS := ["Idle", "Walk", "Run", "Charge"]
const VIEW_TARGET := Vector3(.45, 1.7, 0)
const SPLIT_OVERVIEW_SIZE := 14.5
var model: Node3D
var dimensions: Dictionary
var animation: AnimationPlayer
var skeleton: Skeleton3D
var rigs: Array[Node3D] = []
var views: Array[SubViewport] = []
var containers: Array[SubViewportContainer] = []
var clip := "Idle"
var time := 0.0
var playing := true
var speed := 1.0
var split := false
var status: Label
var timeline: HSlider
var _scrubbing := false


## 创建与游戏相同米制的原生模型与正交相机，入口不加载会话或存档。
func _ready() -> void:
	# 1. 直接加载导出的资产，不用替身或非等比缩放演示尺寸。
	_environment()
	model = load(MODEL).instantiate()
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MODEL.get_basename()+"_manifest.json"))
	dimensions = manifest.dimensions_requested
	add_child(model)
	animation = model.find_children("*", "AnimationPlayer", true, false)[0]
	skeleton = model.find_children("*", "Skeleton3D", true, false)[0]
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var human: Node3D = load("res://assets/models/v3/characters/valley_explorer_recovery.glb").instantiate()
	human.position = Vector3(5.3, 0, 3.2)
	human.rotation_degrees.y = -18
	add_child(human)
	_label(Vector3(5.3, 1.9, 3.2), "角色参照 · 约1.5米")
	# 2. 双视图共享同一个真实模型，但使用各自的40度起始相机。
	_ui()
	select_clip("Idle")
	if "--m12-capture" in OS.get_cmdline_user_args():
		set_process(false)
		_capture()


## 雪面、环境与照明仅用于检查轮廓、阴影和脚掌接触。
func _environment() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("a3bacd")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("d2e2ed")
	environment.environment.ambient_light_energy = .65
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment.tonemap_exposure = .85
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(80, 80)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("d4e1ec")
	mat.roughness = 1.0
	floor_mesh.material_override = mat
	floor_mesh.position.y = -.005
	add_child(floor_mesh)
	# 1. 1米标尺用于直观看尺寸，不对角色或模型做相机补偿缩放。
	for index in range(11):
		var mark := MeshInstance3D.new()
		mark.mesh = BoxMesh.new()
		mark.mesh.size = Vector3(.09, .012, .35)
		mark.position = Vector3(-4.9+index, .004, 5.5)
		add_child(mark)
	_label(Vector3(.1, .3, 6), "地面刻度 · 每格1米")


## 场景标记参与深度测试，不能盖住模型脚部或当作碰撞证明。
func _label(at: Vector3, value: String) -> void:
	var text := Label3D.new()
	text.position = at
	text.text = value
	text.font_size = 30
	text.pixel_size = .006
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.modulate = Color("f3f7fa")
	text.outline_modulate = Color("234055")
	add_child(text)


## 按钮、时间轴与双视图均只控制审阅台，不修改正式按键设置。
func _ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(layout)
	var title := Label.new()
	title.text = "M12 冰脊雪熊 · 模型与动作预览"
	title.add_theme_font_size_override("font_size", 25)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(title)
	status = Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(status)
	var hint := Label.new()
	hint.text = "右键拖动／滚轮／Home；右屏 IJKL／UO／P；空格暂停。走跑为原地动作，场地碰撞尚未接入。"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(hint)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(row)
	for index in range(2):
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(container)
		containers.append(container)
		var view := SubViewport.new()
		view.world_3d = get_world_3d()
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		view.msaa_3d = Viewport.MSAA_2X
		container.add_child(view)
		views.append(view)
		var rig: Node3D = ORBIT.new()
		view.add_child(rig)
		rig.target = VIEW_TARGET
		rig.yaw_degrees = 38 if index == 0 else -75
		rig.pitch_degrees = 40
		rig._update_transform()
		rigs.append(rig)
	containers[1].hide()
	var actions := HFlowContainer.new()
	actions.alignment = FlowContainer.ALIGNMENT_CENTER
	layout.add_child(actions)
	for name_value: String in LABELS:
		_button(actions, LABELS[name_value], select_clip.bind(name_value))
	_button(actions, "播放／暂停", _toggle_play)
	_button(actions, "单屏／左右双屏", toggle_split)
	_button(actions, "正常／慢放", _toggle_speed)
	timeline = HSlider.new()
	timeline.max_value = 1
	timeline.step = .001
	timeline.custom_minimum_size.y = 28
	timeline.drag_started.connect(func(): _scrubbing = true)
	timeline.drag_ended.connect(func(_changed: bool): _scrubbing = false)
	timeline.value_changed.connect(_seek_fraction)
	layout.add_child(timeline)


## 统一建立按钮并取消焦点，空格只用于暂停而不重复激活上次按钮。
func _button(parent: Control, value: String, action: Callable) -> void:
	var button := Button.new()
	button.text = value
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)


## 切换原生动作时清零播放时间，非循环动作到末帧后保持姿态。
func select_clip(value: String) -> void:
	clip = value
	time = 0
	playing = true
	animation.play(clip)
	sample(0)


## 手动采样实际导入动作，避免动画播放器与时间轴重复推进。
func sample(seconds: float) -> void:
	time = clampf(seconds, 0, animation.get_animation(clip).length)
	animation.seek(time, true)
	animation.advance(0)
	status.text = "肩高%.1f米／体长约%.1f米／体宽%.2f米／冰脊峰顶%.2f米  ·  %s %.2f秒  ·  %s ×%.2f" % [dimensions.shoulder_height, dimensions.body_length, dimensions.width, dimensions.crest_peak, LABELS[clip], time, "播放中" if playing else "已暂停", speed]
	if not _scrubbing:
		timeline.set_value_no_signal(time/maxf(.001, animation.get_animation(clip).length))


## 两屏相机保留各自角度；切屏不改变模型姿态与真实尺寸。
func toggle_split() -> void:
	split = not split
	containers[1].visible = split
	# 1. 放大后的真实体长占满窄屏；初次切双屏拉远，仍允许自由缩放。
	if split:
		for rig: Node3D in rigs:
			rig.desired_size = maxf(rig.desired_size, SPLIT_OVERVIEW_SIZE)
			rig.camera.size = rig.desired_size


## 审阅台复位时双屏使用完整轮廓构图，正式探索相机默认值不变。
func _reset_view(index: int) -> void:
	rigs[index].reset_view()
	rigs[index].target = VIEW_TARGET
	if split:
		rigs[index].desired_size = SPLIT_OVERVIEW_SIZE
		rigs[index].camera.size = SPLIT_OVERVIEW_SIZE
	rigs[index]._update_transform()


## 播放开关只改变动画预览时间。
func _toggle_play() -> void:
	playing = not playing
	sample(time)


## 慢放用于观察脚掌接触，不能用于声称性能指标。
func _toggle_speed() -> void:
	speed = .25 if speed == 1 else 1


## 拖动时间轴会暂停，便于检查拍掌和侧倒中的任意姿态。
func _seek_fraction(value: float) -> void:
	playing = false
	sample(value*animation.get_animation(clip).length)


## 仅把显示时间推进至源动画末帧，不驱动探索物理或资源消耗。
func _process(delta: float) -> void:
	if playing:
		var length := animation.get_animation(clip).length
		var next := time+delta*speed
		if next >= length:
			if clip in LOOPS:
				next = fposmod(next, length)
			else:
				next = length
				playing = false
		sample(next)
	if split:
		var turn := Vector2(float(Input.is_physical_key_pressed(KEY_L))-float(Input.is_physical_key_pressed(KEY_J)), float(Input.is_physical_key_pressed(KEY_K))-float(Input.is_physical_key_pressed(KEY_I)))
		rigs[1].orbit(turn*delta*180)
		if Input.is_physical_key_pressed(KEY_U):
			rigs[1].request_zoom(-delta*4)
		if Input.is_physical_key_pressed(KEY_O):
			rigs[1].request_zoom(delta*4)


## 审阅输入沿用已确认的鼠标与镜头范围，不读写正式改键配置。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		rigs[0].orbit(event.relative)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			rigs[0].request_zoom(-1)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			rigs[0].request_zoom(1)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_HOME:
			_reset_view(0)
		if event.physical_keycode == KEY_P:
			_reset_view(1)
		if event.physical_keycode == KEY_SPACE:
			_toggle_play()
		if event.physical_keycode == KEY_ESCAPE:
			get_tree().quit()


## 采集真实Godot帧供造型审阅；不将原地动画当作场地移动和碰撞验收。
func _capture() -> void:
	# 1. 所有文件都来自同一导入模型，不输出二维替身图。
	await get_tree().process_frame
	var directory := "res://docs/validation/v3/"
	for spec: Dictionary in [
		{"name":"three_quarter", "clip":"Idle", "time":0, "yaw":38.0, "pitch":40.0},
		{"name":"side", "clip":"Idle", "time":0, "yaw":90.0, "pitch":25.0},
		{"name":"front", "clip":"Idle", "time":0, "yaw":0.0, "pitch":25.0},
		{"name":"rear", "clip":"Idle", "time":0, "yaw":160.0, "pitch":40.0},
		{"name":"warning", "clip":"ChargeWarning", "time":.7, "yaw":38.0, "pitch":40.0},
		{"name":"slam", "clip":"Slam", "time":.48, "yaw":-40.0, "pitch":25.0},
		{"name":"fall", "clip":"Fall", "time":1.9, "yaw":38.0, "pitch":40.0},
		{"name":"split", "clip":"Slam", "time":.48, "yaw":38.0, "pitch":40.0}]:
		select_clip(spec.clip)
		playing = false
		sample(float(spec.time))
		rigs[0].yaw_degrees = spec.yaw
		rigs[0].pitch_degrees = spec.pitch
		rigs[0]._update_transform()
		if spec.name == "split":
			toggle_split()
		for frame in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(directory+"m12_model_"+spec.name+".png")
	get_tree().quit()
