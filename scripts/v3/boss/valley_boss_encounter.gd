extends Node3D
## 一个正式挑战持有者；物资、角色、天气和时间继续使用现有世界。
const ORIGIN := Vector3(112,11.769204,-166)
const BOSS = preload("res://scripts/v3/boss/valley_snow_boss.gd")
const GEOMETRY = preload("res://scripts/v3/boss/valley_arena_geometry.gd")
const AMMO = preload("res://assets/models/v2/weapons/valley_ammo_box.glb")
var world: Node3D
var boss: CharacterBody3D
var geometry: Node3D
var ground: Node3D
var boss_map := RID()
var player_map := RID()
var player_region: NavigationRegion3D
var boss_region: NavigationRegion3D
var participants: Array = []
var retired: Array = []
var status := "idle"
var kind := "first"
var _memory_result := ""
var _invitation_base: Dictionary = {}
var party := "solo"
var votes: Array = []
var boxes: Array = [16,16]
var invulnerable := {"p1":0.0,"p2":0.0}
var held := {"p1":false,"p2":false}
var progress := {"p1":0.0,"p2":0.0}
var nearby := {"p1":-1,"p2":-1}
var _pressed: Array = []
var _shot_counts := {"p1":0,"p2":0}
var _nav_active := false
var _box_models: Array = []
var _abort_queued := false
var launch_after_retry := ""
var last_boss_powder := 0.0
var telegraph: MeshInstance3D
var hud: CanvasLayer
var _camera_before: Dictionary = {}
var _ai_route: RefCounted

## 装配在V3启动存档之前；复用场地源，但只保留正式世界唯一地面和山门。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -9
	ground = load("res://scripts/v3/boss/valley_boss_ground.gd").new()
	ground.world = world
	add_child(ground)
	geometry = GEOMETRY.new()
	geometry.process_mode = Node.PROCESS_MODE_PAUSABLE
	geometry.position = ORIGIN
	add_child(geometry)
	geometry.gate.free()
	geometry.get_node("ArenaGround").free()
	geometry.floor_mesh.hide()
	# 独立小样南侧雪堤只用于有限预览边界；正式世界必须保留原主路接近山门。
	geometry.model.find_child("BoundaryBank_3",true,false).free()
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v3/boss/ice_courtyard_manifest.json"))
	var bank: StaticBody3D = geometry.get_node("VisibleSnowBanks")
	var bank_shapes := bank.get_children()
	for index in range(source.obstacles.size()):
		if source.obstacles[index].name=="BoundaryBank_3": bank_shapes[index].free()
	for object: StaticBody3D in geometry.find_children("*","StaticBody3D",true,false):
		object.collision_layer |= 1|4
		object.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
	for object: StaticBody3D in world.events.geometry.gate_body.get_parent().find_children("*","StaticBody3D",true,false):
		object.collision_layer |= 4
	geometry.walls_changed.connect(_navigation_changed)
	boss_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(boss_map,true)
	NavigationServer3D.map_set_cell_size(boss_map,.2)
	NavigationServer3D.map_set_cell_height(boss_map,.1)
	NavigationServer3D.map_set_merge_rasterizer_cell_scale(boss_map,.01)
	player_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(player_map,true)
	NavigationServer3D.map_set_cell_size(player_map,.2)
	NavigationServer3D.map_set_cell_height(player_map,.1)
	NavigationServer3D.map_set_merge_rasterizer_cell_scale(player_map,.01)
	player_region = NavigationRegion3D.new()
	player_region.position = ORIGIN
	player_region.set_navigation_map(player_map)
	add_child(player_region)
	player_region.navigation_mesh = load("res://assets/environment/v3/m12_arena_player_nav_0.res")
	boss_region = NavigationRegion3D.new()
	boss_region.position = ORIGIN
	boss_region.set_navigation_map(boss_map)
	add_child(boss_region)
	boss_region.navigation_mesh = load("res://assets/environment/v3/m12_arena_boss_nav_0.res")
	boss = BOSS.new()
	boss.process_mode = Node.PROCESS_MODE_PAUSABLE
	boss.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
	boss.stage = self
	boss.position = grounded(ORIGIN+Vector3(2,0,-12))
	add_child(boss)
	for id: String in ["p1","p2"]:
		body(id).collision_layer |= 2
		body(id).collision_mask |= 4|8
		_shot_counts[id] = weapon(id).shots_fired
	for index in range(2):
		var group := Node3D.new()
		group.position = grounded(ORIGIN+Vector3(-12 if index==0 else 16,0,-12))
		add_child(group)
		var models: Array = []
		for row in range(4):
			var model: Node3D = AMMO.instantiate()
			model.position = Vector3((row%2)*.45,0,(row/2)*.35)
			group.add_child(model)
			models.append(model)
		_box_models.append(models)
		var label := Label3D.new()
		label.text = "公共弹药箱"
		label.position.y = .7
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		group.add_child(label)
	telegraph = MeshInstance3D.new()
	telegraph.mesh = ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("e3751d")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	telegraph.material_override = material
	add_child(telegraph)
	hud = load("res://scripts/v3/boss/valley_boss_hud.gd").new()
	hud.encounter = self
	add_child(hud)
	world.rescue.boss_retry_completed.connect(_after_retry)
	# 仅登记显示副本，碰撞与导航不复制。
	for mesh: MeshInstance3D in geometry.find_children("*","MeshInstance3D",true,false):
		if mesh!=geometry.floor_mesh:
			world.interior._register_mesh(mesh,"tree")
	_sync_boxes()

