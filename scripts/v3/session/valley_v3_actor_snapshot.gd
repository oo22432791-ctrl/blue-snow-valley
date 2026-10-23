extends "res://scripts/session/valley_snapshot.gd"
## V3规范快照：世界物资一份、两角色独立、控制来源和本地视图不入档。

const V3_STORE = preload("res://scripts/v3/session/valley_v3_save_store.gd")
const ACTOR_STATE = preload("res://scripts/v3/actors/valley_actor_state.gd")
const EVENT_STATE = preload("res://scripts/v3/world/valley_event_state.gd")
const BOSS_STATE = preload("res://scripts/v3/boss/valley_boss_state.gd")
const TRANSIENT_POLICY = "cancel_reload_exit_match_clear_snow"
const PROGRESS_KEYS = ["exploration_event", "traversal_event", "boss_unlocked", "boss_defeated", "ending_seen"]
var _validation_shot_limit: int = -1
var _checkpoint_depth: int = 0


## 世界能力只捕获一次，随身数据按固定槽位分离，不重复保存公共物资。
func capture(world: Node3D, _protection_until: float) -> Dictionary:
	# 1. 复用现有模块捕获纯数据，P1真实状态由角色适配器取得。
	var base: Dictionary = super.capture(world, world.survival.protection_until)
	return {"version": V3_STORE.JOURNEY_VERSION, "world": V3_STORE.WORLD_ID_V3,
		"implementation_stage": "m14_journey", "transient_policy": TRANSIENT_POLICY,
		"actors": world.actor_registry.capture_actors(),
		"world_state": {"clock": base.clock, "weather": base.weather, "doors": base.doors,
			"bears": base.bears, "stores": base.survival.stores, "resources": base.survival.resources,
			"fuel_seconds": base.survival.fuel_seconds, "ammo_pickups": base.rifle.pickups,
			"journey":{"briefing_seen":world.journey.briefing_seen}, "boss":world.boss_encounter.capture_state() if is_instance_valid(world.boss_encounter) else BOSS_STATE.initial(), "resource_multiplier": 2, "companion_policy": world.guard.capture_policy(), "events":world.events.capture_state(), "boss_checkpoint": world.rescue.boss_checkpoint.duplicate(true) if is_instance_valid(world.rescue) else {}}, "progress": world.v3_progress.duplicate(true)}


