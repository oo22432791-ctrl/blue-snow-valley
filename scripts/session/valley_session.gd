extends Node
## M12会话协调：完整校验后恢复、入屋保存、失败单次扣柴与明确坏档选择。

signal state_restored

const SNAPSHOT=preload("res://scripts/session/valley_snapshot.gd")
const STORE=preload("res://scripts/session/valley_save_store.gd")
var world: Node3D
var store=STORE.new()
var schema=SNAPSHOT.new()
var busy: bool=true
var session_ready: bool=false
var save_count: int=0
var last_save_ms: float=0.0
var auto_save_count: int=0
var load_count: int=0
var return_count: int=0
var last_result: Dictionary={}
var history: Array[Dictionary]=[]
var _save_queued: bool=false
var _boot_fault: bool=false
var _skip_entry: StringName=&""
var _return_pending: bool=false
var _return_reason: StringName=&""
var _retry: Button
var _info: Label
var _toast: Label
var _fresh: Button
var _backup: Button
var _resume: Button
var _companion_restore_at := Vector3.INF


## 启动屏障等待熊导航就绪，首次无档正常开始，有档完整恢复后才放开输入。
func _ready() -> void:
	# 1. UI和协调器在暂停中可运行，世界模拟仍由统一场景树冻结。
	process_mode=Node.PROCESS_MODE_ALWAYS;store.directory=world.save_directory
	store.snapshot_validator=func(data: Dictionary) -> String:return schema.validate(data,world)
	_create_menu();world.set_session_paused(true)
	world.survival.failed.connect(_on_failed);world.interior.entered.connect(_on_entered)
	call_deferred("_boot")


## 使用现有暂停布局添加产品操作，技术路径与调试字段不进入玩法菜单。
func _create_menu() -> void:
	# 1. 继续按钮保留原Esc行为，忙碌屏障由世界暂停入口统一校验。
	_resume=world._pause_overlay.find_child("ResumeButton",true,false)
	var content: VBoxContainer=_resume.get_parent()
	_button(content,"SaveButton","保存进度",func() -> void:request_save())
	_button(content,"LoadButton","读取进度",func() -> void:load_slot(false))
	_backup=_button(content,"BackupButton","恢复上次备份",func() -> void:load_slot(true))
	_button(content,"SaveQuitButton","保存并退出",_save_and_quit)
	_retry=_button(content,"RetryReturnButton","重试返回安全小屋",_retry_return);_retry.hide()
	_fresh=_button(content,"PreserveStartButton","保留原档后重新开始",_preserve_and_start);_fresh.hide()
	_info=Label.new();_info.text="正在准备山谷…";_info.custom_minimum_size=Vector2(430,60);_info.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;content.add_child(_info)
	# 2. 自动保存与失败返回通知不抢输入，也不显示内部稳定ID。
	var layer:=CanvasLayer.new();layer.layer=15;add_child(layer)
	_toast=Label.new();_toast.position=Vector2(430,112);_toast.add_theme_font_size_override("font_size",22)
	_toast.add_theme_color_override("font_color",Color("f1f6fb"));_toast.add_theme_color_override("font_shadow_color",Color("20364f"));_toast.add_theme_constant_override("shadow_offset_x",2);_toast.add_theme_constant_override("shadow_offset_y",2);_toast.mouse_filter=Control.MOUSE_FILTER_IGNORE;layer.add_child(_toast)


## 按钮统一走协调器，忙碌时拒绝重复点击而不创建额外提交。
func _button(parent: Node, name_value: String, title: String, action: Callable) -> Button:
	# 1. 按钮大小与原继续按钮相同，回调不透传为射击输入。
	var button:=Button.new();button.name=name_value;button.text=title;button.custom_minimum_size=Vector2(430,50)
	button.pressed.connect(func() -> void:
		if not busy:action.call())
	parent.add_child(button);return button


