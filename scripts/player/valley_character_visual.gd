extends "res://scripts/player/character_visual.gd"
## 七骨骼接触小样：保留原动作，逐脚校准支撑与抬脚；不是带膝关节的完整腿部IK。

const STOP_FOOT_SPEED: float = 2.0
const MAX_HORIZONTAL_FOOT_SPEED: float = 7.2
var snow_surface: Node3D
var stride_scale: float = 1.0
var _anchors: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _planted: Array[bool] = [false,false]
var _previous_cycles: Array[float] = [0.0,0.0]
var contact_state: Array[Dictionary] = [{},{}]
var _weapon: Node3D
var _rifle_animation: AnimationNodeAnimation
var _rifle_mix: float=0.0


## 仅V2的11骨骼角色装配枪械上身层，原五段动作和脚部采样继续由共享树负责。
func configure_rifle(weapon: Node3D) -> void:
	# 1. 新动作只过滤头、臂、肘、腕，不覆盖根、胸与左右脚，保持踩雪回归边界。
	_weapon=weapon
	# 新腕骨位于实际手套中心；兼容原投雪球接口时不再沿旧整臂骨猜出手点。
	_hand_bone=skeleton.find_bone("Hand_R");_hand_offset=Vector3.ZERO
	var graph: AnimationNodeBlendTree=_tree.tree_root
	_rifle_animation=AnimationNodeAnimation.new();_rifle_animation.animation="RifleHold";graph.add_node("RiflePose",_rifle_animation)
	graph.add_node("RifleSeek",AnimationNodeTimeSeek.new());graph.connect_node("RifleSeek",0,"RiflePose")
	var blend:=AnimationNodeBlend2.new();blend.filter_enabled=true
	var clip:=animation_player.get_animation("RifleHold")
	for track in range(clip.get_track_count()):
		var path:=clip.track_get_path(track)
		if path.get_subname_count()>0 and String(path.get_subname(0)) in ["Head","Arm_L","Arm_R","Forearm_L","Forearm_R","Hand_L","Hand_R"]:blend.set_filter_path(path,true)
	# 2. 原树最终上身节点为HitShot；装备层只在持枪时启用，不重建其余混合节点。
	graph.add_node("RifleBlend",blend);graph.disconnect_node("output",0)
	graph.connect_node("RifleBlend",0,"HitShot");graph.connect_node("RifleBlend",1,"RifleSeek");graph.connect_node("output",0,"RifleBlend")
	_tree.advance(0)


