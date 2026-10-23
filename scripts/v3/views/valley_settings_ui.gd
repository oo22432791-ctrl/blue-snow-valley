extends CanvasLayer
## 操作说明和设置共用生效映射；编辑草稿、捕获、应用、取消有独立生命周期。

var world: Node3D
var opened: bool = false
var draft: Dictionary = {}
var capture: String = ""
var page: int = 0
var _root: Control
var _panel: PanelContainer
var _rows: VBoxContainer
var _status: Label
var _pages: OptionButton
var _return_focus: Control
const PAGES = ["P1 · 键盘", "P1 · 鼠标与镜头", "P2 · 键盘与镜头", "P2 · 手柄与镜头", "操作说明"]


## 设置在暂停中仍可操作，所有按钮只编辑草稿而不提交游戏动作。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 35
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(.025,.055,.09,.96)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_panel = PanelContainer.new()
	_root.add_child(_panel)
	var margin := MarginContainer.new()
	for edge: String in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_"+edge,16)
	_panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",10)
	margin.add_child(column)
	var title := Label.new()
	title.text = "操作与设置"
	title.add_theme_font_size_override("font_size",26)
	column.add_child(title)
	_pages = OptionButton.new()
	for name_text: String in PAGES:
		_pages.add_item(name_text)
	_pages.item_selected.connect(func(index: int) -> void:
		page = index
		capture = ""
		_status.text = ""
		_build_rows())
	column.add_child(_pages)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.y = 42
	column.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation",8)
	scroll.add_child(_rows)
	var footer := HFlowContainer.new()
	column.add_child(footer)
	_button(footer,"应用并保存",apply_draft)
	_button(footer,"取消／返回",close)
	_button(footer,"当前角色／设备恢复默认",restore_page)
	world.get_viewport().size_changed.connect(_layout)
	_root.hide()
	_layout()


## 从主菜单或暂停菜单进入；退出设置不会暗中恢复世界模拟。
func open(help_only: bool = false) -> void:
	# 1. 先冻结并释放所有输入，再复制当前生效设置。
	world.set_session_paused(true)
	world.local_controls.clear_all()
	world.input_router.cancel_orbit()
	_return_focus = world.get_viewport().gui_get_focus_owner()
	draft = world.control_settings.data.duplicate(true)
	page = 4 if help_only else 0
	_pages.select(page)
	capture = ""
	_status.text = "修改后点应用生效；Esc／B取消捕获，关闭设置放弃尚未应用的编辑。"
	opened = true
	_root.show()
	_build_rows()
	_pages.grab_focus()


## 放弃尚未提交的草稿和捕获意图，返回原菜单而非直接进入游戏。
func close() -> void:
	capture = ""
	opened = false
	_root.hide()
	world.local_controls.clear_all()
	world.input_router._release_actions()
	if is_instance_valid(_return_focus):
		_return_focus.grab_focus()


## 完整草稿验证和写盘均成功后再让输入消费者读取新映射。
func apply_draft() -> void:
	var problem: String = world.control_settings.apply(draft)
	if not problem.is_empty():
		_status.text = problem
		return
	world.apply_control_settings()
	draft = world.control_settings.data.duplicate(true)
	_status.text = "已应用并保存到本机；世界进度未改变。"
	capture = ""
	_build_rows()


## 恢复只修改当前页的草稿，不抹除另一角色／设备的设置。
func restore_page() -> void:
	var defaults: Dictionary = world.control_settings.defaults()
	if page in [0,2]:
		var actor := "p1" if page == 0 else "p2"
		for id: String in defaults.keyboard:
			if id.begins_with(actor+"."):
				draft.keyboard[id] = defaults.keyboard[id]
	elif page == 1:
		draft.mouse = defaults.mouse.duplicate()
	elif page == 3:
		draft.gamepad = defaults.gamepad.duplicate()
	else:
		_status.text = "先选择要恢复的角色／设备页。"
		return
	var camera_page := _camera_page()
	if not camera_page.is_empty():
		draft.cameras[camera_page] = defaults.cameras[camera_page].duplicate()
	capture = ""
	_status.text = "已恢复当前页默认值；点应用后才生效。"
	_build_rows()