## 完整验证世界和两个角色，未知格式不能猜测兼容。
func validate(raw: Dictionary, world: Node3D) -> String:
	# 1. M0是同一V3工程的内部迁移，V2身份不能进入迁移路径。
	if not V3_STORE.new()._is_supported(raw):
		return "第三版存档版本或开发阶段不兼容，原文件已保留"
	if raw.version == V3_STORE.BOOTSTRAP_VERSION:
		var legacy := raw.duplicate(true)
		legacy.version = VERSION
		legacy.world = WORLD_ID
		var old_problem: String = super.validate(legacy, world)
		if not old_problem.is_empty():
			return old_problem
	var data := normalize(raw, world)
	if not data.get("actors") is Dictionary or data.actors.size() != 2:
		return "第三版必须包含固定P1和P2两个角色槽位"
	if not data.get("world_state") is Dictionary or not data.get("progress") is Dictionary:
		return "第三版缺少完整世界状态"
	var state: Dictionary = data.world_state
	if not state.get("journey") is Dictionary or state.journey.size()!=1 or not state.journey.get("briefing_seen") is bool:
		return "旅程目标页状态不完整"
	var policy: Variant = state.get("companion_policy")
	if not policy is Dictionary or policy.size() != 3 or policy.get("command") not in ["follow", "wait"] or not policy.get("fire_allowed") is bool or not vector(policy.get("wait_position")):
		return "伙伴指令存档无效"
	if absf(policy.wait_position[0]) > 224 or absf(policy.wait_position[2]) > 256:
		return "伙伴等待位置超出山谷"
	for key: String in ["clock", "weather", "doors", "stores", "resources", "fuel_seconds"]:
		if not state.get(key) is Dictionary:
			return "世界状态缺少模块：" + key
	if not state.get("bears") is Array or not state.get("ammo_pickups") is Array or not integer(state.get("resource_multiplier"), 2, 2):
		return "公共补给或资源规则不兼容"
	if data.get("transient_policy") != TRANSIENT_POLICY:
		return "第三版临时状态规则不兼容"
	if not number(state.clock.get("elapsed_seconds"), 0, 1e12):
		return "世界时间无效"
	# 2. 每个角色分别检查，不能用P1有效掩盖P2损坏。
	for id: String in ["p1", "p2"]:
		var problem := _actor(data.actors.get(id), id, world, state)
		if not problem.is_empty():
			return problem
	if data.actors.p1.rifle.rounds_given != data.actors.p2.rifle.rounds_received or data.actors.p2.rifle.rounds_given != data.actors.p1.rifle.rounds_received:
		return "双方弹药赠送账目不一致"
	var p1: Array = data.actors.p1.position
	var p2: Array = data.actors.p2.position
	if Vector2(p1[0] - p2[0], p1[2] - p2[2]).length() < 0.59 and absf(p1[1] - p2[1]) < 1.5:
		return "两角色保存位置重叠"
	# 3. 事件与Boss进度单独验证，不把控制来源保存为世界进度。
	if data.progress.size() != PROGRESS_KEYS.size():
		return "第三版目标进度不完整"
	for key: String in PROGRESS_KEYS:
		if not data.progress.get(key) is bool:
			return "目标进度无效：" + key
	if (data.progress.boss_unlocked and not (data.progress.exploration_event and data.progress.traversal_event)) or (data.progress.boss_defeated and not data.progress.boss_unlocked) or (data.progress.ending_seen and not data.progress.boss_defeated):
		return "第三版目标进度不一致"
	var event_problem := EVENT_STATE.validate(state.get("events"),data.progress)
	if not event_problem.is_empty():
		return event_problem
	# 4. 检查点最多一层，完整校验后才能作为Boss重试输入。
	var checkpoint: Variant = state.get("boss_checkpoint")
	if not checkpoint is Dictionary:
		return "缺少Boss重试边界"
	if not checkpoint.is_empty():
		if _checkpoint_depth > 0:
			return "Boss重试快照不能嵌套"
		_checkpoint_depth = 1
		var checkpoint_problem := validate(checkpoint, world)
		_checkpoint_depth = 0
		if not checkpoint_problem.is_empty():
			return "Boss入场快照无效：" + checkpoint_problem
		var entry := normalize(checkpoint, world)
		if entry.actors.p1.life.state != "standing" or entry.actors.p2.life.state != "standing" or entry.world_state.clock.elapsed_seconds > state.clock.elapsed_seconds:
			return "Boss入场快照必须早于当前且角色站立"
	var boss_problem := BOSS_STATE.validate(state.get("boss"),data.progress,checkpoint)
	if not boss_problem.is_empty(): return boss_problem
	# 5. 熊去重使用两把枪累计序号；个人弹药仍由上面的逐角色校验负责。
	_validation_shot_limit = int(data.actors.p1.rifle.fire_serial) + int(data.actors.p2.rifle.fire_serial)
	var world_problem: String = super.validate(to_legacy(data, world), world)
	_validation_shot_limit = -1
	return world_problem


## 复用原熊语义校验，仅替换合作世界的合法射击序号上界。
func _bear(data: Dictionary, actual: CharacterBody3D, elapsed: float, serial: int) -> String:
	# 1. M0迁移仍使用原P1上界，新302可验证两人已提交的累计射击。
	if _validation_shot_limit >= 0 and data.get("target_actor_id") not in ["p1", "p2"]:
		return "熊攻击目标无效"
	if _validation_shot_limit >= 0 and not integer(data.get("last_landed_attack_serial"), 0, data.get("attack_serial", 0)):
		return "熊命中事件序号无效"
	return super._bear(data, actual, elapsed, _validation_shot_limit if _validation_shot_limit >= 0 else serial)


