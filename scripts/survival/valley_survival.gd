extends Node
## M9宽松生存：统一时钟驱动暖意、有限柴火与燃料，交互在物理帧原子提交。

signal interaction_opened(target: Dictionary, token: int)
signal action_completed(result: Dictionary)
signal failed(reason: StringName)

const COLD_PER_SECOND: float=80.0/540.0
const WOOD_SECONDS: float=180.0
const FUEL_CAPACITY: float=900.0
const CARRY_CAPACITY: int=20
const STORE_CAPACITY: int=60
const RESPAWN_SECONDS: float=720.0
var world: Node3D
var warmth: float=100.0
var carried: int=4
var stores: Dictionary={"house.safe":0,"house.storage":0,"house.forest":0}
var resources: Dictionary={}
var heaters: Dictionary={}
var targets: Dictionary={}
var failure_latched: bool=false
var failure_count: int=0
var protection_until: float=0.0
var last_thermal: Dictionary={}
var nearest: Dictionary={}
var transaction_history: Array[Dictionary]=[]
var _interact_pending: bool=false
var _action_pending: Dictionary={}
var _session_id: String=""
var _token: int=0
var _refresh_age: float=0.0
var _resource_nodes: Dictionary={}


## 从已确认源清单装配交互锚点，不重建或修改任何Blender源、GLB和导航。
func _ready() -> void:
	# 1. 三屋各有独立仓储与炉子，炉口位置读取实际碰撞源清单。
	for cabin: Node3D in world.landmarks.cabins:
		var id:=String(cabin.get_meta("building_id"))
		var stove:=Vector3.ZERO
		var store:=Vector3.ZERO
		for record: Dictionary in cabin.manifest.collisions:
			if record.name=="Stove":stove=Vector3(record.at[0],record.at[1],record.at[2])
			if record.name in ["WoodBox","Firewood","Crate"]:store=Vector3(record.at[0],record.at[1],record.at[2])
		var heat_id:=id+".heat"
		var position: Vector3=cabin.to_global(Vector3(stove.x,.95,stove.z+.48))
		heaters[heat_id]={"id":heat_id,"site":id,"name":String(cabin.get_meta("display_name"))+"炉子","position":position,"radius":5.0,"fuel_seconds":0.0,"permanent":id=="house.safe","kind":"stove","cabin":cabin}
		targets[heat_id]={"id":heat_id,"site":id,"name":heaters[heat_id].name,"kind":"heater","position":position,"reach":2.0}
		targets[id+".store"]={"id":id+".store","site":id,"name":String(cabin.get_meta("display_name"))+"储柴处","kind":"store","position":cabin.to_global(Vector3(store.x,.9,store.z)),"reach":2.0}
	# 2. 两营火使用M7真实火塘坐标；初始无燃料，石圈与坐凳碰撞不变。
	for site: StringName in world.landmarks.camps_by_id:
		var camp: Node3D=world.landmarks.camps_by_id[site]
		var values: Array=camp.manifest.firepit
		var position: Vector3=camp.to_global(Vector3(values[0],.65,values[2]))
		var id:=String(site)+".heat"
		heaters[id]={"id":id,"site":String(site),"name":world.landmarks.catalogue.camps[String(site)].label+"营火","position":position,"radius":3.0,"fuel_seconds":0.0,"permanent":false,"kind":"camp","cabin":null}
		targets[id]={"id":id,"site":String(site),"name":heaters[id].name,"kind":"heater","position":position,"reach":2.0}
	# 3. 仅把原有可拾枯枝／木柴接入资源，按稳定ID固定1–3根，不重复创建随机资源。
	var index:=0
	for record: Dictionary in world.landmarks.catalogue.props:
		if record.asset not in ["branch_bundle","wood_stack"]:continue
		var id:=String(record.id)
		var quantity:=1+index%3
		var position:=Vector3(record.position[0],record.position[1]+.35,record.position[2])
		resources[id]={"id":id,"quantity":quantity,"capacity":quantity,"ready_at":-1.0,"position":position}
		targets[id]={"id":id,"site":"","name":"散落木柴" if record.asset=="wood_stack" else "可拾枯枝","kind":"resource","position":position,"reach":1.9}
		index+=1
	world.regions.region_loaded.connect(func(_key: Vector2i) -> void:call_deferred("_sync_resources"))
	_sync_resources()
	last_thermal={"weight":0.0,"source":"","sheltered":false,"cold_multiplier":1.0,"rate":-COLD_PER_SECOND}
	world.world_clock.advanced.connect(_advance)


