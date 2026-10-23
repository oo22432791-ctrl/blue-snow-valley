extends CanvasLayer
## 公共演出与旅程菜单；P2确认只接受自己的键盘／手柄，不借用P1鼠标。
var journey: Node
var cinema: Control
var title: Label
var subtitle: Label
var skip_button: Button
var skip_p2: Label
var dialog: Control
var heading: Label
var body: Label
var primary: Button
var secondary: Label
var cancel: Button
var _last := ""
var _archive_ok := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 16
	cinema = Control.new()
	cinema.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cinema.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cinema)
	var texture := TextureRect.new()
	texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture.texture = journey.world.view_manager.views["view.p1"].viewport.get_texture()
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.stretch_mode = TextureRect.STRETCH_SCALE
	texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cinema.add_child(texture)
	title = _label(cinema,30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(24,50)
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	subtitle = _label(cinema,21)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	subtitle.offset_left = 24
	subtitle.offset_right = -24
	subtitle.offset_top = -152
	subtitle.offset_bottom = -110
	var footer := HBoxContainer.new()
	footer.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	footer.position = Vector2(-310,-82)
	footer.add_theme_constant_override("separation",24)
	cinema.add_child(footer)
	skip_button = _button(footer,"跳过演出",func() -> void:journey.choose("p1",true))
	skip_p2 = _label(footer,18)
	var modal_layer := CanvasLayer.new()
	modal_layer.layer = 30
	add_child(modal_layer)
	dialog = Control.new()
	dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_layer.add_child(dialog)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(.025,.065,.12,.96)
	dialog.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 680
	var style := StyleBoxFlat.new()
	style.bg_color = Color("18334a")
	style.set_corner_radius_all(12)
	style.content_margin_left = 28
	style.content_margin_right = 28
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel",style)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",18)
	panel.add_child(column)
	heading = _label(column,28)
	body = _label(column,20)
	body.custom_minimum_size = Vector2(620,180)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	primary = _button(column,"确认",_confirm)
	secondary = _label(column,19)
	cancel = _button(column,"返回",func() -> void:journey.close())
	refresh()

