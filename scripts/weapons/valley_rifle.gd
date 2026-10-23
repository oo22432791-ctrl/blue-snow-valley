extends Node3D
## M11单发猎枪：物理帧消费输入，枪口射线、完成才装填和小屋弹药共用有界状态。

const VIEW=preload("res://scripts/weapons/valley_rifle_view.gd")
const RANGE: float=40.0
const RELOAD_SECONDS: float=2.0
const RESERVE_CAPACITY: int=12
var world: Node3D
var view: Node3D
var equipped: int=2
var chamber: int=1
var reserve: int=5
var shots_fired: int=0
var rounds_collected: int=0
var fire_serial: int=0
var pickups: Dictionary={}
var shot_history: Array[Dictionary]=[]
var _reload_at: float=-1.0
var _last_shot_at: float=-1.0
var _pending_fire: bool=false
var _screen:=Vector2.ZERO
var _refresh: float=0.0
var _message: String=""
var _message_until: float=0.0
var _hud: Label
var _aim_yaw_value: float=0.0


## 只装配V2模型、输入消费者与有限HUD，第一版入口不加载本模块。
func _ready() -> void:
	# 1. 角色采样与物理位移之后再更新枪口，避免用上一帧骨架计算命中。
	process_physics_priority=10
	view=VIEW.new();view.world=world;view.weapon=self;add_child(view)
	_aim_yaw_value=world.player._visual.rotation.y-deg_to_rad(60)
	world.player._visual.configure_rifle(self)
	world.input_router.equipment_requested.connect(equip)
	world.input_router.reload_requested.connect(request_reload)
	world.input_router.primary_requested.connect(_request_fire)
	world.world_clock.advanced.connect(_advance)
	world.survival.failed.connect(func(_reason: StringName) -> void:cancel_reload();_pending_fire=false)
	# 2. 弹药HUD不接收点击，拾取仍交给唯一E交互／事务菜单。
	var layer:=CanvasLayer.new();layer.layer=4;add_child(layer)
	_hud=Label.new();_hud.position=Vector2(1030,26);_hud.add_theme_font_size_override("font_size",23)
	_hud.add_theme_color_override("font_color",Color("f1f6fb"));_hud.add_theme_color_override("font_shadow_color",Color("20364f"));_hud.add_theme_constant_override("shadow_offset_x",2);_hud.add_theme_constant_override("shadow_offset_y",2)
	_hud.mouse_filter=Control.MOUSE_FILTER_IGNORE;layer.add_child(_hud)
	_register_pickups()


## 装备切换和新主操作互斥，中断装填不转移任何子弹。
func equip(slot: int) -> void:
	# 1. 小游戏上下文不能切枪；暂停与失焦拒绝直接调用绕过输入路由。
	if not _can_act() or slot not in [1,2]:return
	if equipped==slot:return
	cancel_reload();_pending_fire=false;equipped=slot


## R请求只有空膛且有备用弹时才开启一次两秒装填。
func request_reload() -> void:
	# 1. 装填开始不扣弹；重复R、已装弹或没有弹药不会重置期限。
	if not _can_act() or equipped!=2 or reloading() or chamber>0:return
	if reserve<=0:notice("没有备用弹药 · 可在小屋寻找补给");return
	_reload_at=world.world_clock.elapsed_seconds
	view.play_sound(&"reload")


## 明确的中断只撤销动作，弹药仍保留在原容器。
func cancel_reload() -> void:
	# 1. 完成之前没有预扣备用弹，所以无需补发或回滚数量。
	_reload_at=-1.0


## 装填判定统一暴露给人物动作、机械动作和UI。
func reloading() -> bool:
	# 1. 单个开始时刻避免多计时器重复完成。
	return _reload_at>=0.0


