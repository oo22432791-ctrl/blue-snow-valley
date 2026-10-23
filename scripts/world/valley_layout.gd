extends RefCounted
## M2稳定布局：米制世界坐标、弯曲主路线、三屋两营地与留白，不决定M5房屋造型。

const ORIGIN: Vector2 = Vector2(-224.0, -256.0)
const WORLD_SIZE: Vector2 = Vector2(448.0, 512.0)
const PLAY_MIN: Vector2 = Vector2(-160.0, -192.0)
const PLAY_MAX: Vector2 = Vector2(160.0, 192.0)
const CHUNK_SIZE: float = 32.0
const GRID_STEP: float = 2.0
const ROAD_HALF_WIDTH: float = 4.0
const SNOWBALL_CLEARING: Rect2 = Rect2(-98.0, 155.0, 20.0, 16.0)
const ROUTE_CONTROLS: Array[Vector3] = [
	Vector3(-100, 1, 150), Vector3(-85, 1.5, 100), Vector3(-30, 2.6, 65),
	Vector3(5, 5.2, 10), Vector3(-40, 4.5, -45), Vector3(10, 7.5, -90),
	Vector3(70, 9, -120), Vector3(115, 12, -170),
]
const SITES: Array[Dictionary] = [
	{"id":"house.safe", "label":"安全小屋", "kind":"house", "position":Vector2(-106,150), "entry":Vector2(-106,153.5)},
	{"id":"house.storage", "label":"储物屋", "kind":"house", "position":Vector2(-36,64), "entry":Vector2(-36,67.5)},
	{"id":"house.forest", "label":"林间小屋", "kind":"house", "position":Vector2(64,-122), "entry":Vector2(64,-118.5)},
	{"id":"camp.west", "label":"溪弯营地", "kind":"camp", "position":Vector2(11,12), "entry":Vector2(8,13)},
	{"id":"camp.east", "label":"北坡营地", "kind":"camp", "position":Vector2(16,-88), "entry":Vector2(13,-87)},
]
const WOODS: Array[Dictionary] = [
	{"id":"woods.south", "label":"南侧疏林", "center":Vector2(-72,103), "radius":30.0},
	{"id":"woods.bend", "label":"山弯林区", "center":Vector2(-35,-27), "radius":30.0},
	{"id":"woods.north", "label":"北侧树林", "center":Vector2(65,-113), "radius":36.0},
]

var route: PackedVector3Array


## 把控制点转为平滑路线，所有地形、道路、导航和测试读取同一采样。
func _init() -> void:
	# 1. 内点以相邻方向建立切线，端点不产生额外闭环。
	var curve := Curve3D.new()
	curve.bake_interval = 2.0
	for index in range(ROUTE_CONTROLS.size()):
		var previous := ROUTE_CONTROLS[maxi(index - 1, 0)]
		var following := ROUTE_CONTROLS[mini(index + 1, ROUTE_CONTROLS.size() - 1)]
		var tangent := (following - previous) * 0.16
		curve.add_point(ROUTE_CONTROLS[index], -tangent, tangent)
	# 2. 烘焙只发生在小型曲线数据中，不在运行时烘焙全场导航。
	route = curve.get_baked_points()


## 查询到主路线的最近距离、高度及段号，供离线地形与稳定地标共用。
func closest_route(point: Vector2) -> Dictionary:
	# 1. 使用水平距离匹配段，避免坡度影响道路宽度。
	var best_squared := INF
	var result: Dictionary = {}
	for index in range(route.size() - 1):
		var a := Vector2(route[index].x, route[index].z)
		var b := Vector2(route[index + 1].x, route[index + 1].z)
		var along := clampf((point - a).dot(b - a) / maxf((b - a).length_squared(), 0.0001), 0.0, 1.0)
		var nearest := a.lerp(b, along)
		var squared := point.distance_squared_to(nearest)
		if squared < best_squared:
			best_squared = squared
			result = {"distance":sqrt(squared), "height":lerpf(route[index].y, route[index + 1].y, along), "segment":index, "point":nearest}
	# 2. 结果保留原路线段号，不用场景节点顺序作为持久身份。
	return result


## 离线生成山谷基底；路旁缓坡、外侧山脊和地标平台有连续过渡。
func design_height(point: Vector2) -> float:
	# 1. 主路线纵向起伏来自控制点，远离路线后抬升为山谷两侧。
	var near := closest_route(point)
	var distance: float = near.distance
	var hill := pow(maxf(distance - 12.0, 0.0) / 35.0, 1.45) * 5.0
	var variation := sin(point.x * 0.055) * cos(point.y * 0.035) * 1.5 + sin(point.y * 0.08 + point.x * 0.025) * 0.7
	var height: float = near.height + hill + variation * smoothstep(ROAD_HALF_WIDTH, 17.0, distance)
	# 2. 小屋与营地周围留出低坡平台，门前支路不会落在陡坡上。
	for site in SITES:
		var at: Vector2 = site.position
		var pad_weight := 1.0 - smoothstep(6.0, 12.0, point.distance_to(at))
		if pad_weight > 0.0:
			height = lerpf(height, float(closest_route(at).height), pad_weight)
	# 3. 安全屋附近留出20×16米活动空地，不据此提前开启雪球比赛。
	var clearing_center := SNOWBALL_CLEARING.get_center()
	var outside := (point - clearing_center).abs() - SNOWBALL_CLEARING.size * 0.5
	var clearing_weight := 1.0 - smoothstep(0.0, 7.0, maxf(outside.x, outside.y))
	return lerpf(height, 1.0, clearing_weight)


## 返回平地区域键，供道具驻留、雪面块与持久ID共享世界坐标。
func region_at(point: Vector2) -> Vector2i:
	# 1. 先减统一原点再向下取整，负坐标不会镜像或跳到相邻块。
	return Vector2i(floori((point.x - ORIGIN.x) / CHUNK_SIZE), floori((point.y - ORIGIN.y) / CHUNK_SIZE))
