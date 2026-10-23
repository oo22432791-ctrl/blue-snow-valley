extends Node3D
## 雪地原型：昼夜配色、双角色移动碰撞、动态厚雪、落脚声音与短促雪粉。

const CameraRig = preload("res://scripts/camera/camera_rig.gd")
const PLAYER_SCENE = preload("res://scenes/characters/player.tscn")
const COMPANION_SCENE = preload("res://scenes/characters/snow_companion.tscn")
const SNOWBALL_GAME = preload("res://scripts/gameplay/snowball_game.gd")
const SNOW_TRACKS_SCRIPT = preload("res://scripts/snow/snow_tracks.gd")
const SNOW_SURFACE_SCRIPT = preload("res://scripts/snow/snow_surface.gd")
const FOOTSTEP_AUDIO_SCRIPT = preload("res://scripts/audio/footstep_audio.gd")
const SNOW_POWDER_SCENE = preload("res://scenes/effects/snow_powder.tscn")
const BLENDER_ASSETS: Dictionary = {
    "house": preload("res://assets/models/winter_house.glb"),
    "shed": preload("res://assets/models/winter_shed.glb"),
    "tree_13": preload("res://assets/models/tree_13.glb"),
    "tree_29": preload("res://assets/models/tree_29.glb"),
    "tree_51": preload("res://assets/models/tree_51.glb"),
    "fence": preload("res://assets/models/snow_fence.glb"),
    "snowman": preload("res://assets/models/snowman.glb"),
    "mound": preload("res://assets/models/snow_mound.glb"),
}
const PALETTES: Array[Resource] = [
	preload("res://materials/palettes/clear_blue.tres"),
	preload("res://materials/palettes/soft_blue.tres"),
	preload("res://materials/palettes/twilight_blue.tres"),
]
const CAPTURE_NAMES: Array[String] = ["clear_blue", "soft_blue", "twilight_blue"]
var _materials: Dictionary = {}
var _snow_material: ShaderMaterial
var _environment: Environment
var _sun: DirectionalLight3D
var _camera_rig: Node3D
var _warm_light: OmniLight3D
var _title: Label
var _subtitle: Label
var _camera_label: Label
var _status: Label
var _buttons: Array[Button] = []
var _swatches: Array[ColorRect] = []
var _palette_index: int = 0
var _capturing: bool = false
var _closing: bool = false
var _player: CharacterBody3D
var _snow_tracks: Node
var _snow_surface: Node3D
var _footstep_audio: Node3D
var _snow_powder: Node3D
var _sound_toggle: CheckButton
var _powder_toggle: CheckButton
var _npc_toggle: CheckButton
var _companion: CharacterBody3D
var _companion_materials: Dictionary = {}
var _navigation_region: NavigationRegion3D
var navigation_bake_ms: float = 0.0
var _npc_transitioning: bool = false
var _snowball_game: Node3D


## 构建小样，并根据显式命令行参数保存实机配色截图。
func _ready() -> void:
	# 1. 先创建共享材质、环境和固定的测试构图。
	_create_materials()
	_create_environment()
	_create_world()
	_create_companion_navigation()
	_create_companion()
	_create_step_feedback()
	_camera_rig = CameraRig.new()
	_camera_rig.name = "CameraRig"
	add_child(_camera_rig)
	_player.movement_camera = _camera_rig.camera
	# 雪球模块只管理投掷和计分，移动与踩雪仍由两个角色负责。
	_snowball_game = SNOWBALL_GAME.new()
	_snowball_game.name = "SnowballGame"
	_snowball_game.world = self
	_snowball_game.player = _player
	_snowball_game.companion = _companion
	_snowball_game.camera = _camera_rig.camera
	_snowball_game.snow_surface = _snow_surface
	add_child(_snowball_game)
	# 2. 创建观察控件，默认使用用户选定的白天清透蓝。
	_create_interface()
	_apply_palette(0)
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(request_close)
	# 3. 仅在明确要求时运行有界截图流程，不在普通启动中自动退出。
	if "--capture-all" in OS.get_cmdline_user_args():
		_capture_palette_set()


