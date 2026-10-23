extends Node3D
## 原能力的角色上下文；指向同一个世界，仅替换角色、镜头和随身能力。

const ENDPOINT = preload("res://scripts/v3/input/valley_actor_input.gd")
const SURVIVAL = preload("res://scripts/v3/actors/valley_secondary_survival.gd")
const RIFLE = preload("res://scripts/v3/weapons/valley_v3_rifle.gd")
var shared_world: Node3D
var player: CharacterBody3D
var camera_rig: Node3D
var input_router: Node
var survival: Node
var rifle: Node3D
var landmarks: Node3D
var regions: Node3D
var interior: Node
var weather: Node
var world_clock: Node
var snowball_game: Node3D
var aim_hit: Dictionary = {}
var _has_pointer: bool = false
var aim_yaw: float = 0.0
var selected_target: CharacterBody3D
var _marker: MeshInstance3D
var _cycle_requested: bool = false


## 复用所有世界对象，装配独立输入端点、库存事务和真实枪械。
func _ready() -> void:
	# 1. 上下文只是引用适配，不建立第二个World3D或公共补给。
	player = shared_world.snowball_game.companion
	camera_rig = shared_world.view_manager.views["view.p2"].rig
	landmarks = shared_world.landmarks
	regions = shared_world.regions
	interior = shared_world.interior
	weather = shared_world.weather
	world_clock = shared_world.world_clock
	snowball_game = shared_world.snowball_game
	input_router = ENDPOINT.new()
	input_router.world = shared_world
	add_child(input_router)
	survival = SURVIVAL.new()
	survival.world = self
	survival.primary = shared_world.survival
	add_child(survival)
	rifle = RIFLE.new()
	rifle.actor_id = "p2"
	rifle.shared_world = shared_world
	rifle.world = self
	add_child(rifle)
	aim_yaw = player._visual.rotation.y - deg_to_rad(60)
	camera_rig.aim_override_provider = Callable(self, "query_actor_aim")
	input_router.interact_requested.connect(survival.request_interact)
	# 2. 指示环只属于右视图；实际武器和角色仍可被两人看见。
	_marker = shared_world._aim_marker.duplicate()
	_marker.name = "P2AimMarker"
	_marker.layers = 4
	add_child(_marker)
	process_physics_priority = -5
	set_controlled(false)


## 世界对象始终通过原稳定ID查找，不复制资源注册表。
func find_world_object(id: StringName) -> Node:
	# 1. 生存可达性查询继续命中真实驻留模型。
	return shared_world.find_world_object(id)


## 恢复P2真实随身状态；公共盒量已由主世界一次提交。
func restore_actor(data: Dictionary) -> void:
	aim_hit = {}
	_has_pointer = false
	# 1. 取消旧菜单、瞄准和装填，恢复不自动触发拾取。
	survival.close_session()
	survival.failure_latched = false
	survival._interact_pending = false
	survival.carried = int(data.carried)
	survival.warmth = float(data.warmth)
	survival.protection_until = float(data.protection_until)
	survival.last_thermal = survival.thermal_at(player.global_position)
	var weapon: Dictionary = data.rifle.duplicate(true)
	weapon["pickups"] = shared_world.rifle.get_state().pickups
	rifle.restore_state(weapon)
	aim_yaw = float(data.rifle.aim_yaw)
	selected_target = null


## 单人待命／活动期间不把未接入的P2枪械动画套在雪球NPC上。
func set_controlled(enabled: bool) -> void:
	# 1. 机械动画树只装配一次，退出同机时释放其上身权重。
	player._visual._weapon = rifle if enabled else null
	camera_rig.aim_override_provider = Callable(self, "query_actor_aim") if enabled else Callable()
	if not enabled:
		player._visual._rifle_mix = 0.0
		player._visual._tree.set("parameters/RifleBlend/blend_amount", 0.0)
		selected_target = null
		_marker.hide()
	rifle.visible = enabled
	# 2. CanvasLayer不继承Node3D可见性，P2弹药只由右屏摘要显示。
	rifle._hud.hide()
	rifle.set_physics_process(enabled)
	input_router.context = input_router.Context.EXPLORATION if enabled else input_router.Context.PAUSED


