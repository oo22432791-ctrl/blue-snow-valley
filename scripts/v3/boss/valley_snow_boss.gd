extends "res://scripts/v3/boss/valley_arena_boss.gd"
## 正式两阶段雪熊；原生骨架、保守转向、同长贴地复用已验收模型。
var stable_id := "ice_ridge_boss"
var health := 320
var maximum_health := 320
var combat := "rest"
var timer := 2.0
var attack_serial := 0
var victims: Array = []
var shot_ids: Array = []
var combo_left := 0
var next_attack := "charge"
var locked_target := ""
var slam_center := Vector3.ZERO
var charge_origin := Vector3.ZERO
var charge_travel := 0.0
var _turn_age := 0.0
var _weak_marks: Array[MeshInstance3D] = []

## 弱点是实体命中形状；普通身体不会因为窗口开启而整身增伤。
func _ready() -> void:
	super._ready()
	set_meta("stable_id",stable_id)
	collision_layer = 1|8
	for side: float in [-1.0,1.0]:
		var shape := SphereShape3D.new()
		shape.radius = .6
		_add_shape(shape,Vector3(side*1.6,4.15,1.65))
		shapes[-1].name = "WeakLeft" if side < 0 else "WeakRight"
		var mark := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = .38
		sphere.height = .76
		mark.mesh = sphere
		mark.position = shapes[-1].position
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("ffbd55")
		material.emission_enabled = true
		material.emission = Color("f98a26")
		mark.material_override = material
		add_child(mark)
		_weak_marks.append(mark)

## 入场人数只影响本次最大生命，倒地不会重算或削减当前生命。
func begin(maximum: int) -> void:
	maximum_health = maximum
	health = maximum
	shot_ids.clear()
	attack_serial = 0
	combo_left = 0
	next_attack = "charge"
	_set_combat("rest",2.0)

## 预警与伤害共享一个序号，恢复存档不会重复结算已经命中的角色。
func _new_attack() -> void:
	attack_serial += 1
	victims.clear()

func phase() -> int:
	return 2 if health*2 <= maximum_health else 1

func _set_combat(value: String, seconds: float) -> void:
	combat = value
	timer = seconds
	age = 0
	state = {"rest":"Idle","approach":"Run","reposition":"Walk","turn":"Idle","charge_warning":"ChargeWarning","charge":"Charge","recover":"Stop","weak":"Idle","slam":"Slam","dead":"Fall"}[value]
	if value=="recover" and next_attack=="charge": state = "Slam"
	animation.play(state)
	velocity.x = 0
	velocity.z = 0

## 可见者按距离选择；遮挡时只寻路，不隔墙开始伤害预警。
func _choose_attack() -> void:
	locked_target = stage.choose_target(global_position)
	if locked_target.is_empty():
		var nearest: String = stage.nearest_standing(global_position)
		if nearest.is_empty():
			return
		goal = stage.body(nearest).global_position
		agent.target_position = goal
		_set_combat("approach",.4)
		return
	goal = stage.body(locked_target).global_position
	_turn_age = 0
	_set_combat("turn",0)

## 完成安全转向后才固定落点并开始完整预警。
func _lock_attack() -> void:
	if not stage.standing(locked_target):
		_set_combat("rest",.1)
		return
	goal = stage.body(locked_target).global_position
	if next_attack == "slam":
		var paw := global_position+global_basis*Vector3(-1.4,0,2.2)
		if Vector2(paw.x-goal.x,paw.z-goal.z).length()>4.2:
			agent.target_position = goal
			_set_combat("approach",.35)
			return
		slam_center = stage.grounded(paw)
		_new_attack()
		_set_combat("slam",.9)
	else:
		_new_attack()
		charge_direction = global_basis.z.normalized()
		charge_origin = global_position
		charge_travel = 0
		if combo_left == 0:
			combo_left = phase()
		_set_combat("charge_warning",1.1)

## 真实碰撞停步后才决定连招或弱点；完整冰壁可打断第二段。
func _charge_end(hit: KinematicCollision3D = null) -> void:
	var ice := false
	if hit != null:
		var collider: Object = hit.get_collider()
		if collider.has_meta("ice_wall"):
			stage.geometry.break_wall(collider.get_meta("ice_wall"))
			ice = true
		stage.powder(hit.get_position(),36)
	if ice:
		combo_left = 0
		next_attack = "slam"
		_set_combat("weak",4.0)
	elif combo_left > 1:
		combo_left -= 1
		_set_combat("rest",.05)
	else:
		combo_left = 0
		next_attack = "slam"
		_set_combat("recover",2.0 if phase()==1 else 1.2)

