extends Node
## M8自然调度与连续光照：无风雪间隔10–14分钟，每场45–75秒，边缘各10秒。

signal palette_changed(palette: Resource, sun_rotation: Vector3)
signal weather_changed(state: StringName, source: StringName)
const DAY=preload("res://materials/palettes/clear_blue.tres")
const NIGHT=preload("res://materials/palettes/twilight_blue.tres")
const COLOR_FIELDS=["snow","shadow","wall","roof","wood","coat","scarf","warm","ambient","sunlight"]
var clock: Node
var snow_tracks: Node
var interior: Node
var seed_value: int=0
var rng:=RandomNumberGenerator.new()
var palette: Resource
var state: StringName=&"clear"
var storm_source: StringName=&"scheduled"
var intensity: float=0.0
var storm_start: float=-1.0
var storm_duration: float=0.0
var next_storm_at: float=0.0
var wind_direction:=Vector2(1.0,-.4).normalized()
var wind_offset:=Vector2.ZERO
var schedule_history: Array[Dictionary]=[]
var _palette_age: float=0.0


## 建立一次独立配色副本和随机流，接入统一时钟。
func _ready() -> void:
	# 1. 普通新局随机化；可复现验收可明确传入种子，但不替代自然调度。
	if seed_value==0:rng.randomize()
	else:rng.seed=seed_value
	palette=DAY.duplicate()
	next_storm_at=rng.randf_range(600.0,840.0)
	clock.advanced.connect(_advance)
	refresh_palette()


## 按同一游戏时间推进调度、风向积分与足迹覆盖倍率。
func _advance(delta: float, elapsed: float) -> void:
	# 1. 每场结束后重新计完整晴静间隔，不累计待补发风雪。
	if state==&"clear" and elapsed>=next_storm_at:
		_start_storm(elapsed,rng.randf_range(45.0,75.0),&"scheduled")
	if state==&"storm":
		var age:=elapsed-storm_start
		intensity=smoothstep(0.0,10.0,age)*smoothstep(0.0,10.0,storm_duration-age)
		if age>=storm_duration:
			state=&"clear";intensity=0.0
			next_storm_at=elapsed+rng.randf_range(600.0,840.0)
			schedule_history.append({"event":"end","seconds":elapsed,"source":String(storm_source),"next_at":next_storm_at})
			weather_changed.emit(state,storm_source)
	# 2. 积分风偏移而非time乘瞬时风速，渐强时雪粒不会突然横跳。
	var velocity:=wind_direction*lerpf(.18,4.2,intensity)
	wind_offset+=velocity*delta
	wind_offset=Vector2(fposmod(wind_offset.x,32.0),fposmod(wind_offset.y,32.0))
	snow_tracks.set_weather_recovery_multiplier(1.0+2.0*intensity)
	# 3. 颜色更新20Hz，基础材质共享；不逐帧遍历全世界网格。
	_palette_age+=delta
	if _palette_age>=.05:
		_palette_age=0.0
		refresh_palette()


## 创建一场明确来源的天气，不开启热源、体温或存档结算。
func _start_storm(at: float, duration: float, source: StringName) -> void:
	# 1. 来源进入审计记录，调试触发不能冒充自然调度。
	state=&"storm";storm_start=at;storm_duration=duration;storm_source=source
	var angle:=rng.randf_range(-PI,PI)
	wind_direction=Vector2(cos(angle),sin(angle))
	schedule_history.append({"event":"start","seconds":at,"duration":duration,"source":String(source),"wind_direction":[wind_direction.x,wind_direction.y]})
	weather_changed.emit(state,source)


## 调试入口只在无正在进行的风雪时触发，仍使用真实渐变和正常速度。
func debug_start_storm() -> bool:
	# 1. 不连续重置风雪；结束后恢复完整晴静间隔。
	if state==&"storm":return false
	_start_storm(clock.elapsed_seconds,60.0,&"debug")
	return true


## 将已确认白夜端点连续插值，并叠加少量风雪灰蓝色。
func refresh_palette() -> void:
	# 1. 端点资源只读，复用唯一运行时Resource供新加载区域读取。
	var daylight: float=clock.get_daylight()
	for field: String in COLOR_FIELDS:
		var color: Color=(NIGHT.get(field) as Color).lerp(DAY.get(field),daylight)
		if field not in ["warm","scarf"]:color=color.darkened(intensity*.07)
		palette.set(field,color)
	palette.light_energy=lerpf(NIGHT.light_energy,DAY.light_energy,daylight)*(1.0-.16*intensity)
	palette.ambient_energy=lerpf(NIGHT.ambient_energy,DAY.ambient_energy,daylight)
	palette.set_meta("window_glow",lerpf(.62,.20,daylight))
	# 2. 主光始终保持可辨认人物的低角度蓝色方向光，方向连续绕动、不在阶段边界翻转。
	var angle: float=clock.get_day_seconds()/1440.0*TAU
	palette_changed.emit(palette,Vector3(-31.0-8.0*sin(angle),-48.0+26.0*sin(angle+.3),0.0))


## 天气遮蔽独立于外壳淡出，M9可读取夜晚／风雪而不在此扣体温。
func exposure_at(point: Vector3) -> Dictionary:
	# 1. 只读取真实房屋内框，未点火小屋也有遮蔽但没有自动热量。
	var shelter: Dictionary=interior.shelter_at(point)
	return {"building_id":shelter.building_id,"weather_sheltered":shelter.weather_sheltered,"precipitation_exposure":shelter.precipitation_exposure,"wind_exposure":shelter.wind_exposure,"night_strength":1.0-clock.get_daylight(),"storm_strength":intensity,"wind_speed_mps":lerpf(.18,4.2,intensity)}


## 提供未来保存模块所需状态，本阶段只暴露数据不写入存档。
func get_state() -> Dictionary:
	# 1. 随机状态用十进制字符串保留64位精度，累计时间不依赖现实钟。
	return {"state":String(state),"storm_source":String(storm_source),"storm_start":storm_start,"storm_duration":storm_duration,"next_storm_at":next_storm_at,"rng_state":str(rng.state),"wind_direction":[wind_direction.x,wind_direction.y],"wind_offset":[wind_offset.x,wind_offset.y]}


## 恢复原游戏期限与随机流，重算派生强度而不随机生成新天气。
func restore_state(data: Dictionary) -> void:
	# 1. 使用存档的统一世界钟；不调用推进函数以免调度下一场或消耗燃料。
	state=StringName(data.state);storm_source=StringName(data.storm_source);storm_start=float(data.storm_start)
	storm_duration=float(data.storm_duration);next_storm_at=float(data.next_storm_at);rng.state=int(data.rng_state)
	wind_direction=Vector2(data.wind_direction[0],data.wind_direction[1]);wind_offset=Vector2(data.wind_offset[0],data.wind_offset[1])
	var age: float=clock.elapsed_seconds-storm_start
	intensity=smoothstep(0.0,10.0,age)*smoothstep(0.0,10.0,storm_duration-age) if state==&"storm" else 0.0
	# 2. 材质与覆盖倍率同步当前阶段，不改变资源或足迹时间。
	snow_tracks.set_weather_recovery_multiplier(1+2*intensity);_palette_age=0;refresh_palette();weather_changed.emit(state,storm_source)
