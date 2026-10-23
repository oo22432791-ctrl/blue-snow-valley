extends RefCounted
## M12快照语义校验；任何持久模块改动之前验证类型、范围、稳定ID与跨模块关系。

const VERSION: int=1
const WORLD_ID: String="blue_snow_valley_v2"
const BEAR_STATES: Array[String]=["idle","patrol","warning","chase","attack","recover","return","stagger","dead"]


## 从已提交状态生成纯数据，不保存节点、RID、痕迹历史或未消费输入。
func capture(world: Node3D, protection_until: float) -> Dictionary:
	# 1. 时间倍率只用于调试；存档重开始终1倍，退出没有现实时间补偿。
	var clock: Dictionary=world.world_clock.get_state();clock.debug_rate=1.0
	var doors: Dictionary={}
	for cabin: Node3D in world.landmarks.cabins:
		doors[String(cabin.get_meta("building_id"))]={"angle":cabin.door_angle,"open":cabin.target_open}
	var actors: Array=[]
	for bear: CharacterBody3D in world.bears.bears:actors.append(bear.get_state())
	var survival: Dictionary=world.survival.get_state();survival["protection_until"]=protection_until
	# M13比赛装备是临时锁定；跨次读档回探索，保存进入活动前的装备槽。
	var rifle: Dictionary=world.rifle.get_state()
	if is_instance_valid(world.snowball_game) and world.snowball_game.participating:rifle.equipped=world.snowball_game.previous_equipment
	return {"version":VERSION,"world":WORLD_ID,"clock":clock,"weather":world.weather.get_state(),"survival":survival,"rifle":rifle,"bears":actors,"doors":doors,"player":{"position":_array(world.player.position),"yaw":world.player._visual.rotation.y,"zoom":world.camera_rig.desired_size},"transient_policy":"cancel_reload_exit_match_clear_snow"}


## 完整校验并返回首个可解释问题；调用方不可在验证中修改运行世界。
func validate(data: Dictionary, world: Node3D) -> String:
	# 1. 版本与世界身份不兼容时直接停止，不以新局覆盖。
	if not integer(data.get("version"),VERSION,VERSION) or not data.get("world") is String or data.world!=WORLD_ID:return "存档版本或山谷数据不兼容"
	for key: String in ["clock","weather","survival","rifle","doors","player"]:
		if not data.get(key) is Dictionary:return "存档缺少完整模块："+key
	if not data.get("transient_policy") is String or data.transient_policy!="cancel_reload_exit_match_clear_snow":return "存档临时状态规则不兼容"
	var clock: Dictionary=data.clock
	if not number(clock.get("elapsed_seconds"),0,1e12) or not number(clock.get("cycle_offset"),-1e12,1e12) or not integer(clock.get("cycle_seconds"),1440,1440) or not number(clock.get("debug_rate"),1,1):return "世界时间无效"
	var elapsed: float=clock.elapsed_seconds
	# 2. 玩家坐标保留真实Y；几何可达性在暂停的物理预检中单独验证。
	var player: Dictionary=data.player
	if not vector(player.get("position")) or not number(player.get("yaw"),-1e6,1e6) or not number(player.get("zoom"),8.5,16):return "玩家位置或镜头无效"
	if absf(player.position[0])>159.7 or absf(player.position[2])>191.7 or not number(player.position[1],-32,96):return "玩家位置在可玩山谷之外"
	var message:=_weather(data.weather,elapsed)
	if not message.is_empty():return message
	# 3. 每个稳定ID都必须存在且唯一，缺项不默认补满物品。
	var survival: Dictionary=data.survival
	if not number(survival.get("warmth"),.000001,100) or not integer(survival.get("carried"),0,20) or not survival.get("failure_latched") is bool or survival.failure_latched or not number(survival.get("protection_until"),0,elapsed+10.001):return "冷暖或失败恢复状态无效"
	if not same_ids(survival.get("stores"),world.survival.stores) or not same_ids(survival.get("fuel_seconds"),world.survival.heaters) or not same_ids(survival.get("resources"),world.survival.resources):return "柴火／热源稳定ID不匹配"
	for id: String in survival.stores:
		if not integer(survival.stores[id],0,60):return "仓储数量无效："+id
	for id: String in survival.fuel_seconds:
		if not number(survival.fuel_seconds[id],0,900):return "燃料数量无效："+id
	for id: String in survival.resources:
		var item: Variant=survival.resources[id]
		if not item is Dictionary or not integer(item.get("quantity"),0,int(world.survival.resources[id].capacity)) or not number(item.get("ready_at"),-1,elapsed+720.001):return "拾柴状态无效："+id
		if (item.quantity==0)!=(item.ready_at>=0):return "拾柴补充期限不一致："+id
	message=_rifle(data.rifle,world,elapsed)
	if not message.is_empty():return message
	if not same_ids(data.doors,world.landmarks.cabins_by_id):return "房屋ID不匹配"
	for id: String in data.doors:
		var door: Variant=data.doors[id]
		if not door is Dictionary or not door.get("open") is bool or not number(door.get("angle"),0,deg_to_rad(100.01)):return "门状态无效："+id
	# 4. 动物死亡与生命、期限、射击序号必须彼此一致，禁止读档复活或重复伤害。
	if not data.get("bears") is Array or data.bears.size()!=world.bears.bears.size():return "熊状态不完整"
	var seen: Dictionary={}
	for row: Variant in data.bears:
		if not row is Dictionary:return "熊状态格式无效"
		var id: String=str(row.get("id",""));var actual: CharacterBody3D
		for bear: CharacterBody3D in world.bears.bears:
			if bear.stable_id==id:actual=bear
		if actual==null or seen.has(id):return "熊ID缺失或重复"
		seen[id]=true
		message=_bear(row,actual,elapsed,int(data.rifle.fire_serial))
		if not message.is_empty():return message+"："+id
	return ""


