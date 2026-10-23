extends Node
## M4有寿命的分区痕迹：CPU保留历史，GPU只缓存附近；米制形变和恢复时钟共用。

const TILE_SIZE: float = 8.0
const RESOLUTION: int = 256
const IMAGE_SIZE: int = RESOLUTION+2
const PIXEL_SIZE: float = TILE_SIZE/RESOLUTION
const CPU_LIMIT: int = 256
const GPU_LIMIT: int = 64
const RECOVERY_SECONDS: float = 180.0
const MAP_ORIGIN := Vector2(-224,-256)
const PAGE_SIZE := Vector2i(56,64)
var gpu_capacity: int = GPU_LIMIT
var snow_surface: Node3D
var world_clock: Node
var elapsed_seconds: float = 0.0
var recovery_clock: float = 0.0
var weather_recovery_multiplier: float = 1.0
var total_steps: int = 0
var total_drags: int = 0
var total_paw_steps: int = 0
var _last_paw_event: Dictionary = {}
var upload_count: int = 0
var uploaded_bytes: int = 0
var expired_tiles: int = 0
var rejected_stamps: int = 0
var cache_loads: int = 0
var cache_unloads: int = 0
var peak_cpu_tiles: int = 0
var peak_gpu_tiles: int = 0
var max_stamp_ms: float = 0.0
var max_flush_ms: float = 0.0
var atlas := Texture2DArray.new()
var page_texture: ImageTexture
var _page_image: Image
var _tiles: Dictionary[Vector2i,Dictionary] = {}
var _cache: Dictionary[Vector2i,int] = {}
var _dirty: Dictionary[Vector2i,bool] = {}
var _free_layers: Array[int] = []
var _maintenance: float = 0.0
var _upload_elapsed: float = 0.0
var _page_dirty: bool = false
var _last_event: Dictionary = {}


## 预建固定64层附近缓存；空CPU历史不分配整图或所有纹理块。
func _ready() -> void:
	# 1. R为有符号米制形变（负为压痕），G为恢复时钟；边缘多一像素保证跨块插值。
	var empty := Image.create(IMAGE_SIZE,IMAGE_SIZE,false,Image.FORMAT_RGF)
	empty.fill(Color(0,0,0,1))
	var layers: Array[Image] = []
	for index in range(gpu_capacity):
		layers.append(empty)
		_free_layers.append(gpu_capacity-1-index)
	assert(atlas.create_from_images(layers)==OK,"Cannot allocate track cache")
	_page_image = Image.create(PAGE_SIZE.x,PAGE_SIZE.y,false,Image.FORMAT_RF)
	_page_image.fill(Color(0,0,0,1))
	page_texture = ImageTexture.create_from_image(_page_image)
	# 2. 两级材质同一个页表和时钟；远景不另建低精度历史。
	for material in [snow_surface.fine_material,snow_surface.far_material]:
		material.set_shader_parameter("track_atlas",atlas)
		material.set_shader_parameter("track_pages",page_texture)
		material.set_shader_parameter("tracks_enabled",true)
	snow_surface.tracks = self


## 游戏时间推进恢复；停止、暂停和退出不会按现实时间额外消耗寿命。
func _process(delta: float) -> void:
	# 1. M8装配统一时钟后只接受它的推进事件，历史独立检视仍保留原入口。
	if is_instance_valid(world_clock):return
	advance_game_time(delta)


## 接受统一游戏时间的单次推进，不创建第二套独立恢复时钟。
func advance_game_time(delta: float) -> void:
	# 1. 晴天180秒；天气只调恢复时钟速率，M8接入时不重置已有痕迹。
	elapsed_seconds += delta
	recovery_clock += delta*weather_recovery_multiplier
	for material in [snow_surface.fine_material,snow_surface.far_material]:
		material.set_shader_parameter("track_clock",recovery_clock)
	_maintenance += delta
	_upload_elapsed += delta
	# 2. 历史按寿命回收，缓存按视野回收，两者没有绑定。
	if _maintenance>=0.25:
		_maintenance = 0
		_expire_history()
		_sync_cache()
	# 3. 最多20Hz合并上传脏层，不在无变化时重复传整图。
	if _upload_elapsed>=0.05:
		_upload_elapsed = 0
		flush_pending()


## 天气覆盖入口只改变今后的恢复速率；不会刷新所有脚印时间戳。
func set_weather_recovery_multiplier(value: float) -> void:
	# 1. 实际天气时段由M8控制，当前只暴露受限的倍率接口。
	weather_recovery_multiplier = clampf(value,1.0,8.0)


