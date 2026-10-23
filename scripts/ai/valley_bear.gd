extends CharacterBody3D
## M10熊：真实碰撞移动、独立离线导航、先警告再追赶及可躲避的抬掌攻击。

const VISUAL=preload("res://scripts/ai/valley_bear_visual.gd")
var world: Node3D
var manager: Node3D
var stable_id: String
var home:=Vector3.ZERO
var state: StringName=&"idle"
var state_age: float=0.0
var transitions: Array[Dictionary]=[]
var visual: Node3D
var path:=PackedVector3Array()
var path_index: int=0
var path_queries: int=0
var distance_travelled: float=0.0
var paw_events: int=0
var attack_serial: int=0
var attack_attempts: int=0
var attack_hits: int=0
var visible_player: bool=false
var player_distance: float=INF
var _rng:=RandomNumberGenerator.new()
var _goal:=Vector3.ZERO
var _repath: float=0.0
var _vision_age: float=0.0
var _lost_sight: float=0.0
var _escaped: float=0.0
var _cooldown: float=0.0
var _phase: float=0.0
var _stuck: float=0.0
var _attack_committed: bool=false
var _knockback:=Vector3.ZERO
var _warning: Label3D
var _idle_seconds: float=2.0
var _chase_started: float=-1.0
var health: int=3
var death_at: float=-1.0
var corpse_removed: bool=false
var _last_shot_serial: int=0


## 读取熊源碰撞与实际骨架；普通运行不生成几何或烘焙导航。
func _ready() -> void:
	# 1. 非球形身体转向与可见熊共享节点旋转，不能只让画面穿过树或墙。
	_rng.seed=3201 if stable_id.ends_with("bend") else 3202
	var manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v2/animals/valley_bear_natural_manifest.json"))
	for record: Dictionary in manifest.colliders:
		var collision:=CollisionShape3D.new();collision.position=Vector3(record.at[0],record.at[1],record.at[2])
		if record.kind=="capsule":
			var shape:=CapsuleShape3D.new();shape.radius=record.radius;shape.height=record.height;collision.shape=shape
		else:
			var shape:=SphereShape3D.new();shape.radius=record.radius;collision.shape=shape
		add_child(collision)
	floor_snap_length=.25
	visual=VISUAL.new();visual.name="BearVisual";add_child(visual)
	_warning=Label3D.new();_warning.position=Vector3(0,1.8,0);_warning.billboard=BaseMaterial3D.BILLBOARD_ENABLED
	_warning.font_size=28;_warning.pixel_size=.008;_warning.modulate=Color("f5d7a8");_warning.outline_size=8;_warning.visible=false;add_child(_warning)
	_goal=home
	world.world_clock.advanced.connect(_advance)


## 游戏计时统一订阅世界钟，物理位移仍保持正常速度，暂停统一冻结。
func _advance(delta: float, _elapsed: float) -> void:
	# 1. 状态期限、视线丢失和脱险保持时间不使用退出后的现实钟。
	state_age+=delta;_cooldown=maxf(0,_cooldown-delta)
	_lost_sight=0.0 if visible_player else _lost_sight+delta
	_escaped=_escaped+delta if player_distance>=18 else 0.0