## 创建复用的哑光材质，让切换配色不重建任何几何。
func _create_materials() -> void:
	# 1. 每个语义色只创建一个材质实例。
	for key in ["snow", "wall", "roof", "wood", "coat", "scarf", "warm", "shadow", "skin"]:
		var material := StandardMaterial3D.new()
		material.roughness = 0.9
		material.metallic_specular = 0.2
		_materials[key] = material
	# 2. 暖窗使用轻微自发光，动态厚雪使用独立着色器。
	_materials["warm"].emission_enabled = true
	_materials["warm"].emission_energy_multiplier = 0.6
	_snow_material = ShaderMaterial.new()
	_snow_material.shader = preload("res://materials/snow.gdshader")


## 建立固定方向的长投影和可随方案变化的环境补光。
func _create_environment() -> void:
	# 1. 显式设置环境，避免依赖编辑器的预览光。
	var world_environment := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.ssao_enabled = true
	_environment.ssao_radius = 0.5
	_environment.ssao_intensity = 0.8
	world_environment.environment = _environment
	add_child(world_environment)
	# 2. 用低角度方向光形成参考图中的长投影。
	_sun = DirectionalLight3D.new()
	_sun.name = "WinterSun"
	_sun.rotation_degrees = Vector3(-31.0, -48.0, 0.0)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 75.0
	_sun.directional_shadow_blend_splits = true
	_sun.light_angular_distance = 0.7
	add_child(_sun)


## 创建动态厚雪与Blender小场景，固定配色采集时保留静态足迹样例。
func _create_world() -> void:
	# 1. 大面积雪地延伸到画面之外，不添加展示底座。
	_snow_tracks = SNOW_TRACKS_SCRIPT.new()
	_snow_tracks.name = "SnowTracks"
	_snow_tracks.snow_material = _snow_material
	add_child(_snow_tracks)
	_snow_surface = SNOW_SURFACE_SCRIPT.new()
	_snow_surface.name = "SnowSurface"
	_snow_surface.snow_material = _snow_material
	_snow_surface.tracks = _snow_tracks
	add_child(_snow_surface)
	_static_box(self, "GroundCollision", Vector3(0.0, -0.1, 0.0), Vector3(70.0, 0.2, 70.0))
	_create_boundaries()
	if "--capture-all" in OS.get_cmdline_user_args():
		_create_static_tracks()
	# 2. 以稀疏布局建立前景与远景，保留中间可阅读的雪面。
	_create_house(Vector3(-3.6, 0.0, -3.0))
	_create_shed(Vector3(4.9, 0.0, -4.8))
	_create_tree(Vector3(-7.0, 0.0, 1.9), 1.0, 13)
	_create_tree(Vector3(2.2, 0.0, -8.0), 1.25, 29)
	_create_tree(Vector3(7.2, 0.0, 0.3), 0.68, 51)
	_create_fence(Vector3(-7.2, 0.0, -5.8))
	# 3. 正式Blender小人沿用确认的角色高度、固定镜头和活动区域。
	_create_character(Vector3(1.25, 0.0, 2.2))
	_create_snowman(Vector3(4.5, 0.0, 3.5))
	for mound in [Vector4(-5.7, 0.01, -0.8, 0.8), Vector4(5.8, 0.0, -4.2, 0.65), Vector4(-7.5, 0.0, 3.0, 0.6)]:
		var snow_mound := _instantiate_asset(self, "mound", "SnowDrift", Vector3(mound.x, mound.y, mound.z))
		snow_mound.scale = Vector3(mound.w * 1.7, 0.14, mound.w)
		for mesh: MeshInstance3D in snow_mound.find_children("*", "MeshInstance3D", true, false):
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 放置连续的静态左右脚印，只验证颜色和镜头下的可读性。
func _create_static_tracks() -> void:
	# 1. 在固定曲线路径上交替采样双脚位置。
	var stamps := PackedVector4Array()
	for index in range(30):
		var t := float(index) / 29.0
		var point := Vector2(0.0, 7.0).lerp(Vector2(1.25, 2.35), t)
		point.x += sin(t * PI * 1.4) * 0.8
		point.x += -0.14 if index % 2 == 0 else 0.14
		stamps.append(Vector4(point.x, point.y, -0.1 + cos(t * PI * 1.4) * 0.3, 1.0))
	# 2. 增加房门附近的阴影区样例，检查暗部足迹对比。
	for index in range(12):
		var t := float(index) / 11.0
		var point := Vector2(-3.4, -0.9).lerp(Vector2(-0.1, 1.0), t)
		point.y += -0.14 if index % 2 == 0 else 0.14
		stamps.append(Vector4(point.x, point.y, -1.05, 0.95))
	# 3. 保留原M0路径样例，仅在配色采集模式写入统一足迹场。
	for index in range(stamps.size()):
		var stamp := stamps[index]
		_snow_tracks.stamp(Vector3(stamp.x, 0.0, stamp.y), stamp.z, index % 2 == 0, 1.0)