## 角色和枪管使用同一游戏时间进度，暂停后继续而不跳帧补弹。
func reload_fraction() -> float:
	# 1. 已取消或未开启时返回0，不向动画传入负时间。
	return clampf((world.world_clock.elapsed_seconds-_reload_at)/RELOAD_SECONDS,0,1) if reloading() else 0.0


## 当前上身动作由状态决定，不使用独立现实墙钟。
func pose_state() -> Dictionary:
	# 1. 射击后短后坐结束回持枪；切装备不会继续驱动枪械上身动作。
	if reloading():return {"clip":"RifleReload","normalized":reload_fraction()}
	var age: float=world.world_clock.elapsed_seconds-_last_shot_at
	if age<.4:return {"clip":"RifleFire","normalized":clampf(age/.4,0,1)}
	return {"clip":"RifleHold","normalized":fposmod(world.world_clock.elapsed_seconds,1)}


## 正交鼠标瞄准决定人物上身方向，人物侧身60度让枪托与长枪双手握持一致。
func aim_yaw() -> float:
	# 1. 未指向有效位置时维持现有朝向，不把启动时的零坐标当作瞄准。
	if not world.aim_hit.is_empty():
		var direction: Vector3=world.aim_hit.position-world.player.global_position
		if Vector2(direction.x,direction.z).length()>=.12:_aim_yaw_value=atan2(direction.x,direction.z)
	elif not world._has_pointer and world.player.horizontal_speed>.025:
		_aim_yaw_value=atan2(world.player.velocity.x,world.player.velocity.z)
	return _aim_yaw_value


## 世界钟只推进装填与补给期限，退出期间没有离线补充。
func _advance(delta: float,_elapsed: float) -> void:
	# 1. 角色装填与公共补给分开，扩展角色不重复推进世界盒子。
	_advance_reload()
	_advance_pickups(delta)


## 每把枪独立推进装填，不推进公共资源。
func _advance_reload() -> void:
	# 1. GUI／失败会中断；暂停不产生advanced信号，已消耗子弹不会重复装入。
	if reloading():
		if not _can_act() or equipped!=2:cancel_reload()
		elif reload_fraction()>=1:
			if chamber==0 and reserve>0:reserve-=1;chamber=1
			cancel_reload();view.play_sound(&"close")


## 默认单角色维护公共盒子，扩展角色复用同一盒状态。
func _advance_pickups(delta: float) -> void:
	# 1. 数量非零或尚未到期的记录不改期限。
	_refresh+=delta
	if _refresh>=1:
		_refresh=0
		for record: Dictionary in pickups.values():
			if record.quantity==0 and record.ready_at>=0 and world.world_clock.elapsed_seconds>=record.ready_at and _away(record.position):
				record.quantity=4;record.ready_at=-1.0
			_sync_pickup(record)


## 鼠标事件只记录待发请求，不在GUI回调里访问物理空间。
func _request_fire(screen: Vector2) -> void:
	# 1. 同一个物理步最多消费一次点击；UI消费的事件根本不会到达这里。
	if not _can_act() or equipped!=2:return
	_screen=screen;_pending_fire=true


## 正式物理步更新实际枪口后再结算命中，HUD和数量读取同一状态。
func _physics_process(delta: float) -> void:
	# 1. 父世界已更新相机瞄准，玩家已更新真实骨架与踩雪步态。
	view.update_frame(delta)
	if reloading() and not _can_act():cancel_reload()
	if _pending_fire:
		_pending_fire=false
		if _can_act() and equipped==2:_fire()
	# 2. 装备1仅提示后续可选雪球活动，不在探索中启动比赛或向小人开枪。
	_hud.text=("猎枪 · 膛内 %d / 1\n备用 %d / 12\n%s" % [chamber,reserve,"装填 %.1f秒" % ((1-reload_fraction())*2) if reloading() else "左键射击 · R装填 · 1/2切换"]) if equipped==2 else "雪球 · 在安全屋活动区主动开局\n按2切换猎枪"
	if world.world_clock.elapsed_seconds<_message_until:_hud.text+="\n"+_message
	# M13活动使用同一区域计分面板；探索恢复后再显示原装备HUD。
	_hud.visible=not is_instance_valid(world.snowball_game) or not world.snowball_game.participating


