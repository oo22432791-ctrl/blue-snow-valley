extends Node
## 统一落脚源：距离相位对应Blender接触帧，读取实际骨骼脚底并发送足迹、声音和雪粉事件。

signal foot_landed(world_position: Vector3, yaw: float, is_left: bool, speed: float)

var _actor: CharacterBody3D
var _last_half_cycle: int = 0
var emitted_steps: int = 0


## 连接角色真实位移，不使用独立计时器估算脚步。
func _ready() -> void:
	# 1. 此节点跟随角色场景装配，初始化当前步态相位。
	_actor = get_parent() as CharacterBody3D
	if _actor == null:
		push_error("FootstepEmitter requires a CharacterBody3D parent")
		return
	_last_half_cycle = floori(_actor.get_gait_phase() / PI)
	# 2. 移动信号在角色完成姿态更新后发出，确保读取最新脚底位置。
	_actor.movement_updated.connect(_on_actor_moved)


## 检测半步周期边界，站立、撞墙和原地观察不产生新脚印。
func _on_actor_moved(previous: Vector3, current: Vector3, real_velocity: Vector3) -> void:
	# 1. 仅接受真实水平位移与贴地状态。
	var half_cycle := floori(_actor.get_gait_phase() / PI)
	var distance := Vector2(current.x - previous.x, current.z - previous.z).length()
	if distance < 0.0005 or not _actor.is_on_floor():
		_last_half_cycle = half_cycle
		return
	# 2. 每跨过半个周期落下一只脚；极低帧率下也不漏掉相位边界。
	while _last_half_cycle < half_cycle:
		_last_half_cycle += 1
		_emit_contact(_last_half_cycle % 2 == 1, real_velocity.length())


## 将当前靴底投影到真实碰撞地面，排除角色自身和不朝上的表面。
func _emit_contact(is_left: bool, speed: float) -> void:
	# 1. 从脚底上方射向地面，避免把足迹写在悬空位置。
	var sole: Vector3 = _actor.get_foot_contact_position(is_left)
	var origin := sole + Vector3.UP * 0.55
	var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * 1.4, 1, [_actor.get_rid()])
	var hit := _actor.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.dot(Vector3.UP) < 0.7:
		return
	# 2. 发布相同事件供雪面、后续声音和粒子共用。
	var contact: Vector3 = hit.position
	if is_instance_valid(_actor.snow_surface):
		contact.y = _actor.snow_surface.get_height_at(contact)
	emitted_steps += 1
	foot_landed.emit(contact, _actor.get_visual_yaw(), is_left, speed)
