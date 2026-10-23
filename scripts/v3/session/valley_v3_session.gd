extends "res://scripts/session/valley_session.gd"
## V3会话适配：复用启动屏障与物理预检，替换磁盘和快照边界。

signal authority_pause_requested(actor_id: String)

const V3_SCHEMA = preload("res://scripts/v3/session/valley_v3_actor_snapshot.gd")
const V3_STORE = preload("res://scripts/v3/session/valley_v3_save_store.gd")
var local_authority: bool = true
var main_menu: Control
var _menu_status: Label
var _pending_restore: Dictionary = {}
var _restore_view_settings: Dictionary = {}
var failure_barrier: bool:
	get:
		return is_instance_valid(world.rescue) and world.rescue.blocks_resume()
var _pending_menu: bool = false
var _return_notice_pending: String = ""
var _initial_snapshot: Dictionary = {}
var _main_menu_button: Button
var preflight_actor_position := Vector3.INF
var _event_menu_waiting: bool = false
var _restore_boss_active: bool = false


## 在父类启动读取之前替换依赖，整个V3生命周期不使用V2存储器。
func _init() -> void:
	# 1. 父类_ready稍后注入世界和目录，当前构造不访问磁盘。
	schema = V3_SCHEMA.new()
	store = V3_STORE.new()


## 保存完整功能状态，不采集M15之前不应测量的保存耗时指标。
func _write(automatic: bool = false) -> bool:
	if is_instance_valid(world.boss_encounter) and world.boss_encounter._abort_queued:
		last_result = {"ok":false,"message":"等待挑战还原后保存"}
		return false
	# 已触发摔落先在真实物理帧完成平台回退，不能写入半空或漏扣暖意。
	if is_instance_valid(world.events) and not world.events.ready_for_save():
		world.events.defer_save(automatic)
		last_result = {"ok":false,"message":"等待平台返回完成后保存"}
		return false
	# 1. 失败锁和模块关系全部通过之后才接触磁盘。
	if not local_authority:
		last_result = {"ok": false, "message": "只有房主可以保存世界进度"}
		_notice(last_result.message)
		return false
	var data: Dictionary = schema.capture(world, world.survival.protection_until)
	var message: String = schema.validate(data, world)
	if not message.is_empty():
		last_result = {"ok": false, "message": message}
		_notice("保存未完成：" + message)
		return false
	# 2. V3存储器再次检查版本与目录，复用摘要、临时写入和备份。
	last_result = store.write_snapshot(data)
	if not last_result.ok:
		_notice(last_result.message)
		return false
	# 3. 只记录功能事件，不记录耗时、帧率或资源监视器数据。
	save_count += 1
	if automatic:
		auto_save_count += 1
	_record("save", {"automatic": automatic})
	_notice("已自动保存" if automatic else "已保存进度")
	return true


