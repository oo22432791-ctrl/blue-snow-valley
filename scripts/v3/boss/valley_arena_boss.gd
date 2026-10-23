extends CharacterBody3D
## M12无伤害雪熊：真实胶囊／球体移动、保守转身和固定骨长贴地。
var stage: Node3D
var model: Node3D
var animation: AnimationPlayer
var skeleton: Skeleton3D
var agent: NavigationAgent3D
var manifest: Dictionary
var shapes: Array[CollisionShape3D] = []
var state := "Idle"
var age := 0.0
var goal := Vector3.ZERO
var charge_direction := Vector3.FORWARD
var last_impact: Object
var moved_distance := 0.0
var foot_contacts: Dictionary = {}
var _slam_emitted := false
var charge_locked := false

## 使用已验收原生源，碰撞覆盖身体、头尾而不拉伸可见模型。
func _ready() -> void:
	collision_layer = 8
	collision_mask = 1|2|4
	floor_snap_length = .65
	floor_max_angle = deg_to_rad(35)
	manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v3/boss/ice_ridge_bear_manifest.json"))
	model = load("res://assets/models/v3/boss/ice_ridge_bear.glb").instantiate()
	add_child(model)
	animation = model.find_children("*","AnimationPlayer",true,false)[0]
	skeleton = model.find_children("*","Skeleton3D",true,false)[0]
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	# 三段相交胶囊覆盖连续躯干，避免前后两段之间留下射线／站位空洞。
	for z in [-2.3,0.0,2.3]:
		var capsule := CapsuleShape3D.new()
		capsule.radius = 2.08
		capsule.height = 4.6
		_add_shape(capsule,Vector3(0,2.3,z))
	for at: Vector3 in [Vector3(0,3.05,4.1),Vector3(0,2.5,-4.15)]:
		var sphere := SphereShape3D.new()
		sphere.radius = .75 if at.z > 0 else .65
		_add_shape(sphere,at)
	agent = NavigationAgent3D.new()
	agent.path_desired_distance = .65
	agent.target_desired_distance = .6
	add_child(agent)
	agent.set_navigation_map(stage.boss_map)
	_sample(0)

