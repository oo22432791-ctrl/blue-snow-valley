extends Node3D
## M10两熊管理：独立导航、有限声部、真实掌印与统一失败入口。

signal attack_confirmed(bear_id: StringName, attack_serial: int)
const BEAR=preload("res://scripts/ai/valley_bear.gd")
const NAVIGATION=preload("res://assets/environment/v2/bear_navigation.res")
const GROWL=preload("res://assets/audio/v2/bear_growl.wav")
const PAW=preload("res://assets/audio/v2/bear_paw.wav")
var world: Node3D
var bears: Array[CharacterBody3D]=[]
var navigation_map:=RID()
var navigation_region: NavigationRegion3D
var ready_for_paths: bool=false
var attack_events: Array[Dictionary]=[]
var paw_history: Array[Dictionary]=[]
var _voices: Dictionary={}
var _hint: Label
var _last_attack_at: float=-INF
var _life_age: float=0.0


## 两只熊分别出生于已确认林区，南侧没有熊，地图与人类导航分开。
func _ready() -> void:
	# 1. 独立RID地图避免把熊的大半径导航合并到人类入口走廊。
	navigation_map=NavigationServer3D.map_create();NavigationServer3D.map_set_active(navigation_map,true)
	NavigationServer3D.map_set_cell_size(navigation_map,.25);NavigationServer3D.map_set_cell_height(navigation_map,.1)
	navigation_region=NavigationRegion3D.new();navigation_region.set_navigation_map(navigation_map);navigation_region.navigation_mesh=NAVIGATION
	add_child(navigation_region)
	var layer:=CanvasLayer.new();add_child(layer)
	_hint=Label.new();_hint.position=Vector2(28,690);_hint.add_theme_font_size_override("font_size",24);_hint.add_theme_color_override("font_color",Color("f4dcb4"));_hint.add_theme_color_override("font_shadow_color",Color("20364f"));_hint.add_theme_constant_override("shadow_offset_x",2);_hint.add_theme_constant_override("shadow_offset_y",2);_hint.mouse_filter=Control.MOUSE_FILTER_IGNORE;layer.add_child(_hint)
	await get_tree().physics_frame
	await get_tree().physics_frame
	# 独立服务器地图必须完成同步后才能查询；空地图返回零向量不能充当出生点。
	NavigationServer3D.map_force_update(navigation_map)
	var waits:=0
	var points_ready:=false
	while not points_ready and waits<120:
		await get_tree().process_frame
		waits+=1
		if NavigationServer3D.map_get_iteration_id(navigation_map)==0:continue
		points_ready=true
		for requested: Vector3 in [Vector3(-45,4.4,-30),Vector3(86,10,-113)]:
			if NavigationServer3D.map_get_closest_point(navigation_map,requested).distance_to(requested)>6:points_ready=false
	assert(points_ready,"Bear navigation geometry did not synchronize")
	# 2. 仅出生初始化允许投影到可走地面，之后返回／卡住从不传送。
	for record: Dictionary in [{"id":"bear.bend","position":Vector3(-45,0,-30)},{"id":"bear.north","position":Vector3(86,0,-113)}]:
		var requested: Vector3=record.position;requested.y=world.terrain.get_ground_height(Vector2(requested.x,requested.z))
		var home:=NavigationServer3D.map_get_closest_point(navigation_map,requested)
		assert(home.distance_to(requested)<6.0,"Bear spawn must be near its confirmed woodland")
		var bear: CharacterBody3D=_create_bear();bear.world=world;bear.manager=self;bear.stable_id=record.id
		bear.home=home;bear.position=home+Vector3.UP*.05;bear.name=record.id.replace(".","_");add_child(bear)
		world.register_world_object(StringName(record.id),bear);bears.append(bear)
		var voices: Array[AudioStreamPlayer3D]=[]
		for index in range(3):
			# 俯视相机离角色38米，空间声部先补偿虚拟听点，实际听觉范围由人物距离控制。
			var voice:=AudioStreamPlayer3D.new();voice.max_distance=100;voice.unit_size=40;voice.stream=GROWL if index==0 else PAW
			voice.volume_db=-10 if index==0 else -18
			voice.attenuation_filter_db=-6;voice.panning_strength=.55;voice.max_db=0
			if index==0:bear.add_child(voice)
			else:add_child(voice)
			voices.append(voice)
		_voices[record.id]=voices
	ready_for_paths=true
	world.world_clock.advanced.connect(_advance_life)


## M11尸体与重生按统一游戏秒数推进，近处／画面内禁止突然消失或生成。
func _advance_life(delta: float,_elapsed: float) -> void:
	# 1. 仅死亡对象需要视野查询；活熊仍完全走原来的真实导航流程。
	_life_age+=delta
	if _life_age<.25:return
	_life_age=0
	for bear: CharacterBody3D in bears:
		if bear.health>0:continue
		var age: float=world.world_clock.elapsed_seconds-bear.death_at
		if not bear.corpse_removed and age>=60 and _away_from_view(bear.global_position):
			bear.corpse_removed=true;bear.hide()
		# 2. 必须先合法移除尸体，再于原家域远离玩家／画面处恢复，不掉落材料。
		if bear.corpse_removed and age>=1440 and _away_from_view(bear.home):bear.respawn_after_death()


## 24米以内或实际画面内均保留现状，缩放不会因虚拟相机高度而触发刷新。
func _away_from_view(at: Vector3) -> bool:
	# 1. 和已确认补给的近处视野策略一致，边缘多留64像素。
	if world.player.global_position.distance_to(at)<=24:return false
	var camera: Camera3D=world.camera_rig.camera
	return not (camera.is_position_in_frustum(at) and Rect2(Vector2.ZERO,world.get_viewport().get_visible_rect().size).grow(64).has_point(camera.unproject_position(at)))


