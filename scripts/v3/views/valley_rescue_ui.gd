extends CanvasLayer
## 逐屏临时生命提示，不把开发状态或世界存档字段放进操作说明。

var world: Node3D
var labels: Dictionary = {}


## 提示可在暂停中显示，输入仍由原暂停菜单统一处理。
func _ready() -> void:
	# 1. 只显示文字与进度，不创建第二条救援提交入口。
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 12
	for id: String in ["p1", "p2"]:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", Color("f5e2bb"))
		label.add_theme_color_override("font_shadow_color", Color("19334c"))
		label.add_theme_constant_override("shadow_offset_x", 2)
		label.add_theme_constant_override("shadow_offset_y", 2)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(label)
		labels[id] = label


## 当前剩余秒数从统一时钟读取，暂停时不会视觉上偷偷倒计时。
func _process(_delta: float) -> void:
	# 1. 单屏可显示AI伙伴状态，分屏文字严格限制在自己的矩形内。
	for id: String in labels:
		var label: Label = labels[id]
		label.hide()
		if world.session.main_menu.visible or (id == "p2" and not world.view_manager.split_enabled):
			continue
		var rect: Rect2 = world.view_manager.views["view." + id].rect
		label.position = rect.position + Vector2(22, 70)
		label.size = Vector2(rect.size.x - 44, 126)
		var life: Dictionary = world.rescue.capture_life(id)
		var other: String = world.rescue.peer(id)
		if life.state == "downed":
			label.text = "%s 已倒地 · %d秒内可获救\n伙伴需在2米内，按住交互键3秒" % [id.to_upper(), ceili(life.remaining)]
		elif life.state == "return_pending":
			label.text = "正在等待安全屋站位\n返回完成前不会扣柴；受阻时可在暂停菜单重试"
		elif world.rescue.life[other].state == "downed":
			label.text = "%s 已倒地 · 剩余%d秒\n靠近并按住%s施救：%.1f / 3秒" % [other.to_upper(), ceili(world.rescue.capture_life(other).remaining), world.control_settings.hint(id,"interact",id == "p2" and world.local_controls.scheme == "gamepad"), world.rescue.progress[id]]
		else:
			continue
		if id == "p1" and not world.rescue.ai_status.is_empty():
			label.text += "\n" + world.rescue.ai_status
		label.show()
