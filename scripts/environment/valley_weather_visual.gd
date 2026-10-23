extends Node3D
## M8有限雪粒与风声：4096个共享四边形、五处静态屋盖遮蔽、独立环境声音。

const SNOW_SHADER=preload("res://materials/valley_snowfall.gdshader")
const WIND=preload("res://assets/audio/v2/winter_wind.wav")
const FLAKES: int=4096
var weather: Node
var clock: Node
var player: CharacterBody3D
var cabins: Array[Node3D]=[]
var camps: Array[Node3D]=[]
var material: ShaderMaterial
var snow: MultiMeshInstance3D
var wind: AudioStreamPlayer
var roof_bounds: Array[AABB]=[]
var audio_exposure: float=1.0


## 创建固定绘制池和原创循环声，不随风雪次数申请新节点。
func _ready() -> void:
	# 1. 自定义实例数据只建一次，雪点位置在GPU按显式可暂停时钟计算。
	material=ShaderMaterial.new();material.shader=SNOW_SHADER
	var multimesh:=MultiMesh.new();multimesh.transform_format=MultiMesh.TRANSFORM_3D;multimesh.use_custom_data=true
	var mesh:=QuadMesh.new();mesh.size=Vector2(.035,.075);multimesh.mesh=mesh
	multimesh.instance_count=FLAKES;multimesh.custom_aabb=AABB(Vector3(-18,-5,-18),Vector3(36,22,36))
	var random:=RandomNumberGenerator.new();random.seed=8082026
	for index in range(FLAKES):
		multimesh.set_instance_transform(index,Transform3D.IDENTITY)
		multimesh.set_instance_custom_data(index,Color(random.randf(),random.randf(),random.randf(),random.randf()))
	snow=MultiMeshInstance3D.new();snow.multimesh=multimesh;snow.material_override=material
	snow.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;snow.visible=false;add_child(snow)
	_build_roof_masks()
	# 2. 风声为玩家所处环境混音，房间内衰减；不会改变脚步声总线。
	wind=AudioStreamPlayer.new();wind.name="WinterWind";wind.stream=WIND.duplicate()
	var stream: AudioStreamWAV=wind.stream;stream.loop_mode=AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin=0;stream.loop_end=roundi(stream.get_length()*stream.mix_rate)
	wind.volume_db=-43.0;add_child(wind);wind.play()
	clock.advanced.connect(_advance)


## 从实际源屋顶和营地屋盖读取包络，淡出／LOD都不更改遮蔽数据。
func _build_roof_masks() -> void:
	# 1. 三屋遮盖取Roof组的世界包络，不读取visible或外壳透明度。
	for cabin: Node3D in cabins:
		var roof: Node3D=cabin.model.find_child("Roof",true,false)
		var meshes: Array[Node]=roof.find_children("*","MeshInstance3D",true,false)
		if roof is MeshInstance3D:meshes.append(roof)
		var bounds:=AABB();var first:=true
		for mesh: MeshInstance3D in meshes:
			var box: AABB=mesh.global_transform*mesh.get_aabb()
			bounds=box if first else bounds.merge(box);first=false
		assert(not first,"Cabin weather roof missing")
		roof_bounds.append(bounds)
	# 2. 营地只遮住屋盖下的降雪；半开放空间仍按户外处理风声与未来冷暖。
	for camp: Node3D in camps:
		var bounds:=AABB();var first:=true
		for record: Dictionary in camp.manifest.collisions:
			if not "Roof" in String(record.name):continue
			for point: Array in record.points:
				var at: Vector3=camp.to_global(Vector3(point[0],point[1],point[2]))
				bounds=AABB(at,Vector3.ZERO) if first else bounds.expand(at);first=false
		assert(not first,"Camp weather roof missing")
		roof_bounds.append(bounds)
	assert(roof_bounds.size()==5)
	var masks:=PackedVector4Array();var tops:=PackedFloat32Array()
	for bounds: AABB in roof_bounds:
		var center:=bounds.get_center();masks.append(Vector4(center.x,center.z,bounds.size.x*.5,bounds.size.z*.5));tops.append(bounds.end.y)
	material.set_shader_parameter("roof_masks",masks);material.set_shader_parameter("roof_tops",tops)


## 从同一推进事件更新显式时钟、连续世界风偏移及室内声音衰减。
func _advance(delta: float, elapsed: float) -> void:
	# 1. 包围盒跟随角色用于裁剪，雪点世界坐标只在视野边缘回绕。
	global_position=player.global_position
	material.set_shader_parameter("weather_center",player.global_position)
	material.set_shader_parameter("weather_clock",elapsed)
	material.set_shader_parameter("wind_offset",weather.wind_offset)
	material.set_shader_parameter("storm_strength",weather.intensity)
	material.set_shader_parameter("snow_tint",weather.palette.snow.lightened(.45))
	snow.visible=weather.intensity>.001
	# 2. 自动淡出时裁掉投影进房间体积的雪点，防止屋顶上方的雪落在可见室内画面上。
	material.set_shader_parameter("interior_cutaway",0.0)
	for cabin: Node3D in cabins:
		var opacity: float=weather.interior.shell_opacity(cabin)
		if opacity>=.9999:continue
		var half:=Vector3(float(cabin.manifest.footprint[0])*.5,0,float(cabin.manifest.footprint[1])*.5)
		var low: Vector3=cabin.to_global(Vector3(-half.x,.14,-half.z))
		var high: Vector3=cabin.to_global(Vector3(half.x,2.85,half.z))
		material.set_shader_parameter("interior_min",low);material.set_shader_parameter("interior_max",high)
		material.set_shader_parameter("interior_cutaway",1.0-opacity)
		break
	# 3. 真实屋内风声降低至户外的8%，渐变避免门口瞬时跳音量。
	var exposure: Dictionary=weather.exposure_at(player.global_position)
	var target:=.08 if exposure.weather_sheltered else 1.0
	audio_exposure=lerpf(audio_exposure,target,1.0-exp(-5.0*delta))
	wind.volume_db=lerpf(-43.0,-22.0,weather.intensity)+linear_to_db(maxf(.001,audio_exposure))


## 暂停界面明确冻结音频播放位置，恢复时继续同一循环。
func set_paused(value: bool) -> void:
	# 1. 不重播样本，不让风声在暂停期间继续消耗播放位置。
	wind.stream_paused=value


## 返回与GPU共享的静态屋盖判定，用于接入和运行验收。
func snow_allowed_at(point: Vector3) -> bool:
	# 1. 包络上方仍可降雪；包络下方的房间／棚内不绘制雪点。
	for bounds: AABB in roof_bounds:
		if point.x>bounds.position.x and point.x<bounds.end.x and point.z>bounds.position.z and point.z<bounds.end.z and point.y<bounds.end.y:return false
	return true
