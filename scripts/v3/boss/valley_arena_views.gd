extends CanvasLayer
## 两个实际视口、固定菜单与逐视图遮挡；不复制物理世界。
const ORBIT = preload("res://scripts/v3/camera/valley_orbit_camera.gd")
const FADE = preload("res://scripts/buildings/occlusion_fade.gd")
const FOCUS_WEIGHT := .55
var stage: Node3D
var rigs: Array[Node3D] = []
var views: Array[SubViewport] = []
var containers: Array[SubViewportContainer] = []
var status: Label
var phase: Label
var mode: OptionButton
var split := false
var records: Array[Dictionary] = []
var outlines: Array[ShaderMaterial] = []
var edge_labels: Array[Label] = []
var fade = FADE.new()
var _ray_age := 0.0

## 菜单在暂停中可操作，物理世界保持场景树统一暂停。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	var title := Label.new()
	title.text = "雪熊与场地小样"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size",26)
	layout.add_child(title)
	phase = Label.new()
	phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(phase)
	var buttons := HFlowContainer.new()
	buttons.alignment = FlowContainer.ALIGNMENT_CENTER
	layout.add_child(buttons)
	for item: Array in [["待机","Idle"],["走到落点","Walk"],["跑到落点","Run"],["预警并冲撞","ChargeWarning"],["拍地","Slam"],["受击","Hit"],["侧倒","Fall"]]:
		_button(buttons,item[0],stage.boss_command.bind(item[1]))
	_button(buttons,"设置落点",func() -> void: stage.selecting = true;stage.notice("点击地面设置落点，再选择雪熊动作。"))
	_button(buttons,"重置冰壁",stage.reset_walls)
	_button(buttons,"左右双屏",toggle_split)
	_button(buttons,"暂停／继续",stage.toggle_pause)
	_button(buttons,"返回主菜单",stage.return_to_menu)
	mode = OptionButton.new()
	for text: String in ["P2 · AI跟随","P2 · 键盘","P2 · Xbox手柄","P2 · 待命"]:
		mode.add_item(text)
	mode.item_selected.connect(stage.set_mode)
	buttons.add_child(mode)
	status = Label.new()
	status.text = stage.default_hint()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(status)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(row)
	for index in range(2):
		var container := SubViewportContainer.new()
		container.stretch = true
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(container)
		containers.append(container)
		var view := SubViewport.new()
		view.world_3d = stage.get_world_3d()
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		view.msaa_3d = Viewport.MSAA_2X
		container.add_child(view)
		views.append(view)
		var rig: Node3D = ORBIT.new()
		rig.process_mode = Node.PROCESS_MODE_PAUSABLE
		rig.tracked_actor = stage.players[index]
		view.add_child(rig)
		rig.camera.cull_mask = 1|(2 << index)
		rig.desired_size = 18
		rig.camera.size = 18
		rig.tracked_actor = null
		rig.target = stage.players[index].global_position.lerp(stage.boss.global_position,FOCUS_WEIGHT)+Vector3.UP*1.6
		rig._update_transform()
		stage.players[index].movement_camera = rig.camera
		rigs.append(rig)
		var overlay := CanvasLayer.new()
		view.add_child(overlay)
		var role := Label.new()
		role.text = "P%d" % (index+1)
		role.position = Vector2(15,12)
		role.add_theme_color_override("font_shadow_color",Color("182e47"))
		role.add_theme_constant_override("shadow_offset_x",2)
		role.add_theme_constant_override("shadow_offset_y",2)
		overlay.add_child(role)
		var edge := Label.new()
		edge.add_theme_color_override("font_shadow_color",Color("182e47"))
		edge.add_theme_constant_override("shadow_offset_x",2)
		edge.add_theme_constant_override("shadow_offset_y",2)
		overlay.add_child(edge)
		edge_labels.append(edge)
	containers[1].hide()
	# 1. 只创建显示副本，原网格保留唯一阴影，真实墙体始终只有一份。
	for source: MeshInstance3D in stage.geometry.find_children("*","MeshInstance3D",true,false):
		if source == stage.geometry.floor_mesh:
			continue
		var copies: Array[MeshInstance3D] = []
		for index in range(2):
			var copy := MeshInstance3D.new()
			copy.mesh = source.mesh
			copy.layers = 2 << index
			copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			for surface in range(source.mesh.get_surface_count()):
				copy.set_surface_override_material(surface,source.get_active_material(surface))
			copies.append(copy)
		# 在收集结束后挂副本，避免把自己的副本再次当作源。
		records.append({"source":source,"copies":copies,"opacity":[1.0,1.0]})
	for record: Dictionary in records:
		record.source.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		for copy: MeshInstance3D in record.copies:
			record.source.add_child(copy)
	for player: Node3D in stage.players:
		var outline := ShaderMaterial.new()
		outline.shader = preload("res://materials/v3/occluded_actor.gdshader")
		for mesh: MeshInstance3D in player.find_children("*","MeshInstance3D",true,false):
			mesh.material_overlay = outline
		outlines.append(outline)
	apply_camera_settings()

