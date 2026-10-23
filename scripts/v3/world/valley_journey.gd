extends Node
## M14旅程：世界状态与本地演出分离，演出不推进世界钟、不改角色位置。
var world: Node3D
var briefing_seen := false
var status := "idle"
var menu_requested := false
var elapsed := 0.0
var skip_votes: Array[String] = []
var continue_votes: Array[String] = []
var view: CanvasLayer
var archive: RefCounted
var _manual := false
var _dual := false
var _was_paused := false
var _was_menu := false
var _was_overlay := false
var _old_split := false
var _cameras: Dictionary = {}
var _preview_before: Array = []
var _safety_waiting := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -25
	archive = load("res://scripts/v3/session/valley_journey_archive.gd").new()
	archive.session = world.session
	# V3暂停菜单高于演出，设置页仍保持最高；原按钮和拥有权保持同一实例。
	var pause_layer := CanvasLayer.new()
	pause_layer.layer = 20
	add_child(pause_layer)
	world._pause_overlay.reparent(pause_layer)
	view = load("res://scripts/v3/views/valley_journey_view.gd").new()
	view.journey = self
	add_child(view)

func presenting() -> bool:
	return status not in ["idle","safety"]

func ending_pending() -> bool:
	return world.v3_progress.boss_defeated and not world.v3_progress.ending_seen and not world.boss_encounter.ongoing()

func on_mode_started() -> void:
	if ending_pending(): status = "safety"
	elif not briefing_seen: _open("briefing")

func on_first_victory() -> void:
	status = "safety"
	_safety_waiting = false

## 安全结算在真实物理帧查询；室内受阻时仍允许存活者行动腾出站位。
func _physics_process(_delta: float) -> void:
	if not world.session.session_ready or world.session.busy or world.session.main_menu.visible: return
	if status=="idle" and ending_pending(): status = "safety"
	if status=="safety":
		if not world.rescue.settle_victory():
			if not _safety_waiting:
				world.session._notice("雪熊已被击败 · 等待安全站位，胜利返回不扣柴")
				_safety_waiting = true
			return
		if world.session._write(true):
			if world.session._pending_menu:
				world.session._pending_menu = false
				status = "idle"
				world.session._show_main_menu()
			else: _start_ending(false)
		else: _open("ending_save")

func _process(delta: float) -> void:
	if status=="clip" and not menu_requested:
		elapsed += delta
		_frame_camera()
		# 只推进已倒下雪熊的原生演出；角色、冷暖、天气、物资与世界钟仍冻结。
		if not _manual and world.boss_encounter.boss.combat=="dead": world.boss_encounter.boss._physics_process(delta)
		if elapsed>=18:
			status = "ending_page"
			skip_votes.clear()
	view.refresh()

func _open(value: String) -> void:
	if value not in ["clip","ending_page"]: _dual = false
	_was_paused = get_tree().paused
	_was_menu = world.session.main_menu.visible
	_was_overlay = world._pause_overlay.visible
	status = value
	menu_requested = false
	world.set_session_paused(true)
	world._pause_overlay.hide()
	view.refresh()

func open_progress() -> void:
	if status=="idle": _open("progress")

func open_new() -> void:
	if status=="idle": _open("new_confirm")

func open_archive() -> void:
	if status=="idle": _open("archive_confirm")

func replay_ending() -> void:
	if status=="idle" and world.v3_progress.ending_seen: _start_ending(true)

func _start_ending(manual: bool) -> void:
	_manual = manual
	_dual = world.actor_registry.mode=="local" and world.local_controls.scheme in ["keyboard","gamepad"]
	_open("clip")
	if not manual: _was_paused = false
	world.session.main_menu.hide()
	world.session._clear_mode_transients()
	skip_votes.clear()
	continue_votes.clear()
	elapsed = 0
	_old_split = world.view_manager.split_enabled
	_cameras.clear()
	for id: String in world.view_manager.views:
		var rig: Node3D = world.view_manager.views[id].rig
		_cameras[id] = {"actor":rig.tracked_actor,"target":rig.target,"yaw":rig.yaw_degrees,"pitch":rig.pitch_degrees,"desired":rig.desired_size,"size":rig.camera.size}
	_preview_before = world.regions.preview_positions.duplicate()
	world.regions.preview_positions.append(world.landmarks.safe_cabin.global_position)
	world.regions.preview_positions.append(world.boss_encounter.boss.global_position)
	world.regions.update_regions()
	world.view_manager.set_split(false)
	_frame_camera()
	view.refresh()

