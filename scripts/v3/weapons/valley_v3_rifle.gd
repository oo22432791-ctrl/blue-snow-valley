extends "res://scripts/weapons/valley_rifle.gd"
## 已确认的V3公共弹药翻倍；个人枪膛和备用弹容量不变。
var actor_id: String = "p1"
var shared_world: Node3D
var rounds_given: int = 0
var rounds_received: int = 0


## 拖动镜头时拒绝新射击，但不打断已在正常世界钟上推进的装填。
func _request_fire(screen: Vector2) -> void:
	# 1. 输入路由是主要屏障，本入口再次拒绝旧回调造成的误射。
	if not world.input_router.drag_view.is_empty():
		return
	if is_instance_valid(shared_world.rescue):
		shared_world.rescue.interrupt(actor_id)
	super._request_fire(screen)


## 双视图观察使用分屏摘要，避免原全屏弹药HUD跨到伙伴视图。
func _physics_process(delta: float) -> void:
	# 1. 保留实际枪口、装填和弹药行为，仅调整当前观察布局的显示。
	super._physics_process(delta)
	# V3统一读取紧凑状态卡，原标签不再显示操作段落。
	_hud.hide()


## 初始公共盒量为8发，模型与空间交互位置继续复用原资产。
func _register_pickups() -> void:
	# 1. P2引用同一套公共盒子，只创建自己的实际枪械。
	if actor_id == "p2":
		pickups = shared_world.rifle.pickups
		return
	# 1. 每个世界只装配一次，读档随后恢复实际余量，不再次翻倍。
	super._register_pickups()
	for record: Dictionary in pickups.values():
		record.quantity = 8
		_sync_pickup(record)


## 只在确实发生一次到期刷新时将新盒量设为8，部分领取不重置。
func _advance(delta: float, elapsed: float) -> void:
	if get_tree().paused:
		return
	# 1. 第二把枪只维护自己的装填，公共盒期限由P1实例唯一推进。
	if actor_id == "p2":
		_advance_reload()
		return
	# 1. 记录刷新前为空的盒子，不对已有剩余量乘二。
	var empty: Array[String] = []
	for id: String in pickups:
		if pickups[id].quantity == 0:
			empty.append(id)
	super._advance(delta, elapsed)
	# 2. 父类已经验证游戏期限与远离条件，只替换本次刷新的世界补给量。
	for id: String in empty:
		if pickups[id].quantity == 4 and pickups[id].ready_at == -1.0:
			pickups[id].quantity = 8
			_sync_pickup(pickups[id])


## V3盒内复用原四发网格增加第二层，实际八个弹位随余量独立显示。
func _sync_pickup(record: Dictionary) -> void:
	# 1. 公共显示节点始终归主世界管理，不因P2收取重复复制弹位。
	if actor_id == "p2":
		shared_world.rifle._sync_pickup(record)
		return
	# 1. 只复制当前实例的网格节点，原GLB／Blender源和V2实例不改。
	if record.has("node") and is_instance_valid(record.node) and not record.node.has_meta("v3_eight_slots"):
		var prop: Node3D = record.node
		for mesh: MeshInstance3D in prop.find_children("*", "MeshInstance3D", true, false):
			var label := String(mesh.name)
			if label.begins_with("BrassCase_") or label.begins_with("CaseBase_") or label.begins_with("SoftPoint_"):
				var extra: MeshInstance3D = mesh.duplicate()
				extra.name = label.get_slice("_", 0) + "_" + str(label.get_slice("_", 1).to_int() + 4)
				mesh.get_parent().add_child(extra)
				extra.global_position = mesh.global_position + Vector3.UP * .024
		prop.set_meta("v3_eight_slots", true)
	# 2. 原视图已支持按名字选择弹位，部分领取也逐发显示而非整盒隐藏。
	super._sync_pickup(record)


## 熊的去重序号使用两把枪累计发数，个人序号继续各自守恒。
func _damage_serial() -> int:
	# 1. 任意交错射击都产生递增世界序号，P2首发不会被P1历史误拒。
	if not is_instance_valid(shared_world) or not is_instance_valid(shared_world.secondary_context):
		return fire_serial
	return shared_world.rifle.fire_serial + shared_world.secondary_context.rifle.fire_serial


## 赠送计数与公共拾取分离，避免把转入弹药伪装为新生成物资。
func get_state() -> Dictionary:
	# 1. 原枪械状态继续保存实际膛内弹、备用弹和动作序号。
	var result := super.get_state()
	result.rounds_given = rounds_given
	result.rounds_received = rounds_received
	return result


