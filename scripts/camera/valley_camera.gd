extends Node3D
## 第二版D镜头：固定40°／38°朝向，跟随物理根节点，独立于第一版观察相机。

const PITCH_DEGREES: float = 40.0
const YAW_DEGREES: float = 38.0
const CAMERA_DISTANCE: float = 38.0
const DEFAULT_SIZE: float = 11.5
const MIN_SIZE: float = 8.5
const MAX_SIZE: float = 16.0
const TARGET_HEIGHT: float = 0.2

@export var tracked_actor: Node3D
@export_range(1.0, 30.0) var horizontal_follow_rate: float = 12.0
@export_range(1.0, 20.0) var vertical_follow_rate: float = 5.0
@export_range(1.0, 30.0) var zoom_rate: float = 14.0

var camera: Camera3D
var target: Vector3 = Vector3.ZERO
var desired_size: float = DEFAULT_SIZE
var snow_surface: Node3D
var interior_cabin: Node3D
var interior_weight: float = 0.0
var _interior_center := Vector3.ZERO


## 建立正式正交镜头，并立即对准角色，避免启动从世界原点飞入。
func _ready() -> void:
	# 1. 只有视野大小可缩放，俯角与朝向不暴露为游玩操作。
	camera = Camera3D.new()
	camera.name = "ValleyCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 200.0
	camera.size = DEFAULT_SIZE
	camera.current = true
	add_child(camera)
	# 2. 目标取物理根高度，忽略动画身体与靴子的逐步摆动。
	snap_to_actor()


## 在渲染帧中平滑跟随和缩放，暂停时沿用场景树的冻结边界。
func _process(delta: float) -> void:
	# 1. 分别跟随水平位置与稳定地形高度，避免坡面和转向瞬间跳动。
	if is_instance_valid(tracked_actor):
		interior_weight = move_toward(interior_weight,1.0 if is_instance_valid(interior_cabin) else 0.0,delta/0.35)
		var desired := _actor_target()
		var horizontal_weight := 1.0 - exp(-horizontal_follow_rate * delta)
		target.x = lerpf(target.x, desired.x, horizontal_weight)
		target.z = lerpf(target.z, desired.z, horizontal_weight)
		target.y = lerpf(target.y, desired.y, 1.0 - exp(-vertical_follow_rate * delta))
	# 2. 视野本身保持上下界；连续滚轮只调整目标值，不累积越界误差。
	camera.size = clampf(lerpf(camera.size, desired_size, 1.0 - exp(-zoom_rate * delta)), MIN_SIZE, MAX_SIZE)
	_update_transform()


## 重定位或读档时显式同步角色目标，不把瞬移作为普通平滑移动。
func snap_to_actor() -> void:
	# 1. 无有效角色时保留最后目标，供区域装载阶段安全过渡。
	if is_instance_valid(tracked_actor):
		target = _actor_target()
	# 2. 不改变用户当前缩放，保持固定方向。
	_update_transform()


## 接收输入路由的滚轮步数，正值拉远、负值拉近。
func request_zoom(steps: float) -> void:
	# 1. 每步0.75米，精细滚轮的factor同样保留。
	desired_size = clampf(desired_size + steps * 0.75, MIN_SIZE, MAX_SIZE)


## 调试入口恢复D构图，正式游玩的R始终留给换弹。
func reset_view() -> void:
	# 1. 同步目标与当前视野，复位不残留上一轮缩放插值。
	desired_size = DEFAULT_SIZE
	camera.size = DEFAULT_SIZE
	# 2. 不恢复第一版54°镜头，始终保留第二版固定方向。
	snap_to_actor()


## 从正交相机出发查询真实碰撞；调用方应在物理帧中调用。
func query_aim(screen_position: Vector2, excluded: Array[RID] = []) -> Dictionary:
	# 1. 超出视口不创建射线，暂停／GUI限制由统一输入入口处理。
	if not get_viewport().get_visible_rect().has_point(screen_position):
		return {}
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	# 室内鼠标选择裁掉已淡出的外壳；枪口物理射线不使用此裁剪入口。
	if is_instance_valid(interior_cabin):
		origin = interior_cabin.clip_interior_view_ray(origin,direction)
	# 2. 使用三维碰撞而非固定地面平面，后续可直接瞄准坡面或熊身体。
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * camera.far, 1, excluded)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# 3. 只校准地形上的新雪顶面，房屋、树木和动物仍返回真实碰撞点。
	if not hit.is_empty() and is_instance_valid(snow_surface) and String(hit.collider.name).begins_with("Ground_"):
		hit.position = snow_surface.intersect_surface(origin,direction,hit.position)
		hit.normal = snow_surface.get_surface_normal_at(hit.position)
	return hit


## 室内略抬高并向房间中心收拢，保留人物跟随、原朝向和用户缩放。
func _actor_target() -> Vector3:
	# 1. 户外构图与M1一致，进入时只平滑改变跟随锚点。
	var desired := tracked_actor.global_position+Vector3.UP*TARGET_HEIGHT
	if interior_weight<=0.0001:
		return desired
	var indoor := tracked_actor.global_position+Vector3.UP*0.9
	if is_instance_valid(interior_cabin):
		_interior_center=interior_cabin.to_global(Vector3(0,float(interior_cabin.manifest.floor_y)+0.9,0))
	indoor.x=lerpf(indoor.x,_interior_center.x,0.22)
	indoor.z=lerpf(indoor.z,_interior_center.z,0.22)
	# 2. 只改变构图目标，不传送人物、不重设8.5–16米缩放范围。
	return desired.lerp(indoor,interior_weight)


## 按D样张参数重建相机变换，跟随与缩放均不能旋转镜头。
func _update_transform() -> void:
	# 1. 38米只表示相机布置距离，正交可见范围由size决定。
	var pitch := deg_to_rad(PITCH_DEGREES)
	var yaw := deg_to_rad(YAW_DEGREES)
	camera.global_position = target + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * CAMERA_DISTANCE
	# 2. 朝向始终对准同一跟随点，不读取人物视觉节点的转身角度。
	camera.look_at(target)
