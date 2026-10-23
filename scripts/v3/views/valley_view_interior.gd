extends "res://scripts/buildings/valley_interior.gd"
## 逐视图显示副本；真实屋体、门、天气边界和树木碰撞始终只有一份。

signal view_interior_changed(view_id: String, building_id: StringName)

const VIEW_OUTLINE = preload("res://materials/v3/occluded_actor.gdshader")
const VIEW_LAYERS: Dictionary = {"view.p1": 2, "view.p2": 4}
const SHELL_PARTS: Array[String] = ["Roof", "Wall_Front", "Wall_Back", "Wall_East", "Wall_West", "DoorFrame", "Chimney"]
var _records: Dictionary = {}
var _views: Dictionary = {}
var _manager: Node
var _outlines: Dictionary = {}
var _refresh_queued: bool = false
var _refresh_age: float = 0.0
var _ray_age: float = 0.0


## 收集现有可编辑源的分组，不创建物理副本，也不使用旧固定朝向淡出。
func _ready() -> void:
	# 1. 四面墙都登记，旋到屋后仍能只淡出当前视线阻挡的那一侧。
	for cabin: Node3D in cabins:
		for part: String in SHELL_PARTS:
			var mesh := cabin.model.find_child(part, true, false) as MeshInstance3D
			if mesh != null:
				_register_mesh(mesh, "shell", cabin, part)
	# 2. 只在区域变化时补充新树，副本跟随原实例卸载。
	regions.region_loaded.connect(_queue_refresh)
	regions.region_unloaded.connect(_queue_refresh)
	_refresh_sources()


## 绑定两套角色／相机，内外状态不通过全局材质或一个共享布尔值传递。
func bind_views(manager: Node, registry: Node) -> void:
	# 1. 视图只保存本地关系，不参与世界快照。
	_manager = manager
	for id: String in manager.views:
		var binding: Dictionary = manager.views[id]
		_views[id] = {"rig": binding.rig, "actor": registry.slots[binding.actor_id].body,
			"actor_id": binding.actor_id, "cabin": null, "layer": binding.layer}
	# 2. 同一骨骼网格的边缘材质按当前相机渲染层选择，不复制动画角色。
	for actor_id: String in registry.slots:
		var material := ShaderMaterial.new()
		material.shader = VIEW_OUTLINE
		var meshes: Array[MeshInstance3D] = []
		for mesh: MeshInstance3D in registry.slots[actor_id].body.find_children("*", "MeshInstance3D", true, false):
			meshes.append(mesh)
		_outlines[actor_id] = {"material": material, "meshes": meshes, "actor": registry.slots[actor_id].body, "mask": 0}


## 保留原P1房间事件；P2相机单独计算房间，不修改P1的镜头或取暖状态。
func _physics_process(delta: float) -> void:
	# 1. 父类只运行房间事件，旧显示检测被本类空实现替代。
	super._physics_process(delta)
	sync_rooms()
	# 2. 实体射线只在物理帧查询；显示过渡在渲染帧消费这些结果。
	_ray_age -= delta
	if _ray_age <= 0:
		_ray_age = .1
		_update_outline_masks()


## 恢复与正常物理更新共用逐视图房间判断，不触发额外自动保存。
func sync_rooms() -> void:
	# 1. 该方法不改变世界P1 entered事件，只同步本地构图上下文。
	for id: String in _views:
		var view: Dictionary = _views[id]
		var next: Node3D = view.cabin
		if is_instance_valid(next) and not next.contains_interior(view.actor.position, true):
			next = null
		if not is_instance_valid(next):
			for cabin: Node3D in cabins:
				if cabin.contains_interior(view.actor.position):
					next = cabin
					break
		if view.cabin != next:
			view.cabin = next
			view_interior_changed.emit(id, StringName(next.get_meta("building_id")) if is_instance_valid(next) else &"")
		view.rig.interior_cabin = next


