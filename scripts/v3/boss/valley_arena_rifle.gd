extends Node3D
## 审阅用练习射击：复用实际机械模型与枪口，射线仍被冰壁和伙伴挡住。
const VIEW = preload("res://scripts/weapons/valley_rifle_view.gd")
var actor: CharacterBody3D
var view: Node3D
var equipped := 2
var fire_age := 1.0
var pending := false
var last_hit: Dictionary = {}
var shots := 0
var _yaw := 0.0

## 依赖仅为当前小样角色，不实例化正式武器库存模块。
func _ready() -> void:
	process_physics_priority = 15
	_yaw = actor._visual.rotation.y-deg_to_rad(60)
	view = VIEW.new()
	view.world = actor
	view.weapon = self
	add_child(view)
	actor._visual.configure_rifle(self)

## 使用当前瞄准点提供现有持枪和双手接触所需角度。
func aim_yaw() -> float:
	if not actor.aim_hit.is_empty():
		var direction: Vector3 = actor.aim_hit.position-actor.global_position
		_yaw = atan2(direction.x,direction.z)
	return _yaw

## 练习动画不消耗膛内弹药或备用弹药。
func pose_state() -> Dictionary:
	return {"clip":"RifleFire" if fire_age < .4 else "RifleHold", "normalized":clampf(fire_age/.4,0,1) if fire_age < .4 else 0.0}

## 现有机械视图需要明确装填状态；本小样没有装填和补给事务。
func reloading() -> bool:
	return false

## 机械折管层在练习模式保持闭合。
func reload_fraction() -> float:
	return 0.0

## 输入请求在角色骨骼更新后消费，保证真正从枪口查询阻挡。
func _physics_process(delta: float) -> void:
	fire_age += delta
	view.update_frame(delta)
	if not pending:
		return
	pending = false
	if fire_age < .45:
		return
	fire_age = 0
	shots += 1
	var start: Vector3 = view.marker_position("muzzle")
	var target: Vector3 = actor.aim_hit.get("position",start+view.forward_direction()*40)
	var end := start+(target-start).normalized()*minf(40,start.distance_to(target))
	var space := actor.get_world_3d().direct_space_state
	# 1. 肩至枪口先验证，不能把枪伸入冰壁后从另一面射出。
	var query := PhysicsRayQueryParameters3D.create(view.shoulder_position(),start,1|2|4|8,[actor.get_rid()])
	last_hit = space.intersect_ray(query)
	var blocked := not last_hit.is_empty()
	if not blocked:
		last_hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(start,end,1|2|4|8,[actor.get_rid()]))
	if not last_hit.is_empty():
		end = last_hit.position
	view.on_fired(start,end,blocked,false,not last_hit.is_empty())
	# 2. 不调用Boss伤害或冰壁破坏；真实命中仅作反馈。
