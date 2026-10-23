extends Node
## 两套同机设备方案：按角色收集意图，再交给原物理移动与真实能力。

const ACTOR_MENU = preload("res://scripts/v3/views/valley_actor_menu.gd")
const KEY_BINDINGS = preload("res://scripts/v3/input/valley_key_bindings.gd")
const P1_MOVEMENT: Array[int] = [KEY_W, KEY_A, KEY_S, KEY_D]
const P2_KEYS: Array[int] = [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_I, KEY_J, KEY_K, KEY_L, KEY_U, KEY_O, KEY_P, KEY_ENTER, KEY_PERIOD, KEY_COMMA, KEY_TAB, KEY_BACKSPACE, KEY_PAUSE]
var world: Node3D
var active: bool = false
var scheme: String = ""
var pad_id: int = -1
var menus: Dictionary = {}
var _keys: Dictionary = {}
var _axes: Dictionary = {}
var _buttons: Dictionary = {}
var _focused: bool = true
var _trigger_down: bool = false
var _menu_axis: int = 0
var _pad_held: Dictionary = {}
var key_map = KEY_BINDINGS.new()


## 独立面板一次创建，手柄连接事件不改变世界库存或角色槽位。
func _ready() -> void:
	# 1. 暂停中仍接收设备恢复和明确暂停键，不推进角色。
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -15
	key_map = world.control_settings.keyboard
	for id: String in ["p1", "p2"]:
		var menu := ACTOR_MENU.new()
		menu.world = world
		menu.actor_id = id
		menu.survival = world.survival if id == "p1" else world.secondary_context.survival
		menu.endpoint = world.input_router if id == "p1" else world.secondary_context.input_router
		add_child(menu)
		menus[id] = menu
	Input.joy_connection_changed.connect(_joy_connection_changed)


## 主菜单明确选设备；无手柄不伪装成已可用模式。
func configure(value: String) -> void:
	# 1. 所有旧动作、菜单和目标在控制交接前释放。
	clear_all()
	active = value.begins_with("local_")
	scheme = value.trim_prefix("local_") if active else ""
	pad_id = Input.get_connected_joypads()[0] if scheme == "gamepad" and not Input.get_connected_joypads().is_empty() else -1
	world.secondary_context.set_controlled(active or world.actor_registry.slots.p2.source == "ai")
	world.player.external_control = true
	# 控制来源不改变角色移动能力，关闭AI的真实返程也使用P1同档步速。
	world.snowball_game.companion.walk_speed = world.player.walk_speed
	world.snowball_game.companion.movement_camera = world.view_manager.views["view.p2"].rig.camera


## 主菜单返回时释放输入；真正来源在下一次模式选择统一交接。
func suspend() -> void:
	# 1. 不保存设备或镜头进世界快照。
	clear_all()
	active = false
	world.secondary_context.set_controlled(false)


## 键盘不依赖手柄状态；手柄必须仍是当前绑定的真实设备。
func device_available() -> bool:
	# 1. 本地端点用该值拒绝拔插前留下的意图。
	return scheme == "keyboard" or (pad_id >= 0 and pad_id in Input.get_connected_joypads())


## 在GUI前只接管明确属于P2的设备，避免Tab／A操作P1按钮。
func route_owned(event: InputEvent) -> bool:
	# 1. 主菜单继续使用原GUI；游戏中的P2菜单由独立输入管理。
	if not active or world.session.main_menu.visible:
		return false
	if event is InputEventKey and scheme == "keyboard" and (key_map.owner(event) == "p2" or (menus.p2.opened and event.physical_keycode in [KEY_UP,KEY_DOWN,KEY_ENTER,KEY_BACKSPACE])):
		return handle_event(event)
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return handle_event(event)
	return false