## 在物理帧更新视线、决策、真实位移及四掌骨骼接触。
func _physics_process(delta: float) -> void:
	# 0. 死亡只采样源倒下动作，不再导航、攻击、接地落印或触发失败。
	if health<=0:
		_warning.visible=false
		if not corpse_removed:visual.sample("Death",clampf(state_age/.75,0,1),delta)
		return
	# 1. 有限距离的可见性检测10Hz，墙／树与开关实体门都能挡住。
	_vision_age-=delta;_repath-=delta
	player_distance=Vector2(global_position.x-world.player.global_position.x,global_position.z-world.player.global_position.z).length()
	if _vision_age<=0:
		_vision_age=.1;visible_player=player_distance<=28 and _clear_to_player()
	var safe: bool=world.interior.shelter_at(world.player.global_position).weather_sheltered
	if (safe or world.survival.failure_latched) and state in [&"warning",&"chase",&"attack",&"recover"]:_return_home()
	if state in [&"chase",&"attack",&"recover"] and _chase_started>=0 and world.world_clock.elapsed_seconds-_chase_started>=25:_return_home()
	_decide(safe)
	# 2. 导航只给方向，速度与重力通过move_and_slide，卡住重查路径而不改位置。
	var direction:=_path_direction() if state in [&"patrol",&"chase",&"return"] else Vector3.ZERO
	var speed: float=(3.0 if state==&"chase" else 1.1)*world.snow_surface.get_speed_scale_at(global_position)
	var target:=direction*speed+_knockback
	velocity.x=move_toward(velocity.x,target.x,8*delta);velocity.z=move_toward(velocity.z,target.z,8*delta)
	_knockback=_knockback.move_toward(Vector3.ZERO,6*delta)
	if not is_on_floor():velocity.y-=24*delta
	else:velocity.y=0
	if direction.length()>.01:rotation.y=lerp_angle(rotation.y,atan2(direction.x,direction.z),1-exp(-8*delta))
	elif state==&"warning":
		var facing: Vector3=world.player.global_position-global_position
		rotation.y=lerp_angle(rotation.y,atan2(facing.x,facing.z),1-exp(-5*delta))
	var before:=global_position;move_and_slide()
	var distance:=Vector2(global_position.x-before.x,global_position.z-before.z).length();distance_travelled+=distance
	if direction.length()>.1 and distance<.002:_stuck+=delta
	else:_stuck=0
	if _stuck>.6:_repath=0
	if _stuck>3:_return_home();_stuck=0
	# 3. 位移和原骨架掌底共同驱动反馈，停止或碰墙不刷原地掌印。
	var moving:=distance/delta>.05;var running:=state==&"chase" and moving
	if moving:_phase+=distance/.9
	var clip: String="Run" if running else ("Walk" if moving else "Idle")
	var sample:=fposmod(_phase,1.0) if moving else fposmod(world.world_clock.elapsed_seconds/3,1.0)
	if state==&"warning":clip="Warning";sample=fposmod(state_age/2,1)
	elif state==&"attack":clip="Swipe";sample=.4*clampf(state_age/.8,0,1)
	elif state==&"recover":clip="Swipe";sample=.4+.6*clampf(state_age/.4,0,1)
	elif state==&"stagger":clip="Hit";sample=clampf(state_age/.45,0,1)
	visual.position.y=world.snow_surface.get_height_at(global_position)
	visual.sample(clip,sample,delta)
	for event: Dictionary in visual.adapt_contacts(world.snow_surface,_phase,moving and state not in [&"attack",&"recover",&"stagger"],running,delta):
		paw_events+=1;manager.paw_landed(self,event)
	_warning.visible=state in [&"warning",&"attack"] and player_distance<18
	_warning.text="熊在警告 · 请后退" if state==&"warning" else "抬掌 · 快避开"


## 所有升级都先经过警告；玩家进屋或失败后不继续连打。
func _decide(safe: bool) -> void:
	# 1. 警告至少2游戏秒，继续接近6米才追，不因瞬间贴身跳过预警。
	match state:
		&"idle":
			if _may_warn(safe):_change(&"warning")
			elif state_age>=_idle_seconds:_choose_patrol()
		&"patrol":
			if _may_warn(safe):_change(&"warning")
			elif _at_goal():_idle_seconds=_rng.randf_range(1.5,3.5);_change(&"idle")
		&"warning":
			if player_distance>12 or _lost_sight>=5:_return_home()
			elif state_age>=2 and player_distance<=6 and visible_player:_chase_started=world.world_clock.elapsed_seconds;_change(&"chase");_repath=0
		&"chase":
			if _escaped>=3 or _lost_sight>=5 or state_age>=25:_return_home()
			elif player_distance<=1.5 and visible_player:
				attack_serial+=1;attack_attempts+=1;_attack_committed=false;_change(&"attack")
			elif _repath<=0:_set_goal(world.player.global_position);_repath=.3
		&"attack":
			if state_age>=.8 and not _attack_committed:
				_attack_committed=true
				# 2. 命中帧再次做真实距离／前方／墙体校验，抬掌之后仍能跑开或进屋。
				var toward: Vector3=world.player.global_position-global_position;toward.y=0
				var in_front: bool=toward.length()<.001 or global_basis.z.dot(toward.normalized())>.35
				if player_distance<=1.5 and in_front and not safe and _clear_to_player():
					attack_hits+=1;manager.attack_landed(self,attack_serial);_return_home()
				else:_change(&"recover")
		&"recover":
			if state_age>=1.5:_change(&"chase");_repath=0
		&"return":
			if _at_goal():_cooldown=4;_idle_seconds=2;_change(&"idle")
		&"stagger":
			if state_age>=.45:_cooldown=1;_return_home()