## 所有碰撞保留本地静置姿态，侧倒时同步根骨变换。
func _add_shape(resource: Shape3D, at: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.shape = resource
	shape.position = at
	add_child(shape)
	shape.set_meta("rest",shape.transform)
	shapes.append(shape)

## 只接收明确的审阅按钮；恢复站姿前必须检查占位。
func command(value: String, at: Vector3) -> bool:
	if state == "Fall" and not _clear_shapes(global_transform,Transform3D.IDENTITY):
		stage.notice("站起空间受阻，请先移开角色。")
		return false
	state = value
	goal = at
	age = 0
	_slam_emitted = false
	if state == "ChargeWarning":
		charge_locked = false
	last_impact = null
	velocity = Vector3.ZERO
	animation.play(state)
	if state in ["Walk","Run"]:
		agent.target_position = goal
	return true

## 模型、预警与真实位移按同一个物理时间推进，暂停统一冻结。
func _physics_process(delta: float) -> void:
	var previous := global_position
	var old_age := age
	age += delta
	var speed := 0.0
	if state in ["Walk","Run"]:
		if agent.is_navigation_finished():
			command("Idle",goal)
		else:
			var next := agent.get_next_path_position()
			if _turn_to(next,delta):
				speed = 1.43 if state == "Walk" else 3.73
	elif state == "ChargeWarning":
		if not charge_locked:
			age = 0
			var before := rotation.y
			if _turn_to(goal,delta):
				charge_locked = true
				charge_direction = global_basis.z.normalized()
			elif is_equal_approx(before,rotation.y):
				stage.notice("转身受阻，请移开角色、换落点或先走到开阔处。")
		elif age >= animation.get_animation(state).length:
			command("Charge",goal)
	elif state == "Charge":
		speed = 4.98
		if age > 5:
			command("Stop",goal)
	elif state in ["Stop","Hit","Slam"] and age >= animation.get_animation(state).length:
		command("Idle",goal)
	# 1. 下落和地面支撑交给同一个CharacterBody，不按地形查询瞬移物理实体。
	var direction := charge_direction if state == "Charge" else global_basis.z
	velocity.x = direction.x*speed
	velocity.z = direction.z*speed
	velocity.y = 0 if is_on_floor() else velocity.y-24*delta
	if state != "Fall":
		move_and_slide()
		for index in range(get_slide_collision_count()):
			var hit := get_slide_collision(index)
			if absf(hit.get_normal().y) < .65 and speed > 0:
				last_impact = hit.get_collider()
				if state == "Charge":
					if last_impact.has_meta("ice_wall"):
						stage.geometry.break_wall(last_impact.get_meta("ice_wall"))
					stage.powder(hit.get_position(),36)
					command("Stop",goal)
				elif state in ["Walk","Run"]:
					command("Idle",goal)
				last_impact = hit.get_collider()
				stage.notice("冲撞已被实体阻挡。" if state == "Stop" else "前方受阻，请另选落点。")
				break
	moved_distance += Vector2(global_position.x-previous.x,global_position.z-previous.z).length()
	# 2. 可见根随真实坡面取向；肢体随后用同长两骨链贴合实际支撑。
	var p := global_position
	var right := global_basis.x
	var forward := global_basis.z
	var slope_x: float = (stage.ground.ground(p+right*2)-stage.ground.ground(p-right*2))/4
	var slope_z: float = (stage.ground.ground(p+forward*3.5)-stage.ground.ground(p-forward*3.5))/7
	var up := Vector3(-slope_x,1,-slope_z).normalized()
	var z_axis := Vector3(0,slope_z,1).normalized()
	var x_axis := up.cross(z_axis).normalized()
	model.basis = Basis(x_axis,z_axis.cross(x_axis).normalized(),z_axis)
	model.position.y = stage.ground.ground(p)-p.y
	_sample(age)
	var root := skeleton.find_bone("Root")
	var root_delta: Transform3D = skeleton.transform*skeleton.get_bone_global_pose(root)*skeleton.get_bone_global_rest(root).affine_inverse()*skeleton.transform.affine_inverse()
	if state == "Fall":
		root_delta = model.transform*root_delta*model.transform.affine_inverse()
		if not _clear_shapes(global_transform,root_delta):
			age = old_age
			_sample(age)
			stage.notice("侧倒空间受阻，移开角色后继续。")
			return
	else:
		root_delta = Transform3D.IDENTITY
	for shape: CollisionShape3D in shapes:
		shape.transform = root_delta*Transform3D(shape.get_meta("rest"))
	if state != "Fall":
		_fit_feet()
	if state == "Slam" and age >= 1.04 and not _slam_emitted:
		_slam_emitted = true
		stage.powder(global_position+global_basis*Vector3(-1.4,0,2.2),40)
	if speed > 0 and moved_distance-stage.last_boss_powder > .8:
		stage.last_boss_powder = moved_distance
		stage.powder(global_position-global_basis.z*2,10)

## 保留源动画时序，循环动作取模，其他动作保持末帧。
func _sample(seconds: float) -> void:
	# 上一帧的贴地修正不能成为下一帧源动画的起点，恒定轨道也要复原。
	for index in range(skeleton.get_bone_count()):
		skeleton.set_bone_pose(index,skeleton.get_bone_rest(index))
	if animation.current_animation != state:
		animation.play(state)
	var length := animation.get_animation(state).length
	animation.seek(fposmod(seconds,length) if state in ["Idle","Walk","Run","Charge"] else minf(seconds,length),true)
	animation.advance(0)
	skeleton.force_update_all_bone_transforms()

## 每个候选朝向先查实际形状，不能原地旋进冰壁或伙伴。
func _turn_to(at: Vector3, delta: float) -> bool:
	var direction := at-global_position
	var desired := atan2(direction.x,direction.z)
	var proposed := rotate_toward(rotation.y,desired,delta*.85)
	var pose := Transform3D(Basis(Vector3.UP,proposed),global_position)
	if _clear_shapes(pose,Transform3D.IDENTITY):
		rotation.y = proposed
	return absf(wrapf(desired-rotation.y,-PI,PI)) < .12

## 地面不参与横向转身占位，但所有墙、真人和AI实体均参与。
func _clear_shapes(pose: Transform3D, root_delta: Transform3D) -> bool:
	for shape: CollisionShape3D in shapes:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape.shape
		query.transform = pose*root_delta*Transform3D(shape.get_meta("rest"))
		query.collision_mask = 2|4
		query.exclude = [get_rid()]
		if not get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():
			return false
	return true

## 支撑脚射线命中真实地面；超出骨长可达范围时保留源姿态并记录，不拉腿。
func _fit_feet() -> void:
	foot_contacts.clear()
	for leg: String in manifest.feet:
		var a := skeleton.find_bone(leg+"_Upper")
		var b := skeleton.find_bone(leg+"_Lower")
		var c := skeleton.find_bone(leg+"_Paw")
		var upper := skeleton.get_bone_global_pose(a)
		var lower := skeleton.get_bone_global_pose(b)
		var paw := skeleton.get_bone_global_pose(c)
		var sole := skeleton.to_global(paw.origin)-model.global_basis.y*float(manifest.feet[leg].ankle[1])
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(sole+Vector3.UP*1.0,sole+Vector3.DOWN*2.0,1,[get_rid()]))
		if hit.is_empty() or sole.y-hit.position.y > .12:
			continue
		var target := skeleton.to_local(skeleton.to_global(paw.origin)+Vector3.UP*(hit.position.y-sole.y))
		var u: float = manifest.feet[leg].upper
		var l: float = manifest.feet[leg].lower
		var offset := target-upper.origin
		var d := offset.length()
		if d >= u+l-.005 or d <= absf(u-l)+.005:
			foot_contacts[leg] = {"reachable":false}
			continue
		var axis := offset/d
		var bend := lower.origin-upper.origin
		bend = (bend-axis*bend.dot(axis)).normalized()
		var along := (u*u-l*l+d*d)/(2*d)
		var knee := upper.origin+axis*along+bend*sqrt(maxf(0,u*u-along*along))
		var old_knee := lower.origin
		var old_paw := paw.origin
		upper.basis = Basis(Quaternion((old_knee-upper.origin).normalized(),(knee-upper.origin).normalized()))*upper.basis
		skeleton.set_bone_global_pose(a,upper)
		skeleton.force_update_all_bone_transforms()
		lower.origin = knee
		lower.basis = Basis(Quaternion((old_paw-old_knee).normalized(),(target-knee).normalized()))*lower.basis
		skeleton.set_bone_global_pose(b,lower)
		skeleton.force_update_all_bone_transforms()
		paw.origin = target
		skeleton.set_bone_global_pose(c,paw)
		skeleton.force_update_all_bone_transforms()
		foot_contacts[leg] = {"reachable":true,"height_error":absf(skeleton.to_global(paw.origin).y-model.global_basis.y.y*float(manifest.feet[leg].ankle[1])-hit.position.y)}