## 先建立原暂停菜单，再增加明确的主菜单模式入口。
func _create_menu() -> void:
	# 1. V2菜单不变，V3新增返回主菜单按钮。
	super._create_menu()
	_main_menu_button = _button(_resume.get_parent(), "MainMenuButton", "保存并返回主菜单", return_to_main_menu)
	_button(_resume.get_parent(), "AbandonBossButton", "放弃本次雪熊挑战", func() -> void:world.boss_encounter.request_abandon())
	_button(_resume.get_parent(), "ControlSettingsButton", "操作设置", func() -> void:world.settings_ui.open())
	_button(_resume.get_parent(), "ControlHelpButton", "操作说明", func() -> void:world.settings_ui.open(true))
	_button(_resume.get_parent(), "JourneyProgressButton", "旅程目标与进度", func() -> void:world.journey.open_progress())
	var pause_content: VBoxContainer = _resume.get_parent()
	var pause_center: Node = pause_content.get_parent()
	var pause_scroll := ScrollContainer.new()
	pause_scroll.custom_minimum_size = Vector2(460,600)
	pause_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pause_center.add_child(pause_scroll)
	pause_content.reparent(pause_scroll)
	pause_content.add_theme_constant_override("separation",8)
	pause_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var layer := CanvasLayer.new()
	layer.layer = 25
	add_child(layer)
	main_menu = Control.new()
	main_menu.name = "V3MainMenu"
	main_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_menu.hide()
	layer.add_child(main_menu)
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.035, 0.09, 0.16, 0.94)
	main_menu.add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_menu.add_child(center)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(660,620)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	center.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	var title := Label.new()
	title.text = "蓝色雪境"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	content.add_child(title)
	_menu_status = Label.new()
	_menu_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_menu_status)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation",12)
	grid.add_theme_constant_override("v_separation",8)
	content.add_child(grid)
	# 2. 单人模式分别明确保留待命入口和已接入的跟随护卫。
	_button(content, "SingleOffButton", "单人探索 · 伙伴待命", func() -> void:launch_mode("single_off"))
	var partner := _button(content, "SingleAIButton", "单人探索 · AI护卫伙伴", func() -> void:launch_mode("single_ai"))
	partner.tooltip_text = "伙伴指令可下达跟随／等待／协助与禁火，当前按键见操作说明；伙伴使用真实冷暖和弹药"
	var observation := _button(content, "ViewPreviewButton", "左右双视图观察", func() -> void:
		if launch_mode("single_off"):
			world.view_manager.set_split(true))
	observation.tooltip_text = "此观察入口仅操作P1；两名真人请另选同机双人键盘或手柄入口"
	var keyboard := _button(content, "LocalKeyboardButton", "同机双人 · P2键盘", func() -> void:launch_mode("local_keyboard"))
	keyboard.tooltip_text = "P1键鼠与P2键盘分别控制；当前键位见操作设置／说明"
	var gamepad := _button(content, "LocalGamepadButton", "同机双人 · P2 Xbox手柄", func() -> void:launch_mode("local_gamepad"))
	gamepad.tooltip_text = "左摇杆移动，右摇杆镜头；按钮与扳机可修改，当前映射见操作设置／说明"
	_button(content,"BossArenaPreviewButton","雪熊与场地小样",launch_arena_preview)
	# 3. 不让尚未实现输入／连接的模式伪装成可以游玩的合作入口。
	for row: Array in [["LanButton", "局域网合作"], ["OnlineButton", "互联网合作"]]:
		var unavailable := _button(content, row[0], row[1] + " · 尚未开放", func() -> void:pass)
		unavailable.disabled = true
	_button(content, "ControlSettingsButton", "操作设置／说明", func() -> void:world.settings_ui.open())
	_button(content, "NewJourneyButton", "开始新旅程", func() -> void:world.journey.open_new())
	_button(content, "PreviousJourneyButton", "恢复上一个旅程", func() -> void:world.journey.open_archive())
	_button(content, "ReplayEndingButton", "回看温暖归途", func() -> void:world.journey.replay_ending())
	_button(content, "ExitButton", "退出游戏", func() -> void:get_tree().quit())
	# 模式与旅程操作同屏可见，窄窗口仍保留滚动。
	for child: Node in content.get_children():
		if child is Button:
			child.reparent(grid)
			child.custom_minimum_size = Vector2(310,48)


## 新局或完整恢复后停留主菜单，模式选择不写入世界快照。
func _boot() -> void:
	# 1. 沿用原有导航等待、坏档屏障与完整物理预检。
	for index in range(180):
		if world.bears.ready_for_paths:
			break
		await get_tree().process_frame
	_initial_snapshot = schema.capture(world, world.survival.protection_until)
	await super._boot()
	if session_ready and not _boot_fault:
		_show_main_menu()


## 主菜单展示固定两槽位的已加载物资，不把设备归属当成世界进度。
func _show_main_menu() -> void:
	# 1. 所有模拟暂停，按钮点击不会穿透成武器输入。
	world.set_session_paused(true)
	if is_instance_valid(world.local_controls):
		world.local_controls.suspend()
	world.input_router._release_actions()
	var actors: Dictionary = world.actor_registry.capture_actors()
	_menu_status.text = "同一山谷 · 两份随身行囊\nP1 柴火%d · 弹药%d　P2 柴火%d · 弹药%d" % [actors.p1.carried, actors.p1.rifle.chamber + actors.p1.rifle.reserve, actors.p2.carried, actors.p2.rifle.chamber + actors.p2.rifle.reserve]
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.ongoing():
		_menu_status.text += "\n雪熊挑战进行中 · 选择原队伍继续；改变队伍将还原入场状态"
	main_menu.find_child("ReplayEndingButton",true,false).disabled = not world.v3_progress.ending_seen
	world._pause_overlay.hide()
	main_menu.show()


