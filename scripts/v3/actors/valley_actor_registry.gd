extends Node
## 角色、控制拥有者和本地视图的注册关系；持久库存不绑定控制来源。

signal control_sources_changed(mode_value: String, epoch: int)

const ACTOR_STATE = preload("res://scripts/v3/actors/valley_actor_state.gd")
const SOURCES: Dictionary = {
	"single_off": {"p1": "local", "p2": "idle"},
	"single_ai": {"p1": "local", "p2": "ai"},
	"local": {"p1": "local", "p2": "local"},
	"lan_host": {"p1": "local", "p2": "remote"},
	"internet_host": {"p1": "local", "p2": "remote"},
	"lan_guest": {"p1": "remote", "p2": "local"},
	"internet_guest": {"p1": "remote", "p2": "local"}}
var world: Node3D
var slots: Dictionary = {}
var local_views: Dictionary = {}
var mode: String = "single_off"
var ownership_epoch: int = 0
var returning_home: bool = false
var home: Vector3
var _home_stalled: float = 0.0
var _home_notice_sent: bool = false
var standby_reached: bool = true


## 复用现有两个实体，固定槽位不依赖昵称或实例编号。
func _ready() -> void:
	# 1. 世界装配已完成，不创建第三个重复的伙伴实体。
	for id: String in ["p1", "p2"]:
		var body: CharacterBody3D = world.player if id == "p1" else world.snowball_game.companion
		var state = ACTOR_STATE.new(id)
		state.data.position = [body.position.x, body.position.y, body.position.z]
		state.data.yaw = body._visual.rotation.y
		slots[id] = {"body": body, "state": state, "source": "idle", "owner": 0}
		body.set_meta("actor_slot", id)
	# 2. 待命点在安全屋旁现有雪球入口，不修改房屋或导航资产。
	home = slots.p2.body.position
	register_view("view.p1", "p1", world.camera_rig.camera, world.get_viewport())
	set_mode("single_off")
	process_physics_priority = -20


## 控制归属只在暂停的主菜单变更，一次交接先清理全部旧控制意图。
func set_mode(value: String) -> Error:
	# 1. 拒绝未知模式；主菜单负责限制尚未开放的玩法入口。
	if not SOURCES.has(value):
		return ERR_INVALID_PARAMETER
	if not get_tree().paused:
		return ERR_BUSY
	world.input_router._release_actions()
	world.rifle.cancel_reload()
	world.rifle._pending_fire = false
	world.snowball_game.controller.set_enabled(false)
	ownership_epoch += 1
	for id: String in slots:
		var binding: Dictionary = slots[id]
		binding.body.set_external_direction(Vector3.ZERO)
		binding.body.velocity = Vector3.ZERO
		binding.state.data.rifle.reload_at = -1.0
		binding.source = SOURCES[value][id]
		binding.owner = (1 if id == "p1" else 2) if binding.source == "local" else 0
		# V3所有来源均通过角色意图移动；单人读档也不能回落旧InputMap。
		binding.body.external_control = true
	mode = value
	# 2. 关闭伙伴仅发起实际导航返程，不能借模式切换瞬移到待命点。
	returning_home = slots.p2.source == "idle" and slots.p2.body.position.distance_to(home) > 0.45
	standby_reached = slots.p2.source == "idle" and not returning_home
	_home_stalled = 0.0
	_home_notice_sent = false
	if returning_home:
		slots.p2.body.get_node("NavigationAgent3D").target_position = home
	elif slots.p2.source == "ai":
		world.snowball_game.controller.set_enabled(true)
	control_sources_changed.emit(mode, ownership_epoch)
	return OK


## 视图ID和角色绑定唯一，摄像机／视口不进入世界存档。
func register_view(id: String, actor_id: String, camera: Camera3D, viewport: Viewport) -> Error:
	# 1. 一台相机不能被两个视图共用，避免未来分屏射线串台。
	if id.is_empty() or not slots.has(actor_id) or not is_instance_valid(camera) or not is_instance_valid(viewport):
		return ERR_INVALID_PARAMETER
	if local_views.has(id):
		return ERR_ALREADY_EXISTS
	for binding: Dictionary in local_views.values():
		if binding.camera.get_ref() == camera:
			return ERR_ALREADY_EXISTS
	local_views[id] = {"actor_id": actor_id, "camera": weakref(camera), "viewport": weakref(viewport)}
	return OK


## 视图销毁由其模块管理，注册表先释放关系，避免模式切换留下旧路由。
func unregister_view(id: String) -> Error:
	# 1. 不释放相机节点，防止跨模块重复销毁；弱引用不持有渲染对象。
	if not local_views.has(id):
		return ERR_DOES_NOT_EXIST
	local_views.erase(id)
	return OK


## 只有当前来源和交接代次匹配的意图可被后续角色能力模块消费。
func accepts_intent(actor_id: String, source: String, epoch: int) -> bool:
	# 1. idle没有 gameplay 权限，过期远端或AI意图不能在交接后继续操作。
	return slots.has(actor_id) and source != "idle" and slots[actor_id].source == source and epoch == ownership_epoch and not get_tree().paused


