extends Node3D
## 固定俯视配色镜头：只调整观察距离和俯角，不承担角色跟随。

@export var target: Vector3 = Vector3(0.0, 0.0, 0.4)
@export_range(35.0, 75.0) var pitch_degrees: float = 54.0
@export var yaw_degrees: float = 38.0
@export_range(12.0, 32.0) var view_size: float = 21.0
var camera: Camera3D


## 创建正交相机并应用初始构图。
func _ready() -> void:
	# 1. 创建可用于真实渲染的游戏相机。
	camera = Camera3D.new()
	camera.name = "ArtCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 150.0
	camera.current = true
	add_child(camera)
	# 2. 将参数转换为相机位置和朝向。
	update_camera()


## 在不改变场景布局的前提下更新观察位置。
func update_camera() -> void:
	# 1. 限制调试范围，避免穿入地面或失去整个场景。
	pitch_degrees = clampf(pitch_degrees, 35.0, 75.0)
	view_size = clampf(view_size, 12.0, 32.0)
	var pitch := deg_to_rad(pitch_degrees)
	var yaw := deg_to_rad(yaw_degrees)
	# 2. 固定半径，只改变俯角、朝向和正交观察大小。
	camera.position = target + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * 38.0
	camera.look_at(target)
	camera.size = view_size


## 将观察参数恢复到所有颜色小样共用的初始值。
func reset_view() -> void:
	# 1. 恢复固定构图。
	pitch_degrees = 54.0
	yaw_degrees = 38.0
	view_size = 21.0
	# 2. 同步游戏相机。
	update_camera()
