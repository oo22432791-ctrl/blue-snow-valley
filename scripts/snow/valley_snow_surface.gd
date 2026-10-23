extends Node3D
## M3共享新雪场：物理基底、新雪表面和压实支撑分别查询，附近细节有限驻留。

const SNOW_SHADER = preload("res://materials/valley_snow.gdshader")
const TILE_SIZE: float = 16.0
const TILE_SEGMENTS: int = 512
var terrain: Node3D
var player: CharacterBody3D
var tracks: Node
var manifest: Dictionary
var depths: PackedFloat32Array
var far_material: ShaderMaterial
var fine_material: ShaderMaterial
var detail_bounds: Vector4
var detail_center := Vector2i(2147483647,2147483647)
var window_moves: int = 0
var last_transition_ms: float = 0.0
var _tiles: Array[MeshInstance3D] = []
var _textures: Array[ImageTexture] = []


## 读取一次共享浮点场，复用九块网格；不生成全图高细分或足迹历史纹理。
func _ready() -> void:
	# 1. 运行时只读取离线雪深，资源缺失明确失败。
	manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/snow/v2/manifest.json"))
	var file := FileAccess.open("res://assets/snow/v2/depth_grid.bin",FileAccess.READ)
	depths = file.get_buffer(file.get_length()).to_float32_array()
	file.close()
	assert(depths.size() == int(manifest.width)*int(manifest.depth),"Invalid snow grid")
	var depth_image := Image.create_from_data(int(manifest.width),int(manifest.depth),false,Image.FORMAT_RF,depths.to_byte_array())
	var base_image := Image.create_from_data(int(terrain.manifest.width),int(terrain.manifest.depth),false,Image.FORMAT_RF,terrain.heights.to_byte_array())
	_textures.assign([ImageTexture.create_from_image(depth_image),ImageTexture.create_from_image(base_image)])
	far_material = _make_material(false)
	fine_material = _make_material(true)
	# 2. 基底碰撞保留；只替换地形实例材质，第一版资源完全独立。
	terrain.ground_material = far_material
	for body in terrain.get_children():
		for child in body.get_children():
			if child is MeshInstance3D:
				child.material_override = far_material
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(TILE_SIZE,TILE_SIZE)
	mesh.subdivide_width = TILE_SEGMENTS-1
	mesh.subdivide_depth = TILE_SEGMENTS-1
	# 3. 网格九实例共享资源；位移包围盒包含整座山谷高度，避免坡上被错误剔除。
	for index in range(9):
		var tile := MeshInstance3D.new()
		tile.name = "NearSnow_%d" % index
		tile.mesh = mesh
		tile.material_override = fine_material
		tile.custom_aabb = AABB(Vector3(-8,-10,-8),Vector3(16,180,16))
		tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tile)
		_tiles.append(tile)
	_update_window()


## 仅跨过16米网格时搬动细节窗口，不改变碰撞、雪深或区域对象ID。
func _process(_delta: float) -> void:
	# 1. 九实例常驻，不在行走途中申请高密度网格。
	_update_window()


## 建立共用世界坐标材质，颜色由正式昼夜预览入口统一更新。
func _make_material(fine: bool) -> ShaderMaterial:
	# 1. 两级网格共享相同采样资源和坐标，深度单位始终是米。
	var material := ShaderMaterial.new()
	material.shader = SNOW_SHADER
	material.set_shader_parameter("depth_grid",_textures[0])
	material.set_shader_parameter("base_grid",_textures[1])
	material.set_shader_parameter("fine_mesh",fine)
	return material


## 整数块坐标确定细节边界，相邻块直接共享世界采样点。
func _update_window() -> void:
	# 1. 人物位于中央16米块，外侧保留至少16米精细雪面。
	var at := player.global_position if player.is_inside_tree() else player.position
	var center := Vector2i(floori(at.x/TILE_SIZE),floori(at.z/TILE_SIZE))
	if center == detail_center:
		return
	var started := Time.get_ticks_usec()
	detail_center = center
	var start := Vector2(center-Vector2i.ONE)*TILE_SIZE
	detail_bounds = Vector4(start.x,start.y,start.x+48.0,start.y+48.0)
	# 2. 外边缘两米混合为远景面，内部边界没有高度或法线重置。
	for z in range(3):
		for x in range(3):
			_tiles[z*3+x].position = Vector3(start.x+x*TILE_SIZE+8.0,0,start.y+z*TILE_SIZE+8.0)
			# 细分增加后使用真实地形范围做剔除，边界81个基底节点覆盖所有三角面。
			var minimum := INF
			var maximum := -INF
			for iz in range(9):
				for ix in range(9):
					var height: float = terrain.get_ground_height(Vector2(start.x+x*TILE_SIZE+ix*2,start.y+z*TILE_SIZE+iz*2))
					minimum = minf(minimum,height)
					maximum = maxf(maximum,height)
			_tiles[z*3+x].custom_aabb = AABB(Vector3(-8,minimum-0.1,-8),Vector3(16,maximum-minimum+0.6,16))
	for material in [far_material,fine_material]:
		material.set_shader_parameter("detail_bounds",detail_bounds)
	window_moves += 1
	last_transition_ms = (Time.get_ticks_usec()-started)/1000.0


## 当前精细窗口供脚印缓存查询，不绑定输入设备或保存格式。
func get_detail_windows() -> Array[Vector4]:
	# 1. 原单人只返回一个窗口，脚印缓存不猜测角色或控制模式。
	return [detail_bounds]


