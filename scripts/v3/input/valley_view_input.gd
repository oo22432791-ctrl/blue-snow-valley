extends "res://scripts/session/valley_input_router.gd"
## 根窗口输入按视图转换，右键拖动期间只关闭瞄准／射击，不关闭移动。

var world: Node3D
var drag_view: String = ""
var pointer_root := Vector2.ZERO


## 释放右键必须早于GUI消费处理，避免跨菜单松键后仍继续转镜头。
func _input(event: InputEvent) -> void:
	if is_instance_valid(world.settings_ui) and world.settings_ui.opened:
		return
	# 1. P2设备先于GUI分发，不能借右侧确认键激活左侧菜单。
	if is_instance_valid(world) and is_instance_valid(world.local_controls):
		world.local_controls.observe_release(event)
		if is_instance_valid(world.rescue):
			world.rescue.observe_release(event)
		if world.local_controls.route_owned(event):
			get_viewport().set_input_as_handled()
	# 1. 这里只记录根坐标和释放，不让GUI中的按下事件穿透。
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		pointer_root = event.position
	if event is InputEventMouseButton and event.button_index == world.control_settings.data.mouse.orbit and not event.pressed:
		cancel_orbit()


## 使用当前屏幕所属相机，P2观察窗点击不能误触P1枪械。
func _unhandled_input(event: InputEvent) -> void:
	if is_instance_valid(world.settings_ui) and world.settings_ui.opened:
		return
	# 1. 同机P1只消费自己的WASD／左Shift，P2不读全局InputMap。
	if is_instance_valid(world.local_controls) and world.local_controls.handle_event(event):
		get_viewport().set_input_as_handled()
		return
	# 1. 启动阶段尚无视图时沿用原启动／暂停屏障。
	if not is_instance_valid(world.view_manager):
		super._unhandled_input(event)
		return
	if not allows_camera_input():
		return
	var manager: Node = world.view_manager
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_HOME:
		var id: String = drag_view if not drag_view.is_empty() else manager.view_at(pointer_root)
		if is_instance_valid(world.local_controls) and world.local_controls.active and id == "view.p2":
			id = ""
		if not id.is_empty():
			manager.views[id].rig.reset_view()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	pointer_root = event.position
	var hovered: String = manager.view_at(pointer_root)
	if is_instance_valid(world.local_controls) and world.local_controls.active and hovered == "view.p2":
		hovered = ""
	# 2. 一次拖动锁定原视图，经过中线不会突然控制另一屏。
	if event is InputEventMouseButton and event.button_index == world.control_settings.data.mouse.orbit:
		if event.pressed and not hovered.is_empty():
			drag_view = hovered
			world._has_pointer = false
			world.aim_hit = {}
			world.rifle._pending_fire = false
			world.snowball_game._throw_screen = Vector2.INF
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and not drag_view.is_empty():
		manager.views[drag_view].rig.orbit(event.relative)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var id: String = drag_view if not drag_view.is_empty() else hovered
		if not id.is_empty():
			manager.views[id].rig.request_zoom((-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0) * event.factor)
		get_viewport().set_input_as_handled()
		return
	# 3. 角色1射线只接收左屏局部坐标，观察窗没有未经实现的武器入口。
	if hovered != "view.p1" or not drag_view.is_empty():
		world._has_pointer = false
		world.aim_hit = {}
		get_viewport().set_input_as_handled()
		return
	var converted: InputEvent = event.duplicate()
	converted.position = manager.local_point("view.p1", event.position)
	# 所有鼠标主动作读取生效映射，旧左键不再落入V2输入入口。
	if allows_gameplay_input():
		if converted is InputEventMouseMotion:
			aim_moved.emit(converted.position)
		elif converted.pressed and converted.button_index == world.control_settings.data.mouse.fire:
			primary_requested.emit(converted.position)
			get_viewport().set_input_as_handled()


## 暂停／交互菜单立即结束拖动，保持原有移动清理与GUI互斥规则。
func set_context(value: Context) -> void:
	# 1. 关闭拖动不会重新发射此前未消费的左键。
	cancel_orbit()
	if value != Context.EXPLORATION and is_instance_valid(world.rescue):
		world.rescue.release("p1")
	super.set_context(value)


## 布局、读档、松键和失焦都能安全清除临时镜头意图。
func cancel_orbit() -> void:
	# 1. 不恢复旧鼠标瞄准点，等待下一次有效移动事件。
	drag_view = ""
	if is_instance_valid(world):
		world._has_pointer = false
		world.aim_hit = {}


## 切窗口不保留拖动按钮状态，焦点仍由父类统一处理。
func _notification(what: int) -> void:
	# 1. 父类保留原有持续按键释放；镜头额外清理自己的锁定视图。
	super._notification(what)
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel_orbit()
		if is_instance_valid(world.guard_ui):
			world.guard_ui.close()
		if is_instance_valid(world.guard):
			world.guard.cancel_requests()
	if is_instance_valid(world) and is_instance_valid(world.local_controls) and what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_IN]:
		world.local_controls.focus_changed(what == NOTIFICATION_APPLICATION_FOCUS_IN)


## 倒地人物不能借原单人输入或鼠标绕过角色生命限制。
func allows_gameplay_input() -> bool:
	# 1. 暂停、失焦和原上下文规则继续由父类统一负责。
	return super.allows_gameplay_input() and (not is_instance_valid(world.rescue) or world.rescue.can_act("p1"))


## 倒地只限制角色动作，仍能在本视图观察与缩放；菜单和暂停继续阻止操作。
func allows_camera_input() -> bool:
	# 1. 不调用带倒地限制的能力判定，保留M3独立镜头体验。
	return super.allows_gameplay_input()