## 所有释放都记录，即使按键在GUI或窗口切换期间被消费。
func observe_release(event: InputEvent) -> void:
	# 1. 这里只释放，不在菜单外偷收按下事件。
	if event is InputEventKey and not event.pressed:
		var translated: InputEventKey = key_map.translate(event)
		if translated != null:
			_keys.erase(_key_token(translated))
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_observe_pad_release(event)
	elif event is InputEventJoypadButton and not event.pressed and event.device == pad_id:
		_buttons.erase(event.button_index)
	elif event is InputEventJoypadMotion and event.device == pad_id and event.axis_value < .2 and event.axis == JOY_AXIS_TRIGGER_RIGHT:
		_trigger_down = false


## 一次按下只发送给拥有者，持续移动在固定物理步消费。
func handle_event(event: InputEvent) -> bool:
	# 1. 不把失焦期间的按下或未选设备的操作带入游戏。
	if not _focused or world.session.main_menu.visible or (is_instance_valid(world.settings_ui) and world.settings_ui.opened):
		return false
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return _handle_pad(event)
	if not event is InputEventKey:
		return false
	# 菜单优先使用原始物理键，不能被游戏改键改变确认／返回。
	if _fixed_menu_key(event):
		return true
	var translated: InputEventKey = key_map.translate(event)
	if translated == null:
		return key_map.was_default_key(event)
	event = translated
	var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	var p2: bool = active and scheme == "keyboard" and _is_p2_key(event)
	var p1: bool = code in P1_MOVEMENT or code in [KEY_E, KEY_R, KEY_1, KEY_2, KEY_ESCAPE, KEY_HOME,KEY_Q] or (code == KEY_SHIFT and event.location != KEY_LOCATION_RIGHT)
	if not p1 and not p2:
		return false
	if not event.pressed:
		_keys.erase(_key_token(event))
		return true
	if event.echo:
		return true
	if p2 and code == KEY_PAUSE:
		world.session.request_pause("p2")
		return true
	if p1 and code == KEY_ESCAPE:
		world._on_pause_requested()
		return true
	if get_tree().paused:
		return false
	if p1 and code == KEY_Q:
		world.guard_ui.toggle()
		return true
	if p2 and menus.p2.opened:
		return true
	if p2 and code == KEY_BACKSPACE and world.snowball_game.participating:
		world.snowball_game.handle_owned_action("close")
		return true
	var endpoint: Node = world.secondary_context.input_router if p2 else world.input_router
	if p2 and code in [KEY_I, KEY_J, KEY_K, KEY_L, KEY_U, KEY_O, KEY_P] and endpoint.allows_camera_input():
		_keys[_key_token(event)] = true
		if code == KEY_P:
			world.view_manager.views["view.p2"].rig.reset_view()
		return true
	if p1 and code == KEY_HOME and endpoint.allows_camera_input():
		var view: String = world.view_manager.view_at(world.input_router.pointer_root)
		if not active and not view.is_empty():
			world.view_manager.views[view].rig.reset_view()
		elif view == "view.p1":
			world.camera_rig.reset_view()
		return true
	if not endpoint.allows_gameplay_input():
		return true
	_keys[_key_token(event)] = true
	if p2:
		match code:
			KEY_ENTER: endpoint.interact_requested.emit()
			KEY_PERIOD: endpoint.reload_requested.emit()
			KEY_COMMA: endpoint.equipment_requested.emit(1 if world.secondary_context.rifle.equipped == 2 else 2)
			KEY_TAB: world.secondary_context.request_target_cycle()
			KEY_CTRL: endpoint.primary_requested.emit(Vector2.ZERO)
	else:
		match code:
			KEY_E: endpoint.interact_requested.emit()
			KEY_R: endpoint.reload_requested.emit()
			KEY_1: endpoint.equipment_requested.emit(1)
			KEY_2: endpoint.equipment_requested.emit(2)
	return true