## 有效角色始终来自真实固定槽位，不创建审阅台替身。
func body(id: String) -> CharacterBody3D:
	return world.actor_registry.slots[id].body

func model(id: String) -> Node:
	return world.rescue.model(id)

func weapon(id: String) -> Node3D:
	return world.rescue.weapon(id)

func actor_id(object: Object) -> String:
	for id: String in ["p1","p2"]:
		if object==body(id): return id
	return ""

func grounded(at: Vector3) -> Vector3:
	return Vector3(at.x,ground.ground(at),at.z)

func running() -> bool:
	return status=="fighting" and world.events.geometry.gate_open<.001 and world.session.session_ready and not world.session.busy and not world.session.main_menu.visible and not get_tree().paused

func ongoing() -> bool:
	return status in ["entering","fighting"]

func standing(id: String) -> bool:
	return id in participants and id not in retired and world.rescue.life[id].state=="standing"

func party_for(mode: String) -> String:
	return "duo" if mode.begins_with("local") else ("ai" if mode=="single_ai" else "solo")

## 输入只排队；物理帧再检查距离、视线、权限和双方同意。
func interact_pressed(id: String) -> bool:
	if ((status=="idle" and not world.v3_progress.boss_defeated) or (status=="won" and world.v3_progress.ending_seen)) and world.v3_progress.boss_unlocked and body(id).global_position.distance_to(ORIGIN+Vector3(0,0,3))<5:
		_pressed.append(id)
		return true
	if status=="inviting" and body(id).global_position.distance_to(ORIGIN+Vector3(0,0,3))<5:
		_pressed.append(id)
		return true
	if status=="entering" and id=="p1" and local(body(id).global_position).z>1:
		request_abandon()
		return true
	if running() and standing(id) and int(nearby[id])>=0:
		held[id] = true
		weapon(id).cancel_reload()
		return true
	return false

func release(id: String) -> void:
	held[id] = false
	progress[id] = 0.0

func local(at: Vector3) -> Vector3:
	return at-ORIGIN