func _label(parent: Node, size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size",size)
	label.add_theme_color_override("font_color",Color("eff6ff"))
	label.add_theme_color_override("font_shadow_color",Color("193248"))
	label.add_theme_constant_override("shadow_offset_x",2)
	label.add_theme_constant_override("shadow_offset_y",2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Node,text: String,action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(290,48)
	button.add_theme_font_size_override("font_size",20)
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _confirm() -> void:
	match journey.status:
		"briefing", "ending_page": journey.choose("p1")
		"ending_save": journey.retry_ending_save()
		"progress": journey.close()
		"new_confirm", "archive_confirm":
			var fresh: bool = journey.status=="new_confirm"
			journey.close(false)
			journey.world.session.exchange_journey(fresh)

func _p2_hint() -> String:
	return "P2 · 按Enter确认" if journey.world.local_controls.scheme=="keyboard" else "P2 · 手柄A确认"

func refresh() -> void:
	if not is_instance_valid(cinema): return
	var state: String = journey.status
	cinema.visible = state in ["clip","ending_page"]
	skip_button.get_parent().visible = state=="clip" and not journey.menu_requested
	title.text = "温暖归途"
	subtitle.text = "脚印会被新雪覆盖，一同走过的路不会。" if journey.elapsed<12 else "这段旅程已经完成，雪谷仍为归来的人留着路。"
	title.visible = not journey.menu_requested
	subtitle.visible = not journey.menu_requested
	skip_button.disabled = "p1" in journey.skip_votes
	skip_button.text = "P1已请求跳过" if skip_button.disabled else ("确认跳过" if "p2" in journey.skip_votes else "跳过演出")
	skip_p2.visible = journey._dual
	skip_p2.text = "P2已确认跳过" if "p2" in journey.skip_votes else _p2_hint()+"跳过"
	dialog.visible = state in ["briefing","ending_page","ending_save","progress","new_confirm","archive_confirm"] and not journey.menu_requested
	if state!=_last:
		_last = state
		_configure(state)
	secondary.visible = state=="ending_page" and journey._dual
	secondary.text = "P2已确认" if "p2" in journey.continue_votes else _p2_hint()
	if state=="ending_page":
		primary.disabled = "p1" in journey.continue_votes
		primary.text = "P1已确认" if primary.disabled else ("返回主菜单" if journey._manual and journey._was_menu else "继续探索")

func _configure(state: String) -> void:
	primary.disabled = false
	cancel.visible = state in ["progress","new_confirm","archive_confirm"]
	match state:
		"briefing":
			heading.text = "新的旅程 · 从安全屋出发"
			body.text = journey.progress_text()+"\n路上注意暖意与补给，伙伴也需要自己的柴火与弹药。"
			primary.text = "P1 · 准备出发"
		"progress":
			heading.text = "旅程进度"
			body.text = journey.progress_text()
			primary.text = "返回"
			cancel.hide()
		"ending_page":
			heading.text = "温暖归途"
			body.text = "石刻与栈道留下了这一路的记忆。\n山门后的挑战已经结束，屋檐仍替风雪留着一处安静。\n\n你可以让这段旅程暂歇，也可以再回到雪谷，看看那些还没走过的路。\n\n旅程已完成 · 继续探索，或在门外重温雪熊挑战。"
		"ending_save":
			heading.text = "胜利已结算 · 等待保存"
			body.text = "归途演出尚未开始。保存成功后再继续，当前角色与物资不会重复结算。\n\n"+str(journey.world.session.last_result.get("message","请重试保存"))
			primary.text = "重试保存"
		"new_confirm":
			heading.text = "开始新旅程？"
			body.text = "当前旅程的主档和备份将保留为上一个旅程。\n\n仅保留一个旅程归档，更早的归档将被替换。\n归档成功后，世界、任务与两人随身物资回到起点。\n\n操作设置保留。之后可从主菜单恢复上一个旅程。"
			primary.text = "归档当前旅程并重新出发"
		"archive_confirm":
			heading.text = "恢复上一个旅程？"
			var result: Dictionary = journey.archive.read_previous()
			_archive_ok = result.ok
			body.text = "恢复前会把当前旅程保存为唯一的上一个旅程，相当于交换两个旅程。\n\n操作设置保留，世界恢复后重新选择控制方式。" if result.ok else str(result.message)
			primary.text = "交换并恢复上一个旅程"
			primary.disabled = not _archive_ok

## 菜单键保持固定；P2键盘Enter和所属手柄A只提交P2自己的票。
func _input(event: InputEvent) -> void:
	if not journey.presenting(): return
	# 阻止外来手柄经Godot默认ui_accept按下当前聚焦的P1按钮。
	if event is InputEventJoypadMotion:
		if not journey.menu_requested: get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and not journey.menu_requested:
		if event.device!=journey.world.local_controls.pad_id:
			get_viewport().set_input_as_handled()
			return
		if event.button_index not in [JOY_BUTTON_START,JOY_BUTTON_A] or not event.pressed:
			get_viewport().set_input_as_handled()
			return
		if event.button_index==JOY_BUTTON_A and not (journey._dual and journey.world.local_controls.scheme=="gamepad"):
			get_viewport().set_input_as_handled()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = event.physical_keycode if event.physical_keycode!=0 else event.keycode
		if code in [KEY_ESCAPE,KEY_PAUSE]:
			journey.toggle_pause()
			get_viewport().set_input_as_handled()
		elif code==KEY_ENTER:
			if journey.menu_requested: return
			var p2: bool = journey._dual and journey.world.local_controls.scheme=="keyboard"
			if journey.status in ["clip","ending_page"]: journey.choose("p2" if p2 else "p1",journey.status=="clip")
			elif not p2: _confirm()
			get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed and event.device==journey.world.local_controls.pad_id:
		if event.button_index==JOY_BUTTON_START:
			journey.toggle_pause()
			get_viewport().set_input_as_handled()
		elif event.button_index==JOY_BUTTON_A and journey._dual and journey.world.local_controls.scheme=="gamepad":
			if journey.menu_requested: return
			if journey.status in ["clip","ending_page"]: journey.choose("p2",journey.status=="clip")
			get_viewport().set_input_as_handled()
