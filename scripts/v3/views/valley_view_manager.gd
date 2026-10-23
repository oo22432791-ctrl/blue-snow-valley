extends Node
## 同一物理世界的独立相机／视口；双视图观察不冒充M4第二玩家控制。

const ORBIT_CAMERA = preload("res://scripts/v3/camera/valley_orbit_camera.gd")
const P1_LAYER: int = 2
const P2_LAYER: int = 4
var world: Node3D
var split_enabled: bool = false
var views: Dictionary = {}
var _canvas: CanvasLayer
var _divider: ColorRect


## 两个视口共用World3D，人物、门、天气和物资不复制。
func _ready() -> void:
	# 1. 主视口仍承载菜单，3D由明确的子视口纹理展示。
	_canvas = CanvasLayer.new()
	_canvas.layer = -1
	add_child(_canvas)
	world.get_viewport().audio_listener_enable_3d = false
	for id: String in ["view.p1", "view.p2"]:
		var viewport := SubViewport.new()
		viewport.name = "P1Viewport" if id == "view.p1" else "P2Viewport"
		viewport.world_3d = world.get_world_3d()
		viewport.msaa_3d = world.get_viewport().msaa_3d
		viewport.handle_input_locally = false
		viewport.audio_listener_enable_3d = id == "view.p1"
		add_child(viewport)
		var texture := TextureRect.new()
		texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture.texture = viewport.get_texture()
		texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture.stretch_mode = TextureRect.STRETCH_SCALE
		_canvas.add_child(texture)
		var actor_id := "p1" if id == "view.p1" else "p2"
		var rig: Node3D = world.camera_rig if actor_id == "p1" else ORBIT_CAMERA.new()
		# 2. P1保留同一个相机对象，既有移动／枪口引用不会失效。
		if actor_id == "p1":
			rig.reparent(viewport)
			world.actor_registry.unregister_view(id)
		else:
			rig.tracked_actor = world.snowball_game.companion
			rig.snow_surface = world.snow_surface
			viewport.add_child(rig)
		var layer: int = P1_LAYER if actor_id == "p1" else P2_LAYER
		rig.camera.cull_mask = 1 | layer
		world.actor_registry.register_view(id, actor_id, rig.camera, viewport)
		var label := Label.new()
		label.add_theme_color_override("font_color", Color("f1f7ff"))
		label.add_theme_font_size_override("font_size", 20)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(label)
		views[id] = {"viewport": viewport, "rig": rig, "actor_id": actor_id,
			"layer": layer, "texture": texture, "label": label, "rect": Rect2()}
	_divider = ColorRect.new()
	_divider.color = Color("20344d")
	_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_divider)
	world.get_viewport().size_changed.connect(_layout)
	# 3. 瞄准指示属于P1视图，不把另一个屏幕的射线反馈叠到伙伴画面。
	world._aim_marker.layers = P1_LAYER
	world.snowball_game._marker.layers = P1_LAYER
	set_split(false)


## 单屏和左右观察只改变显示布局，不切角色控制来源或重建世界。
func set_split(enabled: bool) -> void:
	# 1. 交接前释放旧拖动和瞄准，旧坐标不能留到新尺寸视口。
	split_enabled = enabled
	world.snow_surface.set_second_view(enabled)
	world.input_router.cancel_orbit()
	world._has_pointer = false
	world.aim_hit = {}
	views["view.p2"].viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	views["view.p1"].viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	views["view.p2"].texture.visible = enabled
	_divider.visible = enabled
	for binding: Dictionary in views.values():
		binding.label.visible = enabled
	# 2. 原单人HUD保留，观察小样用逐屏摘要避免旧全屏文字跨屏。
	for node: CanvasItem in [world._controls_label, world._status, world._location_label, world._weather_label, world.survival_ui._hud.get_parent(), world.survival_ui._hint]:
		node.visible = not enabled
	_layout()


## 根据根视口逻辑尺寸布局，窗口伸缩和左右边界使用同一组矩形。
func _layout() -> void:
	# 1. 奇数宽度的余像素归右屏，视口坐标转换按实际尺寸缩放。
	var size: Vector2 = world.get_viewport().get_visible_rect().size
	var left_width := floorf(size.x * .5) if split_enabled else size.x
	for id: String in views:
		var binding: Dictionary = views[id]
		var rect := Rect2(Vector2.ZERO, Vector2(left_width, size.y)) if id == "view.p1" else Rect2(Vector2(left_width, 0), Vector2(size.x - left_width, size.y))
		binding.rect = rect
		binding.texture.position = rect.position
		binding.texture.size = rect.size
		binding.viewport.size = Vector2i(maxi(2, int(rect.size.x)), maxi(2, int(rect.size.y)))
		binding.label.position = rect.position + Vector2(16, 16)
	_divider.position = Vector2(left_width - 1, 0)
	_divider.size = Vector2(2, size.y)


## 返回指针所在的唯一视图，界外坐标不会默认指向另一名角色。
func view_at(point: Vector2) -> String:
	# 1. 只有真正显示的视图才参与命中。
	if views["view.p1"].rect.has_point(point):
		return "view.p1"
	if split_enabled and views["view.p2"].rect.has_point(point):
		return "view.p2"
	return ""


## 根窗口事件转换到相应相机的局部像素，禁止跨屏使用旧坐标。
func local_point(id: String, point: Vector2) -> Vector2:
	# 1. 逻辑矩形与实际视口尺寸不完全一致时仍能正确投影。
	var binding: Dictionary = views[id]
	return (point - binding.rect.position) * Vector2(binding.viewport.size) / binding.rect.size


## 观察摘要读取各自状态，P2标签明确表示观察而非真人控制。
func _process(_delta: float) -> void:
	# 1. 正式逐角色图标HUD由M10实现，此处不显示常驻操作段落。
	if not split_enabled:
		return
	var actors: Dictionary = world.actor_registry.capture_actors()
	for id: String in views:
		var actor: Dictionary = actors[views[id].actor_id]
		var local_p2: bool = is_instance_valid(world.local_controls) and world.local_controls.active
		views[id].label.text = ("P1" if id == "view.p1" else ("P2" if local_p2 else "P2 · 观察")) + "　暖意%d · 柴火%d · 弹药%d" % [ceili(actor.warmth), actor.carried, actor.rifle.chamber + actor.rifle.reserve]