## 天气只保存游戏期限和随机流，不使用保存时的现实日期计算进度。
func _weather(data: Dictionary, elapsed: float) -> String:
	# 1. 校验所有阶段字段，恢复时才重算派生强度和配色。
	if not data.get("state") is String or not data.get("storm_source") is String or data.state not in ["clear","storm"] or data.storm_source not in ["scheduled","debug"] or not rng_state(data.get("rng_state")):return "天气状态无效"
	if not number(data.get("storm_start"),-1,elapsed) or not number(data.get("storm_duration"),0,75) or not number(data.get("next_storm_at"),0,elapsed+840.001):return "天气期限无效"
	if data.state=="storm" and (data.storm_start<0 or data.storm_duration<45 or elapsed-data.storm_start>data.storm_duration+.001):return "风雪进度无效"
	if not vector(data.get("wind_direction"),2) or not vector(data.get("wind_offset"),2):return "风向格式无效"
	var direction:=Vector2(data.wind_direction[0],data.wind_direction[1])
	if absf(direction.length()-1)>.001:return "风向长度无效"
	return ""


## 弹药守恒关系和补给期限一起校验，部分拾取不得变成整盒刷新。
func _rifle(data: Dictionary, world: Node3D, elapsed: float) -> String:
	# 1. 数量、累计序号与已射／已收取满足同一守恒关系。
	for spec: Array in [["equipped",1,2],["chamber",0,1],["reserve",0,12],["fire_serial",0,1e9],["shots_fired",0,1e9],["rounds_collected",0,1e9]]:
		if not integer(data.get(spec[0]),spec[1],spec[2]):return "弹药字段无效："+str(spec[0])
	if data.fire_serial!=data.shots_fired or not _ammo_conserved(data):return "弹药守恒不成立"
	if not number(data.get("reload_at"),-1,elapsed) or not number(data.get("last_shot_at"),-1,elapsed) or not number(data.get("aim_yaw"),-1e6,1e6):return "枪械动作期限无效"
	if not data.get("pickups") is Array or data.pickups.size()!=world.rifle.pickups.size():return "弹药补给不完整"
	var seen: Dictionary={}
	for item: Variant in data.pickups:
		if not item is Dictionary:return "弹药补给格式无效"
		var id: String=str(item.get("id",""))
		if not world.rifle.pickups.has(id) or seen.has(id) or not integer(item.get("quantity"),0,4) or not number(item.get("ready_at"),-1,elapsed+1440.001):return "弹药补给字段无效"
		if (item.quantity==0)!=(item.ready_at>=0):return "弹药补给期限不一致"
		seen[id]=true
	return ""


