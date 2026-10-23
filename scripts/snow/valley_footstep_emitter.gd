extends "res://scripts/snow/footstep_emitter.gd"
## V2落脚保留统一信号，但显式区分世界支撑高度与新雪顶面。

signal foot_dragged(from: Vector3, to: Vector3, yaw: float, is_left: bool, speed: float)
var _armed: Array[bool] = [false,false]
var _previous_soles: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _last_drag: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _has_sample: bool = false
var _sample_root := Vector3.ZERO
var _last_moving_speed: float = 0.0


## 真实靴底离开并回到支撑才算落脚，急停延迟收脚也只触发一次。
func _on_actor_moved(_previous: Vector3, current: Vector3, real_velocity: Vector3) -> void:
	# 1. 初始放置或瞬移重置采样，不能在旧位置和新位置之间画长拖痕。
	if not _has_sample or current.distance_to(_sample_root)>0.75:
		for side in range(2):
			_previous_soles[side] = _actor.get_foot_contact_position(side==0)
			_last_drag[side] = _previous_soles[side]
			_armed[side] = false
		_has_sample = true
		_last_moving_speed = 0
	_sample_root = current
	var speed := Vector2(real_velocity.x,real_velocity.z).length()
	if speed>0.025:
		_last_moving_speed = speed
	# 2. 每只脚独立按真实高度进入／离开接触，静止不靠计时器重复触发。
	for side in range(2):
		var left := side==0
		var sole: Vector3 = _actor.get_foot_contact_position(left)
		var support: float = _actor.snow_surface.get_support_height_at(sole)
		var gap := sole.y-support
		if gap>0.035 and _actor.is_on_floor() and _last_moving_speed>0.025:
			_armed[side] = true
		if gap<=0.012 and _armed[side] and _actor.is_on_floor():
			_emit_contact(left,maxf(speed,_last_moving_speed))
			_armed[side] = false
			_last_drag[side] = sole
		# 3. 仅深雪中低位且实际横向移动的脚点留下短拖痕，抬出雪顶后停止。
		var fresh: float = _actor.snow_surface.get_fresh_depth_at(sole)
		var embedded := sole.y<support+fresh-0.055
		var moved := Vector2(sole.x-_last_drag[side].x,sole.z-_last_drag[side].z).length()
		if fresh>0.085 and embedded and moved>=0.03 and _actor.is_on_floor():
			if moved<=0.30 and _last_moving_speed>0.025:
				foot_dragged.emit(_last_drag[side],sole,_actor.get_visual_yaw(),left,maxf(speed,_last_moving_speed))
			_last_drag[side] = sole
		elif not embedded:
			_last_drag[side] = sole
		_previous_soles[side] = sole


## 从修正后的真实脚骨确认地形支撑，再发布本次压入雪面的接触点。
func _emit_contact(is_left: bool, speed: float) -> void:
	# 1. 射线仍验证真实物理支撑，不在悬空、墙侧或掉落期间生成落脚。
	var sole: Vector3 = _actor.get_foot_contact_position(is_left)
	var origin := sole+Vector3.UP*0.55
	var query := PhysicsRayQueryParameters3D.create(origin,origin+Vector3.DOWN*1.4,1,[_actor.get_rid()])
	var hit := _actor.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.dot(Vector3.UP)<0.7:
		return
	# 2. 信号坐标位于真实靴底压实支撑，而非把世界高度误当相对偏移。
	var contact := sole
	contact.y = _actor.snow_surface.get_support_height_at(sole)
	emitted_steps += 1
	foot_landed.emit(contact,_actor.get_visual_yaw(),is_left,speed)


## 会话重定位清除旧落脚采样，不能在读档前后位置之间留下拖痕。
func reset_tracking() -> void:
	# 1. 下一次真实位移重新采样双脚，不制造一次原地落脚。
	_has_sample=false;_armed=[false,false];_last_moving_speed=0.0
