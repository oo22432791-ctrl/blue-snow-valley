extends "res://scripts/world/snow_valley.gd"
## 第三版入口：共享山谷能力，独立管理角色注册、公共补给与会话边界。

const V3_SESSION = preload("res://scripts/v3/session/valley_v3_session.gd")
const V3_STORE = preload("res://scripts/v3/session/valley_v3_save_store.gd")
const ACTOR_REGISTRY = preload("res://scripts/v3/actors/valley_actor_registry.gd")
const V3_RIFLE = preload("res://scripts/v3/weapons/valley_v3_rifle.gd")
const V3_REGIONS = preload("res://scripts/v3/world/valley_v3_regions.gd")
const ORBIT_CAMERA = preload("res://scripts/v3/camera/valley_orbit_camera.gd")
const VIEW_INPUT = preload("res://scripts/v3/input/valley_view_input.gd")
const VIEW_INTERIOR = preload("res://scripts/v3/views/valley_view_interior.gd")
const VIEW_MANAGER = preload("res://scripts/v3/views/valley_view_manager.gd")
const ACTOR_CONTEXT = preload("res://scripts/v3/actors/valley_actor_context.gd")
const LOCAL_CONTROLS = preload("res://scripts/v3/input/valley_local_controls.gd")
const V3_SURVIVAL_UI = preload("res://scripts/v3/views/valley_v3_survival_ui.gd")
const PARTNER_ACTIVITY = preload("res://scripts/v3/actors/valley_partner_activity.gd")
const DUAL_SNOW = preload("res://scripts/v3/views/valley_dual_snow.gd")
const V3_SURVIVAL = preload("res://scripts/v3/actors/valley_v3_survival.gd")
const V3_BEARS = preload("res://scripts/v3/ai/valley_v3_bears.gd")
const RESCUE = preload("res://scripts/v3/actors/valley_rescue.gd")
const RESCUE_UI = preload("res://scripts/v3/views/valley_rescue_ui.gd")
const RECOVERY_PLAYER = preload("res://scenes/v3/valley_recovery_player.tscn")
const GUARD = preload("res://scripts/v3/ai/valley_guard.gd")
const GUARD_UI = preload("res://scripts/v3/views/valley_guard_ui.gd")
const COMPANION_NAVIGATION = preload("res://assets/environment/v3/m11_companion_navigation.res")
const EXPLORATION_EVENTS = preload("res://scripts/v3/world/valley_exploration_events.gd")
var events: Node3D
var boss_encounter: Node3D
var journey: Node
const CONTROL_SETTINGS = preload("res://scripts/v3/input/valley_control_settings.gd")
const SETTINGS_UI = preload("res://scripts/v3/views/valley_settings_ui.gd")
const COMPACT_HUD = preload("res://scripts/v3/views/valley_compact_hud.gd")
var control_settings = CONTROL_SETTINGS.new()
var settings_ui: CanvasLayer
var compact_hud: CanvasLayer
var guard: Node
var guard_ui: CanvasLayer
var companion_navigation: NavigationRegion3D
var _companion_map := RID()
var rescue: Node
var actor_registry: Node
var view_manager: Node
var secondary_context: Node3D
var local_controls: Node
var v3_progress: Dictionary = {"exploration_event": false, "traversal_event": false,
	"boss_unlocked": false, "boss_defeated": false, "ending_seen": false}