## 每次先重新采样原动画，再叠加当前雪深所需的足骨修正，避免累积漂移。
func update_motion(phase: float, speed: float, running: bool, delta: float) -> void:
	# 1. 共享动画树仍负责起停、转身、上身动作与走跑混合。
	if is_instance_valid(_weapon):
		var active: bool=_weapon.equipped==2
		# 静止时允许脚下跟身转向；移动时保留原速度朝向，瞄准只转胸部。
		if active and speed<=.025:rotation.y=lerp_angle(rotation.y,_weapon.aim_yaw()+deg_to_rad(60),1-exp(-12*delta))
		var state: Dictionary=_weapon.pose_state()
		_rifle_animation.animation=state.clip
		_tree.set("parameters/RifleSeek/seek_request",float(state.normalized)*animation_player.get_animation(state.clip).length)
		_rifle_mix=lerpf(_rifle_mix,1.0 if active else 0.0,1-exp(-24*delta))
		_tree.set("parameters/RifleBlend/blend_amount",_rifle_mix)
	# 上一帧接触／瞄准只属于上一帧；恒定动画轨道也必须从源静置姿态重新开始。
	for index in range(skeleton.get_bone_count()):skeleton.set_bone_pose(index,skeleton.get_bone_rest(index))
	super.update_motion(phase,speed,running,delta)
	if is_instance_valid(_weapon) and _rifle_mix>.001:
		var chest:=skeleton.find_bone("Chest")
		var pose:=skeleton.get_bone_global_pose(chest)
		var yaw:=wrapf(_weapon.aim_yaw()+deg_to_rad(60)-global_rotation.y,-PI,PI)
		pose.basis=Basis(Vector3.UP,yaw*(1.0 if _weapon.equipped==2 else _rifle_mix))*pose.basis
		skeleton.set_bone_global_pose(chest,pose)
	if not is_instance_valid(snow_surface):
		return
	# 2. 左右脚分别读取实际姿态与雪场，左右相差半周期。
	for side in range(2):
		var left := side==0
		var cycle := fposmod(phase/TAU+(0.5 if left else 0.0),1.0)
		var bone := _left_bone if left else _right_bone
		var sole_offset := _left_sole_offset if left else _right_sole_offset
		var pose := skeleton.get_bone_global_pose(bone)
		var sole := skeleton.global_transform*(pose*sole_offset)
		var local_sole := to_local(sole)
		local_sole.z *= stride_scale
		var desired := to_global(local_sole)
		var moving := speed>0.025
		var stance := cycle<=0.5 and moving
		if stance:
			# 3. 支撑期锁定世界脚点；急转超出可达范围时选择新落点，稍后限制重落速度。
			if not _planted[side] or cycle<_previous_cycles[side] or Vector2(desired.x-_anchors[side].x,desired.z-_anchors[side].z).length()>0.45:
				_anchors[side] = desired
			_planted[side] = true
			desired.x = _anchors[side].x
			desired.z = _anchors[side].z
			desired.y = snow_surface.get_support_height_at(desired)
		else:
			_planted[side] = false
			var progress := clampf((cycle-0.5)*2.0,0,1)
			var lift := sin(progress*PI) if moving else 0.0
			var depth: float = snow_surface.get_fresh_depth_at(desired)
			# 4. 深雪中央抬到雪顶以上，起落两端允许自然埋入，前摆小弧线帮助出雪。
			var amplitude := maxf(0.13 if running else 0.10,depth-snow_surface.get_height_at(desired)+0.065)
			var forward := global_basis.z.normalized()
			# 宽衣摆遮住原小弧线；深雪前摆22厘米，让抬起的靴头在正式镜头中可读。
			desired += forward*(0.22*smoothstep(0.08,0.30,depth)*lift*_move_blend)
			desired.y = snow_surface.get_support_height_at(desired)+amplitude*lift*_move_blend
		# 5. 急转时限制水平重落，急停时限制完整收脚；瞬移不在旧位置之间插值。
		if contact_state[side].has("sole"):
			desired = _recover_foot_motion(contact_state[side].sole,desired,moving,delta)
		# 6. 修改蒙皮使用的实际足骨；保持原旋转，靴底偏移与落脚源读取同一姿态。
		pose.origin = skeleton.global_transform.affine_inverse()*desired-pose.basis*sole_offset
		skeleton.set_bone_global_pose(bone,pose)
		_previous_cycles[side] = cycle
		contact_state[side] = {"stance":stance,"cycle":cycle,"sole":desired,"support":snow_surface.get_support_height_at(desired),"surface":snow_surface.get_surface_height_at(desired)}


## 从上一帧真实脚点收回，保持坡面支撑，并限制急停／急转时的重定位速度。
func _recover_foot_motion(previous: Vector3, desired: Vector3, moving: bool, delta: float) -> Vector3:
	# 1. 大幅重定位视为读档／调试瞬移，不能从旧世界脚点拖出长腿。
	if previous.distance_to(desired)>=0.75:
		return desired
	# 2. 停步按完整三维距离逐渐收脚，避免moving阈值把抬脚直接切到地面。
	if not moving:
		desired = previous.move_toward(desired,STOP_FOOT_SPEED*delta)
		desired.y = maxf(desired.y,snow_surface.get_support_height_at(desired))
		return desired
	# 3. 快速转向允许有限滑步重落，水平上限为基础跑速的两倍；保持原抬脚高度。
	var horizontal := Vector2(desired.x-previous.x,desired.z-previous.z)
	if horizontal.length()>MAX_HORIZONTAL_FOOT_SPEED*delta:
		var old_support: float = snow_surface.get_support_height_at(desired)
		horizontal = horizontal.limit_length(MAX_HORIZONTAL_FOOT_SPEED*delta)
		desired.x = previous.x+horizontal.x
		desired.z = previous.z+horizontal.y
		desired.y += snow_surface.get_support_height_at(desired)-old_support
	return desired


## 读档／安全返回显式丢弃旧世界的脚掌锚点，避免跨山谷拖拽肢体。
func reset_session_pose() -> void:
	# 1. 重定位后重新采样原动画，骨长与持枪握点仍由原适配器约束。
	_anchors=[Vector3.ZERO,Vector3.ZERO];_planted=[false,false];_previous_cycles=[0.0,0.0];contact_state=[{},{}]
	_move_blend=0;_run_blend=0;_held_time=0
	if not is_instance_valid(snow_surface):snow_surface=get_parent().snow_surface
	if is_instance_valid(_held_ball):_held_ball.hide()
	position.y=snow_surface.get_height_at(global_position)
	update_motion(0,0,false,0)
