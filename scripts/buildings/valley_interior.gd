extends Node
## M6室内状态、可见性与遮蔽接口；取暖、天气模拟与保存由后续模块订阅。

signal entered(building_id: StringName)
signal exited(building_id: StringName)
signal interior_changed(previous_id: StringName,current_id: StringName)

const FADE = preload("res://scripts/buildings/occlusion_fade.gd")
const OUTLINE = preload("res://materials/occluded_actor.gdshader")
const FADE_SECONDS: float = 0.32
const NEAR_PARTS: Array[String] = ["Roof","Wall_Front","Wall_East","DoorFrame","Chimney"]
var player: CharacterBody3D
var camera_rig: Node3D
var regions: Node3D
var cabins: Array[Node3D] = []
var current_cabin: Node3D
var automatic_enabled: bool = true
var _fade = FADE.new()
var _shells: Dictionary[int,Array] = {}
var _opacities: Dictionary[int,float] = {}
var _trees: Array[MeshInstance3D] = []
var _tree_opacities: Dictionary[int,float] = {}
var _tree_targets: Dictionary[int,bool] = {}
var _tree_timer: float = 0.0
var _tree_refresh_queued: bool = false
var _outline: ShaderMaterial
var _actor_meshes: Array[MeshInstance3D] = []
var _outline_active: bool = false
var _physical_occlusion: bool = false
var _occlusion_timer: float = 0.0


## 只收集固定朝向的近侧外壳，远墙、门和全部家具保持原不透明显示。
func _ready() -> void:
	# 1. 三屋源分组已经验收，不修改GLB或原Blender文件。
	for cabin: Node3D in cabins:
		var meshes: Array[MeshInstance3D] = []
		for part: String in NEAR_PARTS:
			var mesh := cabin.model.find_child(part,true,false) as MeshInstance3D
			if mesh!=null:
				meshes.append(mesh)
		_shells[cabin.get_instance_id()]=meshes
		_opacities[cabin.get_instance_id()]=1.0
	# 2. 只有外部遮挡确认后才挂人物边缘剪影，不让自身表面触发或透化家具。
	_outline=ShaderMaterial.new()
	_outline.resource_name="M6OccludedActorSilhouette"
	_outline.shader=OUTLINE
	for mesh: MeshInstance3D in player.find_children("*","MeshInstance3D",true,false):
		_actor_meshes.append(mesh)
	# 3. 只在区域变化时重建候选树集合，卸载节点由弱引用缓存清理。
	regions.region_loaded.connect(_queue_tree_refresh)
	regions.region_unloaded.connect(_queue_tree_refresh)
	_refresh_trees()


## 物理位移后判定房间事件；暂停时随场景树冻结。
func _physics_process(delta: float) -> void:
	# 1. 独立M5模型检视明确禁用自动控制，不争夺手动检视外壳。
	if not automatic_enabled:
		return
	var next: Node3D = current_cabin
	if is_instance_valid(next) and not next.contains_interior(player.global_position,true):
		next=null
	if not is_instance_valid(next):
		for cabin: Node3D in cabins:
			if cabin.contains_interior(player.global_position):
				next=cabin
				break
	# 2. 状态提交后再发信号；重复门槛采样不重复进入，也不自行取暖或存档。
	if next!=current_cabin:
		var previous_id := current_id()
		current_cabin=next
		camera_rig.interior_cabin=current_cabin
		var next_id := current_id()
		if previous_id!=&"":exited.emit(previous_id)
		if next_id!=&"":entered.emit(next_id)
		interior_changed.emit(previous_id,next_id)
	# 3. 物理空间查询只在物理帧执行；显示层每帧消费缓存结果。
	_occlusion_timer-=delta
	if _occlusion_timer<=0.0:
		_occlusion_timer=0.1
		_physical_occlusion=_actor_is_physically_occluded()


## 渐变只修改网格实例；门、墙、屋顶和家具的物理形状始终保留。
func _process(delta: float) -> void:
	# 1. 0.32秒单调淡出／恢复，反向穿门从当前进度继续，不新建Tween叠加。
	if not automatic_enabled:
		return
	for cabin: Node3D in cabins:
		var id := cabin.get_instance_id()
		var target := 0.0 if cabin==current_cabin else 1.0
		var opacity := move_toward(_opacities[id],target,delta/FADE_SECONDS)
		if opacity!=_opacities[id]:
			_opacities[id]=opacity
			for mesh: MeshInstance3D in _shells[id]:_fade.apply(mesh,opacity)
	# 2. 前景树只做保守视线包络检测，碰撞与布局仍由原区域模块管理。
	_tree_timer-=delta
	if _tree_timer<=0.0:
		_tree_timer=0.1
		_update_tree_targets()
	for mesh: MeshInstance3D in _trees:
		if not is_instance_valid(mesh):continue
		var id := mesh.get_instance_id()
		var previous: float = _tree_opacities.get(id,1.0)
		var target := 0.18 if _tree_targets.get(id,false) else 1.0
		var opacity := move_toward(previous,target,delta/0.22)
		if opacity!=previous or opacity<0.9999:
			_tree_opacities[id]=opacity
			_fade.apply(mesh,opacity)


