extends RefCounted
## M6实例淡出缓存：过渡用Alpha Hash，端点恢复原材质和阴影，不改变物理节点。

var _records: Dictionary[int,Dictionary] = {}


## 缓存每个网格原材质；家具和其他房屋不会共享淡出副本。
func apply(mesh: MeshInstance3D, opacity: float) -> void:
	# 1. 每个实例／表面只复制一次材质，避免过渡期间逐帧创建资源。
	var id := mesh.get_instance_id()
	if not _records.has(id) or _records[id].mesh_resource!=mesh.mesh:
		var originals: Array[Material] = []
		var faded: Array[StandardMaterial3D] = []
		for index in range(mesh.mesh.get_surface_count()):
			var original := mesh.get_active_material(index) as StandardMaterial3D
			assert(original != null,"M6 fade requires the existing standard palette material")
			originals.append(original)
			var copy := original.duplicate() as StandardMaterial3D
			copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
			faded.append(copy)
		_records[id] = {"node":weakref(mesh),"mesh_resource":mesh.mesh,"originals":originals,"faded":faded}
	var record: Dictionary = _records[id]
	record["opacity"]=opacity
	# 2. 端点精确恢复原不透明材质／阴影；完全隐藏不再绘制外壳或影子。
	mesh.visible = opacity>0.0001
	for index in range(record.originals.size()):
		if opacity>=0.9999 or opacity<=0.0001:
			mesh.set_surface_override_material(index,record.originals[index])
			continue
		# 3. 昼夜调色更新原实例材质，过渡副本从同一来源同步颜色与发光。
		var original: StandardMaterial3D = record.originals[index]
		var faded: StandardMaterial3D = record.faded[index]
		faded.albedo_color = Color(original.albedo_color,opacity)
		faded.emission_enabled = original.emission_enabled
		faded.emission = original.emission
		faded.emission_energy_multiplier = original.emission_energy_multiplier
		mesh.set_surface_override_material(index,faded)


## 区域卸载后只清理失效弱引用，缓存不会保留整片树林。
func prune() -> void:
	# 1. 原网格生命周期归区域管理，渲染缓存不持有节点强引用。
	for id: int in _records.keys():
		if _records[id].node.get_ref()==null:
			_records.erase(id)


## 为运行验收提供实际缓存规模，不在正式HUD暴露实现细节。
func cached_mesh_count() -> int:
	# 1. 返回当前记录数，调用方可在区域卸载后核对有界性。
	return _records.size()


## 调色切换时同步仍处于半透明状态的副本，原材质身份不改变。
func refresh_colors() -> void:
	# 1. 只刷新现存过渡副本，不创建未参与淡出的物体材质。
	for record: Dictionary in _records.values():
		var mesh: MeshInstance3D = record.node.get_ref()
		var opacity: float = record.get("opacity",1.0)
		if is_instance_valid(mesh) and opacity>0.0001 and opacity<0.9999:
			apply(mesh,opacity)
