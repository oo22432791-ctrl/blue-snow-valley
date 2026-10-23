extends Node3D
## M10原骨架采样与四掌接触；实际位移驱动步态，不用人类靴骨或代理掌印。

const MODEL=preload("res://assets/models/v2/animals/valley_bear_natural.glb")
const PAWS=["LF","RF","LR","RR"]
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
var contacts: Dictionary={}
var _bones: Dictionary={}
var _offsets: Dictionary={}
var _rest_soles: Dictionary={}
var _anchors: Dictionary={}
var _planted: Dictionary={}
var _last_positions: Dictionary={}
var _last_times: Dictionary={}
var _previous: Array[Transform3D]=[]
var _sampled: Array[Transform3D]=[]
var _clip: String=""
var _blend_left: float=0.0
var _time: float=0.0


## 死亡后离开视野重生时清除旧锚点，不能把原尸体位置混入新掌位。
func reset_contacts() -> void:
	# 1. 保留网格和动作资源，仅清理跨帧接触与动画混合缓存。
	contacts.clear();_anchors.clear();_last_positions.clear();_previous.clear();_sampled.clear();_clip="";_blend_left=0;_time=0
	for paw: String in PAWS:_planted[paw]=false;_last_times[paw]=-1.0
	skeleton.reset_bone_poses()


## 从实际导入骨架计算掌底偏移，避免猜测Blender局部轴向。
func _ready() -> void:
	# 1. 使用深棕色自然熊修订源的19骨骼／7段四足动作，运行时只采样姿态。
	var model: Node3D=MODEL.instantiate();add_child(model)
	skeleton=model.find_children("*","Skeleton3D",true,false)[0]
	animation_player=model.find_children("*","AnimationPlayer",true,false)[0]
	animation_player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v2/animals/valley_bear_natural_manifest.json"))
	for paw: String in PAWS:
		var bone:=skeleton.find_bone(paw+"_Paw");assert(bone>=0)
		var at: Array=manifest.sole_centres_rest[paw]
		_rest_soles[paw]=Vector3(at[0],at[1],at[2])
		_bones[paw]=bone;_offsets[paw]=skeleton.get_bone_global_rest(bone).affine_inverse()*Vector3(at[0],at[1],at[2]);_planted[paw]=false;_last_times[paw]=-1.0


## 距离周期采样原动作，状态切换用短姿态过渡，不修改模型资源。
func sample(clip: String, normalized: float, delta: float) -> void:
	# 1. 每次切换保存上一实际姿态；动画不使用独立墙钟继续跑。
	_time+=delta
	if clip!=_clip:
		_previous.assign(_sampled)
		_clip=clip;_blend_left=.12;animation_player.play(clip)
	# 2. 接触修正只属于上一帧，先恢复局部静置变换，防止无位移轨道留下掌骨偏移。
	for index in range(skeleton.get_bone_count()):skeleton.set_bone_pose(index,skeleton.get_bone_rest(index))
	var length: float=animation_player.get_animation(clip).length
	animation_player.seek(clampf(normalized,0,1)*length,true);animation_player.advance(0)
	_blend_left=maxf(0,_blend_left-delta)
	if _blend_left>0 and _previous.size()==skeleton.get_bone_count():
		var weight:=1.0-_blend_left/.12
		for index in range(skeleton.get_bone_count()):skeleton.set_bone_pose(index,_previous[index].interpolate_with(skeleton.get_bone_pose(index),weight))
	# 3. 跨动作过渡只保存动画姿态，不把IK修正再混入下一段源动作。
	_sampled.clear()
	for index in range(skeleton.get_bone_count()):_sampled.append(skeleton.get_bone_pose(index))


