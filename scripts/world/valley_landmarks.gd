extends Node3D
## M7地标：保留三屋与地点ID，装配两类完整营地和少量沿路指向牌。

const ENVIRONMENT_ASSET=preload("res://scripts/world/valley_environment_asset.gd")

const CABIN_SCENES: Dictionary = {
	&"house.safe":preload("res://scenes/buildings/safe_cabin.tscn"),
	&"house.storage":preload("res://scenes/buildings/storage_cabin.tscn"),
	&"house.forest":preload("res://scenes/buildings/forest_cabin.tscn"),
}
var safe_cabin: Node3D
var cabins: Array[Node3D] = []
var cabins_by_id: Dictionary[StringName,Node3D] = {}
var terrain: Node3D
var register_object: Callable
var bind_palette: Callable
var site_nodes: Array[Node3D] = []
var sign_count: int = 0
var camps_by_id: Dictionary[StringName,Node3D] = {}
var catalogue: Dictionary


## 放置三屋两营地与路标，地标常驻保证入口ID不会随树林卸载消失。
func _ready() -> void:
	# 1. 每处地标来自同一个离线清单，高度沿用物理基底。
	catalogue=JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/v2/manifest.json"))
	for site: Dictionary in terrain.manifest.sites:
		_create_site(site)
	# 2. 路标沿真实弯路分布，既能前进也能识别返回安全屋方向。
	for record: Dictionary in catalogue.route_signs:
		var sign_root: Node3D=ENVIRONMENT_ASSET.new()
		sign_root.asset_name=&"way_sign"
		sign_root.position=Vector3(record.position[0],record.position[1],record.position[2])
		sign_root.rotation.y=float(record.yaw)
		add_child(sign_root)
		_add_label(sign_root,"沿路：%s\n返程：%s" % [record.forward,record.backward],Vector3(0,2.7,0),19)
		bind_palette.call(sign_root)
		register_object.call(StringName(record.id),sign_root)
		sign_count += 1


## 按原位置装配三屋和两处营地，地形／入口与稳定ID保持。
func _create_site(site: Dictionary) -> void:
	# 1. 已确认的位置与稳定ID保持不变，不用重排山谷来容纳新房屋。
	var root := Node3D.new()
	root.name = String(site.id).replace(".","_")
	root.position = Vector3(site.position[0],site.position[1],site.position[2])
	root.set_meta("placeholder",false)
	add_child(root)
	register_object.call(StringName(site.id),root)
	site_nodes.append(root)
	if site.kind == "house":
		var building_id := StringName(site.id)
		assert(CABIN_SCENES.has(building_id), "Missing cabin asset for "+String(building_id))
		var cabin: Node3D = CABIN_SCENES[building_id].instantiate()
		cabin.set_meta("building_id",building_id)
		cabin.set_meta("display_name",String(site.label))
		root.add_child(cabin)
		cabins.append(cabin)
		cabins_by_id[building_id] = cabin
		if building_id == &"house.safe":
			safe_cabin = cabin
	else:
		# 2. 木棚／篷布、石圈、原木坐凳、木柴和物资箱都有独立源碰撞，火塘仍未点燃。
		var camp: Node3D=ENVIRONMENT_ASSET.new()
		camp.asset_name=StringName(catalogue.camps[String(site.id)].asset)
		camp.set_meta("camp_id",StringName(site.id))
		root.add_child(camp)
		camps_by_id[StringName(site.id)]=camp
	bind_palette.call(root)
	# 3. 原入口坐标保留给移动与导航；正式环境不再显示开发占位光圈。


## 创建小样盒形道具，细小路标与营地石块可选真实碰撞。
func _add_box(parent: Node3D, at: Vector3, size: Vector3, semantic: String, solid: bool) -> void:
	# 1. 为通用配色绑定器保留语义名，不保存回原模型材质。
	var source := StandardMaterial3D.new()
	source.resource_name = semantic
	var box := BoxMesh.new()
	box.size = size
	box.material = source
	var visual := MeshInstance3D.new()
	visual.mesh = box
	visual.position = at
	parent.add_child(visual)
	# 2. 碰撞包络与当前可见盒一致，没有用覆盖整片营地的隐形墙。
	if solid:
		var body := StaticBody3D.new()
		body.position = at
		var shape := BoxShape3D.new()
		shape.size = size
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		parent.add_child(body)


## 添加面向相机的地点提示，区分正式地点用途与当前占位状态。
func _add_label(parent: Node3D, text: String, at: Vector3, font_size: int) -> void:
	# 1. 位置线索使用世界坐标，不能把远处地标当作已经到达。
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.font_size = font_size
	label.pixel_size = 0.009
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color("eef7ff")
	label.outline_modulate = Color("203850")
	label.outline_size = 5
	parent.add_child(label)
