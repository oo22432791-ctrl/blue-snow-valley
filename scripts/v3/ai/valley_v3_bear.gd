extends "res://scripts/ai/valley_bear.gd"
## 复用实际导航和抬掌规则，目标可在两个有效角色之间选择。

const CONTEXT = preload("res://scripts/v3/ai/valley_bear_context.gd")
var shared_world: Node3D
var target_actor_id: String = "p1"
var _target_age: float = 0.0
var last_landed_attack_serial: int = 0


## 在原熊装配前绑定角色视角，模型、碰撞与声部保持唯一。
func _ready() -> void:
	# 1. 上下文没有新的World3D，原熊地形和时钟引用继续有效。
	shared_world = world
	var context = CONTEXT.new()
	context.shared_world = shared_world
	add_child(context)
	world = context
	super._ready()


## 选择较近、可见且不在有效庇护内的角色，抬掌中锁定原目标。
func _physics_process(delta: float) -> void:
	# 1. 命中前不能把已抬起的掌瞬间改打另一个人。
	_target_age -= delta
	if health > 0 and is_instance_valid(shared_world.actor_registry) and is_instance_valid(shared_world.secondary_context):
		if state in [&"attack", &"recover"]:
			if not _eligible(target_actor_id):
				_return_home()
		elif _target_age <= 0:
			_target_age = .1
			_choose_actor()
	super._physics_process(delta)


## 合作目标过滤不改变原熊对墙、门和树的物理视线要求。
func _clear_to_player() -> bool:
	# 1. 待命、失败或已进屋的角色不能触发预警与命中。
	return _eligible(target_actor_id) and super._clear_to_player()


## 最近候选切换时重新警告，不继承对另一人的追赶计时。
func _choose_actor() -> void:
	# 1. 相同距离按固定槽位顺序处理，避免两角色之间逐帧抖动。
	var selected := ""
	var nearest := INF
	for id: String in ["p1", "p2"]:
		if not _eligible(id):
			continue
		var body: CharacterBody3D = shared_world.actor_registry.slots[id].body
		var distance := Vector2(body.global_position.x - global_position.x, body.global_position.z - global_position.z).length()
		if distance > 28 or distance >= nearest:
			continue
		var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * .95, body.global_position + Vector3.UP * .9, 1, [get_rid(), body.get_rid()])
		if get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			selected = id
			nearest = distance
	if selected.is_empty():
		if state in [&"warning", &"chase"] and not _eligible(target_actor_id):
			_return_home()
		return
	if selected == target_actor_id:
		return
	target_actor_id = selected
	world.target_actor_id = selected
	visible_player = false
	_vision_age = 0
	if state in [&"warning", &"chase"]:
		_change(&"warning")
		state_age = 0
		_chase_started = -1


## 只有实际活动角色和未到待命点的返程角色可以成为攻击对象。
func _eligible(id: String) -> bool:
	# 1. 失败屏障冻结全局，保护期限仍由既有失败入口核验。
	if not is_instance_valid(shared_world.actor_registry) or not is_instance_valid(shared_world.secondary_context):
		return false
	var body: CharacterBody3D = shared_world.actor_registry.slots[id].body
	var model: Node = shared_world.survival if id == "p1" else shared_world.secondary_context.survival
	return shared_world.actor_registry.is_effective(id) and not model.failure_latched and not shared_world.interior.shelter_at(body.global_position).weather_sheltered


## 目标身份持久保存，读档不能把针对P2的抬掌改为命中P1。
func get_state() -> Dictionary:
	# 1. 目标为固定槽位字符串，不保存节点或设备身份。
	var result := super.get_state()
	result.target_actor_id = target_actor_id
	result.last_landed_attack_serial = last_landed_attack_serial
	return result


## 完整快照恢复目标后再恢复动作期限与导航。
func restore_state(data: Dictionary) -> void:
	# 1. 旧格式由快照迁移明确指定P1。
	last_landed_attack_serial = int(data.last_landed_attack_serial)
	target_actor_id = data.target_actor_id
	world.target_actor_id = target_actor_id
	_target_age = 0
	super.restore_state(data)
	# 路径可以重建，已保存的逻辑终点不随多次导航投影漂移。
	_goal = Vector3(data.goal[0],data.goal[1],data.goal[2])