## 只在没有安全屋遮蔽、没有失败锁且真实可见时预警。
func _may_warn(safe: bool) -> bool:
	# 1. 退回冷却期间忽略玩家，避免警告／退回在同一门槛上不断切换。
	return not safe and not world.survival.failure_latched and _cooldown<=0 and player_distance<=9 and visible_player


## 记录有界状态转换并只在第一次预警发声。
func _change(next: StringName) -> void:
	# 1. 重复状态不重置期限，攻击事件号仅在真正开始抬掌时递增。
	if state==next:return
	transitions.append({"from":String(state),"to":String(next),"at":world.world_clock.elapsed_seconds,"player_distance":player_distance})
	if transitions.size()>64:transitions.pop_front()
	state=next;state_age=0;_lost_sight=0;_escaped=0
	if next==&"warning":manager.play_warning(self)


## 在18米家域内挑选当前地图可达的巡游点，不随机瞬移。
func _choose_patrol() -> void:
	# 1. 所有候选投影到独立熊导航，房屋内部没有可用面。
	var angle:=_rng.randf_range(-PI,PI)
	var distance:=_rng.randf_range(5,18)
	_set_goal(home+Vector3(sin(angle)*distance,0,cos(angle)*distance));_change(&"patrol")


## 结束追赶并按真实路径返回，不在脱险时传回出生点。
func _return_home() -> void:
	# 1. 回程不重新触发警告，回到家域后保留冷却窗口。
	_change(&"return");_set_goal(home)


## 查询已加载的独立熊地图，保守导航不随资源拾取反复重烘焙。
func _set_goal(at: Vector3) -> void:
	# 1. 地面终点统一高度来源；地图返回绕行路径，不直接把直线位移当导航。
	at.y=world.terrain.get_ground_height(Vector2(at.x,at.z))
	path=NavigationServer3D.map_get_path(manager.navigation_map,global_position,at,true)
	path_index=0;path_queries+=1
	_goal=path[-1] if not path.is_empty() else global_position


## 沿短路径逐点行走，实际碰撞受阻后允许后续重选。
func _path_direction() -> Vector3:
	# 1. 略过已经抵达的近点，不越过导航缺口直接追踪玩家。
	while path_index<path.size() and Vector2(path[path_index].x-global_position.x,path[path_index].z-global_position.z).length()<.25:path_index+=1
	if path_index>=path.size():return Vector3.ZERO
	var direction:=path[path_index]-global_position;direction.y=0
	return direction.normalized()


## 到点只按水平距离判断，地面碰撞负责高度。
func _at_goal() -> bool:
	# 1. 空路径作为停步处理，不用瞬移兜底。
	return path.is_empty() or Vector2(_goal.x-global_position.x,_goal.z-global_position.z).length()<.4


