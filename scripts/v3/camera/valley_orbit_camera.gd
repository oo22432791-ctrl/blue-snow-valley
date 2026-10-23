extends "res://scripts/camera/valley_camera.gd"
## 每视图独立正交跟随镜头：360度水平旋转、有限俯仰与缩放。

const PITCH_MIN: float = 25.0
const PITCH_MAX: float = 65.0
const SIZE_MIN: float = 8.5
const SIZE_MAX: float = 18.0
var yaw_degrees: float = 38.0
var pitch_degrees: float = 40.0
var orbit_sensitivity: float = 0.22
var zoom_sensitivity: float = 1.0
var invert_vertical: bool = false
var aim_override_provider: Callable


## P2键盘／手柄可提供角色方向目标，P1仍使用鼠标物理射线。
func query_aim(screen_position: Vector2, excluded: Array[RID] = []) -> Dictionary:
	# 1. 外部提供者只决定瞄准方向，不能替代武器的枪口阻挡判定。
	if aim_override_provider.is_valid():
		return aim_override_provider.call(screen_position, excluded)
	return super.query_aim(screen_position, excluded)


## 延续跟随锚点与室内构图，缩放使用本版已确认的上下界。
func _process(delta: float) -> void:
	# 1. 两个镜头分别读取自己的跟随者，不消费全局鼠标或角色输入。
	if is_instance_valid(tracked_actor):
		interior_weight = move_toward(interior_weight, 1.0 if is_instance_valid(interior_cabin) else 0.0, delta / .35)
		var desired := _actor_target()
		var weight := 1.0 - exp(-horizontal_follow_rate * delta)
		target.x = lerpf(target.x, desired.x, weight)
		target.z = lerpf(target.z, desired.z, weight)
		target.y = lerpf(target.y, desired.y, 1.0 - exp(-vertical_follow_rate * delta))
	# 2. 放大／缩小不改变投影类型，最远18米不会被旧版16米上限截断。
	camera.size = clampf(lerpf(camera.size, desired_size, 1.0 - exp(-zoom_rate * delta)), SIZE_MIN, SIZE_MAX)
	_update_transform()


## 右键拖动只改变本镜头角度，水平环绕不会累积无限角度。
func orbit(relative: Vector2) -> void:
	# 1. 拒绝非有限输入，俯仰不能越过地下或翻到角色头顶。
	if not relative.is_finite():
		return
	yaw_degrees = wrapf(yaw_degrees - relative.x * orbit_sensitivity, 0.0, 360.0)
	pitch_degrees = clampf(pitch_degrees + relative.y * orbit_sensitivity * (-1 if invert_vertical else 1), PITCH_MIN, PITCH_MAX)
	_update_transform()


## 每个视图拥有自己的缩放目标，不修改另一角色镜头。
func request_zoom(steps: float) -> void:
	# 1. 鼠标滚轮与后续手柄意图共用同一个有限入口。
	if is_finite(steps):
		desired_size = clampf(desired_size + steps * .75 * zoom_sensitivity, SIZE_MIN, SIZE_MAX)


## Home恢复当前视图默认构图，设备设置和世界进度不随之重置。
func reset_view() -> void:
	# 1. 默认保持已确认40度俯角、38度朝向和11.5米视野。
	yaw_degrees = 38.0
	pitch_degrees = 40.0
	desired_size = DEFAULT_SIZE
	camera.size = DEFAULT_SIZE
	snap_to_actor()


## 绕跟随锚点更新真正相机，角色方向不会反向控制镜头角度。
func _update_transform() -> void:
	# 1. 保留正交布置距离，画面远近由size控制。
	var pitch := deg_to_rad(pitch_degrees)
	var yaw := deg_to_rad(yaw_degrees)
	camera.global_position = target + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * CAMERA_DISTANCE
	camera.look_at(target)