## 主菜单选择单人或两套同机输入；网络入口由后续模块接入。
func launch_mode(value: String) -> bool:
	# 1. 模式切换只能从已完整加载的主菜单发起。
	if not local_authority or busy or not session_ready or _boot_fault or not main_menu.visible or value not in ["single_off", "single_ai", "local_keyboard", "local_gamepad"]:
		return false
	if value == "local_gamepad" and Input.get_connected_joypads().is_empty():
		_menu_status.text = "未发现手柄，请连接后重试；也可选择P2键盘"
		return false
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.ongoing() and world.boss_encounter.party_for(value)!=world.boss_encounter.party:
		world.boss_encounter.launch_after_retry = value
		world.boss_encounter.request_abandon()
		return false
	_clear_mode_transients()
	if is_instance_valid(world.view_manager):
		world.view_manager.set_split(false)
	if world.actor_registry.set_mode("local" if value.begins_with("local_") else value) != OK:
		return false
	world.local_controls.configure(value)
	world.apply_control_settings()
	world.view_manager.set_split(value.begins_with("local_"))
	main_menu.hide()
	world._resume_context = world.input_router.Context.EXPLORATION
	world.set_session_paused(false)
	world.journey.on_mode_started()
	return true


## 独立小样不保存、导入或改写探索快照，从主菜单明确进入。
func launch_arena_preview() -> void:
	if not local_authority or busy or not main_menu.visible:
		return
	world.input_router._release_actions()
	world.local_controls.suspend()
	get_tree().change_scene_to_file.call_deferred("res://scenes/v3/boss_arena_preview.tscn")


## 先验证目标并预检真实空间，再成组交换主档和备份；操作设置不属于旅程。
func exchange_journey(fresh: bool) -> void:
	if not local_authority or busy or not session_ready or _boot_fault or not main_menu.visible: return
	var previous := ""
	var target: Dictionary
	if fresh:
		target = _initial_snapshot.duplicate(true)
	else:
		var archived: Dictionary = world.journey.archive.read_previous()
		if not archived.ok:
			_menu_status.text = archived.message
			return
		target = schema.normalize(archived.snapshot,world)
		previous = archived.previous
	busy = true
	var problem: String = schema.validate(target,world)
	if problem.is_empty(): problem = await _preflight(target)
	if not problem.is_empty():
		busy = false
		_menu_status.text = "旅程未替换："+problem
		return
	# 先提交最新当前世界，使归档包含退出前真实进度。
	if not _write(false):
		busy = false
		_menu_status.text = last_result.message
		return
	var result: Dictionary = world.journey.archive.exchange(target,previous,fresh)
	if not result.ok:
		busy = false
		_menu_status.text = result.message
		return
	_apply(target)
	busy = false
	_show_main_menu()
	_notice("旧旅程已归档 · 请选择新旅程的队伍" if fresh else "已交换并恢复上一个旅程 · 请选择队伍继续")


## 保存成功才返回模式菜单，失败保持暂停界面和原控制关系。
func return_to_main_menu() -> void:
	# 1. 不允许客人借菜单保存、读档或接管世界。
	if not local_authority or busy or not session_ready or _boot_fault:
		return
	if world.journey.presenting(): world.journey.close(false)
	if is_instance_valid(world.events) and not world.events.ready_for_save():
		_event_menu_waiting = true
		world.events.defer_save(false)
		world.set_session_paused(true)
		_notice("先完成平台返回，再保存并回主菜单。")
		return
	if is_instance_valid(world.boss_encounter) and world.boss_encounter.ongoing():
		world.set_session_paused(true)
		_clear_mode_transients()
		if _write(false): _show_main_menu()
		return
	if world.rescue.any_incapacitated():
		_pending_menu = true
		var ids: Array = []
		for id: String in ["p1", "p2"]:
			if not world.rescue.can_act(id):
				ids.append(id)
		world.rescue.request_return(ids)
		_notice("先完成倒地角色的安全返回，再保存并回主菜单。")
		return
	world.set_session_paused(true)
	_clear_mode_transients()
	busy = true
	var saved := _write(false)
	busy = false
	if saved:
		_show_main_menu()