## 设置界面先于玩法处理捕获，确认、取消和手柄Menu都不会穿透射击。
func _input(event: InputEvent) -> void:
	if not opened:
		return
	if event is InputEventKey and event.echo:
		get_viewport().set_input_as_handled()
		return
	if not capture.is_empty():
		_capture_event(event)
		get_viewport().set_input_as_handled()
		return
	if (event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE) or (event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_B,JOY_BUTTON_START]):
		close()
		get_viewport().set_input_as_handled()


## 捕获只接受对应设备，冲突显示占用动作并保留原草稿。
func _capture_event(event: InputEvent) -> void:
	# 1. 固定取消键不被录为新绑定，松键和鼠标移动不构成选择。
	if (event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE) or (event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_B,JOY_BUTTON_START]):
		capture = ""
		_status.text = "已取消捕获，键位未改变。"
		return
	var token: int = -1
	var section: String = "keyboard" if page in [0,2] else ("mouse" if page == 1 else "gamepad")
	if section == "keyboard" and event is InputEventKey and event.pressed:
		token = world.local_controls.key_map._token(event)
	elif section == "mouse" and event is InputEventMouseButton and event.pressed:
		token = event.button_index
	elif section == "gamepad":
		var devices := Input.get_connected_joypads()
		var expected: int = world.local_controls.pad_id if world.local_controls.pad_id >= 0 else (devices[0] if not devices.is_empty() else -1)
		if event.device != expected:
			return
		if event is InputEventJoypadButton and event.pressed:
			token = event.button_index
		elif event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT,JOY_AXIS_TRIGGER_RIGHT] and event.axis_value > .55:
			token = 100+event.axis
	if token < 0:
		return
	_assign(section,capture,token)


## 捕获和按钮下拉共用同一冲突检查，B可从列表选择而保留捕获取消语义。
func _assign(section: String, action: String, token: int) -> void:
	for other: String in draft[section]:
		if other != action and draft[section][other] == token:
			_status.text = "已占用："+_action_name(other)+"；保留原配置。"
			return
	var candidate: Dictionary = draft.duplicate(true)
	candidate[section][action] = token
	var problem: String = world.control_settings.validate(candidate)
	if not problem.is_empty():
		_status.text = problem+"；保留原配置。"
		return
	draft = candidate
	capture = ""
	_status.text = "已记录到草稿，点应用后生效。"
	_build_rows()


