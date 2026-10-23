extends Node
## P2角色输入端点；只接收所属控制器的意图，不读取全局键盘。

signal equipment_requested(slot: int)
signal reload_requested
signal primary_requested(screen_position: Vector2)
signal interact_requested
enum Context { EXPLORATION, UI, PAUSED, SNOWBALL }
var context: Context = Context.PAUSED
var _focused: bool = true
var drag_view: String = ""
var world: Node3D


## 权限沿用固定槽位、主菜单模式和统一暂停屏障。
func allows_gameplay_input() -> bool:
	# 1. 失焦、未接管或设备丢失均不能消费旧意图。
	var ai: bool = is_instance_valid(world.guard) and world.guard.enabled and world.actor_registry.slots.p2.source == "ai" and world.session.local_authority
	var local: bool = is_instance_valid(world.local_controls) and world.local_controls.active and world.local_controls.device_available()
	return (not is_instance_valid(world.rescue) or world.rescue.can_act("p2")) and _focused and not get_tree().paused and context in [Context.EXPLORATION, Context.SNOWBALL] and (ai or local)


## 打开本角色菜单只停本角色，不更改另一个输入上下文。
func set_context(value: Context) -> void:
	# 1. 持续动作和旧枪口请求先释放，再更新上下文。
	context = value
	world.snowball_game.companion.set_external_direction(Vector3.ZERO)
	world.snowball_game.companion.velocity = Vector3.ZERO
	if is_instance_valid(world.local_controls):
		world.local_controls.clear_actor("p2")


## 输入焦点由同机协调器统一同步，恢复后等待新的按键。
func set_focused(value: bool) -> void:
	# 1. 不在后台读取摇杆或触发器。
	_focused = value
	if not value:
		set_context(context)


## 倒地P2仍可控制自己的镜头，但不能移动、开枪或交易。
func allows_camera_input() -> bool:
	# 1. 设备、焦点、菜单和暂停边界与正常镜头一致。
	return _focused and not get_tree().paused and context in [Context.EXPLORATION, Context.SNOWBALL] and is_instance_valid(world.local_controls) and world.local_controls.active and world.local_controls.device_available()