## 只旋转上腿和下腿求解掌位；不可达目标截在原骨长范围内，绝不平移拉长掌骨。
func _place_paw(paw: String, target_sole: Vector3) -> Vector3:
	# 1. 在骨架空间求两段腿的原长与当前弯曲方向，保留源动作掌部朝向。
	var upper:=skeleton.find_bone(paw+"_Upper")
	var lower:=skeleton.find_bone(paw+"_Lower")
	var ankle: int=_bones[paw]
	var a:=skeleton.get_bone_global_pose(upper)
	var b:=skeleton.get_bone_global_pose(lower)
	var c:=skeleton.get_bone_global_pose(ankle)
	var first:=a.origin.distance_to(b.origin)
	var second:=b.origin.distance_to(c.origin)
	var target: Vector3=skeleton.global_transform.affine_inverse()*target_sole-c.basis*_offsets[paw]
	var axis: Vector3=target-a.origin
	var reach:=clampf(axis.length(),absf(first-second)+.0001,first+second-.0001)
	axis=axis.normalized() if axis.length_squared()>.000001 else Vector3.DOWN
	target=a.origin+axis*reach
	var pole: Vector3=b.origin-a.origin-axis*(b.origin-a.origin).dot(axis)
	if pole.length_squared()<.000001:pole=Vector3.FORWARD-axis*Vector3.FORWARD.dot(axis)
	if pole.length_squared()<.000001:pole=Vector3.RIGHT-axis*Vector3.RIGHT.dot(axis)
	# 2. 余弦定理确定膝位；旋转原骨，保持每段局部平移和长度不变。
	var along:=(first*first+reach*reach-second*second)/(2*reach)
	var height:=sqrt(maxf(0,first*first-along*along))
	var knee: Vector3=a.origin+axis*along+pole.normalized()*height
	a.basis=Basis(Quaternion((b.origin-a.origin).normalized(),(knee-a.origin).normalized()))*a.basis
	skeleton.set_bone_global_pose(upper,a)
	b=skeleton.get_bone_global_pose(lower)
	var tip:=skeleton.get_bone_global_pose(ankle).origin
	b.basis=Basis(Quaternion((tip-b.origin).normalized(),(target-b.origin).normalized()))*b.basis
	skeleton.set_bone_global_pose(lower,b)
	# 3. 掌骨只恢复源朝向，位置由两段旋转自然得到；落印使用可达的实际掌底。
	var result:=skeleton.get_bone_global_pose(ankle)
	result.basis=c.basis
	skeleton.set_bone_global_pose(ankle,result)
	return skeleton.global_transform*(result*_offsets[paw])


## 四个静置掌位采样地面，身体顺应坡面并轻微屈腿，为脚部调整留出可达空间。
func _fit_body(surface: Node3D, delta: float) -> void:
	# 1. 以物理身体的水平朝向取样，不让上一帧倾斜继续累积。
	var yaw_basis: Basis=get_parent().global_basis
	var base: Vector3=get_parent().global_position
	var points: Dictionary={}
	var height:=0.0
	for paw: String in PAWS:
		var at: Vector3=base+yaw_basis*_rest_soles[paw]
		at.y=surface.get_support_height_at(at);points[paw]=at;height+=at.y*.25
	var forward: Vector3=(points.LF+points.RF-points.LR-points.RR)*.5
	var right: Vector3=(points.RF+points.RR-points.LF-points.LR)*.5
	var up:=forward.cross(right).normalized()
	# 2. 导航边缘不允许身体翻转；平滑旋转仅改变视觉，实体碰撞仍由actor负责。
	if up.y<.82:up=Vector3.UP.lerp(up,.45).normalized()
	forward=(yaw_basis.z-up*yaw_basis.z.dot(up)).normalized()
	right=up.cross(forward).normalized()
	global_basis=global_basis.orthonormalized().slerp(Basis(right,up,forward),1-exp(-12*delta))
	global_position=Vector3(global_position.x,height-.035,global_position.z)
	# 3. 源步态会转动脚掌；按实际掌底朝向补足垂直可达余量，不能只靠固定屈腿高度。
	var lower_body:=0.0
	for paw: String in PAWS:
		if _clip=="Swipe" and paw=="RF":continue
		var upper:=skeleton.find_bone(paw+"_Upper")
		var lower:=skeleton.find_bone(paw+"_Lower")
		var hip:=skeleton.get_bone_global_pose(upper).origin
		var knee:=skeleton.get_bone_global_pose(lower).origin
		var tip:=skeleton.get_bone_global_pose(_bones[paw])
		var reach:=hip.distance_to(knee)+knee.distance_to(tip.origin)-.015
		var offset: Vector3=skeleton.global_basis*tip.basis*_offsets[paw]
		var hip_world: Vector3=skeleton.global_transform*hip
		var at:=hip_world+offset
		var ankle_height: float=surface.get_support_height_at(at)-offset.y
		lower_body=maxf(lower_body,hip_world.y-ankle_height-reach)
	global_position.y-=clampf(lower_body,0,.16)