## 已通过M0语义校验后，仅做一次内存迁移，不读旧版文件或自动写盘。
func _normalize_actor_format(raw: Dictionary, world: Node3D) -> Dictionary:
	# 1. 新格式深复制，校验和恢复不会改写调用者数据。
	if raw.get("version") == V3_STORE.ACTOR_VERSION:
		return raw.duplicate(true)
	var primary := _actor_from_legacy(raw)
	var secondary = ACTOR_STATE.new("p2").capture()
	var body: CharacterBody3D = world.snowball_game.companion
	var home: Vector3 = world.actor_registry.home
	secondary.position = [home.x,home.y,home.z]
	secondary.yaw = body._visual.rotation.y
	# 2. 仅M0到M2迁移翻倍公共剩余量，不翻倍个人已持有物资。
	var resources: Dictionary = raw.survival.resources.duplicate(true)
	for record: Dictionary in resources.values():
		record.quantity *= 2
	var boxes: Array = raw.rifle.pickups.duplicate(true)
	for record: Dictionary in boxes:
		record.quantity *= 2
	return {"version": V3_STORE.ACTOR_VERSION, "world": V3_STORE.WORLD_ID_V3,
		"implementation_stage": "m2_actors", "transient_policy": TRANSIENT_POLICY,
		"actors": {"p1": primary, "p2": secondary}, "world_state": {
			"clock": raw.clock.duplicate(true), "weather": raw.weather.duplicate(true),
			"doors": raw.doors.duplicate(true), "bears": raw.bears.duplicate(true),
			"stores": raw.survival.stores.duplicate(true), "resources": resources,
			"fuel_seconds": raw.survival.fuel_seconds.duplicate(true),
			"ammo_pickups": boxes, "resource_multiplier": 2},
		"progress": {"exploration_event":false,"traversal_event":false,"boss_unlocked":false,"boss_defeated":false,"ending_seen":false}}


## 生成既有能力恢复器的内存视图，磁盘只保存规范V3结构。
func to_legacy(data: Dictionary, world: Node3D) -> Dictionary:
	# 1. 公共世界与P1随身记录组成旧能力契约，不维护第二份持久真值。
	var state: Dictionary = data.world_state
	var actor: Dictionary = data.actors.p1
	var rifle: Dictionary = actor.rifle.duplicate(true)
	rifle["pickups"] = state.ammo_pickups.duplicate(true)
	return {"version": VERSION, "world": WORLD_ID, "transient_policy": TRANSIENT_POLICY,
		"clock": state.clock.duplicate(true), "weather": state.weather.duplicate(true),
		"doors": state.doors.duplicate(true), "bears": state.bears.duplicate(true),
		"player": {"position": actor.position.duplicate(), "yaw": actor.yaw, "zoom": clampf(world.camera_rig.desired_size, 8.5, 16.0)},
		"survival": {"warmth": maxf(float(actor.warmth), .000001), "carried": actor.carried,
			"protection_until": actor.protection_until, "failure_latched": false,
			"stores": state.stores.duplicate(true), "resources": state.resources.duplicate(true),
			"fuel_seconds": state.fuel_seconds.duplicate(true)}, "rifle": rifle}


