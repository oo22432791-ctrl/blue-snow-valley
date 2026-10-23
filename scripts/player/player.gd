extends CharacterBody3D
## 共享角色控制：键盘或外部方向驱动真实碰撞，骨骼动画复用距离相位与厚雪高度。

signal movement_updated(previous_position: Vector3, current_position: Vector3, horizontal_velocity: Vector3)

@export_range(0.5, 5.0) var walk_speed: float = 2.0
@export_range(1.0, 8.0) var run_speed: float = 3.6
@export_range(1.0, 30.0) var acceleration: float = 9.0
@export_range(1.0, 40.0) var braking: float = 18.0
@export_range(1.0, 25.0) var turn_speed: float = 12.0
@export var external_control: bool = false
var movement_camera: Camera3D
var snow_surface: Node
var snow_speed_scale: float = 1.0
var horizontal_speed: float = 0.0
var is_running: bool = false
var _visual: Node3D
var _phase: float = 0.0
var _input_active: bool = true
var _surface_height_offset: float = 0.0
var _external_direction: Vector3 = Vector3.ZERO
var _external_running: bool = false


## 获取独立视觉节点，让碰撞体保持稳定而角色可以转身和轻微摆动。
func _ready() -> void:
	# 1. 独立外观场景持有Blender模型和动画树，碰撞胶囊保持原配置。
	_visual = $Visual
	# 2. 记录初始朝向，控制逻辑只旋转视觉节点。
	_visual.rotation_degrees.y = 24.0
	if is_instance_valid(snow_surface):
		_surface_height_offset = snow_surface.get_height_at(global_position)
		_visual.position.y = _surface_height_offset


## 在固定物理步长中更新输入、碰撞移动和行走姿态。
func _physics_process(delta: float) -> void:
	# 1. 读取已登记的键盘动作，斜向输入被限制到单位长度。
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if _input_active else Vector2.ZERO
	var direction := (_external_direction if _input_active else Vector3.ZERO) if external_control else _world_direction(input_vector)
	is_running = _input_active and not direction.is_zero_approx() and (_external_running if external_control else Input.is_action_pressed("sprint"))
	var target_speed := run_speed if is_running else walk_speed
	snow_speed_scale = snow_surface.get_speed_scale_at(global_position) if is_instance_valid(snow_surface) else 1.0
	target_speed *= snow_speed_scale
	var target_velocity := direction * target_speed + _environment_velocity()
	var rate := braking if direction.is_zero_approx() else acceleration
	velocity.x = move_toward(velocity.x, target_velocity.x, rate * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, rate * delta)
	# 2. 使用物理碰撞移动，重力保证胶囊稳定贴地，不直接改位置穿过墙体。
	if not is_on_floor():
		velocity.y -= 24.0 * delta
	else:
		velocity.y = 0.0
	var previous_position := global_position
	move_and_slide()
	var displacement := global_position - previous_position
	var horizontal_displacement := Vector3(displacement.x, 0.0, displacement.z)
	var real_velocity := horizontal_displacement / delta
	horizontal_speed = real_velocity.length()
	# 3. 用实际位移驱动转身和摆动，顶住墙时不会原地跑步。
	if horizontal_speed > 0.025:
		var yaw := atan2(real_velocity.x, real_velocity.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, yaw, 1.0 - exp(-turn_speed * delta))
	_update_visual_gait(horizontal_displacement.length(), delta)
	# 4. 在骨骼姿态更新后发布真实位移，让落脚源读取本帧脚底。
	movement_updated.emit(previous_position, global_position, real_velocity)


## 将画面上的方向转换为地面世界方向，避免斜相机下按W斜着走。
func _world_direction(input_vector: Vector2) -> Vector3:
	# 1. 无输入直接返回，不残留上一帧朝向或速度。
	if input_vector.is_zero_approx():
		return Vector3.ZERO
	var camera := movement_camera if is_instance_valid(movement_camera) else get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(input_vector.x, 0.0, input_vector.y)
	# 2. 将相机右向与前向投影到水平面，再保持模拟输入幅度。
	var right := camera.global_basis.x
	right.y = 0.0
	right = right.normalized()
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	return (right * input_vector.x - forward * input_vector.y).normalized() * input_vector.length()


## 接收电脑控制的世界空间移动意图，复用原有碰撞、雪阻力和动画。
func set_external_direction(direction: Vector3, running: bool = false) -> void:
	# 1. 水平向量保留避让后的减速幅度，禁止外部控制额外加速或抬高角色。
	_external_direction = Vector3(direction.x, 0.0, direction.z).limit_length(1.0)
	_external_running = running


## 供电脑控制器判断窗口是否允许推进，避免失焦期间积累移动指令。
func is_control_active() -> bool:
	# 1. 与玩家输入共享同一个焦点状态。
	return _input_active


## 用原步距驱动Blender动画，身体跟随厚雪，脚底由骨骼姿态提供。
func _update_visual_gait(distance: float, delta: float) -> void:
	# 1. 仅移动时推进左右交替相位，停止后平滑回到静止姿态。
	var moving := horizontal_speed > 0.025
	if moving:
		_phase += distance / 0.72 * TAU
	var settle := 1.0 - exp(-18.0 * delta)
	# 2. 身体跟随双脚下较低的雪面，落脚压出凹陷后以短距离下沉跟进。
	var surface_height := 0.0
	if is_instance_valid(snow_surface):
		surface_height = minf(snow_surface.get_height_at(get_foot_contact_position(true)), snow_surface.get_height_at(get_foot_contact_position(false)))
	_surface_height_offset = move_toward(_surface_height_offset, surface_height, 0.8 * delta)
	_visual.position.y = lerpf(_visual.position.y, _surface_height_offset, settle)
	# 3. 衣服和四肢摆动来自正式动画，避免再叠加占位靴子运动。
	_visual.update_motion(_phase, horizontal_speed, is_running, delta)


## 暴露距离步态相位，与Blender中右脚0、左脚半周期的接触帧一致。
func get_gait_phase() -> float:
	# 1. 相位由实际位移推进，站立不增加。
	return _phase


## 返回骨骼动画靴底的世界位置，最终落脚点仍由射线投影到雪地。
func get_foot_contact_position(is_left: bool) -> Vector3:
	# 1. 外观适配器使用Skeleton3D姿态和源模型靴底偏移计算，不猜测鞋子节点中心。
	return _visual.get_foot_contact_position(is_left)


## 提供足迹长轴使用的实际视觉朝向。
func get_visual_yaw() -> float:
	# 1. 外观在转身平滑期间与移动向量不同，脚印应跟随当时脚的方向。
	return _visual.global_rotation.y


## 失焦时清除输入与速度，避免切换窗口后角色自行继续移动。
func _notification(what: int) -> void:
	# 1. 失焦立即停止并清理动作状态。
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_input_active = false
		velocity = Vector3.ZERO
		_external_direction = Vector3.ZERO
		_external_running = false
		if not external_control:
			for action in ["move_left", "move_right", "move_forward", "move_back", "sprint"]:
				if InputMap.has_action(action):
					Input.action_release(action)
	# 2. 回到窗口后重新接收新的操作。
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_input_active = true


## 外部环境只提供期望横向速度，实际位移仍由同一次碰撞移动完成。
func _environment_velocity() -> Vector3:
	# 1. V1／V2无额外推力；V3覆盖此点，避免复制整套角色物理。
	return Vector3.ZERO