## 切模式清理短生命周期状态，但不改变已提交的柴火和弹药数量。
func _clear_mode_transients() -> void:
	if is_instance_valid(world.events):
		world.events.cancel_transients()
	# 1. 比赛退出恢复原装备，装填尚未完成不预扣弹。
	world.snowball_game.end_activity("mode_switch", true)
	_invalidate_input()
	world.rifle.cancel_reload()
	world.rifle.view.reset_feedback()
	if is_instance_valid(world.local_controls):
		world.local_controls.clear_all()
		world.secondary_context.rifle.cancel_reload()
		world.secondary_context.rifle.view.reset_feedback()
		world.secondary_context.selected_target = null
	world.snow_tracks.reset_history(world.world_clock.elapsed_seconds)
	for binding: Dictionary in world.actor_registry.slots.values():
		binding.state.data.rifle.reload_at = -1.0
		binding.body.set_external_direction(Vector3.ZERO)


## 两个有效角色都可请求暂停；客人只发请求，不自行改变房主世界。
func request_pause(actor_id: String) -> bool:
	# 1. 主菜单、启动恢复或闲置角色不能绕过当前屏障。
	if failure_barrier or busy or not session_ready or _boot_fault or main_menu.visible or not world.actor_registry.slots.has(actor_id) or world.actor_registry.slots[actor_id].source == "idle":
		return false
	if local_authority:
		if world.journey.presenting(): world.journey.toggle_pause()
		else: world.set_session_paused(not get_tree().paused)
	else:
		authority_pause_requested.emit(actor_id)
	return true


## 保存入口先检查本地世界权限；真正联机认证由网络模块接入。
func request_save(automatic: bool = false) -> void:
	# 1. 客人不能把房主快照提交成本地其他世界进度。
	if local_authority:
		if is_instance_valid(world.events) and not world.events.ready_for_save():
			world.events.defer_save(automatic)
			return
		super.request_save(automatic)


## 平台回退后重新进入原菜单流程，暖意归零时仍先走M6安全返回。
func resume_event_save(automatic: bool) -> void:
	if _event_menu_waiting:
		_event_menu_waiting = false
		return_to_main_menu()
	else:
		request_save(automatic)


## 读取和备份恢复同样只允许房主，不能由客人任意回滚世界。
func load_slot(backup: bool = false) -> void:
	# 1. 全部校验与恢复仍在父类冻结屏障中执行。
	if local_authority:
		if world.journey.presenting(): world.journey.close(false)
		_event_menu_waiting = false
		_pending_menu = false
		var startup_fault := _boot_fault
		var from_menu := main_menu.visible
		await super.load_slot(backup)
		# 2. 启动坏档恢复成功后仍须回主菜单选择来源，不能绕过新版入口。
		if session_ready and not _boot_fault and (startup_fault or from_menu):
			_show_main_menu()


## 保留坏档后新局也回主菜单，不能绕过模式选择继续旧控制归属。
func _preserve_and_start() -> void:
	# 1. 原流程归档失败时继续停留错误屏障。
	if not local_authority:
		return
	_pending_menu = false
	var reset_life: bool = world.rescue.any_incapacitated()
	if reset_life:
		busy = true
		var problem: String = await _preflight(_initial_snapshot)
		busy = false
		if not problem.is_empty():
			_fault(problem, true)
			return
	super._preserve_and_start()
	if reset_life and session_ready and not _boot_fault:
		_apply(_initial_snapshot)
	if session_ready and not _boot_fault:
		_show_main_menu()


