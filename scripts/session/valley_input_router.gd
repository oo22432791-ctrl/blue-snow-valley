extends Node
## 第二版输入边界：未被GUI消费的操作才发送给当前玩法，暂停和失焦均释放移动。

signal equipment_requested(slot: int)
signal reload_requested
signal primary_requested(screen_position: Vector2)
signal aim_moved(screen_position: Vector2)
signal zoom_requested(steps: float)
signal interact_requested
signal pause_requested

enum Context { EXPLORATION, UI, PAUSED, SNOWBALL }

const ACTION_KEYS: Dictionary = {
	"v2_equip_snowball": KEY_1,
	"v2_equip_rifle": KEY_2,
	"v2_reload": KEY_R,
	"v2_interact": KEY_E,
	"v2_pause": KEY_ESCAPE,
}

var context: Context = Context.EXPLORATION
var controlled_actor: CharacterBody3D
var _focused: bool = true
var _owned_actions: Array[StringName] = []


## 只在第二版场景存活期间登记专属动作，不改第一版移动映射。
func _ready() -> void:
	# 1. 保留外部已有映射，仅记录本节点真正新增的动作。
	for action: String in ACTION_KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = ACTION_KEYS[action]
		InputMap.action_add_event(action, event)
		_owned_actions.append(StringName(action))
	# 2. 场景树暂停后仍接收生命周期通知，但不分发玩法输入。
	process_mode = Node.PROCESS_MODE_ALWAYS


## 同步玩法上下文，切换时清理旧按键，禁止暂停后残留行走。
func set_context(value: Context) -> void:
	# 1. 清除持续输入；活动限制由统一入口判断。
	context = value
	_release_actions()
	# 2. 界面与暂停上下文关闭共享角色物理输入，返回游玩后再恢复。
	if is_instance_valid(controlled_actor):
		controlled_actor.velocity = Vector3.ZERO
		controlled_actor.set_physics_process(context not in [Context.UI, Context.PAUSED])


## 仅向当前允许的模块发送单次请求，不在骨架阶段制造武器或计分状态。
func _unhandled_input(event: InputEvent) -> void:
	# 1. 已确认的Esc可在暂停中恢复；失焦时不接受任何新请求。
	if event is InputEventKey and event.echo:
		return
	if _focused and event.is_action_pressed("v2_pause"):
		pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if not allows_gameplay_input():
		return
	# 2. 小游戏上下文只允许主操作，探索上下文才允许装备和换弹请求。
	if context == Context.EXPLORATION:
		if event.is_action_pressed("v2_equip_snowball"):
			equipment_requested.emit(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("v2_equip_rifle"):
			equipment_requested.emit(2)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("v2_reload"):
			reload_requested.emit()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("v2_interact"):
			interact_requested.emit()
			get_viewport().set_input_as_handled()
	# 3. 鼠标坐标统一来自视口事件，GUI滚动和点击不会穿透至镜头或玩法。
	if event is InputEventMouseMotion:
		aim_moved.emit(event.position)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		primary_requested.emit(event.position)
		get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var direction := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		zoom_requested.emit(direction * event.factor)
		get_viewport().set_input_as_handled()


## 让瞄准显示与玩法分发共用焦点、暂停和上下文判定。
func allows_gameplay_input() -> bool:
	# 1. 暂停状态不依赖角色输入开关，防止未来模块绕过场景树冻结边界。
	return _focused and not get_tree().paused and context in [Context.EXPLORATION, Context.SNOWBALL]


## 对焦点切换释放所有持续动作，恢复时等待新的输入。
func _notification(what: int) -> void:
	# 1. 不将失焦期间的按下状态带到恢复后的游戏。
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		_release_actions()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true


## 清理本模块登记的动作，让同进程返回第一版时没有残留映射。
func _exit_tree() -> void:
	# 1. 先抬起输入，再仅删除本节点拥有的动作。
	_release_actions()
	for action in _owned_actions:
		InputMap.erase_action(action)


## 统一释放键盘动作，供暂停、焦点和场景退出复用。
func _release_actions() -> void:
	# 1. 原有移动动作保留映射，第二版动作只清除按下状态。
	for action in ["move_left", "move_right", "move_forward", "move_back", "sprint"] + ACTION_KEYS.keys():
		if InputMap.has_action(action):
			Input.action_release(action)