## 完整校验之后恢复赠送账目，不因控制模式切换重新发弹。
func restore_state(data: Dictionary) -> void:
	# 1. 旧格式迁移已由快照层显式补零。
	super.restore_state(data)
	rounds_given = int(data.rounds_given)
	rounds_received = int(data.rounds_received)


## 弹药盒刷新同样等待双方离开近处与画面。
func _away(at: Vector3) -> bool:
	# 1. 一个世界只有主枪械实例负责公共补给。
	return is_instance_valid(shared_world.actor_registry) and shared_world.actor_registry.away_from_observers(at)


## V3保留真实枪口阻挡与弹药事务，新增实际命中形状的Boss弱点结算。
func _fire() -> void:
	# 1. 空膛、装填中与冷却中的点击均不结算伤害。
	var now: float=world.world_clock.elapsed_seconds
	if reloading() or now-_last_shot_at<.5:return
	if chamber<=0:notice("空膛 · 按R装填");view.play_sound(&"empty");return
	var excluded: Array[RID]=[world.player.get_rid()]
	var aim: Dictionary=world.camera_rig.query_aim(_screen,excluded)
	var muzzle: Vector3=view.marker_position("muzzle")
	var direction: Vector3=(aim.position-muzzle).normalized() if not aim.is_empty() else view.forward_direction()
	if direction.dot(view.forward_direction())<=0:notice("目标过近 · 请让枪口对准前方");return
	# 2. 枪身伸过墙角时先拦住这一发；不能从墙另一侧的枪口直接穿墙命中熊。
	var guard:=PhysicsRayQueryParameters3D.create(view.shoulder_position(),muzzle,1,excluded);guard.hit_from_inside=true
	var space:=world.get_world_3d().direct_space_state
	var blocked: Dictionary=space.intersect_ray(guard)
	var query:=PhysicsRayQueryParameters3D.create(muzzle,muzzle+direction*RANGE,1,excluded);query.hit_from_inside=true
	var hit: Dictionary=blocked if not blocked.is_empty() else space.intersect_ray(query)
	chamber=0;shots_fired+=1;fire_serial+=1;_last_shot_at=now
	var end: Vector3=hit.position if not hit.is_empty() else muzzle+direction*RANGE
	var damage: Dictionary={}
	var collision_name: String=""
	var collision_id: String=""
	var collision_shape: String=""
	if not hit.is_empty() and is_instance_valid(hit.collider):
		var body: Node=hit.collider
		collision_name=String(body.name)
		collision_id=String(body.get_meta("stable_id",body.name))
		if not body.has_meta("stable_id") and is_instance_valid(body.get_parent()):collision_id=String(body.get_parent().get_meta("stable_id",body.get_parent().get_meta("building_id",collision_id)))
		if body is CollisionObject3D:
			var owner: Object=body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
			if owner is Node:collision_shape=String(owner.name)
	if not hit.is_empty() and is_instance_valid(hit.collider):
		if hit.collider.has_method("receive_shot_hit"):
			damage=hit.collider.receive_shot_hit(hit,actor_id,fire_serial)
		elif hit.collider.has_method("receive_shot"):
			damage=hit.collider.receive_shot(muzzle,_damage_serial())
	var record: Dictionary={"serial":fire_serial,"at":now,"from":muzzle,"to":end,"barrel_blocked":not blocked.is_empty(),"collision_name":collision_name,"collision_id":collision_id,"collision_shape":collision_shape,"damage":damage,"chamber":chamber,"reserve":reserve}
	shot_history.append(record)
	if shot_history.size()>64:shot_history.pop_front()
	# 3. 视觉、音效和命中提示只消费已结算的一发，闪光不创建额外物理子弹。
	view.on_fired(muzzle,end,not blocked.is_empty(),not damage.is_empty() and damage.get("accepted",false),not hit.is_empty())
	var message := "熊已倒下" if damage.get("dead",false) else ("命中 · 熊已退避" if damage.get("accepted",false) else ("枪口被挡住" if not blocked.is_empty() else "已射击 · 按R装填"))
	if not hit.is_empty() and hit.collider.has_method("receive_shot_hit") and damage.get("accepted",false):
		message = "雪熊已被击败" if damage.get("dead",false) else ("肩部弱点 · 40伤害" if damage.get("weak",false) else "命中雪熊 · 20伤害")
	notice(message)
