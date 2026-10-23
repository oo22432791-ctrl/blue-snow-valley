extends CanvasLayer
## 战斗公共血条与每屏当前交互提示；暂停菜单仍拥有唯一保存／放弃入口。
var encounter: Node3D
var health: ProgressBar
var heading: Label
var hints: Array[Label] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 7
	var panel := VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(-310,50)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size.x = 620
	add_child(panel)
	heading = Label.new()
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_theme_font_size_override("font_size",20)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_color_override("font_shadow_color",Color("172d40"))
	heading.add_theme_constant_override("shadow_offset_x",2)
	heading.add_theme_constant_override("shadow_offset_y",2)
	panel.add_child(heading)
	health = ProgressBar.new()
	health.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := StyleBoxFlat.new()
	track.bg_color = Color("1a3046")
	track.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("b85c62")
	fill.set_corner_radius_all(4)
	health.add_theme_stylebox_override("background",track)
	health.add_theme_stylebox_override("fill",fill)
	health.custom_minimum_size.y = 18
	health.show_percentage = false
	panel.add_child(health)
	for index in range(2):
		var label := Label.new()
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size",18)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_shadow_color",Color("172d40"))
		label.add_theme_constant_override("shadow_offset_x",2)
		label.add_theme_constant_override("shadow_offset_y",2)
		add_child(label)
		hints.append(label)

## 提示读取M10真实映射，两个视图不共用P1交互键。
func _process(_delta: float) -> void:
	var e := encounter
	var in_menu: bool = e.world.session.main_menu.visible
	health.get_parent().visible = not in_menu and (e.status=="fighting" or (e.status=="won" and e.local(e.body("p1").global_position).length()<35))
	health.visible = e.status!="won"
	health.max_value = e.boss.maximum_health
	health.value = e.boss.health
	heading.text = "冰脊雪熊 · 阶段%d · %d／%d"%[e.boss.phase(),e.boss.health,e.boss.maximum_health]
	if e.status=="won": heading.text = "冰脊雪熊已被击败 · 山门开放"
	elif e.kind=="memory": heading.text = "回忆挑战 · "+heading.text
	if e.boss.combat=="weak": heading.text += " · 肩部弱点 %.1f秒"%e.boss.timer
	for index in range(2):
		var id := "p1" if index==0 else "p2"
		var label := hints[index]
		label.visible = not in_menu and (index==0 or e.world.view_manager.split_enabled)
		label.custom_minimum_size.x = (get_viewport().get_visible_rect().size.x*(.5 if e.world.view_manager.split_enabled else 1))-56
		label.position = Vector2(28+(get_viewport().get_visible_rect().size.x*.5 if index==1 else 0),132)
		var key: String = e.world.control_settings.key_text(e.world.control_settings.keyboard.bindings[id+".interact"])
		if index==1 and e.world.local_controls.scheme=="gamepad": key = e.world.control_settings.pad_text(e.world.control_settings.data.gamepad.interact)
		label.text = ""
		if id in e.retired:
			label.text = "已退场旁观 · 搭档仍在挑战"
		elif e.status=="entering":
			label.text = "沿门进入，等待全员到齐 · 门外交互取消"
		elif e.status=="inviting":
			label.text = "门外按%s确认挑战 · 暂停菜单可取消"%key
		elif e.status=="idle" and e.world.v3_progress.boss_unlocked and not e.world.v3_progress.boss_defeated and e.local(e.body(id).global_position).length()<7:
			label.text = "%s · 确认挑战雪熊"%key
		elif e.status=="won" and e.world.v3_progress.ending_seen and e.local(e.body(id).global_position).length()<7:
			label.text = "%s · 重温雪熊挑战（结束后还原物资）"%key
		elif e.running() and int(e.nearby[id])>=0:
			label.text = "按住%s取弹 %.1f／2秒 · 箱内%d发"%[key,e.progress[id],e.boxes[e.nearby[id]]]