## 一发只扣一弹，从真实枪口出发并验证身体到枪口之间也没有穿墙。
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
	if not hit.is_empty() and is_instance_valid(hit.collider) and hit.collider.has_method("receive_shot"):
		damage=hit.collider.receive_shot(muzzle,_damage_serial())
	var record: Dictionary={"serial":fire_serial,"at":now,"from":muzzle,"to":end,"barrel_blocked":not blocked.is_empty(),"collision_name":collision_name,"collision_id":collision_id,"collision_shape":collision_shape,"damage":damage,"chamber":chamber,"reserve":reserve}
	shot_history.append(record)
	if shot_history.size()>64:shot_history.pop_front()
	# 3. 视觉、音效和命中提示只消费已结算的一发，闪光不创建额外物理子弹。
	view.on_fired(muzzle,end,not blocked.is_empty(),not damage.is_empty() and damage.get("accepted",false),not hit.is_empty())
	notice("熊已倒下" if damage.get("dead",false) else ("命中 · 熊已退避" if damage.get("accepted",false) else ("枪口被挡住" if not blocked.is_empty() else "已射击 · 按R装填")))


## 输入许可与正式玩法上下文一致，禁止UI、小游戏、失焦和失败时误射。
func _can_act() -> bool:
	# 1. 直接调用也走相同约束，不能借脚本接口绕过输入路由。
	return world.input_router.allows_gameplay_input() and world.input_router.context==world.input_router.Context.EXPLORATION and not world.survival.failure_latched


## 默认单人命中使用本枪序号，合作版本可提供共享世界序号。
func _damage_serial() -> int:
	# 1. 每人弹药守恒仍使用各自fire_serial。
	return fire_serial


## 短提示使用游戏时刻，暂停不耗掉可见反馈期限。
func notice(text: String) -> void:
	# 1. 后一条结果覆盖前一条，不创建积累的提示节点。
	_message=text;_message_until=world.world_clock.elapsed_seconds+3


## 三屋各放一处补给，位置读取现有桌／工作台，不重建房屋或修改碰撞。
func _register_pickups() -> void:
	# 1. 补给登记为原事务模型的一类目标，E仍只选择最近一个对象。
	for cabin: Node3D in world.landmarks.cabins:
		var table:=Vector3.ZERO
		for record: Dictionary in cabin.manifest.collisions:
			if record.name in ["Table","Workbench"]:
				table=Vector3(float(record.at[0])-float(record.size[0])*.5+.15,float(record.at[1])+float(record.size[1])*.5+.002,record.at[2]);break
		var site:=String(cabin.get_meta("building_id"));var id:=site+".ammo"
		var at: Vector3=cabin.to_global(table)
		pickups[id]={"id":id,"site":site,"position":at,"quantity":4,"ready_at":-1.0}
		world.survival.targets[id]={"id":id,"site":site,"name":String(cabin.get_meta("display_name"))+"弹药盒","kind":"ammo","position":cabin.to_global(Vector3(table.x-.28,.95,table.z)),"reach":2.0}
		var prop: Node3D=view.create_ammo_box(at,cabin.global_rotation.y)
		pickups[id].node=prop
		world.register_world_object(StringName(id),prop)


## 提供菜单副本，不允许UI直接拿到可修改的数量字典。
func describe_pickup(id: String) -> Dictionary:
	# 1. 位置与会话访问权仍由生存交互模型验证。
	if not pickups.has(id):return {}
	return {"quantity":int(pickups[id].quantity),"reserve":reserve,"capacity":RESERVE_CAPACITY}