## 门外不把远处搭档拉入场；两名真人分别按自己的交互键确认。
func _vote(id: String) -> void:
	if not world.session.local_authority or not world.rescue.can_act(id): return
	var at := local(body(id).global_position)
	if absf(at.x)>4 or at.z<1 or at.z>6: return
	if status in ["idle","won"]:
		_invitation_base = capture_state()
		kind = "memory" if status=="won" else "first"
		party = party_for(world.actor_registry.mode)
		participants = ["p1"] if party=="solo" else ["p1","p2"]
		votes.clear()
		status = "inviting"
	if id not in participants: return
	if id not in votes: votes.append(id)
	if party=="ai" and "p1" in votes and world.rescue.can_act("p2"):
		var other := local(body("p2").global_position)
		if absf(other.x)<4 and other.z>1 and other.z<8: votes = ["p1","p2"]
	if votes.size()!=participants.size():
		notice("等待搭档到门外按交互键确认 · 暂停菜单可取消")
		return
	if kind=="memory" and not _memory_space_clear():
		notice("回忆场地有人占位 · 请退出冰壁与雪熊起点后重新确认")
		return
	if not world.session.begin_boss_encounter():
		restore_state(_invitation_base)
		return
	if kind=="memory":
		var fresh: Dictionary = load("res://scripts/v3/boss/valley_boss_state.gd").initial()
		preview_state(fresh)
	status = "entering"
	retired.clear()
	boxes = [16,16]
	invulnerable = {"p1":0.0,"p2":0.0}
	boss.begin({"solo":320,"ai":400,"duo":480}[party])
	_use_navigation(true)
	notice("沿山门实际进入 · 全部到齐后开战；门外再次交互可取消")

## 重建前检查玩家实际胶囊；已倒下的旧雪熊将恢复为经过验收的起始姿态。
func _memory_space_clear() -> bool:
	var space := get_world_3d().direct_space_state
	for wall: Dictionary in geometry.walls:
		if wall.pending: return false
		for shape: CollisionShape3D in wall.shapes:
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform
			query.collision_mask = 2
			if not space.intersect_shape(query,1).is_empty(): return false
	var start := Transform3D(Basis.IDENTITY,grounded(ORIGIN+Vector3(2,0,-12)))
	for shape: CollisionShape3D in boss.shapes:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = start*Transform3D(shape.get_meta("rest"))
		query.collision_mask = 2
		if not space.intersect_shape(query,1).is_empty(): return false
	return true

## 原地物理门只在双方完全通过且门洞无占位时关闭。
func _physics_process(delta: float) -> void:
	geometry.visible = world.v3_progress.boss_unlocked
	boss.visible = world.v3_progress.boss_unlocked
	if get_tree().paused or world.session.busy or not world.session.session_ready or world.session.main_menu.visible:
		for id: String in held: release(id)
		return
	_combat_camera(ongoing())
	if ongoing(): world.guard._repath = maxf(0,world.guard._repath-delta)
	for id: String in _pressed: _vote(id)
	_pressed.clear()
	# P1同意仍有效；AI稍晚赶到门外时自动接续，不要求玩家再确认一次。
	if status=="inviting" and party=="ai" and "p1" in votes: _vote("p1")
	if status=="entering":
		if party=="ai": _move_ai(grounded(ORIGIN+Vector3(1,0,-4)),"入场")
		var ready := true
		for id: String in participants:
			var p := local(body(id).global_position)
			ready = ready and p.z < -2 and absf(p.x)<17
		if ready:
			status = "fighting"
			_navigation_changed(geometry.broken_mask)
			notice("雪熊挑战开始")
	if status=="fighting":
		_close_gate(delta)
		_advance_pickups(delta*world.world_clock.debug_rate)
		_draw_warning()
		if party=="ai" and not standing("p2"):
			world.guard.combat_target = null
	elif telegraph.mesh.get_surface_count()>0:
		telegraph.mesh.clear_surfaces()
	if _nav_active and not ongoing():
		var outside := true
		for id: String in participants: outside = outside and local(body(id).global_position).z>2
		if outside: _use_navigation(false)