## 初次装配不产生进屋保存，坏档保持暂停，用户选择之前不覆盖任何文件。
func _boot() -> void:
	# 1. 导航同步有明确上限；进度校验必须使用已建立的稳定熊ID。
	var frames:=0
	while not world.bears.ready_for_paths and frames<180:
		await get_tree().process_frame;frames+=1
	if not world.bears.ready_for_paths:_fault("山谷尚未准备好，存档未改动",true);return
	var result: Dictionary=store.read_slot()
	if result.get("missing",false) and not FileAccess.file_exists(store.directory+"/previous.json"):
		session_ready=true;busy=false;_notice("新的山谷旅程");world.set_session_paused(false);return
	if not result.ok:_fault(result.message,true);return
	var message: String=schema.validate(result.snapshot,world)
	if not message.is_empty():_fault(message,true);return
	message=await _preflight(result.snapshot)
	if not message.is_empty():_fault(message,true);return
	_apply(result.snapshot);session_ready=true;busy=false;load_count+=1;_notice("已继续上次旅程");world.set_session_paused(false)


## 入屋只排队到当前物理事务之后，恢复和失败返回期间不重复自动保存。
func _on_entered(_id: StringName) -> void:
	# 0. 读档／返回已包含这次入屋状态，不再覆盖上次有效备份。
	if _skip_entry!=&"":
		var skipped: bool=_skip_entry==_id;_skip_entry=&""
		if skipped:return
	# 1. 室内模块已去重门槛，协调器再合并同帧请求。
	if session_ready and not busy:request_save(true)


## 手动和自动保存共用一次完整快照；同帧重复点击只消费一笔。
func request_save(automatic: bool=false) -> void:
	# 1. 自动保存等到模块本帧交互提交完成；暂停菜单仍可调用。
	if busy or not session_ready or _boot_fault or _save_queued:return
	_save_queued=true;call_deferred("_flush_save",automatic)


## 帧末主线程同步捕获与写盘，不切暂停或释放持续输入。
func _flush_save(automatic: bool) -> void:
	# 1. 在排队期间若发生失败，由返回流程保存结算后的状态。
	_save_queued=false
	if busy or not session_ready:return
	# 2. 主线程同步捕获／写入没有await，不必切换暂停，避免释放持续移动键。
	busy=true;_write(automatic);busy=false


## 写盘前统一语义校验；校验失败不会触碰有效主档。
func _write(automatic: bool=false) -> bool:
	# 1. 玩家失败锁未解除时不能存入导致下次立即失败的快照。
	var data: Dictionary=schema.capture(world,world.survival.protection_until)
	var message: String=schema.validate(data,world)
	if not message.is_empty():last_result={"ok":false,"message":message};_notice("保存未完成："+message);return false
	var started:=Time.get_ticks_usec();last_result=store.write_snapshot(data);last_save_ms=(Time.get_ticks_usec()-started)/1000.0
	if last_result.ok:
		save_count+=1
		if automatic:auto_save_count+=1
		_record("save",{"automatic":automatic,"write_ms":last_save_ms});_notice("已自动保存" if automatic else "已保存进度")
	else:_notice(last_result.message)
	return last_result.ok


## 主档和备份都先校验／物理预检，用户触发后才恢复且保留暂停。
func load_slot(backup: bool=false) -> void:
	# 1. 任何失败都不提交库存或时间；启动坏档继续阻止游玩直到明确选择。
	if busy:return
	busy=true;world.set_session_paused(true)
	var result: Dictionary=store.read_slot(backup)
	if not result.ok:_fault(result.message,_boot_fault);return
	var message: String=schema.validate(result.snapshot,world)
	if not message.is_empty():_fault(message,_boot_fault);return
	message=await _preflight(result.snapshot)
	if not message.is_empty():_fault(message,_boot_fault);return
	if backup:
		var error: Error=store.archive_current()
		if error!=OK:_fault("无法保留原主档，恢复未提交",_boot_fault);return
		var written: Dictionary=store.write_snapshot(result.snapshot)
		if not written.ok:_fault(written.message,_boot_fault);return
	# 2. 清除旧回合／装填／输入后一次提交，恢复不会触发额外进屋保存。
	_apply(result.snapshot);load_count+=1;session_ready=true;busy=false;_boot_fault=false;_resume.disabled=false;_fresh.hide()
	last_result={"ok":true,"message":"已读取进度"}
	_record("load",{"backup":backup});_notice("已恢复备份，可继续探索" if backup else "已读取进度，可继续探索")