## 分页按实际动作集生成，不保留硬编码旧键位说明。
func _build_rows() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if page == 4:
		_label(_rows,"菜单：方向键／Enter／Esc；手柄十字键／A／B。Esc／Menu保留暂停与返回。\n左摇杆移动，右摇杆转镜头；滚轮上下缩放。靠近伙伴按住交互键3秒救援。\n拖动镜头时暂停鼠标瞄准与射击，移动继续。")
		for actor: String in ["p1","p2"]:
			_label(_rows,actor.to_upper()+" · 当前键盘")
			for id: String in world.control_settings.data.keyboard:
				if id.begins_with(actor+"."):
					_label(_rows,_action_name(id)+"："+world.control_settings.key_text(world.control_settings.keyboard.bindings[id]))
		_label(_rows,"P1鼠标：射击 "+_mouse_text(world.control_settings.data.mouse.fire)+"；拖镜头 "+_mouse_text(world.control_settings.data.mouse.orbit))
		for action: String in world.control_settings.data.gamepad:
			_label(_rows,"P2手柄 · "+_action_name(action)+"："+world.control_settings.pad_text(world.control_settings.data.gamepad[action]))
		return
	var section: String = "keyboard" if page in [0,2] else ("mouse" if page == 1 else "gamepad")
	for id: String in draft[section]:
		if section == "keyboard" and not id.begins_with("p1." if page == 0 else "p2."):
			continue
		var row := HBoxContainer.new()
		_rows.add_child(row)
		var label := _label(row,_action_name(id))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var token: int = draft[section][id]
		var display: String = world.control_settings.key_text(token) if section == "keyboard" else (_mouse_text(token) if section == "mouse" else world.control_settings.pad_text(token))
		_button(row,display,func() -> void:
			capture = id
			_status.text = "请按新的"+("键盘按键" if section == "keyboard" else ("鼠标按钮" if section == "mouse" else "手柄按钮／扳机"))+"；Esc／B取消。")
		if section == "gamepad":
			# B在捕获中固定取消，通过列表仍可将其配置为任意游戏动作。
			var picker := OptionButton.new()
			picker.add_item("选择按钮…",-1)
			for available: int in [JOY_BUTTON_A,JOY_BUTTON_B,JOY_BUTTON_X,JOY_BUTTON_Y,JOY_BUTTON_LEFT_SHOULDER,JOY_BUTTON_RIGHT_SHOULDER,JOY_BUTTON_LEFT_STICK,JOY_BUTTON_RIGHT_STICK,JOY_BUTTON_DPAD_UP,JOY_BUTTON_DPAD_DOWN,JOY_BUTTON_DPAD_LEFT,JOY_BUTTON_DPAD_RIGHT,100+JOY_AXIS_TRIGGER_LEFT,100+JOY_AXIS_TRIGGER_RIGHT]:
				picker.add_item(world.control_settings.pad_text(available),available)
			picker.item_selected.connect(func(index: int) -> void:
				if index > 0:
					_assign("gamepad",id,picker.get_item_id(index)))
			row.add_child(picker)
	var camera_page := _camera_page()
	if camera_page.is_empty():
		return
	for setting: String in ["rotation","zoom","deadzone"] if page == 3 else ["rotation","zoom"]:
		var row := HBoxContainer.new()
		_rows.add_child(row)
		var label := _label(row,{"rotation":"旋转速度倍率","zoom":"缩放速度倍率","deadzone":"摇杆死区"}[setting])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var number := SpinBox.new()
		number.min_value = .1 if setting == "deadzone" else .5
		number.max_value = .35 if setting == "deadzone" else 2.0
		number.step = .01 if setting == "deadzone" else .1
		number.value = draft.cameras[camera_page][setting]
		number.custom_minimum_size = Vector2(140,40)
		number.value_changed.connect(func(value: float) -> void: draft.cameras[camera_page][setting] = value)
		row.add_child(number)
	var invert := CheckButton.new()
	invert.text = "镜头垂直反转"
	invert.button_pressed = draft.cameras[camera_page].invert
	invert.toggled.connect(func(value: bool) -> void: draft.cameras[camera_page].invert = value)
	_rows.add_child(invert)


## 设备页与镜头参数的对应关系固定，不随世界控制来源保存。
func _camera_page() -> String:
	return {1:"p1.mouse",2:"p2.keyboard",3:"p2.gamepad"}.get(page,"")


## 失焦取消未完成捕获，回窗口不把第一下操作意外绑定为新键。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and opened:
		capture = ""
		_status.text = "窗口已失焦，已取消按键捕获；草稿尚未应用。"


## 窄窗口中保持单列并让动作区域滚动，按钮不超出视口。
func _layout() -> void:
	var size: Vector2 = world.get_viewport().get_visible_rect().size
	_panel.size = Vector2(minf(860,size.x-24),maxf(220,size.y-40))
	_panel.position = (size-_panel.size)*.5


## 共用按钮保持可聚焦，键盘与手柄确认不依赖鼠标。
func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(130,40)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## 说明和状态文本可换行，长动作名仍在当前菜单宽度内。
func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(110,32)
	parent.add_child(label)
	return label


## 将内部动作ID转换为角色与中文动作名称。
func _action_name(id: String) -> String:
	var action: String = id.get_slice(".",1) if id.contains(".") else id
	return (id.get_slice(".",0).to_upper()+" · " if id.contains(".") else "")+world.control_settings.ACTION_NAMES.get(action,action)


## 鼠标按钮说明与允许捕获的五种可保持按钮一致。
func _mouse_text(token: int) -> String:
	return {1:"左键",2:"右键",3:"中键",8:"侧键1",9:"侧键2"}.get(token,"鼠标%d" % token)