## 门板下一步真实体积被人占用时等待，不能压着角色强行完成关门。
func _close_gate(delta: float) -> void:
	var gate: StaticBody3D = world.events.geometry.gate_body
	var next := move_toward(world.events.geometry.gate_open,0,delta)
	for shape: CollisionShape3D in gate.find_children("*","CollisionShape3D",true,false):
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = shape.global_transform
		query.transform.origin.y += (next-world.events.geometry.gate_open)*3.4
		query.collision_mask = 2
		if not get_world_3d().direct_space_state.intersect_shape(query,1).is_empty(): return
	world.events.geometry.set_gate_fraction(next)

## 在原相机范围内向雪熊取景；出战后恢复本地入场前设置。
func _combat_camera(active: bool) -> void:
	for id: String in world.view_manager.views:
		var binding: Dictionary = world.view_manager.views[id]
		var rig: Node3D = binding.rig
		if active:
			if not _camera_before.has(id):
				_camera_before[id] = {"size":rig.desired_size,"pitch":rig.pitch_degrees,"yaw":rig.yaw_degrees}
				rig.tracked_actor = null
				rig.desired_size = 18
			var desired: Vector3 = body(binding.actor_id).global_position.lerp(boss.global_position,.55)+Vector3.UP*1.6
			rig.target = rig.target.lerp(desired,.18)
		elif _camera_before.has(id):
			var old: Dictionary = _camera_before[id]
			rig.tracked_actor = body(binding.actor_id)
			rig.desired_size = old.size
			rig.pitch_degrees = old.pitch
			rig.yaw_degrees = old.yaw
			rig.snap_to_actor()
	if not active: _camera_before.clear()

## 四种冰壁资源与相同世界偏移一起切换；离场恢复全谷导航。
func _use_navigation(value: bool) -> void:
	_nav_active = value
	var agent: NavigationAgent3D = body("p2").get_node("NavigationAgent3D")
	agent.set_navigation_map(player_map if value and party!="solo" else world.companion_navigation.get_navigation_map())
	world.guard._repath = 0

func _navigation_changed(mask: int) -> void:
	var prefix := "m13_boss" if status=="fighting" else "m12_arena"
	boss_region.navigation_mesh = load("res://assets/environment/v3/%s_boss_nav_%d.res"%[prefix,mask])
	player_region.navigation_mesh = load("res://assets/environment/v3/%s_player_nav_%d.res"%[prefix,mask])
	if _nav_active: _use_navigation(true)

## 最近可见目标真实被墙挡住时不可开启攻击；可改用导航接近。
func choose_target(from: Vector3) -> String:
	var best := ""
	var distance := INF
	for id: String in participants:
		if not standing(id): continue
		var p := body(id).global_position
		var ray := PhysicsRayQueryParameters3D.create(from+Vector3.UP*3,p+Vector3.UP,1,[boss.get_rid(),body(id).get_rid()])
		if p.distance_to(from)<distance and get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			best = id
			distance = p.distance_to(from)
	return best

func nearest_standing(from: Vector3) -> String:
	var best := ""
	var distance := INF
	for id: String in participants:
		if standing(id) and body(id).global_position.distance_to(from)<distance:
			best = id
			distance = body(id).global_position.distance_to(from)
	return best

## 受击保护仅免Boss伤害，不覆盖原有自然冷暖积分。
func hit_actor(id: String, amount: int, serial: int) -> bool:
	if not running() or not standing(id) or serial!=boss.attack_serial or id in boss.victims: return false
	# 即使被保护挡下，本次攻击也已消费此角色，不能结束保护后再补同一击。
	boss.victims.append(id)
	var now: float = world.world_clock.elapsed_seconds
	if now < float(invulnerable[id]) or now < model(id).protection_until: return false
	invulnerable[id] = now+1.5
	model(id).warmth = maxf(0,model(id).warmth-amount)
	world.rescue.interrupt(id)
	release(id)
	if model(id).warmth<=0: model(id).request_failure(&"bear_attack")
	return true