## 映射修改前清理旧意图，为M10菜单提供实际生效的动作接口。
func bind_key(actor: String, action: String, code: Key, location: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> Error:
	# 1. 冲突时保留现有映射，成功后旧物理键不能继续移动角色。
	var result: Error = key_map.bind_key(actor, action, code, location)
	if result == OK:
		clear_all()
	return result


## 手柄事件严格按设备ID分发，RT按下边沿只开一枪。
func _handle_pad(event: InputEvent) -> bool:
	# 1. 只接受主菜单选定的设备；菜单导航使用物理默认键。
	if not active or scheme != "gamepad" or event.device != pad_id:
		return true
	var endpoint: Node = world.secondary_context.input_router
	if event is InputEventJoypadButton:
		if event.pressed:
			_buttons[event.button_index] = true
		else:
			_buttons.erase(event.button_index)
		if event.button_index == JOY_BUTTON_START and event.pressed:
			world.session.request_pause("p2")
			return true
		if get_tree().paused:
			return false
		if event.pressed and event.button_index in [JOY_BUTTON_A,JOY_BUTTON_B] and world.snowball_game.handle_owned_action("confirm" if event.button_index == JOY_BUTTON_A else "close"):
			return true
		if menus.p2.opened:
			if event.pressed:
				match event.button_index:
					JOY_BUTTON_A: menus.p2.confirm()
					JOY_BUTTON_B: menus.p2.close()
					JOY_BUTTON_DPAD_UP: menus.p2.navigate(-1)
					JOY_BUTTON_DPAD_DOWN: menus.p2.navigate(1)
			return true
	elif event is InputEventJoypadMotion:
		if get_tree().paused:
			return false
		_axes[event.axis] = event.axis_value
		if menus.p2.opened:
			if event.axis == JOY_AXIS_LEFT_Y:
				var next: int = 1 if event.axis_value > .6 else (-1 if event.axis_value < -.6 else 0)
				if next != 0 and next != _menu_axis:
					menus.p2.navigate(next)
				_menu_axis = next
			return true
	# 2. 扳机与按钮映射到同一动作；一次按下边沿只发出一次请求。
	var token: int = _pad_token(event)
	if token < 0:
		return true
	var pressed: bool = event.pressed if event is InputEventJoypadButton else event.axis_value > .55
	for action: String in world.control_settings.data.gamepad:
		if world.control_settings.data.gamepad[action] != token:
			continue
		if not pressed:
			if event is InputEventJoypadMotion and event.axis_value >= .2:
				return true
			_pad_held.erase(action)
			return true
		if _pad_held.has(action):
			return true
		_pad_held[action] = true
		if endpoint.allows_camera_input():
			match action:
				"reset": world.view_manager.views["view.p2"].rig.reset_view()
				"zoom_in": world.view_manager.views["view.p2"].rig.request_zoom(-1)
				"zoom_out": world.view_manager.views["view.p2"].rig.request_zoom(1)
		if endpoint.allows_gameplay_input():
			match action:
				"interact": endpoint.interact_requested.emit()
				"reload": endpoint.reload_requested.emit()
				"equipment": endpoint.equipment_requested.emit(1 if world.secondary_context.rifle.equipped == 2 else 2)
				"target": world.secondary_context.request_target_cycle()
				"fire": endpoint.primary_requested.emit(Vector2.ZERO)
				"close": world.snowball_game.handle_owned_action("close")
		return true
	return true


## 物理扳机与数字按钮使用不重叠编码，摇杆轴保持原有职责。
func _pad_token(event: InputEvent) -> int:
	if event is InputEventJoypadButton:
		return event.button_index
	if event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT,JOY_AXIS_TRIGGER_RIGHT]:
		return 100+event.axis
	return -1


## GUI消费松键时仍撤销持续动作和救援，不等待下一次玩法事件。
func _observe_pad_release(event: InputEvent) -> void:
	if not active or scheme != "gamepad" or event.device != pad_id:
		return
	if (event is InputEventJoypadButton and event.pressed) or (event is InputEventJoypadMotion and event.axis_value >= .2):
		return
	var token: int = _pad_token(event)
	for action: String in world.control_settings.data.gamepad:
		if world.control_settings.data.gamepad[action] == token:
			_pad_held.erase(action)
			if action == "interact" and is_instance_valid(world.rescue):
				world.rescue.release("p2")