## 在原单次令牌事务内部转移弹药，满包不清空补给也不重置倒计时。
func take_ammo(id: String,amount: int) -> Dictionary:
	# 1. 二次检查当前位置、数量与容量，实际转移完成才设置恢复时刻。
	if not pickups.has(id) or not world.survival.target_accessible(id):return {"ok":false,"message":"弹药盒已不可达。","count":0}
	var record: Dictionary=pickups[id]
	var count:=mini(mini(int(record.quantity),RESERVE_CAPACITY-reserve),maxi(0,amount))
	record.quantity-=count;reserve+=count;rounds_collected+=count
	if count>0 and record.quantity==0:record.ready_at=world.world_clock.elapsed_seconds+1440
	_sync_pickup(record)
	return {"ok":count>0,"message":"已收取%d发子弹。" % count if count>0 else "备用弹药已满，或盒中无子弹。","count":count,"action":"ammo","id":id}


## 隐去采空补给；恢复只影响这一盒，不重建室内家具。
func _sync_pickup(record: Dictionary) -> void:
	# 1. 盒子无碰撞，不会让原桌面或房屋的物理通道变化。
	if record.has("node") and is_instance_valid(record.node):view.set_box_quantity(record.node,int(record.quantity))


## 补给与熊重生共用近处视野定义：24米内或画面内均不能突然出现。
func _away(at: Vector3) -> bool:
	# 1. 使用人物距离与真实相机，不受相机虚拟离地38米影响。
	if world.player.global_position.distance_to(at)<=24:return false
	var camera: Camera3D=world.camera_rig.camera
	return not (camera.is_position_in_frustum(at) and Rect2(Vector2.ZERO,world.get_viewport().get_visible_rect().size).grow(64).has_point(camera.unproject_position(at)))


## 暂停冻结有限声音，恢复不补播暂停期间的射击请求。
func set_paused(value: bool) -> void:
	# 1. 清理未结算输入；装填由冻结的世界钟保留剩余进度。
	_pending_fire=false;view.set_paused(value)


## 失焦取消未完成的装填和点击，不在恢复焦点时自动开火。
func _notification(what: int) -> void:
	# 1. 不把旧事件或连续按键带入下一次有效输入。
	if what==NOTIFICATION_APPLICATION_FOCUS_OUT:cancel_reload();_pending_fire=false


## 暴露M12需要的数量与稳定ID状态；这里尚不写盘或恢复存档。
func get_state() -> Dictionary:
	# 1. 仅序列化纯数据，不保存可见节点或实例号。
	var boxes: Array=[]
	for record: Dictionary in pickups.values():boxes.append({"id":record.id,"quantity":record.quantity,"ready_at":record.ready_at})
	return {"equipped":equipped,"chamber":chamber,"reserve":reserve,"fire_serial":fire_serial,"shots_fired":shots_fired,"rounds_collected":rounds_collected,"reload_at":_reload_at,"last_shot_at":_last_shot_at,"aim_yaw":_aim_yaw_value,"pickups":boxes}


## 恢复已验证的弹药与补给；未完成装填取消，原备用弹不预扣或补发。
func restore_state(data: Dictionary) -> void:
	# 1. 清理未消费输入和旧特效，恢复单调序号，避免旧命中再次伤害。
	cancel_reload();_pending_fire=false;_screen=Vector2.ZERO;_message="";_message_until=0;shot_history.clear();view.reset_feedback()
	equipped=int(data.equipped);chamber=int(data.chamber);reserve=int(data.reserve)
	fire_serial=int(data.fire_serial);shots_fired=int(data.shots_fired);rounds_collected=int(data.rounds_collected)
	_last_shot_at=float(data.last_shot_at);_aim_yaw_value=float(data.aim_yaw);_refresh=0
	# 2. 各屋余弹与期限独立恢复，不重新赠送整盒弹药。
	for row: Dictionary in data.pickups:
		pickups[row.id].quantity=int(row.quantity);pickups[row.id].ready_at=float(row.ready_at);_sync_pickup(pickups[row.id])
