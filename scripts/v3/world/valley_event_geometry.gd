extends Node3D
## M11实体资产与同源碰撞；模型源中的平台面也供离线导航读取。

const DIRECTORY := "res://assets/models/v3/events/"
var world: Node3D
var layout: Dictionary
var bridge_manifest: Dictionary
var bridge_origin := Vector3.ZERO
var puzzle_origin := Vector3.ZERO
var targets: Dictionary = {}
var rotors: Array[Node3D] = []
var flags: Array[Node3D] = []
var lever: Node3D
var gate_body: StaticBody3D
var gate_open: float = 0.0
var bridge: Node3D


## 已生成的原生GLB直接装配，不在普通启动运行Blender或重烘焙导航。
func _ready() -> void:
	# 1. 每个摆件独立沿实际地形落地，旧树、石块、三屋与主路保留。
	layout = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY+"layout.json"))
	puzzle_origin = vector(layout.puzzle_origin)
	for index in range(3):
		var at := grounded(puzzle_origin+vector(layout.dial_offsets[index]))
		var plinth := instantiate_asset("dial_plinth",at)
		var rotor := instantiate_asset("dial_rotor",at+Vector3.UP*.76)
		rotors.append(rotor.root)
		_target("event.dial.%d" % index,"转动%s石盘" % ["左","中","右"][index],at+Vector3.UP*1.03,plinth.body)
	for index in range(2):
		var at := grounded(puzzle_origin+vector(layout.clues[index]))
		var clue := instantiate_asset("clue_left" if index == 0 else "clue_right",at)
		_target("event.clue.%d" % index,"观察石刻线索",at+Vector3.UP*1.02,clue.body)
	var lever_at := grounded(puzzle_origin+vector(layout.lever))
	var handle := instantiate_asset("puzzle_lever",lever_at)
	lever = handle.root.find_child("LeverHandle",true,false)
	_target("event.lever","拉动机关拉杆",lever_at+Vector3.UP*1.13,handle.body)
	# 2. 栈道和坡道的实际支撑高度来自同一个导出清单。
	bridge_manifest = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY+"wind_walkway_manifest.json"))
	bridge_origin = vector(bridge_manifest.world_origin)
	bridge = instantiate_asset("wind_walkway",bridge_origin).root
	for index in range(3):
		flags.append(bridge.find_child("Flag_%d" % index,true,false))
	var gate := instantiate_asset("mountain_gate",vector(layout.gate))
	var panel: Node3D = gate.root.find_child("GatePanel",true,false)
	gate_body = StaticBody3D.new()
	gate_body.name = "MovingGate"
	gate.root.add_child(gate_body)
	panel.reparent(gate_body)
	for record: Dictionary in gate.manifest.collisions:
		if record.get("dynamic") == "gate":
			add_collision(gate_body,record)
	_target("event.gate","查看山门锁扣",vector(layout.gate)+Vector3(2.8,1.0,1.05),gate.body)
	# 3. 路口指示使用既有原生木牌，文字只属于场景中的路牌。
	_sign(grounded(Vector3(-25,0,60)),"石刻遗迹 ←")
	_sign(grounded(Vector3(-13,0,-76)),"风口栈道 →")


## 实际碰撞与可见模型使用相同坐标，排除仅用于源文件编辑的线框。
func instantiate_asset(asset: String, at: Vector3) -> Dictionary:
	var record: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY+asset+"_manifest.json"))
	var root: Node3D = load(DIRECTORY+asset+".glb").instantiate()
	root.position = at
	add_child(root)
	var body := StaticBody3D.new()
	body.name = "EnvironmentStructure"
	root.add_child(body)
	for collision: Dictionary in record.collisions:
		if not collision.has("dynamic"):
			add_collision(body,collision)
	return {"root":root,"body":body,"manifest":record}


## 柱体、盒与坡道凸体都由原生源清单建立，物理查询不使用显示透明度。
func add_collision(parent: StaticBody3D, record: Dictionary) -> void:
	var node := CollisionShape3D.new()
	match String(record.kind):
		"box":
			var shape := BoxShape3D.new()
			shape.size = vector(record.size)
			node.shape = shape
			node.position = vector(record.at)
		"cylinder":
			var shape := CylinderShape3D.new()
			shape.radius = record.radius
			shape.height = record.height
			node.shape = shape
			node.position = vector(record.at)
		"convex":
			var shape := ConvexPolygonShape3D.new()
			var points := PackedVector3Array()
			for point: Array in record.points:
				points.append(vector(point))
			shape.points = points
			node.shape = shape
	parent.add_child(node)


## 锁扣解除后真实升起门板和碰撞，预检可直接恢复相同实体姿态。
func set_gate_fraction(value: float) -> void:
	gate_open = clampf(value,0,1)
	gate_body.position.y = gate_open*3.4


## 返回平台中心，三处中心都位于真实水平支撑和挡风板内侧。
func checkpoint(index: int) -> Vector3:
	return bridge_origin+vector(bridge_manifest.checkpoints[index])


## 原地落地查询供摆件装配使用，不改变任何玩家或AI位置。
func grounded(at: Vector3) -> Vector3:
	return Vector3(at.x,world.terrain.get_ground_height(Vector2(at.x,at.z)),at.z)


## 有限实体目标仍由各角色生存模块选择，靠近与提交时分别验距和视线。
func _target(id: String, label: String, at: Vector3, body: StaticBody3D) -> void:
	targets[id] = {"id":id,"site":"","kind":"event","name":label,"position":at,"reach":2.25,"body":body.get_rid()}


## 少量路牌给出支路方向，不在HUD常驻长篇任务说明。
func _sign(at: Vector3, message: String) -> void:
	var prop: Node3D = load("res://assets/models/v2/environment/way_sign.glb").instantiate()
	prop.position = at
	add_child(prop)
	var text := Label3D.new()
	text.text = message
	text.position = at+Vector3(0,1.65,0)
	text.font_size = 42
	text.pixel_size = .007
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.modulate = Color("e7f1ef")
	text.outline_modulate = Color("203641")
	text.no_depth_test = false
	add_child(text)


## 保存清单统一使用数值三元组，调用端不隐式转换未知数据。
static func vector(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])
