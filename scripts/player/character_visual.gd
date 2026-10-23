extends Node3D
## Blender外观适配：距离驱动骨骼动画，统一周期对应左右落脚，身体高度仍由角色控制器负责。

@onready var skeleton: Skeleton3D = $SnowChild/SnowChildRig/Skeleton3D
@onready var animation_player: AnimationPlayer = $SnowChild/AnimationPlayer
var _tree: AnimationTree
var _left_bone: int
var _right_bone: int
var _left_sole_offset: Vector3
var _right_sole_offset: Vector3
var _move_blend: float = 0.0
var _run_blend: float = 0.0
var _hand_bone: int
var _hand_offset: Vector3
var _held_ball: MeshInstance3D
var _held_time: float = 0.0


## 读取实际导入骨架并建立动画混合树，保留GLB原始动画资源。
func _ready() -> void:
	# 1. 用静止骨架计算靴底偏移，避免依赖Blender骨骼的局部轴向。
	_left_bone = skeleton.find_bone("Foot_L")
	_right_bone = skeleton.find_bone("Foot_R")
	_left_sole_offset = skeleton.get_bone_global_rest(_left_bone).affine_inverse() * Vector3(-0.13, 0.0, 0.05)
	_right_sole_offset = skeleton.get_bone_global_rest(_right_bone).affine_inverse() * Vector3(0.13, 0.0, 0.05)
	_hand_bone = skeleton.find_bone("Arm_R")
	_hand_offset = skeleton.get_bone_global_rest(_hand_bone).affine_inverse() * Vector3(0.40, 0.565, 0.055)
	# 2. 走跑共享相位并平滑混合，停止时回到真实待机动画。
	var graph := AnimationNodeBlendTree.new()
	for clip in ["Idle", "Walk", "Run"]:
		var animation := animation_player.get_animation(clip)
		animation.loop_mode = Animation.LOOP_LINEAR
		var node := AnimationNodeAnimation.new()
		node.animation = clip
		graph.add_node(clip, node)
	graph.add_node("WalkSeek", AnimationNodeTimeSeek.new())
	graph.add_node("RunSeek", AnimationNodeTimeSeek.new())
	graph.add_node("Move", AnimationNodeBlend2.new())
	graph.add_node("Locomotion", AnimationNodeBlend2.new())
	graph.connect_node("WalkSeek", 0, "Walk")
	graph.connect_node("RunSeek", 0, "Run")
	graph.connect_node("Move", 0, "WalkSeek")
	graph.connect_node("Move", 1, "RunSeek")
	graph.connect_node("Locomotion", 0, "Idle")
	graph.connect_node("Locomotion", 1, "Move")
	# 3. 上身单次动作只覆盖胸、头和手臂，脚与根始终保留原位移步态。
	var previous := "Locomotion"
	for clip in ["Throw", "Hit"]:
		var animation := animation_player.get_animation(clip)
		animation.loop_mode = Animation.LOOP_NONE
		var clip_node := AnimationNodeAnimation.new()
		clip_node.animation = clip
		graph.add_node(clip, clip_node)
		var shot := AnimationNodeOneShot.new()
		shot.fadein_time = 0.035
		shot.fadeout_time = 0.08
		shot.filter_enabled = true
		for track in range(animation.get_track_count()):
			var path := animation.track_get_path(track)
			if String(path.get_subname(0)) in ["Chest", "Head", "Arm_L", "Arm_R"]:
				shot.set_filter_path(path, true)
		graph.add_node(clip + "Shot", shot)
		graph.connect_node(clip + "Shot", 0, previous)
		graph.connect_node(clip + "Shot", 1, clip)
		previous = clip + "Shot"
	graph.connect_node("output", 0, previous)
	_tree = AnimationTree.new()
	_tree.name = "LocomotionTree"
	_tree.tree_root = graph
	add_child(_tree)
	_tree.anim_player = _tree.get_path_to(animation_player)
	_tree.root_node = _tree.get_path_to($SnowChild)
	_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_tree.active = true
	_tree.advance(0.0)
	# 4. 蓄手时显示小雪球，出手后立即隐藏，不增加碰撞或落脚事件。
	_held_ball = MeshInstance3D.new()
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = 0.115
	ball_mesh.height = 0.23
	ball_mesh.radial_segments = 12
	ball_mesh.rings = 6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.94, 0.98, 1.0)
	material.roughness = 0.95
	ball_mesh.material = material
	_held_ball.mesh = ball_mesh
	_held_ball.visible = false
	add_child(_held_ball)


## 采样骨骼动画后再允许落脚模块读取脚底，快慢与碰撞均沿用真实位移相位。
func update_motion(phase: float, speed: float, running: bool, delta: float) -> void:
	# 1. 两个移动动画都按同一0.72米周期定位，不额外推进独立步频。
	var cycle := fposmod(phase / TAU, 1.0)
	_tree.set("parameters/WalkSeek/seek_request", cycle)
	_tree.set("parameters/RunSeek/seek_request", cycle)
	# 2. 平滑起停与走跑切换，避免静止时卡在抬脚姿态。
	var weight := 1.0 - exp(-22.0 * delta)
	_move_blend = lerpf(_move_blend, 1.0 if speed > 0.025 else 0.0, weight)
	_run_blend = lerpf(_run_blend, 1.0 if running and speed > 2.1 else 0.0, weight)
	_tree.set("parameters/Locomotion/blend_amount", _move_blend)
	_tree.set("parameters/Move/blend_amount", _run_blend)
	_tree.advance(delta)
	_held_time = maxf(0.0, _held_time - delta)
	_held_ball.visible = _held_time > 0.0
	if _held_ball.visible:
		_held_ball.global_position = get_throw_position()


## 播放一次上身投掷或受击动作，不修改移动速度、步态相位或脚底。
func play_snow_action(action: String) -> void:
	# 1. 只接受已定义的两种动画，命中反馈不锁定玩家控制。
	if action not in ["Throw", "Hit"]:
		return
	_tree.set("parameters/" + action + "Shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	if action == "Throw":
		_held_time = 0.18


## 返回投掷手套的当前骨骼世界位置，出手时从手中生成实体雪球。
func get_throw_position() -> Vector3:
	# 1. 使用与蒙皮相同的骨骼姿态，避免硬编码角色转向后的发射点。
	return skeleton.global_transform * (skeleton.get_bone_global_pose(_hand_bone) * _hand_offset)


## 重新开局或关闭反馈时清除上身动作，不触碰行走记录。
func clear_snow_actions() -> void:
	# 1. 中止两条单次动作并隐藏尚未出手的雪球。
	for action in ["Throw", "Hit"]:
		_tree.set("parameters/" + action + "Shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	_held_time = 0.0
	_held_ball.visible = false


## 返回动画骨骼变换后的真实靴底位置，与模型的蒙皮使用同一姿态。
func get_foot_contact_position(is_left: bool) -> Vector3:
	# 1. 使用骨骼空间的全局姿态，显式转换到世界空间。
	var bone := _left_bone if is_left else _right_bone
	var offset := _left_sole_offset if is_left else _right_sole_offset
	return skeleton.global_transform * (skeleton.get_bone_global_pose(bone) * offset)


## 提供当前动画混合信息，供重导入和运行检查读取。
func get_motion_state() -> Dictionary:
	# 1. 只返回标量，避免外部代码改写动画树。
	return {"move_blend": _move_blend, "run_blend": _run_blend, "bones": skeleton.get_bone_count(),
		"throw_active": _tree.get("parameters/ThrowShot/active"), "hit_active": _tree.get("parameters/HitShot/active")}