## 物理帧验证空间可达性并提交事务；GUI回调不直接访问物理空间。
func _physics_process(delta: float) -> void:
	# 1. 暖意模拟只消费缓存的真实遮蔽／射线，暂停随场景树冻结。
	last_thermal=thermal_at(world.player.global_position)
	nearest=find_nearest()
	if _interact_pending:
		_interact_pending=false
		if not nearest.is_empty():
			if nearest.kind=="door":world.landmarks.cabins_by_id[StringName(nearest.site)].request_interact(world.player)
			else:open_session(String(nearest.id))
	# 2. 只保留一笔待提交请求，令牌消费后再发结果，重复点击不能重复结算同一事务。
	if not _action_pending.is_empty():
		var request:=_action_pending
		_action_pending={}
		var result:=_apply_action(request)
		action_completed.emit(result)
	# 3. 资源视图按低频同步；数量／补充时刻不依赖区域实例是否驻留。
	_refresh_age+=delta
	if _refresh_age>=.25:
		_refresh_age=0.0
		_sync_resources()
		_respawn_due()


## 昼夜、天气、燃料和暖意共用同一游戏秒数；燃尽跨帧按有效热量比例积分。
func _advance(delta: float, _elapsed: float) -> void:
	# 1. 先缓存燃尽比例，再唯一扣除公共燃料，最后计算角色暖意。
	var active_fraction := _heat_fraction(delta)
	_advance_fuel(delta)
	_advance_person(delta, active_fraction)


## 燃尽跨帧的有效热量按剩余燃料积分。
func _heat_fraction(delta: float) -> float:
	# 1. 永久炉火不消耗库存，有限热源取本帧可燃比例。
	var source: String = last_thermal.source
	if not source.is_empty() and not heaters[source].permanent:
		return minf(delta, float(heaters[source].fuel_seconds)) / maxf(delta, .000001)
	return 1.0


## 公共燃料随世界钟消耗，与附近角色数量无关。
func _advance_fuel(delta: float) -> void:
	# 1. 每个世界只有主生存实例调用一次。
	for heater: Dictionary in heaters.values():
		if not heater.permanent:
			heater.fuel_seconds = maxf(0.0, float(heater.fuel_seconds) - delta)


## 每个角色按自己的实际位置与保护期限计算暖意。
func _advance_person(delta: float, active_fraction: float) -> void:
	# 2. 夜晚1.5倍，峰值风雪额外加1倍；未点火室内只有遮蔽，不自动升温。
	var exposure: Dictionary=world.weather.exposure_at(world.player.global_position)
	var cold_multiplier: float=1.0+.5*float(exposure.night_strength)+float(exposure.storm_strength)*float(exposure.wind_exposure)
	var cold: float=COLD_PER_SECOND*cold_multiplier*(.45 if exposure.weather_sheltered else 1.0)
	var weight: float=last_thermal.weight*active_fraction
	var rate: float=lerpf(-cold,2.0,weight)
	var active_delta: float = _cold_seconds(delta) if rate < 0 else delta
	warmth=clampf(warmth+rate*active_delta,0.0,100.0)
	last_thermal.cold_multiplier=cold_multiplier
	last_thermal.rate=rate*active_delta/maxf(delta,.000001)
	# 3. 失败只发布一次，不扣柴、不传送、不回滚时间；M12负责返回和恢复调用。
	if warmth<=0.0 and not failure_latched:
		request_failure(&"hypothermia")


## 失温与熊攻击共用一次性失败入口，实际返回与损失由M12消费事件。
func request_failure(reason: StringName) -> bool:
	# 1. 同帧两个来源只允许首次发布，不在多个模块重复扣柴或传送。
	if failure_latched or world.world_clock.elapsed_seconds<protection_until:return false
	failure_latched=true;failure_count+=1;failed.emit(reason)
	return true