## 控件不保留焦点，持续移动键不会反复触发上一个动作按钮。
func _button(parent: Control, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)

## 读取已有M10镜头设置，正式设置文件只读，不写临时选项。
func apply_camera_settings() -> void:
	for index in range(2):
		var page := "p1.mouse" if index == 0 else ("p2.gamepad" if stage.mode == 2 else "p2.keyboard")
		var config: Dictionary = stage.settings.data.cameras[page]
		rigs[index].orbit_sensitivity = .22*float(config.rotation)
		rigs[index].zoom_sensitivity = float(config.zoom)
		rigs[index].invert_vertical = config.invert

## 双屏只改变视口布局，两个角色、碰撞和动作时钟保持同一份。
func toggle_split() -> void:
	split = not split
	containers[1].visible = split

## 视线遮挡按相机分别计算，不透明度不会改变物理状态。
func _process(delta: float) -> void:
	var mask: int = stage.geometry.broken_mask
	phase.text = ("已暂停 · " if get_tree().paused else "")+"雪熊："+stage.action_name()+" · 冰壁："+str(2-int(mask&1)-int((mask>>1)&1))+"／2"
	if get_tree().paused:
		return
	# 远端雪熊仍有方位提示；自由拉近时不假装整个32米场地都能入镜。
	for index in range(2):
		var size := Vector2(views[index].size)
		if size.x < 100 or size.y < 100:
			continue
		var camera: Camera3D = rigs[index].camera
		var projected := camera.unproject_position(stage.boss.global_position+Vector3.UP*2.8)
		var outside := not Rect2(Vector2(40,40),size-Vector2(80,80)).has_point(projected)
		edge_labels[index].visible = outside
		if outside:
			var direction := projected-size*.5
			var amount := minf((size.x*.5-65)/maxf(.01,absf(direction.x)),(size.y*.5-35)/maxf(.01,absf(direction.y)))
			edge_labels[index].position = size*.5+direction*amount-Vector2(20,12)
			var angle := posmod(roundi(atan2(direction.y,direction.x)/(PI/4)),8)
			edge_labels[index].text = "雪熊 "+["→","↘","↓","↙","←","↖","↑","↗"][angle]
	for record: Dictionary in records:
		for index in range(2):
			var blocked := false
			var source: MeshInstance3D = record.source
			if source.is_visible_in_tree():
				var inverse := source.global_transform.affine_inverse()
				var from: Vector3 = inverse*rigs[index].camera.global_position
				var box := source.get_aabb()
				for target: Vector3 in [stage.players[index].global_position+Vector3.UP,stage.boss.global_position+Vector3.UP*2.8]:
					blocked = blocked or box.intersects_segment(from,inverse*target)
			var value := move_toward(float(record.opacity[index]),.17 if blocked else 1.0,delta/.28)
			record.opacity[index] = value
			fade.apply(record.copies[index],value)

## 物理遮挡轮廓与显示淡出分离，巨熊身体挡住角色时仍能辨认角色位置。
func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	# 1. 小样在角色和雪熊之间取景，仍保留各自旋转／缩放和18米上限。
	for index in range(2):
		var desired: Vector3 = stage.players[index].global_position.lerp(stage.boss.global_position,FOCUS_WEIGHT)+Vector3.UP*1.6
		rigs[index].target = rigs[index].target.lerp(desired,1-exp(-8*delta))
	for actor_index in range(2):
		var mask := 0
		for view_index in range(2):
			var actor: CharacterBody3D = stage.players[actor_index]
			var query := PhysicsRayQueryParameters3D.create(rigs[view_index].camera.global_position,actor.global_position+Vector3.UP,1|4|8)
			if not stage.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
				mask |= 2 << view_index
		outlines[actor_index].set_shader_parameter("occluded_view_mask",mask)

## 暂停中仍把恢复键和手柄连接事件交给同一个小样控制入口。
func _input(event: InputEvent) -> void:
	stage.handle_event(event)

## 将主窗口鼠标坐标转换为真实子视口坐标，分屏后瞄准不偏移。
func local_screen(index: int, screen: Vector2) -> Vector2:
	return (screen-containers[index].global_position)/containers[index].size*Vector2(views[index].size)