## 为每个相机独立计算遮挡，并在各自副本上渐变。
func _process(delta: float) -> void:
	# 1. LOD与昼夜仍由源实例管理，这里只同步共享网格和基础材质引用。
	_refresh_age -= delta
	if _refresh_age <= 0:
		_refresh_age = .1
		_sync_sources()
	for record: Dictionary in _records.values():
		var source: MeshInstance3D = record.source.get_ref()
		if not is_instance_valid(source):
			continue
		for id: String in VIEW_LAYERS:
			var copy: Dictionary = record.copies[id]
			var target := 1.0
			if _views.has(id) and _view_active(id):
				var view: Dictionary = _views[id]
				var near_actor: bool = source.global_position.distance_to(view.actor.global_position) < (25.0 if record.kind == "tree" else 32.0)
				var blocked: bool = near_actor and _mesh_blocks_actor(source, view.rig.camera, view.actor)
				if record.kind == "tree":
					target = .18 if blocked else 1.0
				elif (view.cabin == record.cabin.get_ref() and record.part in ["Roof", "Chimney"]) or blocked:
					target = 0.0
			copy.target = target
			var opacity := move_toward(float(copy.opacity), target, delta / (.22 if record.kind == "tree" else FADE_SECONDS))
			if opacity != copy.opacity or opacity < .9999:
				copy.opacity = opacity
				_fade.apply(copy.node, opacity)


## 只检测有限相机线段与头／躯干／脚部包络，忽略人物之后的几何。
func _mesh_blocks_actor(mesh: MeshInstance3D, camera: Camera3D, actor: Node3D) -> bool:
	# 1. 使用当前相机真实位置，360度旋转后不依赖前墙／东墙常量。
	var inverse := mesh.global_transform.affine_inverse()
	var box := mesh.get_aabb().grow(.04)
	var origin := inverse * camera.global_position
	for offset: Vector3 in [Vector3(0, 1.35, 0), Vector3(0, .8, 0), Vector3(.18, .06, 0)]:
		if box.intersects_segment(origin, inverse * (actor.global_position + offset)):
			return true
	return false


## 单个源网格仅创建两个轻量显示实例，材质淡出缓存按副本隔离。
func _register_mesh(source: MeshInstance3D, kind: String, cabin: Node3D = null, part: String = "") -> void:
	# 1. 原网格只保留一份真实世界阴影，副本不叠加阴影或物理形状。
	var key := source.get_instance_id()
	if _records.has(key):
		return
	var copies: Dictionary = {}
	for id: String in VIEW_LAYERS:
		var proxy := MeshInstance3D.new()
		proxy.name = "ViewP1" if id == "view.p1" else "ViewP2"
		proxy.set_meta("v3_view_proxy", true)
		proxy.mesh = source.mesh
		proxy.layers = VIEW_LAYERS[id]
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		source.add_child(proxy)
		for surface in range(source.mesh.get_surface_count()):
			proxy.set_surface_override_material(surface, source.get_active_material(surface))
		copies[id] = {"node": proxy, "opacity": 1.0, "target": 1.0}
	# 2. 不隐藏源节点，否则它的子副本也会被祖先可见性隐藏。
	source.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_records[key] = {"source": weakref(source), "kind": kind, "cabin": weakref(cabin) if cabin != null else null, "part": part, "copies": copies}


## 收集新驻留树，避免把自己的显示副本再次当作源生成副本。
func _refresh_sources() -> void:
	# 1. 所有新节点都来自现有环境模块；不改源模型或静态布局。
	_refresh_queued = false
	for region: Node3D in regions._resident.values():
		for asset: Node3D in region.get_children():
			if asset.get_meta("environment_category", "") == "tree":
				_register_mesh(asset.main_mesh, "tree")
	_sync_sources()


## 合并同帧区域信号，在最终驻留集合上刷新一次。
func _queue_refresh(_key: Vector2i) -> void:
	# 1. 卸载不持有源强引用，失效记录将在同步时清理。
	if not _refresh_queued:
		_refresh_queued = true
		call_deferred("_refresh_sources")


## 网格LOD切换时重绑副本表面，保持昼夜语义材质与原实例一致。
func _sync_sources() -> void:
	# 1. 失效源及其子副本已由区域释放，这里只删除索引。
	for key: int in _records.keys():
		var record: Dictionary = _records[key]
		var source: MeshInstance3D = record.source.get_ref()
		if not is_instance_valid(source):
			_records.erase(key)
			continue
		for copy: Dictionary in record.copies.values():
			var proxy: MeshInstance3D = copy.node
			if proxy.mesh != source.mesh:
				proxy.mesh = source.mesh
				for surface in range(source.mesh.get_surface_count()):
					proxy.set_surface_override_material(surface, source.get_active_material(surface))
	_fade.prune()


