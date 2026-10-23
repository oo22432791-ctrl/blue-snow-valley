extends Node3D
## M3厚雪表面：局部细分、几何凹陷与堆雪边缘，CPU采样同时驱动身体高度和深雪阻力。

@export var snow_material: ShaderMaterial
@export var tracks: Node
@export var geometric_deformation: bool = true
var _center_mesh: MeshInstance3D


## 建立24米细节区与外部平面，保持参考场景的大面积留白。
func _ready() -> void:
	# 1. 细节区使用约4.7厘米网格，能实际表达脚印轮廓。
	_center_mesh = _patch("DetailedSnow", Vector3.ZERO, Vector2(24.0, 24.0), 510)
	# 2. 边界高度平滑收敛到统一基面，外部四块平面不与细节区重叠。
	_patch("WestSnow", Vector3(-23.5, 0.0, 0.0), Vector2(23.0, 70.0), 0)
	_patch("EastSnow", Vector3(23.5, 0.0, 0.0), Vector2(23.0, 70.0), 0)
	_patch("NorthSnow", Vector3(0.0, 0.0, -23.5), Vector2(24.0, 23.0), 0)
	_patch("SouthSnow", Vector3(0.0, 0.0, 23.5), Vector2(24.0, 23.0), 0)
	set_detail_mode(geometric_deformation)


## 创建一块共享雪材质的水平网格。
func _patch(node_name: String, at: Vector3, size: Vector2, subdivisions: int) -> MeshInstance3D:
	# 1. 所有块保持无旋转、Y为0，让世界高度与CPU采样一致。
	var plane := PlaneMesh.new()
	plane.size = size
	plane.subdivide_width = subdivisions
	plane.subdivide_depth = subdivisions
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = plane
	instance.material_override = snow_material
	# 2. 扩大包围盒以包含着色器上抬的积雪，避免边缘剔除。
	instance.extra_cull_margin = 0.5
	add_child(instance)
	instance.position = at
	return instance


## 切换实际几何与法线对照，仅用于同场景质量和性能比较。
func set_detail_mode(enabled: bool) -> void:
	# 1. 切换网格成本，同时保留完全相同的颜色、痕迹和镜头。
	geometric_deformation = enabled
	if _center_mesh != null:
		var plane: PlaneMesh = _center_mesh.mesh
		plane.subdivide_width = 510 if enabled else 62
		plane.subdivide_depth = 510 if enabled else 62
	# 2. 法线对照仍显示足迹明暗，但不对顶点压出脚印。
	snow_material.set_shader_parameter("use_geometry", enabled)


## 采样未踩的新雪厚度，两个柔和雪堆区域形成自然阻力变化。
func get_fresh_depth_at(world_position: Vector3) -> float:
	# 1. 场地中央较浅，右侧与左侧树旁较深，均为连续过渡。
	var point := Vector2(world_position.x, world_position.z)
	var deep_patch := exp(-point.distance_squared_to(Vector2(4.8, 3.0)) / 9.68) * 0.18
	var tree_patch := exp(-point.distance_squared_to(Vector2(-6.0, 2.0)) / 8.0) * 0.12
	# 2. 厚度有上限，重复踩踏不会改变这一基础场。
	return clampf(0.08 + deep_patch + tree_patch, 0.08, 0.28)


## 采样未踩雪面的实际世界高度，与着色器使用同一解析函数。
func get_undisturbed_height_at(world_position: Vector3) -> float:
	# 1. 保留原M0的微小起伏，并加入连续的积雪厚度。
	var point := Vector2(world_position.x, world_position.z)
	var variation := sin(point.x * 0.47) * cos(point.y * 0.38) * 0.028 + sin(point.x * 1.15 + point.y * 0.62) * 0.008
	# 2. 接近细节区域外沿时平滑过渡到8厘米基面，避免网格接缝。
	var edge := 1.0 - smoothstep(10.0, 12.0, maxf(absf(point.x), absf(point.y)))
	return 0.08 + (get_fresh_depth_at(world_position) + variation - 0.08) * edge


## 采样包含脚印和边缘堆雪的实际高度，供角色脚底和后续粒子定位。
func get_height_at(world_position: Vector3) -> float:
	# 1. 读取当前点和四邻域的有效足迹，恢复自动影响同一高度场。
	var center: float = tracks.get_impression_at(world_position)
	var neighbor := _neighbor_max(world_position)
	var depression := minf(0.1, get_fresh_depth_at(world_position) * 0.42) * center
	var rim := maxf(0.0, neighbor - center) * 0.018
	# 2. 细节区外沿采用与网格相同的连续过渡。
	var edge := 1.0 - smoothstep(10.0, 12.0, maxf(absf(world_position.x), absf(world_position.z)))
	return get_undisturbed_height_at(world_position) + (rim - depression) * edge


## 读取邻近积雪压痕，估算脚印边缘的少量隆起。
func _neighbor_max(point: Vector3) -> float:
	# 1. 4.5厘米邻域与着色器一致。
	var result: float = 0.0
	for offset in [Vector3(0.045, 0.0, 0.0), Vector3(-0.045, 0.0, 0.0), Vector3(0.0, 0.0, 0.045), Vector3(0.0, 0.0, -0.045)]:
		result = maxf(result, tracks.get_impression_at(point + offset))
	return result


## 深雪最多降低24%目标速度，踩实处阻力减小，浅雪维持原走跑速度。
func get_speed_scale_at(world_position: Vector3) -> float:
	# 1. 足迹压实降低有效松雪厚度，但不改变原始雪堆地形。
	var impression: float = tracks.get_impression_at(world_position)
	var effective_depth := get_fresh_depth_at(world_position) * (1.0 - impression * 0.65)
	# 2. 用户选择深处适度减速，过渡保持连续，不设置突然的速度台阶。
	return 1.0 - smoothstep(0.14, 0.26, effective_depth) * 0.24