## 支撑目标越出腿长时释放锁掌，沿地面向髋下收回；不通过拉长骨骼强行贴地。
func _reachable_sole(paw: String, sole: Vector3, surface: Node3D) -> Vector3:
	# 1. 计算原长限制和髋下落点，目标只在真实地面上滑移。
	var upper:=skeleton.find_bone(paw+"_Upper")
	var lower:=skeleton.find_bone(paw+"_Lower")
	var ankle: int=_bones[paw]
	var hip:=skeleton.get_bone_global_pose(upper).origin
	var knee:=skeleton.get_bone_global_pose(lower).origin
	var tip:=skeleton.get_bone_global_pose(ankle)
	var reach:=hip.distance_to(knee)+knee.distance_to(tip.origin)-.0002
	var offset: Vector3=tip.basis*_offsets[paw]
	var inverse:=skeleton.global_transform.affine_inverse()
	if (inverse*sole-offset).distance_to(hip)<=reach:return sole
	var below: Vector3=skeleton.global_transform*(hip+offset)
	# 2. 有界搜索优先保留原落点；越界时重置锚点而非无限拖拽短腿。
	for index in range(1,13):
		var candidate:=sole.lerp(below,index/12.0)
		candidate.y=surface.get_support_height_at(candidate)
		if (inverse*candidate-offset).distance_to(hip)<=reach:
			_anchors[paw]=candidate
			return candidate
	return sole


## 四掌分别锁定支撑期，返回本帧真实落地掌，落点同时驱动掌印与声音。
func adapt_contacts(surface: Node3D, phase: float, moving: bool, running: bool, delta: float) -> Array[Dictionary]:
	# 1. 源动作前半周期摆掌、后半周期着地；跑步采用对角双掌，不借用左右靴印。
	_fit_body(surface,delta)
	var landed: Array[Dictionary]=[]
	var offsets: Dictionary={"LF":0.0,"RF":.5,"LR":.5 if running else .75,"RR":0.0 if running else .25}
	for paw: String in PAWS:
		var bone: int=_bones[paw]
		var pose:=skeleton.get_bone_global_pose(bone)
		var sole: Vector3=skeleton.global_transform*(pose*_offsets[paw])
		var cycle:=fposmod(phase+float(offsets[paw]),1)
		var stance:=moving and cycle>=.5
		var was_planted: bool=_planted[paw]
		if stance:
			if not was_planted or Vector2(sole.x-_anchors[paw].x,sole.z-_anchors[paw].z).length()>.42:_anchors[paw]=sole
			sole.x=_anchors[paw].x;sole.z=_anchors[paw].z
			sole.y=surface.get_support_height_at(sole)
		else:
			# 2. 抬掌最低越过压实支撑；深雪允许在可见雪面下形成真实压入。
			var support: float=surface.get_support_height_at(sole)
			sole.y=maxf(sole.y,support)
			if not moving and (_clip in ["Idle","Warning","Hit"] or (_clip=="Swipe" and paw!="RF")):sole.y=support
		if stance or (not moving and _clip in ["Idle","Warning","Hit"]):sole=_reachable_sole(paw,sole,surface)
		sole=_place_paw(paw,sole)
		var support: float=surface.get_support_height_at(sole)
		stance=stance and absf(sole.y-support)<.01
		_planted[paw]=stance
		contacts[paw]={"sole":sole,"support":support,"stance":stance,"cycle":cycle}
		# 3. 初次接触才产生事件，接地距离与最小真实物理间隔防止急转重叠连发。
		if stance and not was_planted and _time-float(_last_times[paw])>.08 and (not _last_positions.has(paw) or sole.distance_to(_last_positions[paw])>.12):
			landed.append({"paw":paw,"position":sole,"front":paw in ["LF","RF"]})
			_last_positions[paw]=sole;_last_times[paw]=_time
	return landed
