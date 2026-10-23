extends CanvasLayer
## 每屏紧凑图形状态卡与情境提示；不持有库存副本或写入世界状态。

const ICON = preload("res://scripts/v3/views/valley_status_icon.gd")
var world: Node3D
var panes: Dictionary = {}
var common: Label
var _age: float = 0.0


## 各视图独立生成卡片，公共时段天气只显示一次。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 5
	common = _label(self,18)
	common.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for id: String in ["p1","p2"]:
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color("182d40")
		style.set_corner_radius_all(8)
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 9
		style.content_margin_bottom = 9
		panel.add_theme_stylebox_override("panel",style)
		add_child(panel)
		var column := VBoxContainer.new()
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(column)
		var heading := _label(column,16)
		var heat := HBoxContainer.new()
		heat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(heat)
		_icon(heat,"warmth")
		var warmth := _label(heat,18)
		warmth.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var bar := _bar(column)
		var wood_row := HBoxContainer.new()
		column.add_child(wood_row)
		_icon(wood_row,"wood")
		var wood := _label(wood_row,18)
		wood.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ammo_row := HBoxContainer.new()
		column.add_child(ammo_row)
		_icon(ammo_row,"ammo")
		var ammo := _label(ammo_row,18)
		ammo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var reload_bar := _bar(column)
		var extra := _label(column,15)
		var prompt := _label(self,19)
		panes[id] = {"panel":panel,"heading":heading,"warmth":warmth,"bar":bar,"wood":wood,"ammo":ammo,"reload":reload_bar,"extra":extra,"prompt":prompt}


## 同步真实能力，所有临时文字都依据当前上下文和实际映射生成。
func _process(delta: float) -> void:
	_age += delta
	if _age < .1:
		return
	_age = 0.0
	# 1. 原V2标签继续可供调试读取，正式画面由唯一V3 HUD显示。
	for node: CanvasItem in [world._controls_label,world._status,world._location_label,world._weather_label,world.survival_ui._hud.get_parent(),world.survival_ui._hint,world.rifle._hud]:
		node.hide()
	for binding: Dictionary in world.view_manager.views.values():
		binding.label.hide()
	world.guard_ui._status.hide()
	common.visible = not world.session.main_menu.visible
	var size: Vector2 = world.get_viewport().get_visible_rect().size
	common.position = Vector2(12,14)
	common.size.x = size.x-24
	common.text = world._weather_label.text
	for id: String in panes:
		var row: Dictionary = panes[id]
		var shown: bool = not world.session.main_menu.visible and (id == "p1" or world.view_manager.split_enabled)
		row.panel.visible = shown
		row.prompt.visible = shown
		if not shown:
			continue
		var model: Node = world.survival if id == "p1" else world.secondary_context.survival
		var weapon: Node3D = world.rifle if id == "p1" else world.secondary_context.rifle
		var source: String = world.actor_registry.slots[id].source
		row.heading.text = id.to_upper()+(" · 观察" if id == "p2" and not world.local_controls.active else "")
		row.warmth.text = "暖意 %d / 100%s" % [ceili(model.warmth)," · 回暖" if float(model.last_thermal.get("rate",0)) > 0 else ""]
		row.bar.value = model.warmth
		row.wood.text = "柴火 %d / 20" % model.carried
		row.ammo.text = ("猎枪" if weapon.equipped == 2 else "雪球")+" · 膛内%d · 备用%d" % [weapon.chamber,weapon.reserve]
		row.reload.visible = weapon.reloading()
		row.reload.value = weapon.reload_fraction()*100
		var extra: String = "装填中" if weapon.reloading() else ""
		if is_instance_valid(world.events):
			var event_status: String = world.events.status_for(id)
			if not event_status.is_empty():
				extra += ("\n" if not extra.is_empty() else "")+event_status
		if world.world_clock.elapsed_seconds < weapon._message_until:
			extra += ("\n" if not extra.is_empty() else "")+_mapped_message(id,weapon._message)
		if model.warmth < 30:
			extra += ("\n" if not extra.is_empty() else "")+"暖意不足 · 寻找热源"
		if id == "p1" and not world.view_manager.split_enabled:
			var companion: Node = world.secondary_context.survival
			extra += ("\n" if not extra.is_empty() else "")+"P2 暖意%d · 柴%d · 弹%d" % [ceili(companion.warmth),companion.carried,world.secondary_context.rifle.chamber+world.secondary_context.rifle.reserve]
			if source == "local" and world.guard.enabled:
				extra += "\n伙伴："+world.guard.status+" · "+("允许开火" if world.guard.fire_allowed else "禁火")
		row.extra.text = extra
		row.extra.visible = not extra.is_empty()
		# 2. 靠近真实可交互对象才显示当前操作键；菜单与暂停期间清空。
		var endpoint: Node = world.input_router if id == "p1" else world.secondary_context.input_router
		row.prompt.text = ""
		if endpoint.allows_gameplay_input() and endpoint.context == endpoint.Context.EXPLORATION and not model.nearest.is_empty():
			row.prompt.text = world.control_settings.hint(id,"interact",id == "p2" and world.local_controls.scheme == "gamepad")+" · "+String(model.nearest.name)
		var rect: Rect2 = world.view_manager.views["view."+id].rect
		var width: float = minf(350,rect.size.x-24)
		row.panel.custom_minimum_size.x = width
		row.panel.size = Vector2(width,0)
		row.panel.position = rect.position+Vector2(12,rect.size.y-row.panel.size.y-12)
		row.prompt.position = rect.position+Vector2(14,maxf(54,rect.size.y-row.panel.size.y-49))
		row.prompt.size = Vector2(rect.size.x-28,42)


## 武器原始提示中的默认键统一替换为本角色当前映射。
func _mapped_message(id: String, text: String) -> String:
	return text.replace("按R", "按"+world.control_settings.hint(id,"reload",id == "p2" and world.local_controls.scheme == "gamepad"))


## 数量／进度图形保留文字身份，不依赖颜色独自表达暖意。
func _bar(parent: Node) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size.y = 7
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := StyleBoxFlat.new()
	track.bg_color = Color("31495c")
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("dbb277")
	bar.add_theme_stylebox_override("background",track)
	bar.add_theme_stylebox_override("fill",fill)
	parent.add_child(bar)
	return bar


## 语义图标与同一行的文字数值配对，缩放后仍保持固定可读轮廓。
func _icon(parent: Node, kind: String) -> void:
	var icon := ICON.new()
	icon.kind = kind
	parent.add_child(icon)


## HUD文字忽略鼠标，不能覆盖射击或拖镜头输入。
func _label(parent: Node, font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size",font_size)
	label.add_theme_color_override("font_color",Color("edf5fa"))
	label.add_theme_color_override("font_shadow_color",Color("142839"))
	label.add_theme_constant_override("shadow_offset_x",1)
	label.add_theme_constant_override("shadow_offset_y",1)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label
