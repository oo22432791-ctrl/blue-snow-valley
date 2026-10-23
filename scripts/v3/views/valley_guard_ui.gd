extends CanvasLayer
## 单人Q指令面板；只停止P1，AI与世界继续推进，命令由物理帧提交。

var world: Node3D
var opened: bool = false
var _overlay: ColorRect
var _status: Label
var _details: Label


## 创建实际按钮而非开发快捷开关，近距伙伴菜单也能进入相同面板。
func _ready() -> void:
	# 1. 状态只显示AI模式，避免把P2真人操作说明变成AI命令。
	layer = 11
	_status = Label.new()
	_status.position = Vector2(24, 340)
	_status.add_theme_font_size_override("font_size", 19)
	_status.add_theme_color_override("font_color", Color("f5e2bb"))
	_status.add_theme_color_override("font_shadow_color", Color("19334c"))
	_status.add_theme_constant_override("shadow_offset_x", 2)
	add_child(_status)
	_overlay = ColorRect.new()
	_overlay.color = Color(.025,.06,.12,.85)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420,0)
	panel.add_theme_constant_override("separation", 10)
	center.add_child(panel)
	_details = Label.new()
	_details.add_theme_font_size_override("font_size", 22)
	panel.add_child(_details)
	for row: Array in [["跟随我", "follow"], ["在当前位置等待", "wait"], ["协助拾取一次附近柴火", "assist"], ["允许护卫开火", "fire"], ["禁止开火", "cease"], ["返回探索", "close"]]:
		var button := Button.new()
		button.text = row[0]
		button.custom_minimum_size.y = 48
		button.focus_mode = Control.FOCUS_NONE
		var action: String = row[1]
		button.pressed.connect(func() -> void: choose(action))
		panel.add_child(button)
	_overlay.hide()


## 面板打开前结束原近距会话，远程命令不借伙伴物资菜单绕过距离校验。
func toggle() -> void:
	# 1. 暂停、倒地、真人P2和雪球期间不能下AI指令。
	if opened:
		close()
		return
	if get_tree().paused or world.session.busy or world.session.main_menu.visible or world.actor_registry.slots.p2.source != "ai" or not world.rescue.can_act("p1") or world.snowball_game.participating:
		return
	world.survival_ui.close()
	world.survival.close_session()
	world.input_router.set_context(world.input_router.Context.UI)
	opened = true
	_overlay.show()


## 按钮只排队意图，不在GUI回调里移动实体或查询路径。
func choose(action: String) -> void:
	if not opened:
		return
	if action == "close" or world.guard.request_command(action):
		close()


## 关闭取消持续移动和旧按钮，不改变已保存的AI策略。
func close() -> void:
	if not opened:
		return
	opened = false
	_overlay.hide()
	world.input_router.set_context(world.input_router.Context.EXPLORATION)


## 即时反馈暖意与缺弹，不因面板打开而暂停世界。
func _process(_delta: float) -> void:
	# 1. 生命周期变化时面板先关闭，避免把旧选择带到另一个控制来源。
	var active: bool = world.actor_registry.slots.p2.source == "ai" and not world.session.main_menu.visible
	if opened and (not active or get_tree().paused or not world.rescue.can_act("p1")):
		close()
	# 紧凑HUD统一显示伙伴状态，旧常驻Q操作文字不再出现在探索画面。
	_status.visible = false
	var text: String = "伙伴 · " + world.guard.status
	if world.secondary_context.survival.warmth < 30:
		text += " · 暖意不足"
	if world.secondary_context.rifle.chamber + world.secondary_context.rifle.reserve == 0:
		text += " · 缺弹"
	text += " · " + ("允许开火" if world.guard.fire_allowed else "禁止开火") + " · Q指令"
	_status.text = text
	_details.text = "伙伴指令 · 世界继续运行\n" + ("跟随" if world.guard.command == "follow" else "等待") + " · " + ("允许开火" if world.guard.fire_allowed else "禁止开火")