## 在实例化任何会话前确认目录，不允许错误场景配置接触V2进度。
func _ready() -> void:
	# 1. 构造器只做路径判断，当前阶段不创建或读取正式存档。
	var directory_guard = V3_STORE.new()
	directory_guard.directory = save_directory
	if not directory_guard.directory_is_allowed():
		push_error("V3入口拒绝非V3存档目录，山谷未启动。")
		get_tree().quit(ERR_INVALID_PARAMETER)
		return
	# 2. 截图始终归入V3，现有V2场景继续使用原默认目录。
	capture_directory = "user://captures/v3"
	# 本地操作设置不进入世界存档；验证实例始终使用各自隔离目录。
	if save_directory.begins_with("user://validation/"):
		control_settings.directory = save_directory.path_join("local_settings")
	control_settings.load_local()
	super._ready()
	# 3. 每个V3世界初始化一次公共柴火容量；读档随后覆盖剩余数量。
	for resource: Dictionary in survival.resources.values():
		resource.capacity *= 2
		resource.quantity *= 2
	actor_registry = ACTOR_REGISTRY.new()
	actor_registry.name = "ActorRegistry"
	actor_registry.world = self
	add_child(actor_registry)
	regions.additional_actors.append(snowball_game.companion)
	snow_surface.secondary_player = snowball_game.companion
	regions.update_regions()
	# 4. 视图最后装配，复用两个实体和同一World3D，输入仍只控制P1。
	view_manager = VIEW_MANAGER.new()
	view_manager.name = "LocalViews"
	view_manager.world = self
	add_child(view_manager)
	interior.bind_views(view_manager, actor_registry)
	# 5. P2只装配独立随身能力，共享实际世界资源；设备在主菜单选择。
	secondary_context = ACTOR_CONTEXT.new()
	secondary_context.name = "P2Context"
	secondary_context.shared_world = self
	add_child(secondary_context)
	secondary_context.survival.failed.connect(func(reason: StringName) -> void: session._on_actor_failed("p2", reason))
	local_controls = LOCAL_CONTROLS.new()
	local_controls.name = "LocalControls"
	local_controls.world = self
	add_child(local_controls)
	rescue = RESCUE.new()
	rescue.world = self
	rescue.name = "RescueCoordinator"
	add_child(rescue)
	rescue.life_changed.connect(session._sync_failure_buttons)
	rescue.returned.connect(session._after_safe_return)
	var rescue_ui = RESCUE_UI.new()
	rescue_ui.world = self
	add_child(rescue_ui)
	# 6. V3伙伴共用独立的整谷可走导航，原V2局部导航资源不修改。
	_companion_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(_companion_map, true)
	NavigationServer3D.map_set_cell_size(_companion_map, .2)
	NavigationServer3D.map_set_cell_height(_companion_map, .1)
	# M11连续坡面烘焙后，细化本地图边合并栅格，避免把邻近边量化为重叠边。
	NavigationServer3D.map_set_merge_rasterizer_cell_scale(_companion_map, .01)
	companion_navigation = NavigationRegion3D.new()
	companion_navigation.set_navigation_map(_companion_map)
	companion_navigation.navigation_mesh = COMPANION_NAVIGATION
	add_child(companion_navigation)
	var old_controller: Node = snowball_game.controller
	old_controller.set_enabled(false)
	old_controller.get_parent().remove_child(old_controller)
	old_controller.queue_free()
	guard = GUARD.new()
	guard.world = self
	snowball_game.controller = guard
	snowball_game.companion.add_child(guard)
	guard_ui = GUARD_UI.new()
	guard_ui.world = self
	add_child(guard_ui)
	settings_ui = SETTINGS_UI.new()
	settings_ui.world = self
	add_child(settings_ui)
	events = EXPLORATION_EVENTS.new()
	events.name = "ExplorationEvents"
	events.world = self
	add_child(events)
	boss_encounter = load("res://scripts/v3/boss/valley_boss_encounter.gd").new()
	boss_encounter.world = self
	add_child(boss_encounter)
	journey = load("res://scripts/v3/world/valley_journey.gd").new()
	journey.world = self
	add_child(journey)
	compact_hud = COMPACT_HUD.new()
	compact_hud.world = self
	add_child(compact_hud)
	apply_control_settings()
	if not control_settings.load_message.is_empty():
		session._notice(control_settings.load_message)
	# 5. 新镜头说明增加一行后顺延地点／天气，避免覆盖现有状态反馈。
	_location_label.position.y = 174
	_weather_label.position.y = 214
	_status.position.y = 249
	_debug_label.position.y = 289
	session._toast.position = Vector2(24, 230)
	session._toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	session._toast.size.x = minf(620,get_viewport().get_visible_rect().size.x-48)
	_update_version_title()


## 独立导航RID随世界释放，重复新局不留下旧地图。
func _exit_tree() -> void:
	if _companion_map.is_valid():
		NavigationServer3D.map_set_active(_companion_map, false)
		NavigationServer3D.free_rid(_companion_map)


## 装配第三版协调器，父类继续负责地形、输入、天气和现有玩法模块。
func _create_session() -> Node:
	# 1. 所有第三版保存／恢复入口都经过同一个格式和目录边界。
	return V3_SESSION.new()


## 公共盒量翻倍只在V3生效，V2仍使用原4发装箱。
func _create_rifle() -> Node3D:
	# 1. 个人武器和容量保持原规则。
	var weapon = V3_RIFLE.new()
	weapon.shared_world = self
	return weapon


## V3两处精细雪面窗口跟随两个固定角色。
func _create_snow_surface() -> Node3D:
	# 1. 一个共享雪场，两个逐视图精细窗口。
	return DUAL_SNOW.new()


## 两处48米窗口最多各64个脚印块，配置固定128层共享页表。
func _create_snow_tracks() -> Node:
	# 1. 只扩大V3固定显示容量，CPU历史和恢复规则不复制。
	var history = TRACKS.new()
	history.gpu_capacity = 128
	return history


## V3伙伴装配现有十一骨骼场景，单人雪球规则继续复用。
func _create_snowball_game() -> Node3D:
	# 1. 只替换伙伴场景的扩展点，旧版活动规则不在此复制。
	return PARTNER_ACTIVITY.new()


## 同机交互覆盖对应半屏，单人继续使用原完整界面。
func _create_survival_ui() -> CanvasLayer:
	# 1. 不在共享V2界面中添加合作模式判断。
	return V3_SURVIVAL_UI.new()