## 游戏暂停通过场景树冻结，正常步长不依赖现实时间。
func _physics_process(delta: float) -> void:
	if not stage.running():
		if combat == "dead":
			super._physics_process(delta)
		else:
			_sample(0)
		for mark: MeshInstance3D in _weak_marks:
			mark.hide()
		return
	var previous := global_position
	var game_delta: float = delta*stage.world.world_clock.debug_rate
	age += game_delta
	timer = maxf(0,timer-game_delta)
	var speed := 0.0
	match combat:
		"rest", "recover", "weak":
			if timer <= 0:
				_choose_attack()
		"turn":
			var before := rotation.y
			if stage.standing(locked_target):
				goal = stage.body(locked_target).global_position
			if _turn_to(goal,delta):
				_lock_attack()
			elif is_equal_approx(before,rotation.y):
				_turn_age += delta
				if _turn_age > 1.2: _reposition()
			else:
				_turn_age = 0
		"approach":
			if agent.is_navigation_finished() or timer <= 0:
				_set_combat("rest",.05)
			elif _turn_to(agent.get_next_path_position(),delta):
				speed = 3.73
		"reposition":
			if timer<=0 or global_position.distance_to(goal)<.25:
				_set_combat("rest",.05)
			else: speed = 1.43
		"charge_warning":
			if timer <= 0:
				_set_combat("charge",1.75)
		"charge":
			speed = 8.0
			if timer <= 0 or charge_travel >= 14:
				_charge_end()
		"slam":
			if timer <= 0:
				for id: String in stage.participants:
					if stage.standing(id) and stage.slam_reaches(slam_center,stage.body(id)):
						stage.hit_actor(id,30,attack_serial)
				stage.powder(slam_center,45)
				next_attack = "charge"
				_set_combat("recover",2.0 if phase()==1 else 1.2)
				age = 1.04
	var direction := charge_direction if combat == "charge" else ((goal-global_position)*Vector3(1,0,1)).normalized() if combat=="reposition" else global_basis.z
	velocity.x = direction.x*speed
	velocity.z = direction.z*speed
	velocity.y = 0 if is_on_floor() else velocity.y-24*delta
	move_and_slide()
	for index in range(get_slide_collision_count()):
		var hit := get_slide_collision(index)
		if speed > 0 and absf(hit.get_normal().y)<.65:
			if combat == "charge":
				var id: String = stage.actor_id(hit.get_collider())
				if not id.is_empty():
					stage.hit_actor(id,40,attack_serial)
				_charge_end(hit)
			elif combat in ["approach","reposition"]:
				_set_combat("rest",.2)
			break
	var distance := Vector2(global_position.x-previous.x,global_position.z-previous.z).length()
	charge_travel += distance if combat == "charge" else 0.0
	moved_distance += distance
	_update_ground_pose()
	for mark: MeshInstance3D in _weak_marks:
		mark.visible = combat == "weak"
	if speed>0 and moved_distance-stage.last_boss_powder>.8:
		stage.last_boss_powder = moved_distance
		stage.powder(global_position-global_basis.z*2,10)

## 原生动作速度与实际冲撞速度对应，预警／拍地映射到已选时长。
func _update_ground_pose() -> void:
	var p := global_position
	var sx: float = (stage.ground.ground(p+global_basis.x*2)-stage.ground.ground(p-global_basis.x*2))/4
	var sz: float = (stage.ground.ground(p+global_basis.z*3.5)-stage.ground.ground(p-global_basis.z*3.5))/7
	var up := Vector3(-sx,1,-sz).normalized()
	var z := Vector3(0,sz,1).normalized()
	var x := up.cross(z).normalized()
	model.basis = Basis(x,z.cross(x).normalized(),z)
	model.position.y = stage.ground.ground(p)-p.y
	var sample := age
	if combat == "charge": sample *= 8.0/4.98
	if combat == "charge_warning": sample *= 1.4/1.1
	if combat == "slam": sample *= 1.04/.9
	if combat == "reposition" and (goal-global_position).dot(global_basis.z)<0: sample = -sample
	_sample(sample)
	if combat!="dead": _fit_feet()