## 放置Blender房屋，保留原有旋转、碰撞包络和暖窗灯光。
func _create_house(at: Vector3) -> void:
	# 1. 模型尺寸与原占位一致，房屋不开放进入。
	var house := _instantiate_asset(self, "house", "House", at)
	house.rotation_degrees.y = -8.0
	_static_box(house, "HouseCollision", Vector3(0.0, 2.1, 0.0), Vector3(3.7, 4.2, 4.1))
	# 2. 灯光继续由Godot配色管理，不导入Blender灯光。
	_warm_light = OmniLight3D.new()
	_warm_light.omni_range = 2.5
	_warm_light.light_energy = 0.65
	add_child(_warm_light)
	_warm_light.global_position = house.to_global(Vector3(-0.87, 1.6, 2.4))


## 放置Blender木棚，保持原来的阻挡范围。
func _create_shed(at: Vector3) -> void:
	# 1. 视觉资产独立重导入，不从复杂渲染网格生成碰撞。
	var shed := _instantiate_asset(self, "shed", "Shed", at)
	# 2. 复用原来的低成本物理包络。
	_static_box(shed, "ShedCollision", Vector3(0.0, 0.75, 0.0), Vector3(1.5, 1.5, 1.65))


## 放置三种Blender枯树，缩放与位置沿用已确认的小场景布局。
func _create_tree(at: Vector3, scale_factor: float, seed_value: int) -> void:
	# 1. 三个导出资产来自不同种子，避免重复枝条轮廓。
	var tree := _instantiate_asset(self, "tree_%d" % seed_value, "WinterTree%d" % seed_value, at)
	tree.scale = Vector3.ONE * scale_factor
	# 2. 继续使用树干圆柱碰撞，细枝不形成难以察觉的障碍。
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.16
	shape.height = 3.0
	collision.shape = shape
	collision.position.y = 1.5
	body.add_child(collision)
	tree.add_child(body)


## 放置Blender木栏，保留四个木桩与横栏的物理阻挡。
func _create_fence(at: Vector3) -> void:
	# 1. 整体视觉使用一个语义材质网格。
	var fence := _instantiate_asset(self, "fence", "SnowFence", at)
	# 2. 碰撞尺寸与原型一致，避免换模型后出现新的通行规则。
	for index in range(4):
		_static_box(fence, "FencePostCollision", Vector3(index * 1.05, 0.5, 0.0), Vector3(0.13, 1.0, 0.13))
	_static_box(fence, "FenceCollision", Vector3(1.575, 0.5, 0.0), Vector3(3.3, 1.0, 0.12))


