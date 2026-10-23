extends CanvasLayer
## 雪球邀请和比分各属于自己的视图；P2按钮只接受所属键盘／手柄。

var game: Node3D
var world: Node3D
var panes: Dictionary = {}


## 实际面板包含接受、拒绝、重开和退出，所有按钮仅提交意图。
func _ready() -> void:
	# 1. 父活动在世界早期装配，布局等到视图注册后读取。
	layer = 10
	for id: String in ["p1","p2"]:
		var panel := PanelContainer.new()
		add_child(panel)
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation",8)
		panel.add_child(column)
		var text := Label.new()
		text.add_theme_font_size_override("font_size",19)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(text)
		var buttons: Dictionary = {}
		for row: Array in [["接受邀请", "accept"],["拒绝邀请", "decline"],["邀请再玩一局", "restart"],["退出比赛", "exit"]]:
			var button := Button.new()
			button.text = row[0]
			button.custom_minimum_size.y = 40
			button.focus_mode = Control.FOCUS_NONE
			button.mouse_filter = Control.MOUSE_FILTER_STOP if id == "p1" else Control.MOUSE_FILTER_IGNORE
			var action: String = row[1]
			button.pressed.connect(func() -> void: choose(id,action))
			column.add_child(button)
			buttons[action] = button
		panes[id] = {"panel":panel,"text":text,"buttons":buttons}
		panel.hide()


## GUI只发送当前角色的明确操作，跨角色和旧邀请由活动层拒绝。
func choose(id: String, action: String) -> void:
	if get_tree().paused:
		return
	match action:
		"accept": game.answer_invitation(id,true)
		"decline": game.answer_invitation(id,false)
		"restart": game.invite(id)
		"exit": game.request_exit(id)


## 每屏只显示本人的确认方式，比分由游戏实例直接读取。
func refresh() -> void:
	# 1. CanvasLayer不依赖3D可见性；非活动和主菜单主动隐藏。
	if not is_instance_valid(world.view_manager):
		return
	for id: String in panes:
		var row: Dictionary = panes[id]
		row.panel.visible = (game.participating or not game.invitation.is_empty()) and not world.session.main_menu.visible and (id == "p1" or world.view_manager.split_enabled)
		if not row.panel.visible:
			continue
		var rect: Rect2 = world.view_manager.views["view."+id].rect
		var width := minf(390,rect.size.x-48)
		row.panel.position = rect.position+Vector2(rect.size.x-width-24,72)
		row.panel.custom_minimum_size.x = width
		row.panel.size = Vector2(width,0)
		var incoming: bool = not game.invitation.is_empty() and game.invitation.to == id
		var waiting: bool = not game.invitation.is_empty() and not incoming
		var text: String = "P1 %d : %d P2 · 先到5分\n" % [game.player_score,game.npc_score]
		if incoming:
			text += "伙伴邀请" + ("再玩一局" if game.invitation.restart else "雪球比赛") + "\n" + ("请选择接受或拒绝" if id == "p1" else "Enter／A接受 · Backspace／B拒绝")
		elif waiting:
			text += "已邀请，等待伙伴明确接受"
		elif not game.round_active:
			text += ("P1获胜" if game.winner == "player" else "P2获胜") + "\n" + ("可以重开或退出" if id == "p1" else "Enter／A邀请重开 · Backspace／B退出")
		else:
			text += "鼠标瞄准 · "+world.settings_ui._mouse_text(world.control_settings.data.mouse.fire)+"投掷" if id == "p1" else world.control_settings.hint("p2","fire",world.local_controls.scheme == "gamepad")+"投掷 · "+world.control_settings.hint("p2","target",world.local_controls.scheme == "gamepad")+"选对手\n"+world.control_settings.hint("p2","close",world.local_controls.scheme == "gamepad")+"退出"
		row.text.text = text
		row.buttons.accept.visible = incoming
		row.buttons.decline.visible = incoming
		row.buttons.restart.visible = game.participating and not game.round_active and not incoming and not waiting
		row.buttons.exit.visible = game.participating and not incoming


## 状态刷新只读纯数据，所有物理校验继续留在活动物理帧。
func _process(_delta: float) -> void:
	refresh()