## 动物状态必须完整，活动计时不以读档时刻重新开始。
func _bear(data: Dictionary, actual: CharacterBody3D, elapsed: float, serial: int) -> String:
	# 1. 固定家域不能被存档改写到安全区，运行位置需在实际世界范围内。
	if not vector(data.get("position")) or not vector(data.get("home")) or not vector(data.get("goal")) or not vector(data.get("knockback")) or not rng_state(data.get("rng_state")):return "熊坐标或随机流无效"
	if Vector3(data.home[0],data.home[1],data.home[2]).distance_to(actual.home)>.001:return "熊家域不匹配"
	if absf(data.position[0])>160 or absf(data.position[2])>192 or not number(data.position[1],-32,96):return "熊位置越界"
	if actual.world.interior.shelter_at(Vector3(data.position[0],data.position[1],data.position[2])).weather_sheltered:return "熊位置不允许在小屋内部"
	if not data.get("state") is String or data.state not in BEAR_STATES or not integer(data.get("health"),0,3) or not integer(data.get("last_shot_serial"),0,serial):return "熊生命或行为无效"
	for field: String in ["state_age","cooldown","idle_seconds","lost_sight","escaped","phase"]:
		if not number(data.get(field),0,1e12):return "熊计时无效"
	if not number(data.get("yaw"),-1e6,1e6) or not number(data.get("death_at"),-1,elapsed) or not number(data.get("chase_started"),-1,elapsed) or not integer(data.get("attack_serial"),0,1e9) or not data.get("corpse_removed") is bool or not data.get("attack_committed") is bool:return "熊动作期限无效"
	if (data.health==0)!=(data.state=="dead") or (data.health==0)!=(data.death_at>=0) or (data.corpse_removed and data.health>0):return "熊死亡状态不一致"
	if data.corpse_removed and elapsed-data.death_at<60:return "尸体移除过早"
	return ""


## 数值统一拒绝非有限值和隐式字符串转换，避免坏档污染模拟。
func number(value: Variant, minimum: float, maximum: float) -> bool:
	# 1. JSON整数通常读成浮点，接受有限数值但不接受布尔或字符串。
	return (value is float or value is int) and is_finite(float(value)) and value>=minimum and value<=maximum


## 数量必须精确为整数，不能用强转截断坏档。
func integer(value: Variant, minimum: float, maximum: float) -> bool:
	# 1. 先验范围再验小数部分，调用方之后才转换为int。
	return number(value,minimum,maximum) and float(value)==floorf(float(value))


## 固定维度向量只包含有限数值。
func vector(value: Variant, dimension: int=3) -> bool:
	# 1. 不允许短数组在恢复时触发索引错误。
	if not value is Array or value.size()!=dimension:return false
	for component: Variant in value:
		if not number(component,-1e12,1e12):return false
	return true


## 随机流保持带符号64位十进制字符串，避免JSON浮点精度损失。
func rng_state(value: Variant) -> bool:
	# 1. 规范回转阻止超范围或被截断的随机状态。
	return value is String and value.is_valid_int() and str(int(value))==value


## 稳定ID集合必须精确匹配，顺序和StringName实现差异不影响结果。
func same_ids(value: Variant, expected: Dictionary) -> bool:
	# 1. 逐键对比，防止少一处资源后被默认重填。
	if not value is Dictionary or value.size()!=expected.size():return false
	for id: Variant in expected:
		if not value.has(String(id)):return false
	return true


## Vector3序列化为普通数字数组，避免Godot对象编码进入存档。
func _array(value: Vector3) -> Array:
	# 1. 统一坐标顺序为XYZ。
	return [value.x,value.y,value.z]


## 原版没有赠送，全部弹药来自初始六发与公共收取。
func _ammo_conserved(data: Dictionary) -> bool:
	# 1. 扩展版可登记角色间转移，原版守恒公式不变。
	return data.chamber+data.reserve+data.shots_fired==6+data.rounds_collected
