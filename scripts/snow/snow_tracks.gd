extends Node
## M2动态足迹场：记录强度和带权时间戳，痕迹约30秒恢复，纹理存储不受64脚印限制。

@export var snow_material: ShaderMaterial
@export var world_rect: Rect2 = Rect2(-12.0, -12.0, 24.0, 24.0)
@export_range(256, 2048, 256) var resolution: int = 1024
@export_range(1.0, 180.0) var recovery_seconds: float = 30.0
var elapsed_seconds: float = 0.0
var total_steps: int = 0
var _image: Image
var _texture: ImageTexture
var _dirty: bool = false
var _recent_steps: Array[Dictionary] = []


## 分配固定大小的浮点痕迹图，并与雪面材质共享世界坐标映射。
func _ready() -> void:
	# 1. R保存强度，G保存强度乘以时间，避免线性过滤导致新脚印边缘时间失真。
	_image = Image.create(resolution, resolution, false, Image.FORMAT_RGF)
	_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_texture = ImageTexture.create_from_image(_image)
	# 2. 显式绑定区域和时钟，纹理本身不作为颜色做sRGB转换。
	snow_material.set_shader_parameter("footprint_map", _texture)
	snow_material.set_shader_parameter("track_origin", world_rect.position)
	snow_material.set_shader_parameter("track_size", world_rect.size)
	snow_material.set_shader_parameter("recovery_seconds", recovery_seconds)
	snow_material.set_shader_parameter("track_time", elapsed_seconds)


## 只在有新落脚时上传纹理；逐帧恢复由着色器时钟完成。
func _process(delta: float) -> void:
	# 1. 使用游戏运行时间推进恢复，清理过期的诊断记录。
	elapsed_seconds += delta
	snow_material.set_shader_parameter("track_time", elapsed_seconds)
	while not _recent_steps.is_empty() and elapsed_seconds - float(_recent_steps[0].time) >= recovery_seconds:
		_recent_steps.pop_front()
	# 2. 同一渲染帧内的多次物理落脚合并为一次GPU上传。
	flush_pending()


## 将尚未上传的局部写入同步到GPU，也供固定构图采集模式使用。
func flush_pending() -> void:
	# 1. 没有新落脚时不重复上传整张纹理。
	if _dirty:
		_texture.update(_image)
		_dirty = false


## 将一次落脚写入有限世界区域，重踩更新强度和恢复时间而不无限加深。
func stamp(world_position: Vector3, yaw: float, is_left: bool, strength: float = 1.0) -> bool:
	# 1. 区域外直接忽略，区域边缘只裁切，不允许纹理重复到对侧。
	var point := Vector2(world_position.x, world_position.z)
	if not world_rect.has_point(point):
		return false
	var uv := world_to_uv(point)
	var center := uv * float(resolution)
	var pixel_radius := ceili(0.23 / minf(world_rect.size.x, world_rect.size.y) * resolution)
	var minimum := Vector2i(maxi(0, floori(center.x) - pixel_radius), maxi(0, floori(center.y) - pixel_radius))
	var maximum := Vector2i(mini(resolution - 1, ceili(center.x) + pixel_radius), mini(resolution - 1, ceili(center.y) + pixel_radius))
	var right := Vector2(cos(yaw), -sin(yaw))
	var forward := Vector2(sin(yaw), cos(yaw))
	# 2. 把柔边靴底形状写入局部像素；左右脚使用镜像的轻微内侧收窄。
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var pixel_world := world_rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / float(resolution) * world_rect.size
			var offset := pixel_world - point
			var local := Vector2(offset.dot(right) / 0.105, offset.dot(forward) / 0.18)
			var arch_side := -1.0 if is_left else 1.0
			local.x += arch_side * exp(-pow(local.y * 2.8, 2.0)) * 0.12
			var mask := (1.0 - smoothstep(0.6, 1.12, local.length())) * clampf(strength, 0.0, 1.0)
			if mask < 0.002:
				continue
			var previous := _image.get_pixel(x, y)
			var surviving := _effective_impression(previous)
			var depth := maxf(mask, surviving)
			_image.set_pixel(x, y, Color(depth, depth * elapsed_seconds, 0.0, 1.0))
	# 3. 记录有限寿命的落脚元数据，供检查左右脚和方向；像素场保留完整区域状态。
	_dirty = true
	total_steps += 1
	_recent_steps.append({"position": world_position, "yaw": yaw, "left": is_left, "time": elapsed_seconds, "strength": strength})
	return true


## 接收公共落脚事件，速度保留为后续雪粉和力度调节的依据。
func on_foot_landed(world_position: Vector3, yaw: float, is_left: bool, speed: float) -> void:
	# 1. 用当前走跑速度生成轻微强度差，不改变足迹尺寸和恢复时长。
	var strength := lerpf(0.88, 1.0, clampf((speed - 2.0) / 1.6, 0.0, 1.0))
	# 2. 所有角色后续均可复用同一个记录入口。
	stamp(world_position, yaw, is_left, strength)


## 将地面XZ位置转换为固定纹理区域的UV。
func world_to_uv(point: Vector2) -> Vector2:
	# 1. 映射不做取模，避免越界足迹在另一端出现。
	return (point - world_rect.position) / world_rect.size


## 读取当前位置的有效痕迹强度，用于调试与运行验收。
func get_impression_at(world_position: Vector3) -> float:
	# 1. 检查区域并定位相应像素。
	var point := Vector2(world_position.x, world_position.z)
	if not world_rect.has_point(point):
		return 0.0
	var pixel := Vector2i(world_to_uv(point) * float(resolution))
	pixel.x = clampi(pixel.x, 0, resolution - 1)
	pixel.y = clampi(pixel.y, 0, resolution - 1)
	# 2. 使用与着色器一致的恢复曲线返回当前有效值。
	return _effective_impression(_image.get_pixelv(pixel))


## 解释一个像素的时间戳并计算恢复后的强度。
func _effective_impression(pixel: Color) -> float:
	# 1. 空像素没有有效时间戳，避免除零。
	if pixel.r <= 0.00001:
		return 0.0
	var age := maxf(0.0, elapsed_seconds - pixel.g / pixel.r)
	# 2. 平滑地在用户选择的30秒内恢复，不突然删除脚印。
	return pixel.r * (1.0 - smoothstep(0.0, recovery_seconds, age))


## 调试清空所有足迹，保留当前运行时钟和角色状态。
func clear_tracks() -> void:
	# 1. 同时清空CPU场、可见纹理和诊断列表。
	_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_texture.update(_image)
	_recent_steps.clear()
	total_steps = 0
	# 2. 已经同步到GPU，不再重复上传空纹理。
	_dirty = false


## 提供只读副本，避免诊断调用意外修改足迹元数据。
func get_recent_steps() -> Array[Dictionary]:
	# 1. 深复制小范围、有限寿命的记录。
	return _recent_steps.duplicate(true)