## 全局暂停出口和独立交互菜单用固定物理键，不随游戏改键变化。
func _fixed_menu_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	var code: int = event.physical_keycode
	if code == KEY_ESCAPE:
		if menus.p1.opened:
			menus.p1.close()
		elif menus.p2.opened:
			menus.p2.close()
		else:
			world._on_pause_requested()
		return true
	if get_tree().paused:
		return false
	if active and scheme == "keyboard":
		if code in [KEY_ENTER,KEY_BACKSPACE] and world.snowball_game.handle_owned_action("confirm" if code == KEY_ENTER else "close"):
			return true
		if menus.p2.opened:
			match code:
				KEY_UP: menus.p2.navigate(-1)
				KEY_DOWN: menus.p2.navigate(1)
				KEY_ENTER: menus.p2.confirm()
				KEY_BACKSPACE: menus.p2.close()
			if code in [KEY_UP,KEY_DOWN,KEY_ENTER,KEY_BACKSPACE]:
				return true
	# P1同机交互保留鼠标，避免方向键同时导航P1菜单并移动P2。
	if menus.p1.opened and not (active and scheme == "keyboard"):
		match code:
			KEY_UP: menus.p1.navigate(-1)
			KEY_DOWN: menus.p1.navigate(1)
			KEY_ENTER: menus.p1.confirm()
		return code in [KEY_UP,KEY_DOWN,KEY_ENTER]
	return false


## 两角色分别依据自己的相机方向移动，绝不广播InputMap全局动作。
func _physics_process(delta: float) -> void:
	# 1. 菜单只阻止其拥有者，统一暂停则两角色都不推进。
	if not _focused or get_tree().paused or world.session.main_menu.visible:
		return
	var p1_vector := Vector2(_down(KEY_D) - _down(KEY_A), _down(KEY_S) - _down(KEY_W)).limit_length()
	if not world.input_router.allows_gameplay_input():
		p1_vector = Vector2.ZERO
	world.player.set_external_direction(world.player._world_direction(p1_vector), _down(KEY_SHIFT, KEY_LOCATION_LEFT) > 0 or _down(KEY_SHIFT) > 0)
	if not active:
		return
	var vector := Vector2.ZERO
	var running := false
	var look := Vector2.ZERO
	var endpoint: Node = world.secondary_context.input_router
	if endpoint.allows_gameplay_input():
		if scheme == "keyboard":
			vector = Vector2(_down(KEY_RIGHT) - _down(KEY_LEFT), _down(KEY_DOWN) - _down(KEY_UP)).limit_length()
			running = _down(KEY_SHIFT, KEY_LOCATION_RIGHT) > 0
		else:
			vector = _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
			running = _pad_held.has("sprint")
	if endpoint.allows_camera_input():
		if scheme == "keyboard":
			look = Vector2(_down(KEY_L) - _down(KEY_J), _down(KEY_K) - _down(KEY_I))
			world.view_manager.views["view.p2"].rig.request_zoom((_down(KEY_O) - _down(KEY_U)) * 4 * delta)
		else:
			look = _stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	var actor: CharacterBody3D = world.snowball_game.companion
	var direction: Vector3 = actor._world_direction(vector)
	actor.set_external_direction(direction, running)
	if direction.length() > .05 and not is_instance_valid(world.secondary_context.selected_target):
		world.secondary_context.aim_yaw = atan2(direction.x, direction.z)
	world.view_manager.views["view.p2"].rig.orbit(look * (100 * delta / .22))


## 摇杆使用径向死区，保留模拟幅度并限制斜向速度。
func _stick(x: int, y: int) -> Vector2:
	# 1. 中心漂移不产生移动或镜头意图。
	var value := Vector2(float(_axes.get(x, 0)), float(_axes.get(y, 0))).limit_length()
	var deadzone: float = world.control_settings.data.cameras["p2.gamepad"].deadzone
	return value.normalized() * remap(value.length(), deadzone, 1, 0, 1) if value.length() > deadzone else Vector2.ZERO