## 范围是掌落点的实际圆；墙和未碎冰壁阻挡落掌冲击。
func slam_reaches(center: Vector3, actor: CharacterBody3D) -> bool:
	var p := actor.global_position
	if Vector2(p.x-center.x,p.z-center.z).length()>4.5: return false
	var ray := PhysicsRayQueryParameters3D.create(center+Vector3.UP*.35,p+Vector3.UP*.6,1,[boss.get_rid(),body("p1").get_rid(),body("p2").get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

## 个人超时退场不调用整场恢复；仅全倒／无人能救时请求原完整快照。
func handle_returns(ids: Array) -> bool:
	if status!="fighting": return false
	var alive := nearest_standing(boss.global_position)
	if alive.is_empty():
		request_abandon()
		return true
	for id: String in ids:
		if id in retired: continue
		var place := Vector3.INF
		for offset: Vector3 in [Vector3(-2,0,4),Vector3(2,0,4),Vector3(-3,0,7),Vector3(3,0,7)]:
			var p := grounded(ORIGIN+offset)+Vector3.UP*.03
			var excluded: Array[RID] = [body(id).get_rid()]
			if world.rescue._stand_clear(p,excluded):
				place = p
				break
		if place==Vector3.INF:
			notice("场外站位受阻，尚未扣柴，正在等待重试")
			continue
		model(id).carried -= floori(model(id).carried*.2)
		model(id).reset_failure(100)
		model(id).protection_until = world.world_clock.elapsed_seconds+10
		body(id).global_position = place
		world.rescue.life[id] = world.rescue.standing_life()
		world.rescue._deadlines.erase(id)
		retired.append(id)
		model(id).failure_latched = true
		world.rescue._freeze_actor(id)
		notice(id.to_upper()+"已退场旁观 · 搭档继续挑战")
	return true

## 同帧多发击杀只提交一次胜利，耗材与时间保留，检查点随后释放。
func win() -> void:
	if status!="fighting": return
	if kind=="memory":
		_memory_result = "回忆挑战胜利 · 已还原挑战前世界与随身物资"
		request_abandon()
		return
	status = "won"
	world.v3_progress.boss_defeated = true
	world.session.finish_boss_encounter()
	world.events.geometry.set_gate_fraction(1)
	_navigation_changed(geometry.broken_mask)
	for id: String in retired:
		model(id).failure_latched = false
		world.rescue._unfreeze_actor(id)
	retired.clear()
	world.journey.on_first_victory()
	notice("雪熊已被击败 · 山门开放 · 本次物资与进度保留")

## 主玩家可暂停中放弃；反复请求不创建第二份恢复事务。
func request_abandon() -> void:
	if not world.session.local_authority or _abort_queued: return
	if status=="inviting":
		restore_state(_invitation_base)
		return
	if not ongoing(): return
	_abort_queued = true
	world.session.retry_boss_entry.call_deferred()

func _after_retry() -> void:
	_abort_queued = false
	if not _memory_result.is_empty():
		notice(_memory_result)
		_memory_result = ""
	if not launch_after_retry.is_empty():
		var requested := launch_after_retry
		launch_after_retry = ""
		world.session.launch_mode.call_deferred(requested)

func notice(text: String) -> void:
	world.session._notice(text)

## 门外选敌与场内弹药交互点始终取自可见实体。
func box_position(index: int) -> Vector3:
	return _box_models[index][0].get_parent().global_position

func _advance_pickups(delta: float) -> void:
	for id: String in participants:
		nearby[id] = -1
		if not standing(id):
			release(id)
			continue
		var actor := body(id)
		for index in range(2):
			if boxes[index]<=0 or actor.global_position.distance_to(box_position(index))>2: continue
			var ray := PhysicsRayQueryParameters3D.create(actor.global_position+Vector3.UP,box_position(index)+Vector3.UP*.3,1,[actor.get_rid(),boss.get_rid()])
			if get_world_3d().direct_space_state.intersect_ray(ray).is_empty(): nearby[id] = index
		var moved: bool = world.rescue._movement_requested(id) or actor.horizontal_speed>.05
		if not held[id] or int(nearby[id])<0 or moved or weapon(id)._pending_fire or weapon(id).shots_fired!=_shot_counts[id]:
			progress[id] = 0.0
		else:
			progress[id] += delta
			if progress[id]>=2:
				var index: int = nearby[id]
				var count := mini(4,mini(boxes[index],12-weapon(id).reserve))
				boxes[index] -= count
				weapon(id).reserve += count
				weapon(id).rounds_collected += count
				release(id)
				_sync_boxes()
		_shot_counts[id] = weapon(id).shots_fired

func _sync_boxes() -> void:
	for index in range(_box_models.size()):
		for row in range(4):
			world.rifle.view.set_box_quantity(_box_models[index][row],clampi(int(boxes[index])-row*4,0,4))

## AI只提供真实移动／交互／枪械意图，救援仍由原协调器验证并积分。
func drive_ai(delta: float) -> void:
	if not running() or party!="ai" or not standing("p2"): return
	var actor := body("p2")
	world.guard.combat_target = null
	world.rescue._held.p2 = false
	if danger(actor.global_position):
		release("p2")
		world.rescue.interrupt("p2")
		var candidate := Vector3.INF
		var best := INF
		for index in range(12):
			var angle := index*TAU/12
			var p := actor.global_position+Vector3(cos(angle),0,sin(angle))*5.8
			p = NavigationServer3D.map_get_closest_point(player_map,p)
			var path := NavigationServer3D.map_get_path(player_map,actor.global_position,p,true)
			if local(p).z < -1 and path.size()>1 and path[-1].distance_to(p)<.8 and not danger(p) and p.distance_to(actor.global_position)<best:
				candidate = p
				best = p.distance_to(actor.global_position)
		if candidate!=Vector3.INF: _move_ai(candidate,"躲避雪熊预警")
		else: actor.set_external_direction(Vector3.ZERO)
		return
	if world.rescue.life.p1.state=="downed":
		if actor.global_position.distance_to(body("p1").global_position)>1.5:
			_move_ai(body("p1").global_position+(actor.global_position-body("p1").global_position).normalized()*1.1,"寻找施救路线")
		else:
			actor.set_external_direction(Vector3.ZERO)
			weapon("p2").cancel_reload()
			world.rescue._held.p2 = true
		return
	if weapon("p2").chamber==0 and weapon("p2").reserve==0 and world.guard.fire_allowed:
		var index := -1
		var distance := INF
		for i in range(2):
			if boxes[i]>0 and box_position(i).distance_to(actor.global_position)<distance:
				index = i
				distance = box_position(i).distance_to(actor.global_position)
		if index>=0:
			if int(nearby.p2)==index:
				actor.set_external_direction(Vector3.ZERO)
				held.p2 = true
			else: _move_ai(box_position(index),"寻找场内弹药")
			return
	var offset := actor.global_position-boss.global_position
	var distance := Vector2(offset.x,offset.z).length()
	if distance<6.5:
		_move_ai(actor.global_position+offset.normalized()*3,"拉开距离")
		return
	var aim: Vector3 = boss.aim_point(actor)
	var ray := PhysicsRayQueryParameters3D.create(actor.global_position+Vector3.UP,aim,1,[actor.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or hit.collider!=boss or distance>18:
		_move_ai(_firing_position(actor),"寻找射击位置")
		return
	actor.set_external_direction(Vector3.ZERO)
	if not world.guard.fire_allowed: return
	world.guard.combat_target = boss
	world.secondary_context.selected_target = boss
	var direction := aim-actor.global_position
	world.secondary_context.aim_yaw = atan2(direction.x,direction.z)
	if weapon("p2").equipped!=2: weapon("p2").equip(2)
	if weapon("p2").chamber==0: weapon("p2").request_reload()
	elif not weapon("p2").reloading(): weapon("p2")._request_fire(Vector2.ZERO)

## 仍用原NavigationAgent和胶囊移动；不把未到达的路径点写成角色位置。
func _move_ai(at: Vector3, text: String) -> void:
	if _ai_route==null:
		_ai_route = load("res://scripts/v3/boss/valley_boss_route.gd").new()
		_ai_route.encounter = self
		_ai_route.actor = body("p2")
	var direction: Vector3 = _ai_route.direction(at,get_physics_process_delta_time())
	body("p2").set_external_direction(direction,true)
	world.guard.status = text if not direction.is_zero_approx() else text+" · 路径受阻，正在重试"

## 可射击位置同时满足静态路线和实际视线，不能停在遮挡后的同一个目标点。
func _firing_position(actor: CharacterBody3D) -> Vector3:
	var best := actor.global_position
	var distance := INF
	for index in range(16):
		var angle := index*TAU/16
		var p := NavigationServer3D.map_get_closest_point(player_map,boss.global_position+Vector3(cos(angle),0,sin(angle))*8)
		var ray := PhysicsRayQueryParameters3D.create(p+Vector3.UP*1.1,boss.global_position+Vector3.UP*2.8,1,[actor.get_rid(),boss.get_rid()])
		if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty(): continue
		var path := NavigationServer3D.map_get_path(player_map,actor.global_position,p,true)
		if path.size()>1 and path[-1].distance_to(p)<.8 and local(p).z < -1 and p.distance_to(actor.global_position)<distance and not danger(p):
			best = p
			distance = p.distance_to(actor.global_position)
	return best

## 预警与AI躲避共用同一个锁定范围，碰撞／遮挡另由实际世界验证。
func danger(at: Vector3) -> bool:
	if boss.combat=="slam":
		return Vector2(at.x-boss.slam_center.x,at.z-boss.slam_center.z).length()<5.2
	if boss.combat in ["charge_warning","charge"]:
		var offset: Vector3 = at-boss.charge_origin
		var along: float = offset.dot(boss.charge_direction)
		return along > -2 and along<19 and absf(offset.dot(boss.charge_direction.cross(Vector3.UP)))<3.0
	return false

## 正式预警沿真实雪面绘制，画面范围和实际伤害半径相同。
func _draw_warning() -> void:
	var mesh: ImmediateMesh = telegraph.mesh
	mesh.clear_surfaces()
	if boss.combat not in ["slam","charge_warning","charge"]: return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	if boss.combat=="slam":
		for index in range(64):
			var a := index*TAU/64
			var b := (index+1)*TAU/64
			_ribbon(mesh,boss.slam_center+Vector3(cos(a),0,sin(a))*4.5,boss.slam_center+Vector3(cos(b),0,sin(b))*4.5)
	else:
		var from: Vector3 = boss.global_position
		var direction: Vector3 = boss.charge_direction
		var side := direction.cross(Vector3.UP)*2.15
		var length := maxf(0,14-boss.charge_travel)
		for shape: CollisionShape3D in boss.shapes:
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform
			query.motion = direction*length
			query.collision_mask = 4
			length = minf(length,length*get_world_3d().direct_space_state.cast_motion(query)[0])
		var to := from+direction*(length+4.85)
		_ribbon(mesh,from-side,to-side)
		_ribbon(mesh,from+side,to+side)
		_ribbon(mesh,to-side,to+side)
	mesh.surface_end()

func _ribbon(mesh: ImmediateMesh, a: Vector3, b: Vector3) -> void:
	var difference := b-a
	var side := Vector3(difference.z,0,-difference.x).normalized()*.07
	var count := maxi(1,ceili(difference.length()/.5))
	for index in range(count):
		var start := a.lerp(b,float(index)/count)
		var end := a.lerp(b,float(index+1)/count)
		for p: Vector3 in [start-side,start+side,end+side,start-side,end+side,end-side]:
			mesh.surface_add_vertex(grounded(p)+Vector3.UP*.09)

## 只生成有限雪粉，原世界的精细雪与足迹继续独立工作。
func powder(at: Vector3, amount: int) -> void:
	var particles := GPUParticles3D.new()
	particles.process_mode = Node.PROCESS_MODE_PAUSABLE
	particles.position = at
	particles.amount = amount
	particles.one_shot = true
	particles.explosiveness = 1
	particles.lifetime = .7
	var motion := ParticleProcessMaterial.new()
	motion.direction = Vector3.UP
	motion.spread = 65
	motion.initial_velocity_min = .6
	motion.initial_velocity_max = 2
	motion.gravity = Vector3(0,-4,0)
	motion.scale_min = .05
	motion.scale_max = .13
	particles.process_material = motion
	var sphere := SphereMesh.new()
	sphere.radius = .5
	sphere.height = 1
	particles.draw_pass_1 = sphere
	add_child(particles)
	get_tree().create_timer(1.6,false).timeout.connect(particles.queue_free)

## 读档取消未完成操作，已转移的弹药和已经退休的角色保持原状态。
func capture_state() -> Dictionary:
	if status=="inviting": return _invitation_base.duplicate(true)
	return {"kind":"first" if status=="inviting" else kind,"status":("won" if kind=="memory" else "idle") if status=="inviting" else status,"party":party,"participants":participants.duplicate() if status!="inviting" else [],"retired":retired.duplicate(),"boxes":boxes.duplicate(),"broken":geometry.broken_mask,"protection":{"p1":maxf(0,invulnerable.p1-world.world_clock.elapsed_seconds),"p2":maxf(0,invulnerable.p2-world.world_clock.elapsed_seconds)},"boss":boss.capture()}

## 恢复几何可用于冻结中的实际位置预检，不执行攻击或奖励。
func preview_state(data: Dictionary) -> void:
	for index in range(2):
		var wall: Dictionary = geometry.walls[index]
		if wall.tween!=null and wall.tween.is_valid(): wall.tween.kill()
		wall.broken = bool(int(data.broken)&(1<<index))
		wall.pending = false
		for shape: CollisionShape3D in wall.shapes: shape.disabled = wall.broken
		for pivot: Node3D in wall.pivots:
			pivot.transform = pivot.get_meta("rest")
			pivot.visible = not wall.broken
	geometry.broken_mask = int(data.broken)
	_navigation_changed(int(data.broken))
	boss.restore(data.boss)

func restore_state(data: Dictionary) -> void:
	status = data.status
	kind = data.kind
	preview_state(data)
	party = data.party
	participants = data.participants.duplicate()
	retired = data.retired.duplicate()
	boxes = [int(data.boxes[0]),int(data.boxes[1])]
	for id: String in ["p1","p2"]:
		release(id)
		invulnerable[id] = world.world_clock.elapsed_seconds+float(data.protection[id])
		if id in retired:
			model(id).failure_latched = true
			world.rescue._freeze_actor(id)
	_pressed.clear()
	votes.clear()
	_abort_queued = false
	_sync_boxes()
	_use_navigation(ongoing() or status=="won")
	_combat_camera(ongoing())
	world.events.geometry.set_gate_fraction(0 if status=="fighting" else (1 if world.v3_progress.boss_unlocked else 0))

func _exit_tree() -> void:
	if boss_map.is_valid(): NavigationServer3D.free_rid(boss_map)
	if player_map.is_valid(): NavigationServer3D.free_rid(player_map)