## 墙边转身受限时先真实后退／侧移腾出体积，不旋进墙或瞬移回中心。
func _reposition() -> void:
	var best := Vector3.INF
	var distance := INF
	var center: Vector3 = stage.ORIGIN+Vector3(2,0,-12)
	var start_nav := NavigationServer3D.map_get_closest_point(stage.boss_map,global_position)
	var start_gap := Vector2(global_position.x-start_nav.x,global_position.z-start_nav.z).length()
	for angle in range(8):
		var direction := global_basis.z.rotated(Vector3.UP,angle*TAU/8)
		var at := global_position+direction*1.5
		var reachable := NavigationServer3D.map_get_closest_point(stage.boss_map,at)
		var gap := Vector2(at.x-reachable.x,at.z-reachable.z).length()
		if gap>.65 and gap>=start_gap-.1: continue
		if not _clear_shapes(Transform3D(global_basis,at),Transform3D.IDENTITY): continue
		if at.distance_to(center)<distance:
			best = at
			distance = at.distance_to(center)
	if best==Vector3.INF:
		_set_combat("rest",.3)
	else:
		goal = best
		_set_combat("reposition",1.3)

## 辅助瞄准选择实际可见的肩部形状；被本体或冰壁挡住时仍只能打普通部位。
func aim_point(actor: CharacterBody3D) -> Vector3:
	if combat=="weak":
		for shape: CollisionShape3D in shapes:
			if not String(shape.name).begins_with("Weak"): continue
			var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(actor.global_position+Vector3.UP*1.1,shape.global_position,1,[actor.get_rid()]))
			if not hit.is_empty() and hit.collider==self:
				var owner: Object = shape_owner_get_owner(shape_find_owner(int(hit.shape)))
				if owner==shape: return shape.global_position
	return global_position+Vector3.UP*2.8

## 枪械传入真实命中形状及自己的射击序号，只结算本场站立参战者。
func receive_shot_hit(hit: Dictionary, shooter: String, serial: int) -> Dictionary:
	var token := shooter+":"+str(serial)
	if not stage.running() or not stage.standing(shooter) or health<=0 or token in shot_ids:
		return {"accepted":false}
	shot_ids.append(token)
	var owner := shape_owner_get_owner(shape_find_owner(int(hit.shape))) as Node
	var weak := combat=="weak" and owner != null and String(owner.name).begins_with("Weak")
	var damage := 40 if weak else 20
	health = maxi(0,health-damage)
	if health==0:
		_set_combat("dead",0)
		stage.win()
	return {"accepted":true,"dead":health==0,"weak":weak,"damage":damage,"health":health}

## 战斗快照只含纯数据；动作内已命中的角色和射击去重记录一起保存。
func capture() -> Dictionary:
	return {"health":health,"maximum":maximum_health,"combat":combat,"timer":timer,"age":age,"position":array(global_position),"yaw":rotation.y,"goal":array(goal),"direction":array(charge_direction),"charge_origin":array(charge_origin),"travel":charge_travel,"slam":array(slam_center),"attack_serial":attack_serial,"victims":victims.duplicate(),"shots":shot_ids.duplicate(),"combo":combo_left,"next":next_attack,"target":locked_target,"turn_age":_turn_age}

## 恢复不调用入场或攻击开始，保留原序号和已结算集合。
func restore(data: Dictionary) -> void:
	health = int(data.health)
	maximum_health = int(data.maximum)
	next_attack = data.next
	_set_combat(data.combat,data.timer)
	age = data.age
	global_position = vector(data.position)
	rotation.y = data.yaw
	goal = vector(data.goal)
	charge_direction = vector(data.direction)
	charge_origin = vector(data.charge_origin)
	charge_travel = data.travel
	slam_center = vector(data.slam)
	attack_serial = int(data.attack_serial)
	victims = data.victims.duplicate()
	shot_ids = data.shots.duplicate()
	combo_left = int(data.combo)
	next_attack = data.next
	locked_target = data.target
	_turn_age = data.turn_age
	velocity = Vector3.ZERO
	agent.target_position = goal
	_update_ground_pose()
	var root_index := skeleton.find_bone("Root")
	var root_delta := Transform3D.IDENTITY
	if combat=="dead":
		root_delta = model.transform*skeleton.transform*skeleton.get_bone_global_pose(root_index)*skeleton.get_bone_global_rest(root_index).affine_inverse()*skeleton.transform.affine_inverse()*model.transform.affine_inverse()
	for shape: CollisionShape3D in shapes:
		shape.transform = root_delta*Transform3D(shape.get_meta("rest"))
	# CharacterBody暂停时不会把新场景姿态同步给服务器；预检必须查询保存姿态。
	PhysicsServer3D.body_set_mode(get_rid(),PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_state(get_rid(),PhysicsServer3D.BODY_STATE_TRANSFORM,global_transform)
	PhysicsServer3D.body_set_mode(get_rid(),PhysicsServer3D.BODY_MODE_KINEMATIC)

static func array(value: Vector3) -> Array:
	return [value.x,value.y,value.z]

static func vector(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])