## 放置自制Blender骨骼角色，移动胶囊、厚雪与反馈接口保持独立。
func _create_character(at: Vector3) -> void:
	# 1. 在进入场景树前绑定雪面并替换模型各语义材质。
	_player = PLAYER_SCENE.instantiate()
	_player.position = at
	_player.snow_surface = _snow_surface
	_apply_asset_materials(_player.get_node("Visual/SnowChild"))
	add_child(_player)
	# 2. 落脚发射器仍首先更新雪场，声音和雪粉在之后订阅。
	_player.get_node("FootstepEmitter").foot_landed.connect(_snow_tracks.on_foot_landed)


## 从低成本静态碰撞烘焙散步区域，不读取高密度雪面的渲染网格。
func _create_companion_navigation() -> void:
	# 1. 地图与烘焙体素保持一致；边界和所有静态道具都参与路径绕障。
	var started := Time.get_ticks_usec()
	var map := get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, 0.2)
	NavigationServer3D.map_set_cell_height(map, 0.1)
	var mesh := NavigationMesh.new()
	mesh.cell_size = 0.2
	mesh.cell_height = 0.1
	mesh.agent_radius = 0.4
	mesh.agent_height = 1.5
	mesh.agent_max_climb = 0.1
	mesh.agent_max_slope = 35.0
	mesh.region_min_size = 1.0
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.filter_baking_aabb = AABB(Vector3(-8.6, -0.2, -8.4), Vector3(17.2, 7.0, 16.0))
	# 2. 烘焙只在小场景启动时执行一次；电脑目标另行排除屋顶与隔离岛。
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, self)
	NavigationServer3D.bake_from_source_geometry_data(mesh, source)
	_navigation_region = NavigationRegion3D.new()
	_navigation_region.name = "WanderNavigation"
	_navigation_region.navigation_mesh = mesh
	add_child(_navigation_region)
	navigation_bake_ms = float(Time.get_ticks_usec() - started) / 1000.0
	# 3. 玩家作为移动避让障碍，仍保留真实物理碰撞作最后防线。
	var obstacle := NavigationObstacle3D.new()
	obstacle.name = "CompanionAvoidance"
	obstacle.radius = 0.46
	obstacle.height = 1.5
	_player.add_child(obstacle)
	_player.movement_updated.connect(func(_previous: Vector3, _current: Vector3, velocity: Vector3) -> void: obstacle.velocity = velocity)


## 实例化同一骨骼小人，用独立蓝围巾材质区分电脑与玩家。
func _create_companion() -> void:
	# 1. 模型、动画和落脚源继承玩家场景；单独的AI仅提交移动意图。
	_companion = COMPANION_SCENE.instantiate()
	_companion.position = Vector3(5.8, 0.0, 5.5)
	_companion.snow_surface = _snow_surface
	_apply_asset_materials(_companion.get_node("Visual/SnowChild"))
	for key in ["coat", "scarf"]:
		_companion_materials[key] = _materials[key].duplicate()
	for node: MeshInstance3D in _companion.find_children("*", "MeshInstance3D", true, false):
		for index in range(node.mesh.get_surface_count()):
			var semantic: String = node.mesh.surface_get_material(index).resource_name
			if _companion_materials.has(semantic):
				node.set_surface_override_material(index, _companion_materials[semantic])
	add_child(_companion)
	# 2. 两套骨架和动画树独立；痕迹场共享，仍先压雪再播放其他反馈。
	_companion.get_node("WanderController").player = _player
	_companion.get_node("FootstepEmitter").foot_landed.connect(_snow_tracks.on_foot_landed)


## 放置Blender雪人，保留原来的尺度参照与碰撞包络。
func _create_snowman(at: Vector3) -> void:
	# 1. 视觉资产由Blender源文件管理。
	var snowman := _instantiate_asset(self, "snowman", "Snowman", at)
	# 2. 延续静态障碍范围，不扩大可见雪面中的阻挡。
	_static_box(snowman, "SnowmanCollision", Vector3(0.0, 0.6, 0.0), Vector3(0.75, 1.2, 0.75))


