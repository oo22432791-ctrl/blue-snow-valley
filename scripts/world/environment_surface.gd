extends "res://scripts/buildings/cabin_surface.gd"
## M7近脚实体支撑：站在岩石、木柴或坐凳上时沿真实碰撞落脚，雪场本身保持只读。

var _support_frame: int = -1
var _supports: Dictionary[Vector3i,float] = {}


## 优先沿用三屋铺装；只在人物近脚范围查询环境实体的朝上碰撞面。
func _dry_height(point: Vector3) -> float:
	# 1. 保留已确认房屋的解析铺装；角色或物理空间未就绪时不发出射线。
	var cabin_height:=super._dry_height(point)
	if cabin_height<INF:return cabin_height
	if not is_instance_valid(player) or not player.is_inside_tree():return INF
	var nearest: CharacterBody3D
	var excluded: Array[RID] = []
	for actor: CharacterBody3D in _support_actors():
		if not is_instance_valid(actor) or not actor.is_inside_tree():continue
		excluded.append(actor.get_rid())
		if Vector2(point.x-actor.global_position.x,point.z-actor.global_position.z).length_squared()<=1.44:
			nearest=actor
	if nearest==null:return INF
	var ground:float=terrain.get_ground_height(Vector2(point.x,point.z))
	if maxf(point.y,nearest.global_position.y)<ground+.07:return INF
	# 2. 同一物理帧的重复足底查询共用结果，不把射线扩展到雪深网格或整张地图。
	var frame:=Engine.get_physics_frames()
	if frame!=_support_frame:
		_support_frame=frame
		_supports.clear()
	var key:=Vector3i(roundi(point.x*200),roundi(point.y*200),roundi(point.z*200))
	if _supports.has(key):return _supports[key]
	var from:=Vector3(point.x,maxf(point.y,nearest.global_position.y)+.35,point.z)
	var hit:=get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,Vector3(point.x,ground+.01,point.z),1,excluded))
	var height:=INF
	# 3. 仅接收环境资产上表面；竖直墙、树干侧面和原地面不会被误认成干燥铺装。
	if not hit.is_empty() and hit.collider.name==&"EnvironmentStructure" and hit.normal.y>=.65:
		height=hit.position.y
	_supports[key]=height
	return height


## 默认近脚支撑只查询主角，合作版本可提供两个现有角色。
func _support_actors() -> Array[CharacterBody3D]:
	# 1. 不扩大为整图射线，只查询有限人物附近的支撑。
	return [player]