## 对玩家胸部查询真实遮挡，自身与目标身体不遮挡这一视线。
func _clear_to_player() -> bool:
	# 1. 房间禁入另有独立判定；这里保证墙、门、树与地形都能阻挡攻击。
	var query:=PhysicsRayQueryParameters3D.create(global_position+Vector3.UP*.95,world.player.global_position+Vector3.UP*.9,1,[get_rid(),world.player.get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## 命中反馈只产生真实击退速度，不通过改位置穿墙；伤害由receive_shot唯一结算。
func receive_hit(from: Vector3, strength: float=1.0) -> Dictionary:
	# 1. 非有限参数拒绝；只产生真实物理速度，不通过改位置穿墙击退。
	if not from.is_finite() or not is_finite(strength) or health<=0:return {"accepted":false}
	var away:=global_position-from;away.y=0
	_knockback=away.normalized()*clampf(strength,0,1.5);_change(&"stagger")
	return {"accepted":true,"bear_id":stable_id,"state":String(state),"health_implemented":true}


## M11一发只造成一次伤害，第三次有效命中进入唯一死亡状态，不掉材料。
func receive_shot(from: Vector3,serial: int) -> Dictionary:
	# 1. 单调射击序号拒绝同发重算；尸体不能继续受伤或重复触发死亡。
	if not from.is_finite() or health<=0 or serial<=_last_shot_serial:return {"accepted":false}
	_last_shot_serial=serial;health-=1
	if health>0:
		receive_hit(from,1.2)
	else:
		# 2. 原有独立导航和实体保留身份，尸体停止阻挡路径／射线，移除和重生由管理器调度。
		death_at=world.world_clock.elapsed_seconds;corpse_removed=false
		velocity=Vector3.ZERO;_knockback=Vector3.ZERO;path.clear();_change(&"dead")
		collision_layer=0;collision_mask=0
		for child: Node in get_children():
			if child is CollisionShape3D:child.set_deferred("disabled",true)
		manager.on_bear_dead(self)
	return {"accepted":true,"bear_id":stable_id,"health":health,"dead":health<=0,"serial":serial}


## 仅在管理器验证期限与视野后恢复同一稳定ID，不用于活熊卡住时传送。
func respawn_after_death() -> void:
	# 1. 恢复初始数量与状态，随机流仍保留；枪械射击序号单调，旧命中不能再次结算。
	if health>0:return
	health=3;death_at=-1;corpse_removed=false;show()
	global_position=Vector3(home.x,world.terrain.get_ground_height(Vector2(home.x,home.z))+.05,home.z)
	velocity=Vector3.ZERO;_knockback=Vector3.ZERO;path.clear();_cooldown=4;_chase_started=-1;_attack_committed=false;_escaped=0;_lost_sight=0;_stuck=0
	collision_layer=1;collision_mask=1
	for child: Node in get_children():
		if child is CollisionShape3D:child.set_deferred("disabled",false)
	visual.reset_contacts();_change(&"idle")


## 暴露M12所需纯数据，包含生命值、尸体移除与游戏时间重生期限；当前不写盘。
func get_state() -> Dictionary:
	# 1. 位置、家域、状态期限与随机流均不依赖节点路径或运行时实例号。
	return {"id":stable_id,"position":[global_position.x,global_position.y,global_position.z],"yaw":rotation.y,"home":[home.x,home.y,home.z],"state":String(state),"state_age":state_age,"rng_state":str(_rng.state),"attack_serial":attack_serial,"cooldown":_cooldown,"health":health,"death_at":death_at,"corpse_removed":corpse_removed,"last_shot_serial":_last_shot_serial,"goal":[_goal.x,_goal.y,_goal.z],"idle_seconds":_idle_seconds,"lost_sight":_lost_sight,"escaped":_escaped,"phase":_phase,"chase_started":_chase_started,"attack_committed":_attack_committed,"knockback":[_knockback.x,_knockback.y,_knockback.z]}


## 仅会话完整校验后恢复持续状态，导航路径重建而非保存服务器RID。
func restore_state(data: Dictionary) -> void:
	# 1. 恢复生命与时间，不通过重生接口重置刚击杀的熊。
	global_position=Vector3(data.position[0],data.position[1],data.position[2]);rotation.y=float(data.yaw);velocity=Vector3.ZERO
	health=int(data.health);state=StringName(data.state);state_age=float(data.state_age);_rng.state=int(data.rng_state)
	attack_serial=int(data.attack_serial);_cooldown=float(data.cooldown);death_at=float(data.death_at);corpse_removed=data.corpse_removed;_last_shot_serial=int(data.last_shot_serial)
	_idle_seconds=float(data.idle_seconds);_lost_sight=float(data.lost_sight);_escaped=float(data.escaped);_phase=float(data.phase);_chase_started=float(data.chase_started);_attack_committed=data.attack_committed
	_knockback=Vector3(data.knockback[0],data.knockback[1],data.knockback[2]);_stuck=0;_repath=0;_vision_age=0;visible_player=false
	path.clear();_goal=Vector3(data.goal[0],data.goal[1],data.goal[2])
	# 2. 实体、尸体显示与源动作保持一致，旧声部与掌印采样不跨会话。
	collision_layer=1 if health>0 else 0;collision_mask=collision_layer
	for child: Node in get_children():
		if child is CollisionShape3D:child.disabled=health<=0
	visible=not corpse_removed;_warning.hide();manager.on_bear_dead(self);visual.reset_contacts()
	if state in [&"patrol",&"chase",&"return"]:_set_goal(_goal)
	if health<=0:visual.sample("Death",clampf(state_age/.75,0,1),0)