## 将声音与雪粉接到同一个落脚事件，足迹先写入，其他模块随后读取压实高度。
func _create_step_feedback() -> void:
	# 1. 音频与粒子分别管理固定池，供双方角色复用。
	_footstep_audio = FOOTSTEP_AUDIO_SCRIPT.new()
	_footstep_audio.name = "FootstepAudio"
	add_child(_footstep_audio)
	_snow_powder = SNOW_POWDER_SCENE.instantiate()
	_snow_powder.snow_surface = _snow_surface
	add_child(_snow_powder)
	# 2. 不新增步频计时器，所有反馈遵循同一次真实接触。
	for actor in [_player, _companion]:
		var emitter: Node = actor.get_node("FootstepEmitter")
		emitter.foot_landed.connect(_footstep_audio.on_foot_landed)
		emitter.foot_landed.connect(_snow_powder.on_foot_landed)


## 创建独立的低成本静态碰撞，不依赖渲染网格生成复杂碰撞。
func _static_box(parent: Node3D, node_name: String, at: Vector3, size: Vector3) -> void:
	# 1. 独立物理体只负责阻挡，不修改原来的视觉节点。
	var body := StaticBody3D.new()
	body.name = node_name
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	# 2. 使用局部位置，房屋旋转与树木比例由父节点继承。
	parent.add_child(body)
	body.position = at


## 限定当前小场地的活动区域，确保固定相机能继续看到玩家。
func _create_boundaries() -> void:
	# 1. 四周薄墙只参与物理，保持开阔雪面视觉。
	_static_box(self, "WestBoundary", Vector3(-8.8, 1.5, 0.0), Vector3(0.4, 3.0, 18.0))
	_static_box(self, "EastBoundary", Vector3(8.8, 1.5, 0.0), Vector3(0.4, 3.0, 18.0))
	_static_box(self, "NorthBoundary", Vector3(0.0, 1.5, -8.6), Vector3(18.0, 3.0, 0.4))
	_static_box(self, "SouthBoundary", Vector3(0.0, 1.5, 7.8), Vector3(18.0, 3.0, 0.4))


## 实例化独立glTF资产，并以共享语义材质保持昼夜换色。
func _instantiate_asset(parent: Node3D, key: String, node_name: String, at: Vector3) -> Node3D:
	# 1. 导出资产使用米制、地面原点和统一坐标方向。
	var scene: PackedScene = BLENDER_ASSETS[key]
	var instance: Node3D = scene.instantiate()
	instance.name = node_name
	instance.position = at
	parent.add_child(instance)
	# 2. 不依赖导出时的固定色值，继续使用用户确认的配色资源。
	_apply_asset_materials(instance)
	return instance


## 逐表面绑定导出材质名，保留蒙皮及一个网格内的不同语义颜色。
func _apply_asset_materials(node: Node) -> void:
	# 1. 只覆盖颜色材质，不修改导入网格、骨架、动画或碰撞。
	if node is MeshInstance3D:
		for index in range(node.mesh.get_surface_count()):
			var source_material: Material = node.mesh.surface_get_material(index)
			if source_material != null and _materials.has(source_material.resource_name):
				node.set_surface_override_material(index, _materials[source_material.resource_name])
			else:
				push_error("M5 asset has an unknown semantic material")
	# 2. 对所有子节点递归，支持角色和环境资产的不同层级。
	for child in node.get_children():
		_apply_asset_materials(child)