## 将快照位置及实体门临时放入冻结物理世界，查询完成后先回滚预检摆放。
func _preflight(data: Dictionary) -> String:
	# 1. 暂停屏障中仅暂移空间对象，库存、生命、随机流和时间均未提交。
	var previous: Vector3=world.player.position;var door_poses: Dictionary={};var bear_poses: Array=[]
	world.player.position=Vector3(data.player.position[0],data.player.position[1],data.player.position[2]);world.regions.update_regions()
	for cabin: Node3D in world.landmarks.cabins:
		var id:=String(cabin.get_meta("building_id"));door_poses[id]=cabin.door.transform
		cabin.door.transform=Transform3D(Basis(Vector3.UP,float(data.doors[id].angle)),cabin._vector(cabin.manifest.door.pivot))
	for index in range(world.bears.bears.size()):
		var bear: CharacterBody3D=world.bears.bears[index];var row: Dictionary={}
		for saved: Dictionary in data.bears:
			if saved.id==bear.stable_id:row=saved
		bear_poses.append({"pose":bear.transform,"layer":bear.collision_layer,"mask":bear.collision_mask,"disabled":[]})
		for child: Node in bear.get_children():
			if child is CollisionShape3D:
				bear_poses[-1].disabled.append(child.disabled);child.disabled=row.health<=0
		bear.position=Vector3(row.position[0],row.position[1],row.position[2]);bear.rotation.y=float(row.yaw)
		bear.collision_layer=1 if row.health>0 else 0
	# M13先验证电脑新站位，完整提交前不改变其位置。暂停时CharacterBody的服务器位置冻结，
	# 玩家预检只排除这一个已有有效新站位的非持久电脑；墙体、家具和熊仍参与原校验。
	_companion_restore_at=world.snowball_game.find_restore_point(world.player.position)
	await get_tree().physics_frame;await get_tree().physics_frame
	var message:=_position_problem(world.player.position,world.snowball_game.companion.get_rid()) if _companion_restore_at.is_finite() else "活动伙伴附近没有可站位置，恢复未提交"
	# 后续版本可在相同已摆放的门／熊物理状态下校验其他持久角色。
	if message.is_empty():message=_preflight_additional(data)
	# 2. 无论通过与否先撤销预检空间变化，最终提交在调用方验证成功之后。
	world.player.position=previous;world.regions.update_regions()
	for cabin: Node3D in world.landmarks.cabins:cabin.door.transform=door_poses[String(cabin.get_meta("building_id"))]
	for index in range(world.bears.bears.size()):
		var bear: CharacterBody3D=world.bears.bears[index];bear.transform=bear_poses[index].pose;bear.collision_layer=bear_poses[index].layer;bear.collision_mask=bear_poses[index].mask
		var shape_index:=0
		for child: Node in bear.get_children():
			if child is CollisionShape3D:child.disabled=bear_poses[index].disabled[shape_index];shape_index+=1
	return message


## V2没有额外持久角色，扩展版本在冻结预检屏障中验证附加状态。
func _preflight_additional(_data: Dictionary) -> String:
	# 1. 默认不改变现有V2校验结果或空间对象。
	return ""


## V2无附加持久状态，扩展版本在恢复完成信号前同步其他角色。
func _restore_additional_state(_data: Dictionary) -> void:
	# 1. 默认空实现确保旧版恢复流程完全沿用原行为。
	pass


## 真实碰撞与脚下支撑一起验证，拒绝墙内、空中或家具内部的恢复点。
func _position_problem(at: Vector3, transient_exclusion: RID=RID()) -> String:
	# 1. 微缩胶囊容忍正常贴地接触，不把地板本身误判为卡墙。
	var shape:=CapsuleShape3D.new();shape.radius=.28;shape.height=1.46
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.transform=Transform3D(Basis.IDENTITY,at+Vector3.UP*.75);query.collision_mask=1;query.exclude=[world.player.get_rid()];query.margin=0
	# 已验证会在提交时移开的活动电脑仅影响读档预检，不改变安全屋失败返回校验。
	if transient_exclusion.is_valid():
		var excluded: Array[RID]=[world.player.get_rid(),transient_exclusion]
		query.exclude=excluded
	var space:=world.get_world_3d().direct_space_state
	if not space.intersect_shape(query,8).is_empty():return "保存位置被实体遮挡，请恢复备份"
	var ray:=PhysicsRayQueryParameters3D.create(at+Vector3.UP*.15,at-Vector3.UP*.4,1,[world.player.get_rid()])
	if space.intersect_ray(ray).is_empty():return "保存位置缺少脚下支撑，请恢复备份"
	return ""


