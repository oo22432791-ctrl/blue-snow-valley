extends Node3D
## M4短促雪粉：固定粒子池只在落脚时触发，位置采用压实后的雪面高度。

@export var enabled: bool = true
@export var snow_surface: Node3D
@export_range(0.2, 0.7, 0.05) var burst_lifetime: float = 0.4
var total_bursts: int = 0
var _bursts: Array[GPUParticles3D] = []
var _expires: Array[float] = []
var _cursor: int = 0
var _elapsed: float = 0.0
var _material: StandardMaterial3D
var _last_event: Dictionary = {}


## 构建八个可复用短爆发，球形微粒不需要外部纹理。
func _ready() -> void:
	# 1. 使用柔和半透明的小雪粒，关闭粒子投影避免画面杂乱。
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	var grain := SphereMesh.new()
	grain.radius = 0.023
	grain.height = 0.046
	grain.radial_segments = 6
	grain.rings = 2
	grain.material = _material
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 0.8))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var fade := GradientTexture1D.new()
	fade.gradient = gradient
	# 2. 雪粉向上略散，重力使其迅速落回，生命周期限制在0.4秒。
	for index in range(8):
		var process := ParticleProcessMaterial.new()
		process.direction = Vector3.UP
		process.spread = 48.0
		process.gravity = Vector3(0.0, -2.4, 0.0)
		process.initial_velocity_min = 0.3
		process.initial_velocity_max = 0.7
		process.scale_min = 0.45
		process.scale_max = 1.0
		process.color_ramp = fade
		var burst := GPUParticles3D.new()
		burst.name = "PowderBurst%d" % index
		burst.emitting = false
		burst.one_shot = true
		burst.explosiveness = 1.0
		burst.amount = 5
		burst.lifetime = burst_lifetime
		burst.local_coords = false
		burst.fixed_fps = 60
		burst.visibility_aabb = AABB(Vector3(-0.5, -0.3, -0.5), Vector3(1.0, 1.0, 1.0))
		burst.process_material = process
		burst.draw_pass_1 = grain
		burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(burst)
		_bursts.append(burst)
		_expires.append(0.0)


## 使用游戏时间追踪活动爆发，固定帧率录像和正常游玩保持同样节奏。
func _process(delta: float) -> void:
	# 1. 只更新一个标量，不创建或销毁节点。
	_elapsed += delta


## 同一次落脚触发一次少量雪粉，跑步略增加数量和踢起力度。
func on_foot_landed(world_position: Vector3, yaw: float, is_left: bool, speed: float) -> void:
	# 1. 禁用时不影响脚印、身体高度或声音。
	if not enabled:
		return
	var burst: GPUParticles3D = _bursts[_cursor]
	var process: ParticleProcessMaterial = burst.process_material
	var effort := clampf((speed - 2.0) / 1.6, 0.0, 1.0)
	var contact := world_position
	if is_instance_valid(snow_surface):
		contact.y = snow_surface.get_height_at(contact)
	# 2. 信号中的足迹已先写入雪面，粒子从压实后的表面附近喷出。
	burst.global_position = contact + Vector3.UP * 0.035
	burst.rotation.y = yaw
	burst.amount = roundi(lerpf(5.0, 9.0, effort))
	process.direction = Vector3(0.0, 1.0, -0.22)
	process.initial_velocity_max = lerpf(0.7, 0.95, effort)
	burst.visible = true
	burst.restart()
	burst.emitting = true
	_expires[_cursor] = _elapsed + burst_lifetime
	_cursor = (_cursor + 1) % _bursts.size()
	# 3. 固定大小诊断信息验证位置、左右脚和同帧触发，不积累历史。
	total_bursts += 1
	_last_event = {"position": contact, "left": is_left, "speed": speed, "amount": burst.amount, "physics_frame": Engine.get_physics_frames()}


## 配色切换时同步粒子颜色，保持蓝色雪面中的柔和亮粒。
func apply_color(snow_color: Color) -> void:
	# 1. 混入少量白色，使白天、夜晚均可辨认而不形成强闪光。
	_material.albedo_color = snow_color.lerp(Color.WHITE, 0.22)


## 切换雪粉并立即隐藏残留，供声音和粒子独立比较。
func set_enabled(value: bool) -> void:
	# 1. 不清空雪面足迹，只调整本模块。
	enabled = value
	# 2. 关闭时清除可见爆发；下次有效落脚会重新启动池中粒子。
	if not enabled:
		for index in range(_bursts.size()):
			_bursts[index].emitting = false
			_bursts[index].visible = false
			_expires[index] = 0.0


## 获取仍在生命周期内的爆发数，用于验证停止后自动回收。
func get_live_burst_count() -> int:
	# 1. 数量上限固定为池大小，不随游戏时长增长。
	var count := 0
	for expiry in _expires:
		if expiry > _elapsed:
			count += 1
	return count


## 返回最后一次雪粉事件的副本。
func get_last_event() -> Dictionary:
	# 1. 诊断调用不能改写内部落脚信息。
	return _last_event.duplicate(true)