func _frame_camera() -> void:
	var boss: CharacterBody3D = world.boss_encounter.boss
	var target: Vector3
	var within: float
	if elapsed<6:
		target = boss.global_position+Vector3.UP*1.4
		within = elapsed/6
	elif elapsed<12:
		target = world.landmarks.safe_cabin.global_position+Vector3.UP
		within = (elapsed-6)/6
	else:
		var show_second: bool = world.actor_registry.slots.p2.source!="idle" and elapsed>=15
		target = world.rescue.body("p2" if show_second else "p1").global_position+Vector3.UP*.7
		within = fmod(elapsed-12,3)/3
	var rig: Node3D = world.camera_rig
	rig.tracked_actor = null
	rig.target = target
	rig.yaw_degrees = lerpf(30,48,within)
	rig.pitch_degrees = 40
	rig.camera.size = 18
	rig._update_transform()

func choose(id: String, skip: bool = false) -> void:
	if menu_requested: return
	if id!="p1" and not _dual: return
	if status=="clip" and skip:
		if id not in skip_votes: skip_votes.append(id)
		if _agreed(skip_votes):
			status = "ending_page"
			skip_votes.clear()
	elif status=="ending_page":
		if id not in continue_votes: continue_votes.append(id)
		if _agreed(continue_votes):
			if not _manual:
				world.v3_progress.ending_seen = true
				if not world.session._write(true):
					world.v3_progress.ending_seen = false
					continue_votes.clear()
					return
			close()
	elif status=="briefing" and id=="p1":
		briefing_seen = true
		if world.session._write(true): close()
		else: briefing_seen = false

func _agreed(votes: Array[String]) -> bool:
	return "p1" in votes and (not _dual or "p2" in votes)

func retry_ending_save() -> void:
	if status!="ending_save": return
	if world.session._write(true):
		if world.session._pending_menu:
			world.session._pending_menu = false
			status = "idle"
			world.session._show_main_menu()
			return
		# 安全结算已完成，恢复演出之前的探索暂停归属。
		status = "idle"
		world.set_session_paused(_was_paused)
		_start_ending(false)

## Esc／Menu只打开或关闭暂停页，不能让演出中的世界恢复模拟。
func toggle_pause() -> void:
	if not presenting(): return
	if status in ["progress","new_confirm","archive_confirm"]:
		close()
		return
	menu_requested = not menu_requested
	world._pause_overlay.visible = menu_requested
	view.refresh()

func close(resume_world: bool = true) -> void:
	var was_cinematic := not _cameras.is_empty()
	status = "idle"
	menu_requested = false
	if was_cinematic:
		world.view_manager.set_split(_old_split)
		for id: String in _cameras:
			var old: Dictionary = _cameras[id]
			var rig: Node3D = world.view_manager.views[id].rig
			rig.tracked_actor = old.actor
			rig.target = old.target
			rig.yaw_degrees = old.yaw
			rig.pitch_degrees = old.pitch
			rig.desired_size = old.desired
			rig.camera.size = old.size
			rig._update_transform()
		world.regions.preview_positions.assign(_preview_before)
		world.regions.update_regions()
		_cameras.clear()
	world.session.main_menu.visible = _was_menu
	if resume_world: world.set_session_paused(_was_paused)
	world._pause_overlay.visible = _was_overlay if resume_world else false
	view.refresh()

func reset_for_restore(data: Dictionary) -> void:
	if presenting(): close(false)
	status = "idle"
	briefing_seen = data.world_state.journey.briefing_seen
	skip_votes.clear()
	continue_votes.clear()

func progress_text() -> String:
	var p: Dictionary = world.v3_progress
	var text := "从安全屋出发，自由探索并准备暖意、柴火与弹药。\n\n"
	for row: Array in [["exploration_event","储物屋旁 · 石刻转盘"],["traversal_event","北坡营地旁 · 阵风栈道"],["boss_unlocked","主路尽头 · 山门开放"],["boss_defeated","冰壁围院 · 击败巨大雪熊"],["ending_seen","温暖归途 · 看完结局"]]:
		text += ("✓ " if p[row[0]] else "○ ")+row[1]+"\n"
	return text+"\n石盘与栈道可任意顺序完成。胜利后可继续探索，门外可重温挑战。"