## 查询最大有效热量；同房间边界、实体墙与距离共同限制，多个火源不叠乘。
func thermal_at(at: Vector3) -> Dictionary:
	# 1. 遮蔽用实际房间内框，不使用屋顶透明度或进入迟滞状态。
	var shelter: Dictionary=world.interior.shelter_at(at)
	var best:=0.0
	var source: String=""
	for id: String in heaters:
		var heater: Dictionary=heaters[id]
		if heater.permanent:
			if String(shelter.building_id)==heater.site:return {"weight":1.0,"source":id,"sheltered":true,"cold_multiplier":1.0,"rate":2.0}
			continue
		if heater.fuel_seconds<=0.0:continue
		if heater.kind=="stove" and String(shelter.building_id)!=heater.site:continue
		var offset: Vector3=at-heater.position
		var distance:=Vector2(offset.x,offset.z).length()
		if distance>=float(heater.radius) or absf(offset.y)>1.8:continue
		if not _heat_clear_line(heater.position,at+Vector3.UP*.9):continue
		# 2. 内80%范围完全回暖，最后20%平滑渐弱，门外不会继承室内热量。
		var weight: float=1.0-smoothstep(float(heater.radius)*.8,float(heater.radius),distance)
		if weight>best:best=weight;source=id
	return {"weight":best,"source":source,"sheltered":shelter.weather_sheltered,"cold_multiplier":1.0,"rate":0.0}


## 执行有限实体射线，允许击中目标本身的碰撞表面，禁止隔墙操作。
func clear_line(from: Vector3, to: Vector3, target_body: RID=RID()) -> bool:
	# 1. 人物自身不遮挡；交互允许终点位于资源包络内，但其他碰撞一律阻挡。
	var query:=PhysicsRayQueryParameters3D.create(from,to,1,[world.player.get_rid()])
	var hit:=world.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or (target_body.is_valid() and hit.rid==target_body) or hit.position.distance_to(to)<.07


## 逐个候选校验距离和同屋边界，返回唯一最近对象，E不会同时触发门和添柴。
func find_nearest() -> Dictionary:
	# 1. 门保留直接E实体开关，其余对象打开菜单；同一事件只选一个最近候选。
	var found: Dictionary={}
	var distance:=INF
	for cabin: Node3D in world.landmarks.cabins:
		if not cabin.can_interact(world.player.global_position):continue
		var hinge: Array=cabin.manifest.door.pivot
		var at: Vector3=cabin.to_global(Vector3(hinge[0]+cabin.manifest.door.at[0],.9,hinge[2]))
		var d: float=world.player.global_position.distance_to(at)
		if d<distance:
			distance=d;found={"id":String(cabin.get_meta("building_id"))+".door","site":String(cabin.get_meta("building_id")),"kind":"door","name":String(cabin.get_meta("display_name"))+"的门"}
	for id: String in targets:
		if not target_accessible(id):continue
		var target: Dictionary=targets[id]
		var d: float=world.player.global_position.distance_to(target.position)
		if d<distance:distance=d;found=target
	return found


## 即时验证目标仍可达，菜单打开后位移或区域卸载不能保留远程操作权。
func target_accessible(id: String) -> bool:
	# 1. 资源耗尽仍可查看补充提示，但不允许从未驻留的远处对象拾取。
	if not targets.has(id):return false
	var target: Dictionary=targets[id]
	var at: Vector3=world.player.global_position
	if at.distance_to(target.position)>float(target.reach):return false
	if String(target.site).begins_with("house.") and String(world.interior.shelter_at(at).building_id)!=String(target.site):return false
	var body:=RID()
	if target.kind=="resource":
		var node: Node3D=world.find_world_object(StringName(id))
		if not is_instance_valid(node):return false
		body=node.structure.get_rid()
	# M13动态伙伴端点位于角色胶囊内部，射线允许命中该唯一对象。
	if target.kind=="snowball" and is_instance_valid(world.snowball_game):
		body=world.snowball_game.companion.get_rid()
	# 2. 仓储端点抬到木箱上方，炉子端点在炉窗前方，墙体仍能阻挡。
	return clear_line(at+Vector3.UP*.95,target.position,body)


## E仅排队一次，下一物理帧重新挑选对象，不在输入回调中查询碰撞。
func request_interact() -> void:
	# 1. UI与暂停由统一输入上下文限制；队列合并键盘重复请求。
	_interact_pending=true


## 在有效目标上建立一次性会话；库存变化后刷新令牌供下一次明确点击。
func open_session(id: String) -> bool:
	# 1. 只有当前可达目标可创建菜单，旧令牌立即作废。
	if not target_accessible(id):return false
	_session_id=id;_token+=1
	interaction_opened.emit(describe(id),_token)
	return true