## 两个保存位置周围先驻留，再使用相同门和熊状态进行物理预检。
func _preflight(data: Dictionary) -> String:
	# 1. 父流程调用前已通过完整语义校验，规范化不写盘。
	_pending_restore = schema.normalize(data, world)
	world.regions.preview_positions.clear()
	for actor: Dictionary in _pending_restore.actors.values():
		world.regions.preview_positions.append(Vector3(actor.position[0], actor.position[1], actor.position[2]))
	world.regions.update_regions()
	# V3固定P2另有真实位置预检，不沿用V2临时散步NPC的近处重排。
	preflight_actor_position = Vector3(_pending_restore.actors.p2.position[0],_pending_restore.actors.p2.position[1],_pending_restore.actors.p2.position[2])
	var current_boss: Dictionary = world.boss_encounter.capture_state()
	world.boss_encounter.preview_state(_pending_restore.world_state.boss)
	var gate_fraction: float = world.events.geometry.gate_open
	world.events.geometry.set_gate_fraction(0 if _pending_restore.world_state.boss.status=="fighting" else (1 if _pending_restore.progress.boss_unlocked else 0))
	var problem: String = await super._preflight(schema.to_legacy(_pending_restore, world))
	preflight_actor_position = Vector3.INF
	world.boss_encounter.preview_state(current_boss)
	world.events.geometry.set_gate_fraction(gate_fraction)
	# 2. 无论通过或失败都撤销临时加载关注点，保留运行中的真实两角色。
	world.regions.preview_positions.clear()
	world.regions.update_regions()
	return problem


## 在父类已摆放保存门／熊并完成物理同步时验证P2胶囊和脚下支撑。
func _preflight_additional(_data: Dictionary) -> String:
	# 1. 排除两个自身实体，人物互相重叠已由规范快照提前拒绝。
	var values: Array = _pending_restore.actors.p2.position
	var at := Vector3(values[0], values[1], values[2])
	var excluded: Array[RID] = [world.player.get_rid(), world.snowball_game.companion.get_rid()]
	var shape := CapsuleShape3D.new()
	shape.radius = .28
	shape.height = 1.46 if _pending_restore.actors.p2.life.state == "standing" else .99
	var center: float = .75 if _pending_restore.actors.p2.life.state == "standing" else .525
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * center)
	query.collision_mask = 1
	query.exclude = excluded
	query.margin = 0
	var space := world.get_world_3d().direct_space_state
	if not space.intersect_shape(query, 8).is_empty():
		return "第二角色保存位置被实体遮挡，恢复未提交"
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .15, at - Vector3.UP * .4, 1, excluded)
	if space.intersect_ray(ray).is_empty():
		return "第二角色保存位置缺少支撑，恢复未提交"
	return ""


## 规范快照转成现有能力契约，附加状态在恢复完成信号之前提交。
func _apply(data: Dictionary) -> void:
	if world.journey.presenting(): world.journey.close(false)
	_return_notice_pending = ""
	# 1. 控制来源不从存档恢复，保持当前主菜单选择。
	_pending_restore = schema.normalize(data, world)
	_restore_view_settings.clear()
	_restore_boss_active = world.boss_encounter.ongoing()
	# 2. 镜头属于本地视图设置，世界读档不能把合法18米缩放截成旧版16米。
	if is_instance_valid(world.view_manager):
		for id: String in world.view_manager.views:
			var rig: Node3D = world.view_manager.views[id].rig
			_restore_view_settings[id] = {"yaw": rig.yaw_degrees, "pitch": rig.pitch_degrees, "desired_size": rig.desired_size, "size": rig.camera.size}
	super._apply(schema.to_legacy(_pending_restore, world))