## 创建简单的配色观察界面；这些是M0观察控件，不是最终游戏HUD。
func _create_interface() -> void:
	# 1. 在独立画布中放置标题与配色切换。
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	margin.add_theme_constant_override("margin_left", 42)
	margin.add_theme_constant_override("margin_right", 42)
	margin.add_theme_constant_override("margin_top", 32)
	root.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color("1b3553"))
	column.add_child(_title)
	_subtitle = Label.new()
	_subtitle.add_theme_color_override("font_color", Color("2d5073"))
	column.add_child(_subtitle)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)
	for index in range(PALETTES.size()):
		var button := Button.new()
		button.text = "%d  %s" % [index + 1, PALETTES[index].display_name]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(180.0, 40.0)
		button.pressed.connect(_apply_palette.bind(index))
		row.add_child(button)
		_buttons.append(button)
	# 2. 两个独立开关用于比较画面、声音反馈，不影响移动与足迹。
	var feedback_row := HBoxContainer.new()
	feedback_row.add_theme_constant_override("separation", 18)
	column.add_child(feedback_row)
	_sound_toggle = CheckButton.new()
	_sound_toggle.text = "M  踩雪声音"
	_sound_toggle.button_pressed = true
	_sound_toggle.focus_mode = Control.FOCUS_NONE
	_sound_toggle.toggled.connect(set_sound_enabled)
	feedback_row.add_child(_sound_toggle)
	_powder_toggle = CheckButton.new()
	_powder_toggle.text = "P  轻微雪粉"
	_powder_toggle.button_pressed = true
	_powder_toggle.focus_mode = Control.FOCUS_NONE
	_powder_toggle.toggled.connect(set_powder_enabled)
	feedback_row.add_child(_powder_toggle)
	_npc_toggle = CheckButton.new()
	_npc_toggle.text = "N  电脑小人"
	_npc_toggle.button_pressed = true
	_npc_toggle.focus_mode = Control.FOCUS_NONE
	_npc_toggle.toggled.connect(set_npc_enabled)
	feedback_row.add_child(_npc_toggle)
	# 3. 底部使用轻量文字显示观察方式与截图结果。
	var footer := VBoxContainer.new()
	footer.position = Vector2(42.0, 835.0)
	footer.add_theme_constant_override("separation", 7)
	root.add_child(footer)
	var swatch_row := HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	footer.add_child(swatch_row)
	for index in range(6):
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(43.0, 9.0)
		swatch_row.add_child(swatch)
		_swatches.append(swatch)
	_camera_label = Label.new()
	_camera_label.add_theme_color_override("font_color", Color("254566"))
	footer.add_child(_camera_label)
	var help := Label.new()
	help.text = "WASD / 方向键 移动 · Shift 跑步 · C 清脚印 · 1–3 配色 · 滚轮 远近 · PgUp / PgDn 俯角 · R 镜头 · F12 截图"
	help.add_theme_color_override("font_color", Color("254566"))
	help.add_theme_font_size_override("font_size", 15)
	footer.add_child(help)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("254566"))
	_status.add_theme_font_size_override("font_size", 14)
	footer.add_child(_status)


## 仅替换颜色和光照参数，保留几何、脚印与镜头供公平比较。
func _apply_palette(index: int) -> void:
	# 1. 将语义色应用到所有共享材质。
	_palette_index = clampi(index, 0, PALETTES.size() - 1)
	var palette: Resource = PALETTES[_palette_index]
	for key in ["snow", "wall", "roof", "wood", "coat", "scarf", "warm", "shadow"]:
		_materials[key].albedo_color = palette.get(key)
	_materials["skin"].albedo_color = palette.snow.lerp(palette.warm, 0.42)
	_companion_materials["coat"].albedo_color = palette.coat.lerp(palette.snow, 0.25)
	_companion_materials["scarf"].albedo_color = palette.wall.lerp(palette.snow, 0.45)
	_materials["warm"].emission = palette.warm
	_snow_material.set_shader_parameter("snow_color", palette.snow)
	_snow_material.set_shader_parameter("footprint_color", palette.shadow)
	_snow_powder.apply_color(palette.snow)
	_snowball_game.apply_palette(palette.snow)
	# 2. 同步环境补光、方向光和暖窗灯光。
	_environment.background_color = palette.snow
	_environment.ambient_light_color = palette.ambient
	_environment.ambient_light_energy = palette.ambient_energy
	_sun.light_color = palette.sunlight
	_sun.light_energy = palette.light_energy
	_warm_light.light_color = palette.warm
	# 3. 显示配色资源中记录的昼夜用途与当前选择状态。
	_title.text = "蓝色雪境 / " + palette.display_name
	_subtitle.text = palette.description + "   ·   厚雪脚步稍慢，脚印约30秒恢复"
	for button_index in range(_buttons.size()):
		_buttons[button_index].set_pressed_no_signal(button_index == _palette_index)
	var swatch_colors: Array[Color] = [palette.snow, palette.shadow, palette.wall, palette.roof, palette.scarf, palette.warm]
	for swatch_index in range(_swatches.size()):
		_swatches[swatch_index].color = swatch_colors[swatch_index]
	_update_camera_label()