## 关闭交互使旧按钮与排队点击失效，关闭不会丢失柴火或暂停世界。
func close_session() -> void:
	# 1. 取消尚未提交的请求；已经提交的事务只保留一次结果。
	_session_id="";_token+=1;_action_pending={}


## GUI只提交意图和会话令牌，实际数量／燃料上限在物理帧再次核验。
func submit_action(token: int, action: String, amount: int=1) -> bool:
	# 1. 单个排队槽防止同帧重复点击或相同信号连接导致两次结算。
	if token!=_token or _session_id.is_empty() or not _action_pending.is_empty() or amount<=0:return false
	_action_pending={"token":token,"id":_session_id,"action":action,"amount":mini(amount,STORE_CAPACITY)}
	return true


## 资源、随身、仓储与燃料转移一次提交，不允许负量、溢出或复制。
func _apply_action(request: Dictionary) -> Dictionary:
	# 1. 令牌消费在数量变更之前完成；拒绝过期或已经走远的菜单请求。
	if request.token!=_token or request.id!=_session_id:return {"ok":false,"message":"操作已失效，请重新靠近。"}
	_token+=1
	if not target_accessible(request.id):return {"ok":false,"message":"距离太远或被遮挡，请重新靠近。"}
	var target: Dictionary=targets[request.id]
	var count:=0
	match String(request.action):
		"snowball":
			# M13使用已有单次令牌与物理帧提交，不另建第二条E入口。
			if target.kind!="snowball" or not is_instance_valid(world.snowball_game):return {"ok":false,"message":"这里没有雪球活动。"}
			var started: bool=world.snowball_game.start_match()
			return {"ok":started,"message":"雪球比赛开始。" if started else "请在活动空地内重新靠近伙伴。"}
		"ammo":
			# M11弹药沿用同一个E会话和一次性令牌，不能绕过门／库存最近目标选择。
			if target.kind!="ammo" or not is_instance_valid(world.rifle):return {"ok":false,"message":"这里没有可拾弹药。"}
			return world.rifle.take_ammo(request.id,request.amount)
		"pickup":
			if target.kind!="resource":return {"ok":false,"message":"这里没有可拾木柴。"}
			var resource: Dictionary=resources[request.id]
			count=mini(mini(int(resource.quantity),CARRY_CAPACITY-carried),int(request.amount))
			resource.quantity-=count;carried+=count
			if count>0 and resource.quantity==0:resource.ready_at=world.world_clock.elapsed_seconds+RESPAWN_SECONDS
		"deposit":
			if target.kind!="store":return {"ok":false,"message":"这里不能存放。"}
			count=mini(mini(carried,STORE_CAPACITY-int(stores[target.site])),int(request.amount))
			carried-=count;stores[target.site]+=count
		"withdraw":
			if target.kind!="store":return {"ok":false,"message":"这里不能取出。"}
			count=mini(mini(int(stores[target.site]),CARRY_CAPACITY-carried),int(request.amount))
			stores[target.site]-=count;carried+=count
		"fuel":
			if target.kind!="heater" or heaters[request.id].permanent:return {"ok":false,"message":"安全屋持续温暖，无需添柴。"}
			var heater: Dictionary=heaters[request.id]
			var room:=floori((FUEL_CAPACITY-float(heater.fuel_seconds)+.000001)/WOOD_SECONDS)
			count=mini(mini(carried,room),int(request.amount))
			carried-=count;heater.fuel_seconds+=count*WOOD_SECONDS
		_:
			return {"ok":false,"message":"该操作不可用。"}
	# 2. 只有实际转移计入历史；数量为零时不重设资源补充时刻或追加燃料。
	var result: Dictionary={"ok":count>0,"message":"已转移%d根木柴。" % count if count>0 else "没有可转移的木柴，或容量已满。","count":count,"action":request.action,"id":request.id}
	if count>0:
		transaction_history.append({"at":world.world_clock.elapsed_seconds,"id":request.id,"action":request.action,"count":count,"carried":carried})
		if transaction_history.size()>128:transaction_history.pop_front()
	_sync_resources()
	return result


## 返回可显示的对象状态，正式界面不泄露射线、纹理块或内部令牌。
func describe(id: String) -> Dictionary:
	# 1. 描述为副本，UI不能通过字典引用修改模型状态。
	if not targets.has(id):return {}
	var result: Dictionary=targets[id].duplicate()
	result.carried=carried
	if result.kind=="resource":result.quantity=resources[id].quantity
	if result.kind=="store":result.stored=stores[result.site]
	if result.kind=="heater":result.fuel_seconds=heaters[id].fuel_seconds;result.permanent=heaters[id].permanent
	if result.kind=="ammo" and is_instance_valid(world.rifle):result.merge(world.rifle.describe_pickup(id),true)
	return result