## 一次真实落脚生成确定的靴印，形状和压力由脚别、雪厚及走跑决定。
func on_foot_landed(at: Vector3, yaw: float, left: bool, speed: float) -> void:
	# 1. 深雪压入到支撑附近，浅路只留下较浅压实，不随机改变靴子尺寸。
	var depth: float = snow_surface.get_fresh_depth_at(at)
	var pressure := lerpf(0.98,1.0,clampf(speed/3.6,0,1))
	_stamp(at,yaw,left,pressure,false)
	total_steps += 1
	_last_event = {"position":at,"left":left,"speed":speed,"depth":depth,"physics_frame":Engine.get_physics_frames()}


## 深雪中真实脚点的短距离滑动留下较窄浅拖痕，不另触发声音或落脚雪粉。
func on_foot_dragged(from: Vector3, to: Vector3, yaw: float, left: bool, _speed: float) -> void:
	# 1. 拒绝瞬移长线，少量采样覆盖实际脚底连续路径。
	var distance := Vector2(to.x-from.x,to.z-from.z).length()
	if distance<0.025 or distance>0.30:
		return
	var count := clampi(ceili(distance/0.045),1,7)
	for index in range(count):
		_stamp(from.lerp(to,float(index+1)/count),yaw,left,0.34,true)
	total_drags += 1


## 将米制压痕与少量挤雪边缘写到所有受影响块及其边缘像素。
func _stamp(at: Vector3, yaw: float, left: bool, pressure: float, drag: bool, profile: StringName=&"boot") -> void:
	# 1. 世界坐标连续采样，块边界两侧使用相同像素中心和形状函数。
	var started := Time.get_ticks_usec()
	var point := Vector2(at.x,at.z)
	var paw:=profile!=&"boot"
	var radius := .39 if paw else (0.31 if not drag else 0.16)
	var low := Vector2i(floori((point.x-radius-PIXEL_SIZE)/TILE_SIZE),floori((point.y-radius-PIXEL_SIZE)/TILE_SIZE))
	var high := Vector2i(floori((point.x+radius+PIXEL_SIZE)/TILE_SIZE),floori((point.y+radius+PIXEL_SIZE)/TILE_SIZE))
	var right := Vector2(cos(yaw),-sin(yaw))
	var forward := Vector2(sin(yaw),cos(yaw))
	var fresh: float = snow_surface.get_fresh_depth_at(at)
	var depression := minf(0.065,fresh*0.30)*pressure if drag else maxf(0,fresh-snow_surface.get_height_at(at))*pressure
	var bank := minf(0.035,fresh*0.12)*(0.35 if drag else pressure)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var key := Vector2i(x,z)
			if not _valid_key(key):
				continue
			var tile := _get_or_create(key)
			if tile.is_empty():
				rejected_stamps += 1
				continue
			var image: Image = tile.image
			var origin := Vector2(key)*TILE_SIZE
			var start := Vector2i((point-Vector2.ONE*radius-origin)/PIXEL_SIZE+Vector2.ONE).clamp(Vector2i.ZERO,Vector2i.ONE*(IMAGE_SIZE-1))
			var end := Vector2i((point+Vector2.ONE*radius-origin)/PIXEL_SIZE+Vector2.ONE).clamp(Vector2i.ZERO,Vector2i.ONE*(IMAGE_SIZE-1))
			for py in range(start.y,end.y+1):
				for px in range(start.x,end.x+1):
					var offset := origin+(Vector2(px,py)-Vector2.ONE*0.5)*PIXEL_SIZE-point
					var local := Vector2(offset.dot(right),offset.dot(forward))
					var half_width := 0.065 if drag else 0.105
					var half_length := 0.10 if drag else 0.18
					# 2. 靴跟、靴头和内侧足弓有确定轮廓；边缘微褶由位置决定，不逐步随机。
					var arch := exp(-pow(local.y/0.065,2))*0.012*(-1.0 if left else 1.0)
					var toe_width := half_width*(1.0+0.12*clampf(local.y/half_length,-1,1))
					var shape := Vector2((local.x+arch)/toe_width,local.y/half_length).length()
					if paw:
						# 动物掌垫与五枚趾垫用独立轮廓，不缩放或复用人类靴跟／足弓。
						var scale:=1.0 if profile==&"paw_front" else .90
						var p:=local/scale
						shape=Vector2(p.x/.125,(p.y+.035)/.13).length()
						for toe in range(5):
							var center:=Vector2((toe-2)*.055,.12+.024*(1.0-absf(toe-2)/2.0))
							shape=minf(shape,(p-center).length()/.038)
					var core := 1.0-smoothstep(0.55,1.20,shape)
					var rim := smoothstep(1.10,1.24,shape)*(1.0-smoothstep(1.24,1.48,shape))
					var crease := 0.99+0.01*sin(local.y*89.0+local.x*37.0)
					var candidate := -depression*core*crease if core>0.002 else bank*rim
					if absf(candidate)<0.00004:
						continue
					var old := _effective(image.get_pixel(px,py))
					# 3. 重踩取较深的有限压实，挤雪不覆盖已有凹槽，不累加尖峰。
					if candidate<0:
						candidate = minf(old,candidate)
					elif old<0:
						continue
					else:
						candidate = maxf(old,candidate)
					image.set_pixel(px,py,Color(candidate,recovery_clock,0,1))
			tile.last_touch = recovery_clock
			_dirty[key] = true
	# 4. 只记录累计量，不保留无限增长的逐脚列表。
	peak_cpu_tiles = maxi(peak_cpu_tiles,_tiles.size())
	max_stamp_ms = maxf(max_stamp_ms,(Time.get_ticks_usec()-started)/1000.0)