## 每个物理步重新确认目标仍可见；失去目标时只取消锁定，不自动换目标。
func _physics_process(_delta: float) -> void:
	# 1. 雪球锁定由活动验证对手，不沿用熊的40米战斗目标。
	if shared_world.snowball_game.participating:
		_marker.hide()
		_cycle_requested = false
		selected_target = null
		return
	# 1. AI提供真实目标意图，枪械仍通过本人的上下文和枪口结算。
	if shared_world.actor_registry.slots.p2.source == "ai" and is_instance_valid(shared_world.guard):
		selected_target = shared_world.guard.combat_target
		aim_hit = query_actor_aim(Vector2.ZERO, [])
		_has_pointer = is_instance_valid(selected_target)
		_marker.hide()
		return
	var active: bool = input_router.allows_gameplay_input()
	if not active:
		_marker.hide()
		_cycle_requested = false
		return
	if _cycle_requested:
		_cycle_requested = false
		cycle_target()
	if is_instance_valid(selected_target) and not _target_visible(selected_target, false):
		selected_target = null
	if is_instance_valid(selected_target):
		var offset: Vector3 = selected_target.global_position - player.global_position
		aim_yaw = atan2(offset.x, offset.z)
	aim_hit = query_actor_aim(Vector2.ZERO, [])
	_has_pointer = true
	_marker.visible = is_instance_valid(selected_target)
	if _marker.visible:
		_marker.global_position = selected_target.global_position + Vector3.UP * .03


## Tab／LB主动循环当前可见战斗目标，选择本身不会开火。
func request_target_cycle() -> void:
	if shared_world.snowball_game.participating:
		shared_world.snowball_game.cycle_secondary_target()
		return
	# 1. 输入回调只排队，实体视线查询留给物理帧。
	_cycle_requested = true


## Tab／LB主动循环当前可见战斗目标，选择本身不会开火。
func cycle_target() -> void:
	# 1. 候选按稳定ID排序，同一输入不会依赖字典枚举顺序。
	var candidates: Array[CharacterBody3D] = []
	for bear: CharacterBody3D in shared_world.bears.bears:
		if _target_visible(bear, true):
			candidates.append(bear)
	if is_instance_valid(shared_world.boss_encounter) and shared_world.boss_encounter.running():
		var boss: CharacterBody3D = shared_world.boss_encounter.boss
		if _target_visible(boss,true): candidates.append(boss)
	candidates.sort_custom(func(a: CharacterBody3D, b: CharacterBody3D) -> bool: return a.stable_id < b.stable_id)
	if candidates.is_empty():
		selected_target = null
		return
	var index := candidates.find(selected_target)
	selected_target = candidates[(index + 1) % candidates.size()]


## 前方90度、40米、对应相机画面与实体视线共同限制辅助目标。
func _target_visible(target: CharacterBody3D, check_cone: bool) -> bool:
	# 1. 不能选择尸体、画面外或墙另一侧的熊。
	if not is_instance_valid(target) or target.health <= 0:
		return false
	var point: Vector3 = target.aim_point(player) if target.has_method("aim_point") else target.global_position + Vector3.UP * .85
	var offset := point - (player.global_position + Vector3.UP)
	if offset.length() > 40 or not camera_rig.camera.is_position_in_frustum(point):
		return false
	if check_cone and Vector3(sin(aim_yaw), 0, cos(aim_yaw)).dot(Vector3(offset.x, 0, offset.z).normalized()) < cos(PI / 4):
		return false
	var ray := PhysicsRayQueryParameters3D.create(player.global_position + Vector3.UP * 1.1, point, 1, [player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	return hit.is_empty() or hit.collider == target


## 武器沿角色方向或已选目标瞄准，最终命中仍由真实枪口射线决定。
func query_actor_aim(_screen: Vector2, _excluded: Array) -> Dictionary:
	# 1. 无目标不猜最近敌人，不自动开火，也不改P1瞄准点。
	var point := player.global_position + Vector3.UP * 1.0 + Vector3(sin(aim_yaw), 0, cos(aim_yaw)) * 40
	if is_instance_valid(selected_target):
		point = selected_target.aim_point(player) if selected_target.has_method("aim_point") else selected_target.global_position + Vector3.UP * .85
	return {"position": point, "normal": Vector3.UP}