## 捕获两套独立状态；P1当前通过既有能力适配，P2数据由独立容器保留。
func capture_actors() -> Dictionary:
	# 1. P1状态只从真实生存和枪械模块获取，避免维护两份真值。
	var primary: Dictionary = slots.p1.state.capture()
	primary.warmth = world.survival.warmth
	primary.carried = world.survival.carried
	primary.protection_until = world.survival.protection_until
	primary.rifle = world.rifle.get_state()
	primary.rifle.erase("pickups")
	if world.snowball_game.participating:
		primary.rifle.equipped = world.snowball_game.previous_equipment
	var result: Dictionary = {"p1": primary, "p2": slots.p2.state.capture()}
	# 2. P2能力接入后从真实枪械与行囊捕获，不能保存旧容器中的初始弹药。
	if is_instance_valid(world.secondary_context):
		result.p2.carried = world.secondary_context.survival.carried
		result.p2.warmth = world.secondary_context.survival.warmth
		result.p2.protection_until = world.secondary_context.survival.protection_until
		result.p2.rifle = world.secondary_context.rifle.get_state()
		result.p2.rifle.erase("pickups")
		if world.snowball_game.participating:
			result.p2.rifle.equipped = world.snowball_game.previous_equipment_p2
	# 2. 实体位置和朝向来自各自角色，不保存共享输入或导航目标。
	for id: String in result:
		var body: CharacterBody3D = slots[id].body
		result[id].position = [body.position.x, body.position.y, body.position.z]
		result[id].yaw = body._visual.rotation.y
		if is_instance_valid(world.rescue):
			result[id]["life"] = world.rescue.capture_life(id)
	return result


## 在世界完整预检通过后提交第二角色，P1能力由已有会话适配器恢复。
func restore_actors(actors: Dictionary) -> void:
	# 1. 两容器从深副本恢复，不允许引用存档解析器中的共享对象。
	for id: String in ["p1", "p2"]:
		slots[id].state.restore(actors[id])
	var secondary: CharacterBody3D = slots.p2.body
	var position_data: Array = actors.p2.position
	world.snowball_game.restore_companion(Vector3(position_data[0], position_data[1], position_data[2]))
	secondary._visual.rotation.y = float(actors.p2.yaw)
	if is_instance_valid(world.secondary_context):
		world.secondary_context.restore_actor(actors.p2)
	# 2. 恢复不按存档中的控制模式接管，当前主菜单选择决定来源。
	set_mode(mode)


## 关闭伙伴时沿真实导航返程，受阻提示并在通道恢复后继续。
func _physics_process(delta: float) -> void:
	# 1. 返程是维护行为，不允许旧散步控制器同时发出意图。
	if not returning_home or world.snowball_game.participating or (is_instance_valid(world.rescue) and not world.rescue.can_act("p2")):
		return
	var actor: CharacterBody3D = slots.p2.body
	var agent: NavigationAgent3D = actor.get_node("NavigationAgent3D")
	if NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) == 0:
		return
	if is_instance_valid(world.events) and world.events.drive_ai(home,delta):
		return
	# 栈道临时使用同一导航代理；下坡后必须重新接回原安全屋目标。
	if agent.target_position.distance_to(home) > .05:
		agent.target_position = home
	if actor.position.distance_to(home) <= 0.45:
		returning_home = false
		standby_reached = true
		actor.set_external_direction(Vector3.ZERO)
		return
	var next := agent.get_next_path_position()
	var direction := (next - actor.position) * Vector3(1, 0, 1)
	actor.set_external_direction(direction.normalized())
	_home_stalled = _home_stalled + delta if actor.horizontal_speed < 0.08 else 0.0
	if actor.horizontal_speed > .08:
		_home_notice_sent = false
	# 2. 全谷路程可能超过30秒；只判断实际受阻，不因正常长途步行强行放弃。
	if _home_stalled > 2.0 or (agent.is_navigation_finished() and actor.position.distance_to(home) > 0.6):
		actor.set_external_direction(Vector3.ZERO)
		_home_stalled = 0.0
		if not _home_notice_sent:
			_home_notice_sent = true
			world.rifle.notice("伙伴返回受阻 · 通道恢复后继续")


## 返程受阻仍处于野外，只有真正到达待命点才暂停P2冷暖。
func is_effective(id: String) -> bool:
	# 1. 控制来源切换不制造保护或回暖。
	return id == "p1" or slots[id].source != "idle" or not standby_reached or world.snowball_game.participating


## 补给与动物生命周期同时考虑两个实体和所有显示中的视图。
func away_from_observers(at: Vector3) -> bool:
	# 1. 闲置实体附近也保留现状，避免接管时脚边物资突然刷新。
	for binding: Dictionary in slots.values():
		if binding.body.global_position.distance_to(at) <= 24.0:
			return false
	for id: String in local_views:
		if id == "view.p2" and (not is_instance_valid(world.view_manager) or not world.view_manager.split_enabled):
			continue
		var camera: Camera3D = local_views[id].camera.get_ref()
		var viewport: Viewport = local_views[id].viewport.get_ref()
		if is_instance_valid(camera) and is_instance_valid(viewport) and camera.is_position_in_frustum(at) and Rect2(Vector2.ZERO, viewport.get_visible_rect().size).grow(64).has_point(camera.unproject_position(at)):
			return false
	return true