## 双线性读取共享新雪厚度；输入为世界位置，不依赖当前加载块。
func get_fresh_depth_at(point: Vector3) -> float:
	# 1. 与着色器显式插值相同，负坐标使用floor，边界不镜像。
	var grid := (Vector2(point.x,point.z)-Vector2(manifest.origin[0],manifest.origin[1]))/float(manifest.step)
	var width := int(manifest.width)
	var x := clampi(floori(grid.x),0,width-2)
	var z := clampi(floori(grid.y),0,int(manifest.depth)-2)
	var u := clampf(grid.x-x,0,1)
	var v := clampf(grid.y-z,0,1)
	return lerpf(lerpf(depths[z*width+x],depths[z*width+x+1],u),lerpf(depths[(z+1)*width+x],depths[(z+1)*width+x+1],u),v)


## 返回新雪加当前有效形变的顶面，供瞄准和反馈使用。
func get_surface_height_at(point: Vector3) -> float:
	# 1. 形变有米制上下限；脚部固定压实支撑不因重踩无限下降。
	var offset: float = tracks.get_offset_at(point) if is_instance_valid(tracks) else 0.0
	return terrain.get_ground_height(Vector2(point.x,point.z))+maxf(0.004,get_fresh_depth_at(point)+offset)


## 返回压入后靴底支撑；松软深雪包住小腿，但真实碰撞基底始终保留。
func get_support_height_at(point: Vector3) -> float:
	# 1. 最多保留4.5厘米压实雪，避免整个角色被抬到深雪顶上。
	return terrain.get_ground_height(Vector2(point.x,point.z))+get_height_at(point)


## 兼容共享角色初始化所需的相对基底支撑偏移，不返回世界高度。
func get_height_at(point: Vector3) -> float:
	# 1. 此兼容接口只用于视觉偏移；世界落脚查询使用显式support接口。
	return minf(get_fresh_depth_at(point)*0.25,0.045)


## 深雪平滑降低移动速度，主路和屋前保持原2米每秒基准。
func get_speed_scale_at(point: Vector3) -> float:
	# 1. 从8厘米开始逐渐增加阻力，30厘米及以上保留58%速度。
	return 1.0-0.42*smoothstep(0.08,0.30,get_fresh_depth_at(point))


## 深处缩短真实距离周期，与脚骨前后行程使用同一比例。
func get_stride_at(point: Vector3) -> float:
	# 1. 每完整左右周期由72厘米缩为56厘米，不用独立定时器加快脚步。
	return lerpf(0.72,0.56,smoothstep(0.08,0.30,get_fresh_depth_at(point)))


## 共享顶面梯度法线，供瞄准环与接触检查使用。
func get_surface_normal_at(point: Vector3) -> Vector3:
	# 1. 采样间距与GPU法线一致，所有雪块沿用同一坐标。
	var e := 0.03125 if is_instance_valid(tracks) else 0.25
	return Vector3(get_surface_height_at(point-Vector3(e,0,0))-get_surface_height_at(point+Vector3(e,0,0)),2*e,
		get_surface_height_at(point-Vector3(0,0,e))-get_surface_height_at(point+Vector3(0,0,e))).normalized()


## 沿原相机射线求雪顶交点，避免只抬高Y导致准星偏离鼠标。
func intersect_surface(origin: Vector3, direction: Vector3, base_hit: Vector3) -> Vector3:
	# 深脚印侧壁使高度函数不再单调，先找射线上首个交点，不能只用牛顿迭代跳过边缘。
	if is_instance_valid(tracks):
		return _intersect_deformed_surface(origin,direction,base_hit)
	# 1. 基底命中给出近似距离；牛顿修正使用同一世界梯度。
	var distance := (base_hit-origin).dot(direction)
	for iteration in range(6):
		var point := origin+direction*distance
		var error := point.y-get_surface_height_at(point)
		var normal := get_surface_normal_at(point)
		var derivative := direction.dot(normal)/maxf(normal.y,0.1)
		if absf(derivative)<0.05:
			break
		distance -= clampf(error/derivative,-1.0,1.0)
	return origin+direction*distance


## 从基底前方建立区间，再按细节精度找首个穿入雪面的点并二分收敛。
func _intersect_deformed_surface(origin: Vector3, direction: Vector3, base_hit: Vector3) -> Vector3:
	# 1. 相机到物理基底之前都是有效搜索段；必要时向前扩大，覆盖坡面和挤雪边缘。
	var end := (base_hit-origin).dot(direction)
	var span := minf(1.0,end)
	var low := maxf(0,end-span)
	while low>0 and (origin+direction*low).y<=get_surface_height_at(origin+direction*low):
		span *= 2
		low = maxf(0,end-span)
	# 2. 2.5厘米步长小于痕迹像素，先命中前缘；后方凹槽不会吸走瞄准点。
	var previous := low
	var distance := low
	while distance<end:
		distance = minf(end,distance+0.025)
		var point := origin+direction*distance
		if point.y<=get_surface_height_at(point):
			# 3. 已有正负区间后再二分，避免陡峭侧壁上的梯度除零或跳到错误表面。
			var high := distance
			low = previous
			for iteration in range(12):
				var middle := (low+high)*0.5
				point = origin+direction*middle
				if point.y>get_surface_height_at(point):
					low = middle
				else:
					high = middle
			return origin+direction*((low+high)*0.5)
		previous = distance
	return base_hit


## 昼夜端点只改变材质颜色，不重置深度或细节窗口。
func set_palette(snow: Color, path: Color) -> void:
	# 1. 两级同时换色，避免远近边界出现不同配色。
	for material in [far_material,fine_material]:
		material.set_shader_parameter("snow_color",snow)
		material.set_shader_parameter("path_color",path)