## 两角色与目标进度一次恢复完成，监听者不能看到一半新一半旧状态。
func _restore_additional_state(_data: Dictionary) -> void:
	# 1. P1真实生存和枪械已恢复，此处提交独立P2及规范容器。
	world.actor_registry.restore_actors(_pending_restore.actors)
	world.v3_progress = _pending_restore.progress.duplicate(true)
	world.events.restore_state(_pending_restore.world_state.events)
	# 2. 两角色位置提交后重算各自房间，最后在完成信号之前恢复本地构图。
	world.interior.sync_rooms()
	world.guard.restore_policy(_pending_restore.world_state.companion_policy)
	world.boss_encounter.retired.clear()
	world.rescue.restore_state(_pending_restore.actors, _pending_restore.world_state.boss_checkpoint)
	world.boss_encounter.restore_state(_pending_restore.world_state.boss)
	for id: String in ["p1","p2"]: world.rescue.body(id).sync_restored_pose()
	world.journey.reset_for_restore(_pending_restore)
	_sync_failure_buttons()
	for id: String in _restore_view_settings:
		if _restore_boss_active and not world.boss_encounter.ongoing(): continue
		var rig: Node3D = world.view_manager.views[id].rig
		var settings: Dictionary = _restore_view_settings[id]
		rig.yaw_degrees = settings.yaw
		rig.pitch_degrees = settings.pitch
		rig.desired_size = settings.desired_size
		rig.camera.size = settings.size
		rig.interior_weight = 1.0 if is_instance_valid(rig.interior_cabin) else 0.0
		rig.snap_to_actor()


## P1与P2失败共用角色级倒地入口，不再使用M5全局临时失败屏障。
func _on_failed(reason: StringName) -> void:
	# 1. 固定角色归属明确，不把P2命中转换为P1扣损。
	_on_actor_failed("p1", reason)


## 逐角色去重、倒地等待和全倒返回由同一协调器负责。
func _on_actor_failed(actor_id: String, reason: StringName) -> void:
	# 1. 世界装配完成前没有可游玩失败事件。
	if is_instance_valid(world.rescue):
		world.rescue.fail_actor(actor_id, reason)


## 倒地可以保存；仅全倒返回点受阻时禁止直接继续。
func _sync_failure_buttons() -> void:
	# 1. 持续倒地状态由306保存，UI不以“禁止保存”代替完整生命周期。
	_resume.disabled = failure_barrier or _boot_fault
	for name_value: String in ["SaveButton", "SaveQuitButton"]:
		var button: Button = _resume.get_parent().get_node(name_value)
		button.disabled = _boot_fault
	_main_menu_button.text = "保存并返回主菜单"
	_retry.visible = is_instance_valid(world.rescue) and world.rescue.return_blocked
	_retry.text = "重试安全返回"


## 返回完成后唯一保存；若是用户切模式请求，先保存再进入主菜单。
func _after_safe_return(ids: Array) -> void:
	# 1. 失败前存档不覆盖半个返回事务，已经扣过的角色不再参与重试。
	return_count += ids.size()
	_sync_failure_buttons()
	if _pending_menu and not world.rescue.any_incapacitated():
		_pending_menu = false
		_return_notice_pending = ""
		return_to_main_menu()
	else:
		_return_notice_pending = world.rescue.last_return_notice
		request_save(true)


## 冻结期间重试只发意图，物理帧再校验当前真实站位。
func _retry_return() -> void:
	# 1. 无预扣柴、无临时关闭碰撞，重复按钮不会复制结算。
	world.rescue.retry_returns()


## 输入、菜单、比赛与施救进度在读档时一起释放，避免跨档误射或秒救。
func _invalidate_input() -> void:
	if is_instance_valid(world.events):
		world.events.cancel_transients()
	if is_instance_valid(world.guard_ui):
		world.guard_ui.close()
	# 1. 保留已有原子库存，撤销尚未提交的双方动作。
	super._invalidate_input()
	world.snowball_game.end_activity("restore", true)
	if is_instance_valid(world.local_controls):
		world.local_controls.clear_all()
		world.secondary_context.survival.close_session()
		world.secondary_context.survival._interact_pending = false
		world.secondary_context.rifle.cancel_reload()
		world.secondary_context.rifle._pending_fire = false
		world.secondary_context.selected_target = null