## 已通过语义与几何验证后同步所有持续模块，不按现实时间补进度。
func _apply(data: Dictionary) -> void:
	# 1. 关闭旧事务、释放输入，临时状态按用户确认规则清理。
	_invalidate_input();world.world_clock.restore_state(data.clock)
	world.player.position=Vector3(data.player.position[0],data.player.position[1],data.player.position[2]);world.player.velocity=Vector3.ZERO
	world.player.horizontal_speed=0;world.player._phase=0;world.player._visual.rotation.y=float(data.player.yaw)
	world.player.get_node("FootstepEmitter").reset_tracking();world.regions.update_regions()
	# M13提交与预检完全相同的电脑位置，不能在恢复后与玩家重叠。
	world.snowball_game.restore_companion(_companion_restore_at)
	for cabin: Node3D in world.landmarks.cabins:
		var row: Dictionary=data.doors[String(cabin.get_meta("building_id"))]
		cabin.door_angle=float(row.angle);cabin.target_open=row.open;cabin.door_blocked=false
		cabin.door.transform=Transform3D(Basis(Vector3.UP,cabin.door_angle),cabin._vector(cabin.manifest.door.pivot))
	# 2. 天气、资源、弹药和熊消费同一累计秒数，所有对象沿用原稳定ID。
	world.snow_tracks.reset_history(world.world_clock.elapsed_seconds);world.weather.restore_state(data.weather)
	world.survival.restore_state(data.survival);world.rifle.restore_state(data.rifle)
	world.bears._last_attack_at=-INF;world.bears._life_age=0
	for row: Dictionary in data.bears:
		for bear: CharacterBody3D in world.bears.bears:
			if bear.stable_id==row.id:bear.restore_state(row)
	world.camera_rig.desired_size=float(data.player.zoom);world.camera_rig.camera.size=float(data.player.zoom)
	world.player._visual.reset_session_pose();world.rifle.view.update_frame(0)
	_skip_entry=StringName(world.interior.shelter_at(world.player.position).building_id)
	world.interior.current_cabin=null;world.camera_rig.interior_cabin=null;world.camera_rig.interior_weight=0;world.camera_rig.snap_to_actor()
	world._resume_context=world.input_router.Context.EXPLORATION;_return_pending=false;_retry.hide()
	_restore_additional_state(data)
	state_restored.emit()


## 首个失败立即冻结，重复来源在返回完成前由失败锁拒绝。
func _on_failed(reason: StringName) -> void:
	# 1. 不在信号中同步扣柴，避免调用栈中的熊动作／自动保存交错结算。
	if busy or not session_ready:return
	busy=true;_return_pending=true;_return_reason=reason;world.set_session_paused(true);_notice("正在返回安全小屋…");call_deferred("_recover_failure",reason)


