extends CanvasLayer
## 交互面板只覆盖操作者视图；按钮和键盘确认提交同一套单次事务。

var world: Node3D
var actor_id: String
var survival: Node
var endpoint: Node
var opened: bool = false
var selected: int = 0
var options: Array[Dictionary] = []
var _overlay: ColorRect
var _panel: VBoxContainer
var _title: Label
var _details: Label
var _message: Label
var _actions: VBoxContainer
var _target: String = ""
var _token: int = 0
var _busy: bool = false
var _refresh_age: float = 0.0


## 另一玩家交易后同步当前数量，不更改本菜单令牌或选择位置。
func _process(delta: float) -> void:
	# 1. 描述只读共享数据；实际提交仍在生存模块物理帧复核。
	_refresh_age += delta
	if not opened or _refresh_age < .15:
		return
	_refresh_age = 0.0
	var target: Dictionary = survival.describe(_target)
	if target.is_empty():
		return
	match String(target.kind):
		"partner": _details.text = "自己：柴火%d · 备用弹%d\n伙伴：柴火%d / 20 · 备用弹%d / 12" % [survival.carried, target.reserve, target.peer_carried, target.peer_reserve]
		"resource": _details.text = "随身柴火 %d / 20 · 此处剩余 %d" % [survival.carried, target.quantity]
		"ammo": _details.text = "备用弹 %d / %d · 盒内 %d" % [target.reserve, target.capacity, target.quantity]
		"store": _details.text = "随身柴火 %d / 20 · 公共仓储 %d / 60" % [survival.carried, target.stored]
		"heater": _details.text = "随身柴火 %d / 20 · %s" % [survival.carried, "安全屋持续温暖" if target.permanent else "燃料剩余%d秒" % ceili(target.fuel_seconds)]


## 局部界面不使用全局焦点，P2确认不能激活P1按钮。
func _ready() -> void:
	# 1. P1按钮接受鼠标，P2由所属设备显式导航。
	layer = 9
	_overlay = ColorRect.new()
	_overlay.color = Color(.025, .06, .12, .78)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP if actor_id == "p1" else Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 12)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_panel)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_panel.add_child(_title)
	_details = Label.new()
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.add_theme_font_size_override("font_size", 18)
	_panel.add_child(_details)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.add_theme_font_size_override("font_size", 18)
	_panel.add_child(_message)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_panel.add_child(_actions)
	_overlay.hide()
	world.get_viewport().size_changed.connect(_layout)
	survival.interaction_closed.connect(close)
	if actor_id == "p2":
		survival.interaction_opened.connect(open_target)
		survival.action_completed.connect(completed)


## 一次打开或刷新只取得当前有效令牌，世界时间和另一角色继续推进。
func open_target(target: Dictionary, token: int) -> void:
	# 1. 旧活动锚点不替代伙伴邀请入口，两人均从伙伴菜单发起。
	if target.kind == "snowball":
		world.rifle.notice("请在空地内靠近伙伴，从伙伴菜单发起雪球邀请")
		survival.close_session()
		return
	opened = true
	endpoint.set_context(endpoint.Context.UI)
	_target = target.id
	_token = token
	_busy = false
	_message.text = ""
	options.clear()
	_title.text = actor_id.to_upper() + " · " + String(target.name)
	match String(target.kind):
		"partner":
			_details.text = "自己：柴火%d · 备用弹%d\n伙伴：柴火%d / 20 · 备用弹%d / 12" % [survival.carried, target.reserve, target.peer_carried, target.peer_reserve]
			if actor_id == "p1" and world.actor_registry.slots.p2.source == "ai":
				_add("伙伴指令", "ai_commands", 1)
			_add("赠送1根柴火", "give_wood", 1)
			_add("赠送对方可收的柴火", "give_wood", 20)
			_add("赠送1发备用弹", "give_ammo", 1)
			_add("赠送对方可收的备用弹", "give_ammo", 12)
			if target.snowball_available:
				_add("雪球比赛", "snowball", 1)
		"resource":
			_details.text = "随身柴火 %d / 20 · 此处剩余 %d" % [survival.carried, target.quantity]
			_add("拾取可携带的木柴", "pickup", 60)
		"ammo":
			_details.text = "备用弹 %d / %d · 盒内 %d" % [target.reserve, target.capacity, target.quantity]
			_add("收取可携带的弹药", "ammo", 12)
		"store":
			_details.text = "随身柴火 %d / 20 · 公共仓储 %d / 60" % [survival.carried, target.stored]
			_add("存入1根", "deposit", 1)
			_add("存入可存柴火", "deposit", 60)
			_add("取出1根", "withdraw", 1)
			_add("取出可携带的柴火", "withdraw", 60)
		"heater":
			_details.text = "随身柴火 %d / 20 · %s" % [survival.carried, "安全屋持续温暖" if target.permanent else "燃料剩余%d秒" % ceili(target.fuel_seconds)]
			if not target.permanent:
				_add("添1根柴", "fuel", 1)
				_add("添满可用柴火", "fuel", 5)
	_add("返回探索", "close", 0)
	selected = mini(selected, options.size() - 1)
	_rebuild()
	_layout()
	_overlay.show()