## 接受实际四掌骨骼落地，和人类痕迹共享寿命／缓存但使用独立五趾形状。
func on_paw_landed(at: Vector3, yaw: float, front: bool, pressure: float=1.08) -> void:
	# 1. 干燥铺装不留掌印；独立计数与事件不会覆盖原人类声音同步记录。
	if snow_surface.is_dry_surface(at):return
	_stamp(at,yaw,false,clampf(pressure,.4,1.2),false,&"paw_front" if front else &"paw_rear")
	total_paw_steps+=1
	_last_paw_event={"position":at,"front":front,"physics_frame":Engine.get_physics_frames(),"profile":"five_toe_paw"}


## 返回最后动物接触副本，供M10校验，不改变人类脚步事件接口。
func get_last_paw_event() -> Dictionary:
	# 1. 读取者不能通过引用改写已记录事件。
	return _last_paw_event.duplicate()


## 只在有痕迹的块分配CPU记录；容量满时拒绝新写入，不删除未恢复脚印。
func _get_or_create(key: Vector2i) -> Dictionary:
	# 1. 容量上限独立于GPU显示缓存，离开镜头不能提前删除历史。
	if _tiles.has(key):
		return _tiles[key]
	if _tiles.size()>=CPU_LIMIT:
		return {}
	var image := Image.create(IMAGE_SIZE,IMAGE_SIZE,false,Image.FORMAT_RGF)
	image.fill(Color(0,0,0,1))
	_tiles[key] = {"image":image,"last_touch":recovery_clock}
	return _tiles[key]


## 依据最后写入的恢复时钟清理到期块，暂停不会推进这个边界。
func _expire_history() -> void:
	# 1. 仅达到完整恢复期后回收，不能依照视口距离删除。
	for key: Vector2i in _tiles.keys():
		if recovery_clock-float(_tiles[key].last_touch)>=RECOVERY_SECONDS:
			_tiles.erase(key)
			_dirty.erase(key)
			if _cache.has(key):
				_free_layers.append(_cache[key])
				_cache.erase(key)
				_page_dirty = true
			expired_tiles += 1


## 附近只驻留64层，映射可重建；CPU历史不受显示窗口变动影响。
func _sync_cache() -> void:
	# 1. 48米窗口包含两端相邻边缘，最多8×8个8米块。
	var windows: Array[Vector4] = snow_surface.get_detail_windows()
	var wanted: Dictionary[Vector2i,bool] = {}
	for key: Vector2i in _tiles:
		var at := Vector2(key)*TILE_SIZE
		for bounds: Vector4 in windows:
			if at.x+TILE_SIZE>=bounds.x and at.x<=bounds.z and at.y+TILE_SIZE>=bounds.y and at.y<=bounds.w:
				wanted[key] = true
				break
	for key: Vector2i in _cache.keys():
		if not wanted.has(key):
			_free_layers.append(_cache[key])
			_cache.erase(key)
			_page_dirty = true
			cache_unloads += 1
	for key: Vector2i in wanted:
		if not _cache.has(key) and not _free_layers.is_empty():
			_cache[key] = _free_layers.pop_back()
			_dirty[key] = true
			_page_dirty = true
			cache_loads += 1
	peak_gpu_tiles = maxi(peak_gpu_tiles,_cache.size())


## 合并同一帧写入后仅上传变化的附近层，空闲时只更新一个恢复时钟。
func flush_pending() -> void:
	# 1. 新脚印所在块即时进入附近页表，远处脏块只保留CPU数据。
	var started := Time.get_ticks_usec()
	_sync_cache()
	for key: Vector2i in _dirty.keys():
		if _cache.has(key) and _tiles.has(key):
			atlas.update_layer(_tiles[key].image,_cache[key])
			upload_count += 1
			uploaded_bytes += IMAGE_SIZE*IMAGE_SIZE*8
			_dirty.erase(key)
	# 2. 页表14KiB左右，仅映射变化时上传；零表示该位置没有可显示历史。
	if _page_dirty:
		_page_image.fill(Color(0,0,0,1))
		for key: Vector2i in _cache:
			var page := key-Vector2i(MAP_ORIGIN/TILE_SIZE)
			_page_image.set_pixelv(page,Color(_cache[key]+1,0,0,1))
		page_texture.update(_page_image)
		_page_dirty = false
	max_flush_ms = maxf(max_flush_ms,(Time.get_ticks_usec()-started)/1000.0)