## 更新相机观察参数的可见说明。
func _update_camera_label() -> void:
	# 1. 保持显示值与实际镜头一致。
	_camera_label.text = "正交俯视  /  俯角 %.0f°  /  视野 %.1f m" % [_camera_rig.pitch_degrees, _camera_rig.view_size]


## 同步声音模块与可见开关，键盘和鼠标操作使用同一路径。
func set_sound_enabled(value: bool) -> void:
	# 1. 停止或恢复本模块，保持其他落脚反馈继续工作。
	_footstep_audio.set_enabled(value)
	_snowball_game.set_feedback(value, _snow_powder.enabled)
	# 2. 无信号更新防止开关回调递归。
	_sound_toggle.set_pressed_no_signal(value)


## 同步雪粉模块与可见开关，关闭时立即清除残留。
func set_powder_enabled(value: bool) -> void:
	# 1. 只控制短时粒子，不清除已经踩出的脚印。
	_snow_powder.set_enabled(value)
	_snowball_game.set_feedback(_footstep_audio.enabled, value)
	# 2. 键盘状态与鼠标开关保持一致。
	_powder_toggle.set_pressed_no_signal(value)


## 开关电脑小人供体验与性能比较；原有足迹继续按30秒恢复。
func set_npc_enabled(value: bool) -> void:
	# 0. 恢复位置需要等待一次物理同步，期间忽略重复开关请求。
	if _npc_transitioning or _closing:
		return
	# 1. 恢复时先确认胶囊空位，避免玩家站在隐藏角色的位置时相互嵌入。
	if value and not _companion.visible:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = _companion.get_node("BodyCollision").shape
		query.exclude = [_companion.get_rid()]
		var candidates: Array[Vector3] = [_companion.global_position, Vector3(5.8, 0.0, 5.5), Vector3(0.0, 0.0, 5.0), Vector3(-5.5, 0.0, 5.0)]
		var found := false
		for candidate in candidates:
			# 底部留出1厘米，防止将地面接触误判为占位。
			query.transform = Transform3D(Basis.IDENTITY, candidate + Vector3(0.0, 0.76, 0.0))
			if get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
				_companion.global_position = candidate
				found = true
				break
		if not found:
			_npc_toggle.set_pressed_no_signal(false)
			_status.text = "电脑小人附近没有空位，稍后再开启"
			return
		# 物理服务器先接收隐藏角色的新位置，再恢复碰撞，避免瞬移被当成平台运动。
		_npc_transitioning = true
		_npc_toggle.disabled = true
		await get_tree().physics_frame
		await get_tree().process_frame
		_npc_transitioning = false
		if _closing:
			return
		_npc_toggle.disabled = false
	# 2. 隐藏时同时停用控制器和碰撞，不能留下不可见的阻挡。
	_companion.get_node("WanderController").set_enabled(value)
	_companion.set_physics_process(value)
	_companion.visible = value
	_companion.collision_layer = 1 if value else 0
	_companion.collision_mask = 1 if value else 0
	_npc_toggle.set_pressed_no_signal(value)
	_snowball_game.on_companion_enabled(value)


