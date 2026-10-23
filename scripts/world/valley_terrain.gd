extends Node3D
## M2地形读取：离线分块网格与碰撞常驻，共享三角形查询；不在启动时生成高密雪面。

const LAYOUT = preload("res://scripts/world/valley_layout.gd")
const MANIFEST_PATH: String = "res://assets/terrain/v2/manifest.json"
var manifest: Dictionary = {}
var heights := PackedFloat32Array()
var ground_material: ShaderMaterial
var navigation_region: NavigationRegion3D
var load_ms: float = 0.0
@export var navigation_override: NavigationMesh


## 装入已生成的基底资源，缺失时明确失败，不退回一张假平面。
func _ready() -> void:
	# 1. 普通启动只读取资源；离线工具负责全局采样和导航生成。
	var started := Time.get_ticks_usec()
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_error("Missing M2 terrain. Run Godot --headless --path . --script res://tools/build_valley_terrain.gd")
		get_tree().quit(1)
		return
	manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	var file := FileAccess.open("res://assets/terrain/v2/height_grid.bin",FileAccess.READ)
	heights = file.get_buffer(file.get_length()).to_float32_array()
	file.close()
	ground_material = ShaderMaterial.new()
	ground_material.shader = preload("res://materials/valley_ground.gdshader")
	# 2. 同一网格生成的碰撞始终驻留，环境道具加载不能让地面消失。
	for chunk: Dictionary in manifest.chunks:
		var at := LAYOUT.ORIGIN + Vector2(chunk.x,chunk.z) * LAYOUT.CHUNK_SIZE
		var root := StaticBody3D.new()
		root.name = "Ground_%02d_%02d" % [int(chunk.x),int(chunk.z)]
		root.position = Vector3(at.x,0,at.y)
		var collision := CollisionShape3D.new()
		collision.shape = load(chunk.shape)
		root.add_child(collision)
		var visual := MeshInstance3D.new()
		visual.mesh = load(chunk.mesh)
		visual.material_override = ground_material
		root.add_child(visual)
		add_child(root)
	_create_boundaries()
	# 3. 只注册离线主走廊与门前支路，不同步烘焙整座山谷。
	navigation_region = NavigationRegion3D.new()
	navigation_region.name = "PreparedRouteNavigation"
	navigation_region.navigation_mesh = navigation_override if navigation_override!=null else load(manifest.navigation)
	add_child(navigation_region)
	load_ms = (Time.get_ticks_usec() - started) / 1000.0


## 返回与真实地形三角面一致的高度，M3可在此基底上叠加积雪查询。
func get_ground_height(point: Vector2) -> float:
	# 1. 转到共享格子，边界处使用最后一个有效单元。
	var grid := (point - LAYOUT.ORIGIN) / LAYOUT.GRID_STEP
	var width := int(manifest.width)
	var depth := int(manifest.depth)
	var x := clampi(floori(grid.x),0,width-2)
	var z := clampi(floori(grid.y),0,depth-2)
	var u := clampf(grid.x-x,0,1)
	var v := clampf(grid.y-z,0,1)
	var a := heights[z*width+x]
	var b := heights[z*width+x+1]
	var c := heights[(z+1)*width+x]
	var d := heights[(z+1)*width+x+1]
	# 2. 与网格同一条对角线插值，不用视觉抬高替代物理支撑。
	return a+(b-a)*u+(c-a)*v if u+v <= 1 else d+(c-d)*(1-u)+(b-d)*(1-v)


## 创建不可见物理边界，外侧仍留足地形延伸供斜相机取景。
func _create_boundaries() -> void:
	# 1. 边界高度覆盖山谷边缘高差，不修改地形查询或玩家速度。
	for entry in [
		[Vector3(-160,128,0),Vector3(0.6,256,384)],
		[Vector3(160,128,0),Vector3(0.6,256,384)],
		[Vector3(0,128,-192),Vector3(320,256,0.6)],
		[Vector3(0,128,192),Vector3(320,256,0.6)],
	]:
		var body := StaticBody3D.new()
		body.position = entry[0]
		var shape := BoxShape3D.new()
		shape.size = entry[1]
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		add_child(body)