## 当前未显示的第二视图不产生淡出和角色轮廓状态。
func _view_active(id: String) -> bool:
	# 1. 绑定前不修改任何视图状态。
	return is_instance_valid(_manager) and (id == "view.p1" or _manager.split_enabled)


## 逐相机确认角色是否仍被门、家具、地形或未淡出的物体挡住。
func _update_outline_masks() -> void:
	# 1. 相机层位只控制边缘反馈，主体角色仍是同一副骨骼。
	for actor_id: String in _outlines:
		var row: Dictionary = _outlines[actor_id]
		var mask := 0
		for id: String in _views:
			if _view_active(id) and _actor_blocked_in_view(row.actor, id):
				mask |= VIEW_LAYERS[id]
		row.material.set_shader_parameter("occluded_view_mask", mask)
		if mask != row.mask:
			row.mask = mask
			for mesh: MeshInstance3D in row.meshes:
				if is_instance_valid(mesh):
					mesh.material_overlay = row.material if mask != 0 else null


## 隐藏外壳只在显示射线中跳过，真实枪口、人物和风雪查询仍会命中。
func _actor_blocked_in_view(actor: CharacterBody3D, id: String) -> bool:
	# 1. 另一名角色不能成为自身轮廓判定的遮挡源。
	var excluded: Array[RID] = []
	for row: Dictionary in _outlines.values():
		excluded.append(row.actor.get_rid())
	var camera: Camera3D = _views[id].rig.camera
	for height: float in [1.35, .8, .3]:
		var start := actor.global_position + Vector3.UP * height
		var direction := (camera.global_position - start).normalized()
		for attempt in range(24):
			var query := PhysicsRayQueryParameters3D.create(start, camera.global_position, 1, excluded)
			var hit := actor.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty():
				break
			if not _hit_is_hidden_shell(hit, id):
				return true
			start = hit.position + direction * .04
	return false


## 从真实碰撞形状语义确定它是否属于本视图已淡出的那面外壳。
func _hit_is_hidden_shell(hit: Dictionary, id: String) -> bool:
	# 1. 门和家具不会因属于同一小屋就被整屋排除。
	for cabin: Node3D in cabins:
		if hit.collider != cabin.structure:
			continue
		var body: CollisionObject3D = hit.collider
		var owner: Node = body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
		var label := String(owner.name)
		var part := ""
		if label.begins_with("Roof"):
			part = "Roof"
		elif label.begins_with("Chimney"):
			part = "Chimney"
		elif label.begins_with("FrontWindow"):
			part = "Wall_Front"
		else:
			for wall: String in ["Wall_Front", "Wall_Back", "Wall_East", "Wall_West"]:
				if label.begins_with(wall):
					part = wall
		if label.begins_with("SideWindow") or label.begins_with("TopPlate"):
			var at: Vector3 = cabin.to_local(hit.position)
			part = ("Wall_Front" if at.z > 0 else "Wall_Back") if absf(at.z) > float(cabin.manifest.footprint[1]) * .5 - .3 else ("Wall_East" if at.x > 0 else "Wall_West")
		if not part.is_empty():
			var mesh := cabin.model.find_child(part, true, false) as MeshInstance3D
			return mesh != null and _records.has(mesh.get_instance_id()) and _records[mesh.get_instance_id()].copies[id].target < .3
	return false


## 禁用父类固定朝向的物理显示检测，只保留其室内事件生命周期。
func _actor_is_physically_occluded() -> bool:
	# 1. 新版已在同一物理步中按视图计算轮廓。
	return false


## 调色继续刷新现有淡出副本，不改变另一视图的透明度。
func refresh_palette() -> void:
	# 1. 原材质颜色来自同一个昼夜来源，副本只保留独立alpha。
	_fade.refresh_colors()


## 保留旧单视图诊断接口，对应当前P1屋顶的实际副本透明度。
func shell_opacity(cabin: Node3D) -> float:
	# 1. 查询不改变任何显示或世界状态。
	return shell_opacity_for_view("view.p1", cabin)


## 提供逐视图功能证据，不将内部字段加入玩家HUD。
func shell_opacity_for_view(id: String, cabin: Node3D) -> float:
	# 1. 没有相应源网格时保持完整外壳语义。
	var mesh := cabin.model.find_child("Roof", true, false) as MeshInstance3D
	return float(_records[mesh.get_instance_id()].copies[id].opacity) if mesh != null and _records.has(mesh.get_instance_id()) else 1.0
