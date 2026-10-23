extends "res://scripts/survival/valley_survival.gd"
## 两份行囊共享一个物资世界；公共燃料唯一推进，赠送在物理帧原子提交。

signal interaction_closed
var actor_id: String = "p1"
var shared_world: Node3D


## AI近距拾柴使用原事务，不通过虚拟菜单复制库存或跳过墙体校验。
func pickup_for_ai(id: String) -> int:
	# 1. 仅当前房主AI来源可调用，真人P2不接受自动拾取。
	if actor_id != "p2" or not shared_world.session.local_authority or shared_world.actor_registry.slots.p2.source != "ai" or get_tree().paused or failure_latched or not resources.has(id) or not target_accessible(id):
		return 0
	close_session()
	_session_id = id
	_token += 1
	var result: Dictionary = _apply_action({"token":_token,"id":id,"action":"pickup","amount":CARRY_CAPACITY})
	close_session()
	return int(result.get("count",0))


## 缓存双方燃尽比例后只扣一次燃料，待命角色保留暖意。
func _advance(delta: float, _elapsed: float) -> void:
	# 1. P2不订阅世界钟，由主实例在相同燃料状态下积分。
	var peer: Node = shared_world.secondary_context.survival if is_instance_valid(shared_world.secondary_context) else null
	var own_fraction := _heat_fraction(delta)
	var peer_fraction: float = peer._heat_fraction(delta) if is_instance_valid(peer) else 1.0
	_advance_fuel(delta)
	_advance_person(delta, own_fraction)
	# 2. 首个失败已冻结世界，同一钟回调不继续提交另一人的动作。
	if is_instance_valid(peer) and not get_tree().paused and shared_world.actor_registry.is_effective("p2"):
		peer._advance_person(delta, peer_fraction)


## 动态伙伴锚点只由各自生存实例选择，旧雪球入口合并到伙伴菜单。
func find_nearest() -> Dictionary:
	# 1. 世界装配早期尚无伙伴上下文，沿用原目标查找。
	if not is_instance_valid(shared_world.actor_registry) or not is_instance_valid(shared_world.secondary_context):
		return super.find_nearest()
	var id := _partner_id()
	var peer: CharacterBody3D = _peer_body()
	targets[id] = {"id": id, "site": "", "name": "伙伴 " + _peer_id().to_upper(), "kind": "partner", "position": peer.global_position + Vector3.UP * .9, "reach": 2.0}
	var found := super.find_nearest()
	if found.get("kind") == "snowball" and target_accessible(id):
		return targets[id]
	return found


## 距离与视线在打开及提交时重验，两人的胶囊不允许隔墙交易。
func target_accessible(id: String) -> bool:
	# 1. 失败后事务关闭；真人雪球经伙伴邀请，单人兼容原活动锚点。
	if failure_latched or (is_instance_valid(shared_world.session) and shared_world.session.failure_barrier):
		return false
	if targets.has(id) and targets[id].kind == "event" and is_instance_valid(shared_world.events):
		return shared_world.events.accessible(actor_id,id)
	if targets.has(id) and targets[id].kind == "partner":
		if id != _partner_id() or not is_instance_valid(shared_world.secondary_context) or _peer_model().failure_latched:
			return false
		var peer: CharacterBody3D = _peer_body()
		targets[id].position = peer.global_position + Vector3.UP * .9
		return world.player.global_position.distance_to(peer.global_position) <= 2.0 and clear_line(world.player.global_position + Vector3.UP * .95, targets[id].position, peer.get_rid())
	if targets.has(id) and targets[id].kind == "snowball":
		return actor_id == "p1" and not shared_world.local_controls.active and super.target_accessible(id)
	return super.target_accessible(id)


## 伙伴菜单离开范围即关闭，排队事务仍在父类提交前再次复核。
func _physics_process(delta: float) -> void:
	# 实体机关直接提交一次转动／拉杆，不为每次动作打开占位菜单。
	if _interact_pending and is_instance_valid(shared_world.events):
		var selected := find_nearest()
		if selected.get("kind") == "event":
			_interact_pending = false
			shared_world.events.request_interaction(actor_id,selected.id)
	# 1. 不在渲染或GUI回调中查询物理空间。
	if _session_id == _partner_id() and not target_accessible(_session_id):
		close_session()
		interaction_closed.emit()
	super._physics_process(delta)


## 两种设备都只排队请求，暂停或失败不能结算遗留按钮。
func submit_action(token: int, action: String, amount: int = 1) -> bool:
	# 1. 单次令牌与单槽队列继续由原事务实现消费。
	if get_tree().paused or failure_latched or shared_world.session.failure_barrier:
		return false
	return super.submit_action(token, action, amount)