## 返回只改变玩家、暖意与向下取整的随身柴火，持续世界状态不回滚。
func _recover_failure(reason: StringName) -> void:
	# 1. 在冻结物理帧选择小屋内真实可站点，家具碰撞不临时关闭。
	await get_tree().physics_frame
	var cabin: Node3D=world.landmarks.safe_cabin;var destination:=Vector3.ZERO;var found:=false
	for local: Vector3 in [Vector3(0,.24,.35),Vector3(.5,.24,.35),Vector3(0,.24,-.3),Vector3(-.5,.24,.35)]:
		var candidate: Vector3=cabin.to_global(local)
		if _position_problem(candidate).is_empty():destination=candidate;found=true;break
	if not found:
		busy=false;_resume.disabled=true;_retry.show();_notice("安全屋通道被挡住，返回尚未结算，请重试");return
	_invalidate_input();var before: int=world.survival.carried;var lost:=floori(before*.2)
	world.survival.carried=before-lost;world.player.position=destination;world.player.velocity=Vector3.ZERO;world.player.horizontal_speed=0;world.player._phase=0
	world.player.get_node("FootstepEmitter").reset_tracking();world.regions.update_regions();world.camera_rig.snap_to_actor()
	world.rifle.cancel_reload();world.rifle.view.reset_feedback();world.survival.reset_failure(100)
	world.survival.protection_until=world.world_clock.elapsed_seconds+10;return_count+=1
	world.player._visual.reset_session_pose();world.rifle._pending_fire=false;world.rifle.view.update_frame(0)
	_skip_entry=&"house.safe"
	world.interior.current_cabin=null;world.camera_rig.interior_cabin=null;world.camera_rig.interior_weight=0;world.camera_rig.snap_to_actor()
	# 2. 本次返回自行保存结算结果，随后入屋事件由一次性屏障抑制。
	_record("failure_return",{"reason":String(reason),"carried_before":before,"lost":lost,"carried_after":world.survival.carried,"game_seconds":world.world_clock.elapsed_seconds})
	var saved:=_write(true);busy=false;_return_pending=false;_retry.hide();_resume.disabled=false;world._resume_context=world.input_router.Context.EXPLORATION;world.set_session_paused(false)
	_notice("已返回安全小屋 · 损失%d根柴火 · 保护10秒%s" % [lost,"" if saved else " · 保存未完成"])


## 受阻返回只重试同一失败，不增加失败次数或预扣第二次柴火。
func _retry_return() -> void:
	# 1. 保持暂停到真实安全点可用，明确请求后再执行同一结算。
	if not _return_pending or busy:return
	busy=true;_recover_failure(_return_reason)


## 释放旧按键、指针和事务，不把暂停／读档UI点击当成新世界射击。
func _invalidate_input() -> void:
	# 1. 清空模块自身排队请求，已提交库存不回滚。
	if world.survival_ui.opened:world.survival_ui.close()
	world.survival.close_session();world.survival._interact_pending=false;world.survival._action_pending.clear()
	world.input_router.set_context(world.input_router.Context.PAUSED);world._has_pointer=false;world.aim_hit={};world.rifle._pending_fire=false


## 坏档提示保持原文件；启动时只有显式恢复或保留后新开始才能离开暂停。
func _fault(message: String, startup: bool) -> void:
	# 1. 失败不变更有效运行状态，后续选择仍可重新验证备份。
	busy=false;_boot_fault=startup;_resume.disabled=startup;_fresh.visible=startup
	_fresh.disabled=not world.bears.ready_for_paths
	last_result={"ok":false,"message":message};_notice(message)


## 新开始必须由坏档界面明确点击，先归档所有旧文件再允许新进度写入。
func _preserve_and_start() -> void:
	# 1. 任一步归档失败都保留暂停，不悄悄覆盖原文件。
	var error: Error=store.archive_current()
	if error==OK:error=store.archive_current(true)
	if error!=OK:_fault("无法保留旧存档，请检查目录权限",true);return
	_boot_fault=false;session_ready=true;busy=false;_fresh.hide();_resume.disabled=false;world._resume_context=world.input_router.Context.EXPLORATION
	_notice("旧文件已保留，开始新的旅程");world.set_session_paused(false)


## 保存成功才退出，失败仍保留暂停菜单供用户处理。
func _save_and_quit() -> void:
	# 1. 此按钮只在暂停中使用，快照与退出之间没有额外模拟帧。
	if busy or not session_ready or _boot_fault:return
	busy=true;var saved:=_write();busy=false
	if saved:get_tree().quit()


## 通知和有界历史分离，正式界面只显示玩家可理解的结果。
func _notice(message: String) -> void:
	# 1. 最近结果可供暂停菜单和验收读取，不打印库存或内部路径。
	_info.text=message;_toast.text=message


## 事件历史只保留有限记录，不写入存档或按帧增长。
func _record(kind: String, data: Dictionary) -> void:
	# 1. 深复制避免之后的库存变化改写既有结算证据。
	history.append({"kind":kind,"data":data.duplicate(true)})
	if history.size()>32:history.pop_front()