## 关闭窗口前停止落脚并让混音线程回收声尾，防止播放中的WAV残留引用。
func request_close(exit_code: int = 0) -> void:
	# 1. 防止重复关闭请求，停掉后续落脚与两个反馈模块。
	if _closing:
		return
	_closing = true
	_snowball_game.set_enabled(false)
	_player.set_physics_process(false)
	_companion.get_node("WanderController").set_enabled(false)
	_companion.set_physics_process(false)
	set_sound_enabled(false)
	set_powder_enabled(false)
	_sound_toggle.disabled = true
	_powder_toggle.disabled = true
	_npc_toggle.disabled = true
	# 2. 留出短暂的真实时间让音频线程完成回收，不受游戏时间缩放影响。
	await get_tree().create_timer(0.12, true, false, true).timeout
	get_tree().quit(exit_code)


## 接收观察控件；移动由角色控制器处理，俯角使用PageUp/Down避免方向键冲突。
func _unhandled_input(event: InputEvent) -> void:
	# 1. 自动采集期间锁定观察参数，保证三张截图构图一致。
	if _capturing or _closing:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1, KEY_2, KEY_3:
				_apply_palette(event.keycode - KEY_1)
			KEY_PAGEUP:
				_camera_rig.pitch_degrees += 3.0
			KEY_PAGEDOWN:
				_camera_rig.pitch_degrees -= 3.0
			KEY_R:
				_camera_rig.reset_view()
			KEY_F12:
				_save_user_capture()
			KEY_C:
				_snow_tracks.clear_tracks()
				_status.text = "脚印已清空"
			KEY_M:
				set_sound_enabled(not _footstep_audio.enabled)
			KEY_P:
				set_powder_enabled(not _snow_powder.enabled)
			KEY_N:
				set_npc_enabled(not _companion.visible)
	# 2. 滚轮只调整正交观察大小。
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_rig.view_size -= 1.0
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_rig.view_size += 1.0
	_camera_rig.update_camera()
	_update_camera_label()


## 把当前实际渲染画面写到用户数据目录，适用于普通预览。
func _save_user_capture() -> void:
	# 1. 等待本帧渲染完成，避免读取未完成的渲染目标。
	await RenderingServer.frame_post_draw
	var directory := "user://captures"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := directory.path_join("%s_%s.png" % [CAPTURE_NAMES[_palette_index], timestamp])
	# 2. 成功与失败都向用户显示真实保存结果。
	var error := get_viewport().get_texture().get_image().save_png(path)
	_status.text = "画面已保存：" + ProjectSettings.globalize_path(path) if error == OK else "保存失败，错误码：%d" % error


## 显式截图模式：按同一构图采集三组实际渲染，失败时返回非零退出码。
func _capture_palette_set() -> void:
	# 1. 创建项目内的验收目录，避免把截图写到不明确的位置。
	_capturing = true
	_snowball_game.set_enabled(false)
	for button in _buttons:
		button.disabled = true
	_player.set_physics_process(false)
	_companion.get_node("WanderController").set_enabled(false)
	_companion.set_physics_process(false)
	_snow_tracks.set_process(false)
	_snow_tracks.flush_pending()
	var directory := ProjectSettings.globalize_path("res://docs/validation")
	var directory_error := DirAccess.make_dir_recursive_absolute(directory)
	if directory_error != OK:
		push_error("Cannot create capture directory: %d" % directory_error)
		get_tree().quit(1)
		return
	_camera_rig.reset_view()
	# 2. 每组颜色等待真实渲染稳定后读取PNG，不使用无界面渲染替代。
	for index in range(PALETTES.size()):
		_apply_palette(index)
		for frame_index in range(24):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := directory.path_join("m0_%s.png" % CAPTURE_NAMES[index])
		var error := image.save_png(path)
		if error != OK:
			push_error("Capture failed: %s (%d)" % [path, error])
			get_tree().quit(1)
			return
		print("M0_CAPTURE_OK ", path)
	# 3. 成功收集三组后退出；它只代表采集完成，不代表用户已确认美术。
	print("M0_CAPTURE_SET_COMPLETE renderer=", RenderingServer.get_current_rendering_method())
	get_tree().quit(0)