## 左右修饰键分别编码，P2右Shift不会让P1跑步。
func _key_token(event: InputEventKey) -> int:
	# 1. 普通物理键无需位置扩展。
	var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	return code + (int(event.location) << 32) if code in [KEY_SHIFT, KEY_CTRL] else code


## 固定映射查询是后续改键菜单的单一入口。
func _down(code: int, location: int = 0) -> float:
	# 1. 查询自己的按键集合，不能读取另一方案的InputMap状态。
	return 1.0 if _keys.has(code + (location << 32)) else 0.0


## P2键盘方案显式拥有方向键与右修饰键。
func _is_p2_key(event: InputEventKey) -> bool:
	# 1. 不吞掉P1的左Shift、E、R或数字装备键。
	var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	return code in P2_KEYS or (code in [KEY_CTRL, KEY_SHIFT] and event.location == KEY_LOCATION_RIGHT)


## 某个角色进入菜单时只清理其持续动作与待发请求。
func clear_actor(id: String) -> void:
	if is_instance_valid(world.rescue):
		world.rescue.release(id)
	# 1. 保留另一玩家正在行走的按键。
	for token: int in _keys.keys():
		var code := token & 0xffffffff
		var p1: bool = code in P1_MOVEMENT or (code == KEY_SHIFT and (token >> 32) != KEY_LOCATION_RIGHT)
		if (id == "p1") == p1:
			_keys.erase(token)
	var actor: CharacterBody3D = world.actor_registry.slots[id].body
	actor.set_external_direction(Vector3.ZERO)
	actor.velocity = Vector3.ZERO
	var weapon: Node3D = world.rifle if id == "p1" else world.secondary_context.rifle
	weapon._pending_fire = false
	if id == "p2":
		world.secondary_context._cycle_requested = false
		_axes.clear()
		_buttons.clear()
		_pad_held.clear()
		_trigger_down = false
		_menu_axis = 0


## 模式、读档、暂停与失焦清理两套瞬时输入，不回滚库存。
func clear_all() -> void:
	# 1. 关闭面板会撤销其令牌，不复用排队的菜单确认。
	for menu: CanvasLayer in menus.values():
		if menu.opened:
			menu.close()
	clear_actor("p1")
	clear_actor("p2")


## 统一暂停保存与恢复P2输入上下文及有限声音。
func pause_changed(paused: bool) -> void:
	# 1. 菜单关闭后恢复探索上下文，不能从暂停回到已消失的UI。
	clear_all()
	world.secondary_context.rifle.set_paused(paused)
	if active:
		var resume: int = world.input_router.Context.SNOWBALL if world.snowball_game.participating else world.input_router.Context.EXPLORATION
		world._resume_context = resume
		world.input_router.set_context(world.input_router.Context.PAUSED if paused else resume)
		world.secondary_context.input_router.set_context(world.secondary_context.input_router.Context.PAUSED if paused else resume)
		if not paused and not world.snowball_game.invitation.is_empty():
			var owner: String = world.snowball_game.invitation.to
			var endpoint: Node = world.input_router if owner == "p1" else world.secondary_context.input_router
			endpoint.set_context(endpoint.Context.UI)


## 失焦结束持续动作，回窗口不补发开火或移动。
func focus_changed(focused: bool) -> void:
	# 1. 两个设备共享应用焦点，但各自保留库存和相机。
	_focused = focused
	clear_all()
	world.secondary_context.input_router.set_focused(focused)


## 当前手柄拔出立即冻结世界，重连只恢复设备，不自动恢复游戏。
func _joy_connection_changed(device: int, connected: bool) -> void:
	# 1. 事件不能把P2切回AI，也不能悄悄更换为键盘。
	if not active or scheme != "gamepad":
		return
	if not connected and device == pad_id:
		pad_id = -1
		world.set_session_paused(true)
		world.session._notice("P2手柄已断开 · 重连后按Menu继续，或回主菜单改用键盘")
	elif connected and pad_id < 0:
		pad_id = device
		clear_actor("p2")
		world.session._notice("P2手柄已连接 · 按Menu继续")