## M12在实际场外入口调用，捕获完整世界作为本次Boss挑战的唯一重试起点。
func begin_boss_encounter() -> bool:
	# 1. 倒地、恢复或已在挑战中都不能覆盖原检查点。
	if not local_authority or busy or not session_ready or _boot_fault or world.rescue.any_incapacitated() or not world.rescue.boss_checkpoint.is_empty():
		return false
	var data: Dictionary = schema.capture(world, world.survival.protection_until)
	var problem: String = schema.validate(data, world)
	if not problem.is_empty():
		_notice("尚不能开始挑战：" + problem)
		return false
	world.rescue.boss_checkpoint = data
	return true


## M13胜利结算完成后释放重试边界，不能在探索失败时撤销已完成胜利。
func finish_boss_encounter() -> void:
	# 1. 只由房主世界的胜利结算消费者调用。
	if local_authority and not busy:
		world.rescue.boss_checkpoint.clear()


## Boss失败恢复完整入场快照，先语义和物理预检，成功后才撤销本次消耗。
func retry_boss_entry() -> void:
	# 1. M6建立完整快照边界，M13正式挑战调用同一恢复事务。
	if not local_authority or busy or world.rescue.boss_checkpoint.is_empty():
		world.rescue._boss_busy = false
		return
	var was_paused := get_tree().paused
	busy = true
	world.set_session_paused(true)
	var entry: Dictionary = world.rescue.boss_checkpoint.duplicate(true)
	var problem: String = schema.validate(entry, world)
	if problem.is_empty():
		problem = await _preflight(entry)
	if not problem.is_empty():
		busy = false
		world.rescue._boss_busy = false
		world.rescue.return_blocked = true
		_sync_failure_buttons()
		_notice("挑战入口暂时受阻，重试未提交：" + problem)
		if not was_paused and not failure_barrier:
			world.set_session_paused(false)
		return
	# 2. 世界时间、天气、柴弹、双方位置与全部持久状态一起回到入场前。
	_apply(entry)
	busy = false
	_notice("已回到挑战入口 · 本次挑战的世界变化和消耗已恢复")
	world.rescue.last_return_notice = "已回挑战入口 · 入场前状态已恢复"
	world.rescue.boss_retry_completed.emit()
	_after_safe_return(["p1", "p2"])
	if not was_paused and not main_menu.visible:
		world.set_session_paused(false)


## 坏档不解除倒地或返回屏障，也不覆盖原文件。
func _fault(message: String, startup: bool) -> void:
	# 1. 既有备份恢复与保留后新局继续使用原流程。
	super._fault(message, startup)
	_sync_failure_buttons()


## P1预检按保存的站立／倒地胶囊验证，不能把读档仍倒地误当成立即站起。
func _position_problem(at: Vector3, transient_exclusion: RID = RID()) -> String:
	# 1. V3两角色都已完整验证位置，保留父流程排除自身与临时伙伴的约束。
	var standing: bool = _pending_restore.actors.p1.life.state == "standing"
	var shape := CapsuleShape3D.new()
	shape.radius = .28
	shape.height = 1.46 if standing else .99
	var excluded: Array[RID] = [world.player.get_rid()]
	if transient_exclusion.is_valid():
		excluded.append(transient_exclusion)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * (.75 if standing else .525))
	query.collision_mask = 1
	query.exclude = excluded
	query.margin = 0
	var space := world.get_world_3d().direct_space_state
	if not space.intersect_shape(query, 8).is_empty():
		return "保存位置被实体遮挡，请恢复备份"
	if space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * .15, at - Vector3.UP * .4, 1, excluded)).is_empty():
		return "保存位置缺少脚下支撑，请恢复备份"
	return ""


## 返回后的自动保存保留角色与实际扣柴反馈，不让通用保存文字立即遮掉原因。
func _flush_save(automatic: bool) -> void:
	# 1. 仍在帧末保存，包含另一角色本物理帧已提交的库存事务。
	var before := save_count
	super._flush_save(automatic)
	if not _return_notice_pending.is_empty() and not busy and session_ready:
		if save_count > before:
			_notice(_return_notice_pending + " · 已自动保存")
		elif not last_result.get("ok", true):
			_notice(_return_notice_pending + " · 保存未完成：" + String(last_result.message))
		_return_notice_pending = ""