## 区域加载后把独立库存状态映射到原实例，采空对象隐藏并移除其碰撞。
func _sync_resources() -> void:
	# 1. 仅19处可拾道具，实例卸载后移除弱引用，状态仍保留在resources中。
	for id: String in resources:
		var node: Node3D=world.find_world_object(StringName(id))
		if not is_instance_valid(node):_resource_nodes.erase(id);continue
		var visible: bool=resources[id].quantity>0
		if _resource_nodes.has(id) and _resource_nodes[id].get_ref()==node and node.visible==visible:continue
		_resource_nodes[id]=weakref(node)
		node.visible=visible
		for shape: CollisionShape3D in node.structure.get_children():shape.set_deferred("disabled",not visible)


## 到期且离开近处视野才补充，暂停、退出与重复拾取不重置倒计时。
func _respawn_due() -> void:
	# 1. 不用现实时间，也不要求原资源区域持续驻留。
	for id: String in resources:
		var record: Dictionary=resources[id]
		if record.quantity>0 or record.ready_at<0.0 or world.world_clock.elapsed_seconds<float(record.ready_at):continue
		var at: Vector3=record.position
		if world.player.global_position.distance_to(at)<=24.0:continue
		var camera: Camera3D=world.camera_rig.camera
		if camera.is_position_in_frustum(at) and Rect2(Vector2.ZERO,world.get_viewport().get_visible_rect().size).grow(64).has_point(camera.unproject_position(at)):continue
		# 2. 一次补满原定数量；先提交状态，后在同步中恢复模型，避免眼前突然长柴。
		record.quantity=record.capacity;record.ready_at=-1.0
	_sync_resources()


## M12恢复流程将显式调用此接口；M9不自行传送、扣损失或写盘。
func reset_failure(restored_warmth: float=100.0) -> void:
	# 1. 非有限值拒绝恢复，避免存档或未来会话状态污染暖意。
	if not is_finite(restored_warmth):return
	warmth=clampf(restored_warmth,0.0,100.0);failure_latched=false


## 暴露未来快照所需纯数据，节点、RID与事务回调不进入存档数据。
func get_state() -> Dictionary:
	# 1. 每份状态深复制，读取者无法绕过原子库存操作修改运行状态。
	var resource_state: Dictionary={}
	for id: String in resources:resource_state[id]={"quantity":resources[id].quantity,"ready_at":resources[id].ready_at}
	var fuel: Dictionary={}
	for id: String in heaters:fuel[id]=heaters[id].fuel_seconds
	return {"warmth":warmth,"carried":carried,"stores":stores.duplicate(true),"resources":resource_state,"fuel_seconds":fuel,"failure_latched":failure_latched}


## 只接受会话模块已完整验证的快照，旧交互令牌和待提交点击全部撤销。
func restore_state(data: Dictionary) -> void:
	# 1. 数量使用已验证整数，补充期限保留原游戏绝对秒数。
	close_session();_interact_pending=false;_action_pending.clear()
	warmth=float(data.warmth);carried=int(data.carried);failure_latched=false;protection_until=float(data.protection_until)
	for id: String in stores:stores[id]=int(data.stores[id])
	for id: String in heaters:heaters[id].fuel_seconds=float(data.fuel_seconds[id])
	for id: String in resources:
		resources[id].quantity=int(data.resources[id].quantity);resources[id].ready_at=float(data.resources[id].ready_at)
	# 2. 视图从提交后的实际数量重建，不创建新的资源ID。
	_sync_resources();last_thermal=thermal_at(world.player.position);nearest=find_nearest()


## 热源默认使用原版实体视线，合作版排除两个角色自身。
func _heat_clear_line(from: Vector3, to: Vector3) -> bool:
	# 1. 房屋、树与地形继续阻挡热量。
	return clear_line(from, to)


## 默认保留原版按当前时刻判断保护期的行为，V3可细化跨帧积分。
func _cold_seconds(delta: float) -> float:
	# 1. 正向取暖不经过此接口，保护只阻止暖意下降。
	return 0.0 if world.world_clock.elapsed_seconds < protection_until else delta