## 每个固定槽位分别校验类型、范围和弹药守恒。
func _actor(value: Variant, id: String, world: Node3D, state: Dictionary) -> String:
	# 1. 固定身份不能由昵称、设备或客人包中的任意字符串覆盖。
	if not value is Dictionary or value.get("slot_id") != id or not value.get("rifle") is Dictionary:
		return "角色身份或装备不完整：" + id
	if not vector(value.get("position")) or not number(value.get("yaw"), -1e6, 1e6):
		return "角色位置无效：" + id
	if absf(value.position[0]) > 159.7 or absf(value.position[2]) > 191.7 or not number(value.position[1], -32, 96):
		return "角色位置越界：" + id
	var life_problem := _life(value.get("life"))
	if not life_problem.is_empty():
		return life_problem + "：" + id
	if value.life.state != "standing" and (value.rifle.get("reload_at") != -1.0 or not number(value.get("protection_until"), 0, state.clock.elapsed_seconds)):
		return "倒地角色不能继续装填或处于保护中：" + id
	if not number(value.get("warmth"), .000001 if value.life.state == "standing" else 0.0, 100) or not integer(value.get("carried"), 0, 20) or not number(value.get("protection_until"), 0, float(state.clock.elapsed_seconds) + 10.001):
		return "角色暖意或随身物资无效：" + id
	for key: String in ["rounds_given", "rounds_received"]:
		if not integer(value.rifle.get(key), 0, 1e12):
			return "角色弹药赠送账目无效：" + id
	var rifle: Dictionary = value.rifle.duplicate(true)
	rifle["pickups"] = state.ammo_pickups.duplicate(true)
	return _rifle(rifle, world, state.clock.elapsed_seconds)


## 公共盒上限为8；个人弹药和时间仍使用原守恒校验。
func _rifle(data: Dictionary, world: Node3D, elapsed: float) -> String:
	# 1. 先检查原始数量，再构造旧校验器所需非零／期限视图。
	if not data.get("pickups") is Array:
		return "公共弹药补给不完整"
	var adapted := data.duplicate(true)
	for row: Variant in adapted.pickups:
		if not row is Dictionary or not integer(row.get("quantity"), 0, 8):
			return "公共弹药数量无效"
		row.quantity = mini(4, int(row.quantity))
	return super._rifle(adapted, world, elapsed)


## M0主角迁移为P1，保留已消耗物资和单调动作序号。
func _actor_from_legacy(data: Dictionary) -> Dictionary:
	# 1. 公共盒不属于随身库存，独立进入world_state。
	var rifle: Dictionary = data.rifle.duplicate(true)
	rifle.erase("pickups")
	return {"slot_id": "p1", "position": data.player.position.duplicate(), "yaw": data.player.yaw,
		"warmth": data.survival.warmth, "carried": data.survival.carried,
		"protection_until": data.survival.protection_until, "rifle": rifle}


## M0／M2仅在内存明确迁移，读取不写盘、不再次翻倍公共补给。
func _normalize_survival(raw: Dictionary, world: Node3D) -> Dictionary:
	# 1. 当前格式必须包含账目和熊目标，不替坏字段猜默认值。
	if raw.get("version") == V3_STORE.SURVIVAL_VERSION:
		return raw.duplicate(true)
	var data := _normalize_actor_format(raw, world)
	if data.get("actors") is Dictionary:
		for actor: Variant in data.actors.values():
			if actor is Dictionary and actor.get("rifle") is Dictionary:
				actor.rifle.rounds_given = 0
				actor.rifle.rounds_received = 0
	if data.get("world_state") is Dictionary and data.world_state.get("bears") is Array:
		for bear: Variant in data.world_state.bears:
			if bear is Dictionary:
				bear.target_actor_id = "p1"
	data.version = V3_STORE.SURVIVAL_VERSION
	data.implementation_stage = "m5_survival"
	return data


## 个人弹药加上赠出量等于起始弹药、公共收取与赠入量之和。
func _ammo_conserved(data: Dictionary) -> bool:
	# 1. 两角色对应收支还需在完整快照层相等，不能单边凭空增弹。
	return data.chamber + data.reserve + data.shots_fired + data.get("rounds_given", 0) == 6 + data.rounds_collected + data.get("rounds_received", 0)