## P2共享整个世界的暂停边界，并释放独立菜单与设备意图。
func set_session_paused(value: bool) -> void:
	if not value and is_instance_valid(journey) and journey.presenting():
		if journey.menu_requested: journey.toggle_pause()
		return
	if value and is_instance_valid(events):
		events.cancel_transients()
	if value and is_instance_valid(guard_ui):
		guard_ui.close()
	if value and is_instance_valid(guard):
		guard.cancel_requests()
	if not value and is_instance_valid(session) and session.failure_barrier:
		return
	# 1. 设备丢失后必须重连或回主菜单换方案，不能恢复成失去P2的半个合作局。
	if not value and is_instance_valid(local_controls) and local_controls.active and local_controls.scheme == "gamepad" and not local_controls.device_available():
		session._notice("P2手柄未连接 · 请重连，或保存返回主菜单选择P2键盘")
		return
	# 1. 世界装配早期尚无P2能力时仍可使用原启动屏障。
	super.set_session_paused(value)
	if is_instance_valid(local_controls):
		local_controls.pause_changed(value)


## V3两个角色共同维护环境驻留，旧版工厂保持单角色。
func _create_regions() -> Node3D:
	# 1. 第二角色在世界装配完成后注册，不创建重复物理世界。
	return V3_REGIONS.new()


## V3使用独立正交自由镜头，旧版固定镜头不改。
func _create_camera() -> Node3D:
	# 1. 雪面和跟随对象由公共装配顺序注入。
	return ORBIT_CAMERA.new()


## V3按视图隔离遮挡显示，房间和物理查询沿用既有契约。
func _create_interior() -> Node:
	# 1. 不复制小屋或环境的碰撞节点。
	return VIEW_INTERIOR.new()


## 鼠标事件在根窗口路由，随后转换为对应子视口坐标。
func _create_input_router() -> Node:
	# 1. 世界引用在_ready之前设置，焦点生命周期可立即安全清理。
	var router = VIEW_INPUT.new()
	router.world = self
	return router


## 共享能力刷新后保持第三版标题和自由镜头说明。
func _physics_process(delta: float) -> void:
	# 1. 物理与能力仍由相应模块负责，最终HUD改造在M10接入。
	super._physics_process(delta)
	_update_version_title()


## 主菜单不能被Esc绕过；未来客人的暂停输入只发布权限受控请求。
func _on_pause_requested() -> void:
	if is_instance_valid(journey) and journey.presenting():
		journey.toggle_pause()
		return
	if is_instance_valid(guard_ui) and guard_ui.opened:
		guard_ui.close()
		return
	if is_instance_valid(settings_ui) and settings_ui.opened:
		settings_ui.close()
		return
	# 1. 启动时会话可能尚未创建，沿用原有启动屏障。
	if is_instance_valid(session):
		if session.failure_barrier:
			return
		if is_instance_valid(local_controls) and not local_controls.active and local_controls.menus.p1.opened:
			local_controls.menus.p1.close()
			return
		if is_instance_valid(session.main_menu) and session.main_menu.visible:
			return
		if not session.local_authority:
			session.request_pause("p2")
			return
	super._on_pause_requested()


## 每帧共享说明刷新后重申版本，避免暂停或雪球活动把标题恢复成V2。
func _update_version_title() -> void:
	# 1. 仅替换标题，保留当前实际可用的操作说明。
	if is_instance_valid(_controls_label):
		_controls_label.text = _controls_label.text.replace("蓝色雪境 · 山谷探索", "蓝色雪境 · 第三版开发预览")
		_controls_label.hide()


## 应用设备参数时统一释放瞬时动作，读档与模式选择共用同一生效配置。
func apply_control_settings() -> void:
	# 1. 映射对象由消费者持有，提交时不替换其身份。
	local_controls.key_map = control_settings.keyboard
	local_controls.clear_all()
	input_router._release_actions()
	input_router.cancel_orbit()
	for id: String in view_manager.views:
		var key: String = "p1.mouse" if id == "view.p1" else ("p2.gamepad" if local_controls.scheme == "gamepad" else "p2.keyboard")
		var values: Dictionary = control_settings.data.cameras[key]
		var rig: Node3D = view_manager.views[id].rig
		rig.orbit_sensitivity = .22*values.rotation
		rig.zoom_sensitivity = values.zoom
		rig.invert_vertical = values.invert
		_controls_label.text += "\n右键拖动旋转／俯仰 · Home复位当前镜头"


## 双角色生存共享公共燃料，V2仍用单角色原实现。
func _create_survival() -> Node:
	# 1. 世界引用在_ready之前注入。
	var model = V3_SURVIVAL.new()
	model.shared_world = self
	return model


## 合作熊选择有效角色，保留已有导航、模型和动作。
func _create_bears() -> Node3D:
	# 1. 不改变原版熊的默认目标。
	return V3_BEARS.new()


## V3角色另用新增动作源，原V2场景仍加载旧模型。
func _create_player() -> CharacterBody3D:
	# 1. P1与P2使用相同能力场景，不复制不同的生命规则。
	return RECOVERY_PLAYER.instantiate()