## 显示选项不直接修改库存，提交时仍复核类型、距离和容量。
func _add(label: String, action: String, amount: int) -> void:
	# 1. 两种输入共用同一条事务路径。
	options.append({"label": label, "action": action, "amount": amount})


## 每次事务后重建有限按钮；禁用全局焦点以隔离两名玩家。
func _rebuild() -> void:
	# 1. 移除旧节点后再创建本次令牌对应的按钮。
	for child: Node in _actions.get_children():
		_actions.remove_child(child)
		child.queue_free()
	for index in range(options.size()):
		var button := Button.new()
		button.text = ("▶ " if selected == index else "") + String(options[index].label)
		button.custom_minimum_size.y = 46
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_STOP if actor_id == "p1" else Control.MOUSE_FILTER_IGNORE
		button.pressed.connect(func() -> void: confirm(index))
		_actions.add_child(button)


## 只有P2所属方向键／摇杆改变自己的选项。
func navigate(steps: int) -> void:
	# 1. 等待事务提交时不切换待确认项。
	if opened and not _busy and not options.is_empty():
		selected = posmod(selected + steps, options.size())
		_rebuild()


## 确认消耗当前令牌，重复按钮或按键不会叠加同一操作。
func confirm(index: int = -1) -> void:
	# 1. 暂停后不可提交菜单遗留的请求。
	if not opened or _busy or get_tree().paused:
		return
	var row: Dictionary = options[selected if index < 0 else index]
	if row.action == "close":
		close()
	elif row.action == "ai_commands":
		close()
		world.guard_ui.toggle()
	elif survival.submit_action(_token, row.action, row.amount):
		_busy = true
		for button: Button in _actions.get_children():
			button.disabled = true


## 提交后刷新真实共享数量和令牌；目标失效时关闭此玩家面板。
func completed(result: Dictionary) -> void:
	if result.get("activity_action",false):
		if opened:
			close()
		return
	# 1. 不接管另一角色的会话或输入上下文。
	if opened and not survival.open_session(_target):
		close()
	if opened:
		_message.text = result.message


## 关闭只释放本角色菜单和未提交事务。
func close() -> void:
	# 1. 已完成库存转移不回滚，旧令牌不能复用。
	opened = false
	_overlay.hide()
	survival.close_session()
	endpoint.set_context(endpoint.Context.EXPLORATION)


## 依据同一套分屏矩形布局，窗口伸缩不会把面板画进另一屏。
func _layout() -> void:
	# 1. 菜单属于根Canvas，但范围严格等于其角色视图。
	var rect: Rect2 = world.view_manager.views["view." + actor_id].rect
	_overlay.position = rect.position
	_overlay.size = rect.size
	_panel.position = Vector2(24, maxf(60, rect.size.y * .2))
	_panel.size.x = rect.size.x - 48