## CPU与着色器同样逐像素恢复后再插值，不能把空白时间戳混成新脚印。
func get_offset_at(point: Vector3) -> float:
	# 1. 负坐标用floor，边缘像素来自邻块同一世界采样点。
	var key := Vector2i(floori(point.x/TILE_SIZE),floori(point.z/TILE_SIZE))
	if not _tiles.has(key):
		return 0
	var grid := (Vector2(point.x,point.z)-Vector2(key)*TILE_SIZE)/PIXEL_SIZE+Vector2.ONE*0.5
	var cell := Vector2i(floori(grid.x),floori(grid.y)).clamp(Vector2i.ZERO,Vector2i.ONE*(IMAGE_SIZE-2))
	var f := grid-Vector2(cell)
	var image: Image = _tiles[key].image
	return lerpf(lerpf(_effective(image.get_pixelv(cell)),_effective(image.get_pixelv(cell+Vector2i.RIGHT)),f.x),
		lerpf(_effective(image.get_pixelv(cell+Vector2i.DOWN)),_effective(image.get_pixelv(cell+Vector2i.ONE)),f.x),f.y)


## 每个像素先按自身时间恢复，再参加双线性混合，正负边缘不会污染年龄。
func _effective(pixel: Color) -> float:
	# 1. 零形变无时间含义；180秒平滑归零而不是到点突然清空。
	return pixel.r*(1.0-smoothstep(0.0,RECOVERY_SECONDS,maxf(0,recovery_clock-pixel.g)))


## 排除地图外的写入，不取模、不镜像到另一端。
func _valid_key(key: Vector2i) -> bool:
	# 1. 与固定页表世界范围一致。
	var page := key-Vector2i(MAP_ORIGIN/TILE_SIZE)
	return page.x>=0 and page.y>=0 and page.x<PAGE_SIZE.x and page.y<PAGE_SIZE.y


## 返回有上限的资源和同步诊断，不暴露可修改图像。
func get_statistics() -> Dictionary:
	# 1. 原始字节不含驱动开销，实际进程与渲染内存需另行测量。
	return {"cpu_tiles":_tiles.size(),"gpu_tiles":_cache.size(),"cpu_limit":CPU_LIMIT,"gpu_limit":gpu_capacity,"paw_steps":total_paw_steps,
		"cpu_bytes":_tiles.size()*IMAGE_SIZE*IMAGE_SIZE*8,"gpu_atlas_bytes":gpu_capacity*IMAGE_SIZE*IMAGE_SIZE*8,
		"peak_cpu_tiles":peak_cpu_tiles,"peak_gpu_tiles":peak_gpu_tiles,"steps":total_steps,"drags":total_drags,
		"uploads":upload_count,"uploaded_bytes":uploaded_bytes,"expired_tiles":expired_tiles,"rejected_stamps":rejected_stamps,
		"cache_loads":cache_loads,"cache_unloads":cache_unloads,"max_stamp_ms":max_stamp_ms,"max_flush_ms":max_flush_ms,
		"clock":recovery_clock,"elapsed":elapsed_seconds,"weather_multiplier":weather_recovery_multiplier}


## 统一反馈同步检查读取最近一次事件，记录大小固定。
func get_last_event() -> Dictionary:
	# 1. 深拷贝防止外部修改内部状态。
	return _last_event.duplicate(true)


## 用户确认读档不保留足迹或压实，清除CPU历史与GPU页表而不改地形新雪。
func reset_history(game_seconds: float) -> void:
	# 1. 空页表让旧纹理层不可见，固定缓存复用，避免重建大块GPU资源。
	_tiles.clear();_cache.clear();_dirty.clear();_free_layers.clear()
	for index in range(gpu_capacity):_free_layers.append(gpu_capacity-1-index)
	_page_image.fill(Color(0,0,0,1));page_texture.update(_page_image);_page_dirty=false
	_last_event.clear();_last_paw_event.clear();elapsed_seconds=game_seconds;recovery_clock=0;_maintenance=0;_upload_elapsed=0
	# 2. 计时和显示使用新的空历史，晴雪／风雪的恢复倍率仍由天气负责。
	for material in [snow_surface.fine_material,snow_surface.far_material]:material.set_shader_parameter("track_clock",0.0)