## 赠送只改变双方行囊，容量不足部分原地保留在赠送者身上。
func _apply_action(request: Dictionary) -> Dictionary:
	# 1. 原有仓储、添柴、拾取继续使用同一个共享世界事务。
	if request.id != _partner_id():
		return super._apply_action(request)
	if request.token != _token or request.id != _session_id:
		return {"ok": false, "message": "操作已失效，请重新靠近。"}
	_token += 1
	if not target_accessible(request.id) or get_tree().paused:
		return {"ok": false, "message": "伙伴已离开或被遮挡。"}
	var count := 0
	var peer: Node = _peer_model()
	match String(request.action):
		"give_wood":
			count = mini(mini(carried, CARRY_CAPACITY - peer.carried), request.amount)
			carried -= count
			peer.carried += count
		"give_ammo":
			# 2. 枪膛和未完成装填不参与赠送，收支独立于公共拾取计数。
			var own: Node3D = world.rifle
			var other: Node3D = shared_world.rifle if actor_id == "p2" else shared_world.secondary_context.rifle
			count = mini(mini(own.reserve, 12 - other.reserve), request.amount)
			own.reserve -= count
			other.reserve += count
			own.rounds_given += count
			other.rounds_received += count
		"snowball":
			var sent: bool = shared_world.snowball_game.invite(actor_id)
			return {"ok":sent,"message":"雪球邀请已发送。" if sent else "请双方在空地内靠近后重试。","activity_action":true}
		_:
			return {"ok": false, "message": "该操作不可用。"}
	# 3. 数量为零不产生收支，历史仅记录已提交的一次转移。
	if count > 0:
		transaction_history.append({"at": world.world_clock.elapsed_seconds, "id": request.id, "action": request.action, "count": count, "from": actor_id, "to": _peer_id()})
		if transaction_history.size() > 128:
			transaction_history.pop_front()
	return {"ok": count > 0, "count": count, "message": "已赠送%d份。" % count if count > 0 else "物资不足或伙伴容量已满。"}


## 描述同时展示双方数量，按钮不预扣物资或锁定对方容量。
func describe(id: String) -> Dictionary:
	# 1. 每次刷新从两套真实能力读取，禁止UI修改共享字典。
	var result := super.describe(id)
	if not result.is_empty() and result.kind == "partner":
		result.peer_carried = _peer_model().carried
		result.reserve = world.rifle.reserve
		result.peer_reserve = (shared_world.rifle if actor_id == "p2" else shared_world.secondary_context.rifle).reserve
		result.snowball_available = shared_world.snowball_game._both_ready() and (actor_id == "p1" or shared_world.local_controls.active)
	return result


## 热源射线排除两个人物，实际墙体仍阻挡室内／营火热量。
func _heat_clear_line(from: Vector3, to: Vector3) -> bool:
	# 1. 人物不阻挡同一炉火的暖意，避免伙伴靠近令另一人意外失温。
	var excluded: Array[RID] = [world.player.get_rid()]
	if is_instance_valid(shared_world.actor_registry):
		excluded = [shared_world.actor_registry.slots.p1.body.get_rid(), shared_world.actor_registry.slots.p2.body.get_rid()]
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, excluded)
	return world.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## 公共柴火须离开双方位置与全部有效本地画面才补充。
func _respawn_due() -> void:
	# 1. 世界装配早期不执行刷新，避免注册表尚未完整时判断可见性。
	if not is_instance_valid(shared_world.actor_registry):
		return
	for record: Dictionary in resources.values():
		if record.quantity == 0 and record.ready_at >= 0 and world.world_clock.elapsed_seconds >= record.ready_at and shared_world.actor_registry.away_from_observers(record.position):
			record.quantity = record.capacity
			record.ready_at = -1.0
	_sync_resources()


## 固定的对方槽位不跟随昵称或设备发生变化。
func _peer_id() -> String:
	# 1. 当前只有计划约定的P1与P2。
	return "p2" if actor_id == "p1" else "p1"


## 每人只开放自己指向伙伴的交互ID。
func _partner_id() -> String:
	# 1. 两个菜单不会共享交互令牌。
	return "actor." + _peer_id() + ".trade"


## 伙伴实体由固定注册表取得。
func _peer_body() -> CharacterBody3D:
	# 1. 真实距离、身体阻挡与目标显示复用同一实体。
	return shared_world.actor_registry.slots[_peer_id()].body


## 伙伴行囊通过实际能力访问，不使用存档缓存。
func _peer_model() -> Node:
	# 1. AI、待命和真人接管均保留同一份随身状态。
	return shared_world.secondary_context.survival if actor_id == "p1" else shared_world.survival


## 倒地者暖意保留，公共燃料仍由世界主实例继续推进。
func _advance_person(delta: float, fraction: float) -> void:
	# 1. 失温和受击共用一次失败锁，救援／返回才解除。
	if not failure_latched:
		super._advance_person(delta, fraction)


## 近处倒地伙伴优先按住救援，其余交互继续使用原单次事务。
func request_interact() -> void:
	# 1. 输入回调不查询空间，使用协调器的物理帧可救缓存。
	if is_instance_valid(shared_world.rescue) and shared_world.rescue.interact_pressed(actor_id):
		return
	if is_instance_valid(shared_world.boss_encounter) and shared_world.boss_encounter.interact_pressed(actor_id):
		return
	super.request_interact()


## 失败只由世界结算方确认，未来客人不能本地创造失败锁或安全返回。
func request_failure(reason: StringName) -> bool:
	# 1. 当前离线始终本地主玩家结算，网络模块复用同一权限边界。
	if is_instance_valid(shared_world.session) and not shared_world.session.local_authority:
		return false
	return super.request_failure(reason)


## 保护跨越长游戏帧时只计算到期后的负向冷暖，暂停不推进世界时间。
func _cold_seconds(delta: float) -> float:
	# 1. 救起与返回的十秒保护不会因60倍功能时钟在最后一帧提前失效。
	var frame_start: float = world.world_clock.elapsed_seconds - delta
	return delta - clampf(protection_until - frame_start, 0.0, delta)