## 旧V3角色未倒地，明确补站立生命状态；不重发物资或重复翻倍。
func _normalize_rescue(raw: Dictionary, world: Node3D) -> Dictionary:
	# 1. 当前格式缺字段必须拒绝，迁移只针对登记的历史版本。
	if raw.get("version") == V3_STORE.RESCUE_VERSION:
		return raw.duplicate(true)
	var data := _normalize_survival(raw, world)
	if data.get("actors") is Dictionary:
		for actor: Variant in data.actors.values():
			if actor is Dictionary:
				actor.life = {"state": "standing", "reason": "", "remaining": 0.0}
	if data.get("world_state") is Dictionary:
		data.world_state.boss_checkpoint = {}
		if data.world_state.get("bears") is Array:
			for bear: Variant in data.world_state.bears:
				if bear is Dictionary and integer(bear.get("attack_serial"), 0, 1e9):
					bear.last_landed_attack_serial = maxi(0, int(bear.attack_serial) - (1 if bear.get("state") == "attack" and bear.get("attack_committed") == false else 0))
	data.version = V3_STORE.RESCUE_VERSION
	data.implementation_stage = "m6_rescue"
	return data


## 历史V3补默认护卫策略，保留306生命状态和物资，不猜测兼容未知版本。
func _normalize_partner(raw: Dictionary, world: Node3D) -> Dictionary:
	# 1. 当前格式缺策略必须拒绝，只有明确旧格式可以补默认值。
	if raw.get("version") == V3_STORE.PARTNER_VERSION:
		return raw.duplicate(true)
	var data := _normalize_rescue(raw, world)
	if data.get("world_state") is Dictionary and data.get("actors") is Dictionary and data.actors.get("p2") is Dictionary and vector(data.actors.p2.get("position")):
		data.world_state.companion_policy = {"command":"follow", "wait_position":data.actors.p2.position.duplicate(), "fire_allowed":true}
	data.version = V3_STORE.PARTNER_VERSION
	data.implementation_stage = "m7_partner"
	return data


## 仅登记的旧V3补事件起点，保留双人库存、生命、护卫指令与既有进度。
func normalize(raw: Dictionary, world: Node3D) -> Dictionary:
	if raw.get("version") == V3_STORE.JOURNEY_VERSION:
		return raw.duplicate(true)
	var data := _normalize_boss(raw,world)
	if data.get("world_state") is Dictionary:
		data.world_state.journey = {"briefing_seen":true}
		if data.world_state.get("boss") is Dictionary: data.world_state.boss.kind = "first"
	data.version = V3_STORE.JOURNEY_VERSION
	data.implementation_stage = "m14_journey"
	return data

## 313及更早格式先按各自契约迁移，保留原检查点和世界库存。
func _normalize_boss(raw: Dictionary, world: Node3D) -> Dictionary:
	if raw.get("version") == V3_STORE.BOSS_VERSION:
		return raw.duplicate(true)
	var data: Dictionary
	if raw.get("version") == V3_STORE.EVENT_VERSION:
		data = raw.duplicate(true)
	else:
		data = _normalize_partner(raw,world)
		if data.get("world_state") is Dictionary and data.get("progress") is Dictionary:
			data.world_state.events = EVENT_STATE.initial(data.progress)
			data.progress.boss_unlocked = data.progress.get("exploration_event",false) and data.progress.get("traversal_event",false)
	if data.get("world_state") is Dictionary and data.get("progress") is Dictionary:
		data.world_state.boss = BOSS_STATE.initial(data.progress.get("boss_defeated",false))
	data.version = V3_STORE.BOSS_VERSION
	data.implementation_stage = "m13_boss"
	return data


## 生命周期、原因和等待时间一起校验，不把损坏倒地状态猜成免费复活。
func _life(data: Variant) -> String:
	# 1. 剩余时间只表示游戏秒；施救进度、按键和控制来源不入档。
	if not data is Dictionary or data.size() != 3 or data.get("state") not in ["standing", "downed", "return_pending"] or not number(data.get("remaining"), 0, 60):
		return "角色生命状态无效"
	if data.state == "standing":
		return "站立角色生命状态不一致" if data.get("reason") != "" or data.remaining != 0 else ""
	if data.get("reason") not in ["hypothermia", "bear_attack"] or (data.state == "downed" and data.remaining <= 0) or (data.state == "return_pending" and data.remaining != 0):
		return "倒地原因或剩余时间不一致"
	return ""
