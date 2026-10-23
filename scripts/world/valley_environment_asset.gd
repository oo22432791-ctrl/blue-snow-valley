extends Node3D
## M7米制环境资产：独立源清单碰撞、共享语义调色与近／远网格切换。

static var _scenes: Dictionary[StringName,PackedScene] = {}
static var _manifests: Dictionary[StringName,Dictionary] = {}
static var _materials: Dictionary[StringName,StandardMaterial3D] = {}
static var _active_palette: Resource
var asset_name: StringName
var manifest: Dictionary
var model: Node3D
var main_mesh: MeshInstance3D
var structure: StaticBody3D
var far_detail: bool = false
var detail_swaps: int = 0
var _near: Mesh
var _far: Mesh
var _palette: Resource


## 仅装配指定源资产，碰撞与可见几何从同一清单读取。
func _ready() -> void:
	# 1. PackedScene与清单按类型缓存，区域实例不重复读取文件或复制网格。
	var base := "res://assets/models/v2/environment/"+String(asset_name)
	if not _scenes.has(asset_name):
		_scenes[asset_name]=load(base+".glb")
		_manifests[asset_name]=JSON.parse_string(FileAccess.get_file_as_string(base+"_manifest.json"))
	manifest=_manifests[asset_name]
	set_meta("environment_category",String(manifest.category))
	model=_scenes[asset_name].instantiate()
	add_child(model)
	main_mesh=model.find_child("Near",true,false) as MeshInstance3D
	assert(main_mesh!=null,"Missing M7 Near mesh")
	_near=main_mesh.mesh
	var far_node := model.find_child("Far",true,false) as MeshInstance3D
	if far_node!=null:
		_far=far_node.mesh
		# 2. 只保留一个实际渲染节点，LOD不额外产生遮挡检测候选或双层重叠。
		far_node.get_parent().remove_child(far_node)
		far_node.free()
	structure=StaticBody3D.new()
	structure.name="EnvironmentStructure"
	add_child(structure)
	for record: Dictionary in manifest.collisions:
		_add_collision(record)


## 基于人物水平距离切换共享网格，使用25／34米迟滞避免边界来回跳。
func update_detail(distance: float) -> void:
	# 1. 只有带远景网格的树参与；碰撞体与节点身份始终不变。
	if _far==null:return
	var desired := far_detail
	if distance>34.0:desired=true
	elif distance<25.0:desired=false
	if desired==far_detail:return
	# 2. 不继承旧网格的表面编号；每个LOD都按自己的语义表重新绑定。
	for index in range(main_mesh.mesh.get_surface_count()):main_mesh.set_surface_override_material(index,null)
	far_detail=desired
	main_mesh.mesh=_far if far_detail else _near
	detail_swaps+=1
	if _palette!=null:_bind_materials()


## 将环境专属材质语义映射到现有昼夜配色，原GLB不被改写。
func apply_environment_palette(palette: Resource) -> void:
	# 1. 同类表面共享基础材质；遮挡淡出只复制当前实例需要的副本。
	_palette=palette
	if _active_palette!=palette:update_shared_palette(palette)
	_bind_materials()


## 全世界每次调色只更新一套共享基础材质，LOD使用当前颜色而非旧实例快照。
static func update_shared_palette(palette: Resource) -> void:
	# 1. 色彩角色独立于网格表面顺序，新增／切换LOD不会串到其他颜色。
	_active_palette=palette
	var colors: Dictionary={"timber":palette.wood,"boards":palette.wall,
		"bark":palette.wood.lightened(.13),"bark_light":palette.snow.lerp(palette.wall,.35),
		"twig":palette.wood.lightened(.04),"cutwood":palette.wall.lightened(.23),
		"needle":palette.roof.lerp(palette.wall,.32),"snow":palette.snow,
		"stone":palette.shadow.lerp(palette.wall,.38),"stone_light":palette.shadow.lightened(.14),
		"iron":palette.roof.darkened(.08),"linen":palette.snow.lerp(palette.wall,.38),"coal":palette.roof.darkened(.22)}
	for role: StringName in colors:
		if not _materials.has(role):
			var material := StandardMaterial3D.new()
			material.resource_name="env_"+String(role)
			material.roughness=.9
			material.cull_mode=BaseMaterial3D.CULL_DISABLED
			_materials[role]=material
		_materials[role].albedo_color=colors[role]


## 给当前网格的每个表面按名字绑定材质，不假定远近LOD角色数相等。
func _bind_materials() -> void:
	# 1. 原始资源始终只读，昼夜与淡出修改的是运行时材质。
	for index in range(main_mesh.mesh.get_surface_count()):
		var source: Material=main_mesh.mesh.surface_get_material(index)
		var role := StringName(String(source.resource_name).trim_prefix("env_"))
		assert(_materials.has(role),"Unknown M7 palette role: "+String(role))
		main_mesh.set_surface_override_material(index,_materials[role])


## 构建有意简化的盒、树干圆柱或真实凸壳，细枝和绳索不造成隐形封路。
func _add_collision(record: Dictionary) -> void:
	# 1. 形状在源文件有对应线框，可继续手改重导出。
	var collision := CollisionShape3D.new()
	collision.name=String(record.name)+"_%d" % structure.get_child_count()
	match String(record.kind):
		"box":
			var shape := BoxShape3D.new()
			shape.size=_vector(record.size)
			collision.shape=shape
			collision.position=_vector(record.at)
		"cylinder":
			var shape := CylinderShape3D.new()
			shape.radius=float(record.radius)
			shape.height=float(record.height)
			collision.shape=shape
			collision.position=_vector(record.at)
		_:
			var shape := ConvexPolygonShape3D.new()
			var points := PackedVector3Array()
			for point: Array in record.points:points.append(_vector(point))
			shape.points=points
			collision.shape=shape
	# 2. 渲染LOD、树淡化与昼夜调色均不改变本物理节点。
	structure.add_child(collision)


## 显式转换清单XYZ米制坐标，不用模型包络代替碰撞。
func _vector(value: Array) -> Vector3:
	# 1. Blender到Godot的坐标转换已在导出阶段完成。
	return Vector3(float(value[0]),float(value[1]),float(value[2]))