## 倒下时立即停止这一只熊的低吼和掌声，不影响另一只或环境声音。
func on_bear_dead(bear: CharacterBody3D) -> void:
	# 1. 不新建死亡声部、不播放脚步，也不发布失温／攻击失败事件。
	if not _voices.has(bear.stable_id):return
	for voice: AudioStreamPlayer3D in _voices[bear.stable_id]:voice.stop()


## 正式提示只在附近熊已进入警告／追赶时出现，不显示AI参数或伤害调试数值。
func _process(_delta: float) -> void:
	# 1. 人物、门、家具保持原可见性，警告不强制夺取镜头或锁住移动。
	var text: String=""
	for bear: CharacterBody3D in bears:
		if bear.player_distance>22:continue
		if bear.state==&"attack":text="熊正在抬掌 · 跑开或进入小屋"
		elif bear.state==&"chase":text="熊正在追赶 · 拉开距离或进入小屋"
		elif bear.state==&"warning":text="熊在警告 · 请后退，保持距离"
	# 2. 命中后即使熊已退开仍短暂保留结果反馈，避免失败事件没有可见回应。
	if text.is_empty() and world.world_clock.elapsed_seconds-_last_attack_at<4.0:
		text="被熊击中 · 熊已退开"
	_hint.text=text


## 消费骨架的同一个掌接触事件，声音和掌印不使用独立定时器猜落地。
func paw_landed(bear: CharacterBody3D, event: Dictionary) -> void:
	# 1. 原人类脚印计数和最后事件保持独立，动物有专用五趾轮廓。
	world.snow_tracks.on_paw_landed(event.position,bear.rotation.y,event.front)
	var record: Dictionary={"bear_id":bear.stable_id,"paw":event.paw,"position":event.position,"frame":Engine.get_physics_frames(),"support_error":absf(event.position.y-world.snow_surface.get_support_height_at(event.position))}
	paw_history.append(record)
	if paw_history.size()>128:paw_history.pop_front()
	# 2. 每熊两掌声部轮换；远处不播放，但仍保留统一雪面痕迹。
	if bear.player_distance>20 or world.snow_surface.is_dry_surface(event.position):return
	var voices: Array=_voices[bear.stable_id]
	var voice: AudioStreamPlayer3D=voices[1+bear.paw_events%2]
	voice.global_position=event.position+Vector3.UP*.1;voice.pitch_scale=.94 if event.front else 1.04
	voice.volume_db=_volume_at(-18,bear.player_distance,20);voice.play()


## 每次进入警告只播一声原创合成低吼，不逐帧叠音。
func play_warning(bear: CharacterBody3D) -> void:
	# 1. 声部固定上限3个／熊，普通移动不会打断警告声。
	if not _voices.has(bear.stable_id) or bear.player_distance>=22:return
	var voice: AudioStreamPlayer3D=_voices[bear.stable_id][0]
	voice.global_position=bear.global_position+Vector3.UP*.95
	voice.volume_db=_volume_at(-10,bear.player_distance,22);voice.play()


## 按玩家和熊的真实距离柔和衰减；相机缩放与离地高度不决定听觉距离。
func _volume_at(base_db: float, distance: float, limit: float) -> float:
	# 1. 达到人物距离上限前淡出，远处声部在调用入口不播放。
	var gain:=1.0-smoothstep(0.0,limit,distance)
	return base_db+linear_to_db(maxf(.001,gain))


## 命中后走统一失败锁，一次抬掌或两熊同帧都不会重复发布失败。
func attack_landed(bear: CharacterBody3D, serial: int) -> void:
	# 1. 这里只提交一次明确来源事件；返回与损失由M12会话协调。
	if not world.survival.request_failure(&"bear_attack"):return
	_last_attack_at=world.world_clock.elapsed_seconds
	attack_events.append({"bear_id":bear.stable_id,"serial":serial,"at":world.world_clock.elapsed_seconds})
	if attack_events.size()>32:attack_events.pop_front()
	attack_confirmed.emit(StringName(bear.stable_id),serial)


## 和风声一起显式冻结有限音频声部，恢复不补播暂停期间的脚步。
func set_paused(value: bool) -> void:
	# 1. 场景树负责物理／时钟，声音播放位置另作明确冻结。
	for voices: Array in _voices.values():
		for voice: AudioStreamPlayer3D in voices:voice.stream_paused=value


## 暴露未来存档所需稳定熊状态；死亡与重生在M11／M12接入。
func get_state() -> Array[Dictionary]:
	# 1. 不保存运行时导航RID或声部实例，避免跨次启动使用悬空句柄。
	var result: Array[Dictionary]=[]
	for bear: CharacterBody3D in bears:result.append(bear.get_state())
	return result


## 清理独立导航地图，节点退出后不保留服务器RID。
func _exit_tree() -> void:
	# 1. 停止所有有限声部并释放流引用，退出时不把WAV留在混音线程中。
	for voices: Array in _voices.values():
		for voice: AudioStreamPlayer3D in voices:
			if is_instance_valid(voice):voice.stop();voice.stream=null
	# 2. 先把区域与地图脱离，再释放独立地图；不触碰人类World3D导航地图。
	if navigation_map.is_valid():
		if is_instance_valid(navigation_region):NavigationServer3D.region_set_map(navigation_region.get_rid(),RID())
		NavigationServer3D.free_rid(navigation_map)


## 默认创建旧版熊，合作版本只替换目标选择适配器。
func _create_bear() -> CharacterBody3D:
	# 1. 不复制独立导航和动物资产装配。
	return BEAR.new()
