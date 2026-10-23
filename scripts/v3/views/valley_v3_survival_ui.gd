extends "res://scripts/survival/valley_survival_ui.gd"
## 单人保持原界面，同机时把P1交互交给独立左屏面板。


## 同一交互事件只显示一种菜单，不重复切上下文或提交事务。
func _show_target(target: Dictionary, token: int) -> void:
	# 1. 启动装配期间尚无同机协调器，仍可使用原启动屏障。
	if is_instance_valid(world.local_controls):
		world.local_controls.menus.p1.open_target(target, token)
	else:
		super._show_target(target, token)


## 根据当前模式刷新对应面板，不触发另一玩家会话。
func _completed(result: Dictionary) -> void:
	if result.get("activity_action",false):
		return
	# 1. 原单人状态与真实库存逻辑保持一致。
	if is_instance_valid(world.local_controls) and world.local_controls.menus.p1.opened:
		world.local_controls.menus.p1.completed(result)
	else:
		super._completed(result)


## 单人伙伴菜单同样遵守原雪球开局与Esc关闭路径。
func close() -> void:
	# 1. 一个交互事件始终只释放当前打开的面板。
	if is_instance_valid(world.local_controls) and world.local_controls.menus.p1.opened:
		world.local_controls.menus.p1.close()
	super.close()
