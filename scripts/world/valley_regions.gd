extends Node3D
## M7环境驻留：保留M2区域与树ID，装配完整树／道具并按人物距离切换树几何。

signal region_loaded(key: Vector2i)
signal region_unloaded(key: Vector2i)

const LAYOUT = preload("res://scripts/world/valley_layout.gd")
const ASSET = preload("res://scripts/world/valley_environment_asset.gd")
const ACTIVE_RADIUS: int = 2
const RETAIN_RADIUS: int = 3
var terrain: Node3D
var player: CharacterBody3D
var register_object: Callable
var bind_palette: Callable
var current_region: Vector2i = Vector2i(-999,-999)
var _records: Dictionary[Vector2i,Array] = {}
var _resident: Dictionary[Vector2i,Node3D] = {}
var load_count: int = 0
var unload_count: int = 0
var max_resident_regions: int = 0
var last_transition_ms: float = 0.0
var catalogue: Dictionary
var _detail_timer: float = 0.0


## 按稳定区域键索引道具记录，普通区域进入不再生成随机布局。
func _ready() -> void:
	# 1. 数据读取自离线清单，位置与ID不依赖节点创建顺序。
	catalogue=JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/v2/manifest.json"))
	for record: Dictionary in terrain.manifest.trees:
		var converted: Dictionary=record.duplicate()
		var replacement: Dictionary=catalogue.tree_overrides[String(record.id)]
		converted["asset"]=replacement.asset
		converted["yaw"]=replacement.yaw
		_index_record(converted)
	for record: Dictionary in catalogue.props:
		_index_record(record)
	# 2. 初始加载覆盖相机外两圈，不等人物抵达边界才创建碰撞。
	update_regions()


## 将树和外部道具分到同一32米驻留键，不改原地形和地点数据。
func _index_record(record: Dictionary) -> void:
	# 1. 显式稳定ID可跨区域重载，坐标仅来自已保存清单。
	var key := Vector2i(int(record.region[0]),int(record.region[1]))
	if not _records.has(key):_records[key]=[]
	_records[key].append(record)


## 只在玩家跨区域时更新，避免每帧重建树木或导航。
func _process(delta: float) -> void:
	# 1. 暂停随场景树冻结，玩家位置不动时不重复做资源工作。
	update_regions()
	# 2. LOD按人物水平距离低频更新；近脚雪面和输入不等待这项视觉工作。
	_detail_timer-=delta
	if _detail_timer<=0.0:
		_detail_timer=.25
		for root: Node3D in _resident.values():
			for asset: Node3D in root.get_children():
				asset.update_detail(Vector2(asset.global_position.x-player.global_position.x,asset.global_position.z-player.global_position.z).length())


## 维护5×5活动邻域和更大的退出圈，快速折返不立即卸载重建。
func update_regions() -> void:
	# 1. 所有负坐标通过统一原点向下取整，跨块前后坐标不改变。
	var point := Vector2(player.position.x,player.position.z)
	var key := Vector2i(floori((point.x-LAYOUT.ORIGIN.x)/32.0),floori((point.y-LAYOUT.ORIGIN.y)/32.0))
	if key == current_region:
		return
	var started := Time.get_ticks_usec()
	current_region = key
	for z in range(key.y-ACTIVE_RADIUS,key.y+ACTIVE_RADIUS+1):
		for x in range(key.x-ACTIVE_RADIUS,key.x+ACTIVE_RADIUS+1):
			var candidate := Vector2i(x,z)
			if x < 0 or x >= 14 or z < 0 or z >= 16 or _resident.has(candidate):
				continue
			_load_region(candidate)
	# 2. 已离开画面的邻圈先保留，仅超过3块才卸载；地面不受此逻辑影响。
	for old_key in _resident.keys():
		if maxi(absi(old_key.x-key.x),absi(old_key.y-key.y)) > RETAIN_RADIUS:
			_resident[old_key].queue_free()
			_resident.erase(old_key)
			unload_count += 1
			region_unloaded.emit(old_key)
	max_resident_regions = maxi(max_resident_regions,_resident.size())
	last_transition_ms = (Time.get_ticks_usec()-started)/1000.0


## 将某块道具实例化并注册原ID，避免区域回归产生全新持久身份。
func _load_region(key: Vector2i) -> void:
	# 1. 区域根承载道具生命周期，树木自身仍使用完整原GLB实例。
	var root := Node3D.new()
	root.name = "Props_%02d_%02d" % [key.x,key.y]
	add_child(root)
	_resident[key] = root
	for record: Dictionary in _records.get(key,[]):
		var asset: Node3D=ASSET.new()
		asset.asset_name=StringName(record.asset)
		asset.position=Vector3(record.position[0],record.position[1],record.position[2])
		asset.rotation.y=float(record.get("yaw",0))
		asset.scale=Vector3.ONE*float(record.scale)
		root.add_child(asset)
		bind_palette.call(asset)
		asset.update_detail(Vector2(asset.global_position.x-player.global_position.x,asset.global_position.z-player.global_position.z).length())
		register_object.call(StringName(record.id),asset)
	load_count += 1
	region_loaded.emit(key)


## 返回驻留与LOD计数，供性能证据使用，不改变正式玩家HUD。
func get_environment_statistics() -> Dictionary:
	# 1. 只统计已装配节点，不把全图目录记录当作当前内存负载。
	var near_trees := 0
	var far_trees := 0
	var props := 0
	for root: Node3D in _resident.values():
		for asset: Node3D in root.get_children():
			if String(asset.manifest.category)=="tree":
				if asset.far_detail:far_trees+=1
				else:near_trees+=1
			else:props+=1
	return {"resident_regions":_resident.size(),"near_trees":near_trees,"far_trees":far_trees,"props":props,"last_transition_ms":last_transition_ms}