## 发布稳定房间ID，供天气、取暖与自动保存订阅，空值表示户外。
func current_id() -> StringName:
	# 1. 不暴露节点路径或运行时实例号作为持久身份。
	return StringName(current_cabin.get_meta("building_id")) if is_instance_valid(current_cabin) else &""


## 查询实际位置的遮蔽；与外壳透明度、进入迟滞和炉子暖色材质无关。
func shelter_at(at: Vector3) -> Dictionary:
	# 1. 门口过渡带不会因为显示状态尚未恢复而获得完整天气遮蔽。
	for cabin: Node3D in cabins:
		if cabin.shelters_point(at):
			return {"building_id":StringName(cabin.get_meta("building_id")),"weather_sheltered":true,"precipitation_exposure":0.0,"wind_exposure":0.0}
	# 2. 只提供M8／M9消费的状态，不在M6改变体温、燃料或世界时间。
	return {"building_id":&"","weather_sheltered":false,"precipitation_exposure":1.0,"wind_exposure":1.0}


## 诊断读取实际外壳进度，技术参数不进入正式玩家状态栏。
func shell_opacity(cabin: Node3D) -> float:
	# 1. 未装配的实例默认为完整外壳，不改变它的可见性。
	return _opacities.get(cabin.get_instance_id(),1.0)


## 昼夜端点或未来时钟调色后刷新活动淡出副本。
func refresh_palette() -> void:
	# 1. 静止在半透明前景树后的角色也能看到新的配色，无需再走一步。
	_fade.refresh_colors()


## 区域变化后更新候选集合，并清除已卸载的材质缓存。
func _refresh_trees() -> void:
	# 1. 多个加载信号可以在同一帧合并；集合只引用当前驻留网格。
	_tree_refresh_queued=false
	_trees.clear()
	for region: Node3D in regions.get("_resident").values():
		for asset: Node3D in region.get_children():
			if String(asset.get_meta("environment_category","tree"))!="tree":continue
			for mesh: MeshInstance3D in asset.find_children("*","MeshInstance3D",true,false):
				_trees.append(mesh)
	var live: Dictionary[int,bool] = {}
	for mesh: MeshInstance3D in _trees:live[mesh.get_instance_id()]=true
	for id: int in _tree_opacities.keys():
		if not live.has(id):_tree_opacities.erase(id)
	_fade.prune()
	_tree_timer=0.0


## 同帧多个区域信号只排队一次候选重建，避免跨区峰值重复扫描。
func _queue_tree_refresh(_key: Vector2i) -> void:
	# 1. deferred执行时区域的装卸已完成，使用最终驻留集合。
	if not _tree_refresh_queued:
		_tree_refresh_queued=true
		call_deferred("_refresh_trees")


## 检测相机到人物头／胸的前景树包络，忽略远树与人物之后的树。
func _update_tree_targets() -> void:
	# 1. 相机朝向固定，使用三条有限线段覆盖头部和躯干，不扫描全地图树记录。
	_tree_targets.clear()
	# queue_free在延迟调用后结束，周期性清除上一帧刚释放的弱引用。
	_fade.prune()
	var origin: Vector3 = camera_rig.camera.global_position
	var blocked := _physical_occlusion
	for mesh: MeshInstance3D in _trees:
		if not is_instance_valid(mesh) or mesh.global_position.distance_to(player.global_position)>20.0:continue
		var inverse := mesh.global_transform.affine_inverse()
		var box := mesh.get_aabb().grow(0.06)
		for offset in [Vector3(0,1.35,0),Vector3(0,0.8,0),Vector3(0.18,1.1,0)]:
			if box.intersects_segment(inverse*origin,inverse*(player.global_position+offset)):
				_tree_targets[mesh.get_instance_id()]=true
				blocked=true
				break
	# 2. 只有受外部物体遮挡时创建额外绘制，无遮挡时完全移除覆盖材质。
	_outline.set_shader_parameter("externally_occluded",blocked)
	if blocked!=_outline_active:
		_outline_active=blocked
		for mesh: MeshInstance3D in _actor_meshes:
			mesh.material_overlay=_outline if blocked else null


## 用真实头／胸视线确认门、家具或墙的外部遮挡，排除人物自身。
func _actor_is_physically_occluded() -> bool:
	# 1. 隐藏外壳的物理碰撞仍存在，仅在本项显示检测中跳过；其他物理查询照常阻挡。
	var excluded: Array[RID] = [player.get_rid()]
	var camera_at: Vector3 = camera_rig.camera.global_position
	for height: float in [1.35,0.8,0.3]:
		var start: Vector3 = player.global_position+Vector3.UP*height
		var direction: Vector3 = (camera_at-start).normalized()
		for attempt in range(12):
			var query := PhysicsRayQueryParameters3D.create(start,camera_at,1,excluded)
			var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty():break
			var hidden_shell := false
			if is_instance_valid(current_cabin) and hit.collider==current_cabin.structure:
				var body: CollisionObject3D = hit.collider
				var shape_node: Node = body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
				for prefix in ["Roof","Wall_Front","Wall_East","FrontWindow","EastWindow","SideWindow","TopPlate","Chimney"]:
					if String(shape_node.name).begins_with(prefix):hidden_shell=true;break
			if not hidden_shell:return true
			# 2. 仅向前跳过已隐藏的命中表面，不排除整屋，以免连家具也漏掉。
			start=hit.position+direction*0.04
	return false
