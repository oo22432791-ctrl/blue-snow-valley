extends "res://scripts/snow/valley_snow_surface.gd"
## M5铺装适配：户外完全沿用M4，真实木地板／门廊不再当作屋下积雪。

var cabins: Array[Node3D] = []


## 查询已装配小屋的铺装支撑，没有铺装时返回INF。
func _dry_height(point: Vector3) -> float:
	# 1. 房屋常驻且数量有限，不扫描全部世界对象或创建逐帧射线。
	for cabin in cabins:
		var height: float = cabin.dry_height_at(point)
		if height < INF:
			return height
	return INF


## 让统一落脚入口识别木地板，跳过雪印、压雪声和雪粉。
func is_dry_surface(point: Vector3) -> bool:
	# 1. 与脚底支撑读取同一份铺装数据，不使用独立室内触发标记。
	return _dry_height(point) < INF


## 铺装上没有新雪，户外保留M3原始雪深场。
func get_fresh_depth_at(point: Vector3) -> float:
	# 1. 木地板本身高于屋旁新雪，不修改雪深二进制或全图着色器。
	return 0.0 if is_dry_surface(point) else super.get_fresh_depth_at(point)


## 铺装表面直接取可见地板，户外仍查询M4压痕高度。
func get_surface_height_at(point: Vector3) -> float:
	# 1. 此接口返回世界高度，不能把抬高的地板当作相对雪深。
	var dry := _dry_height(point)
	return dry if dry < INF else super.get_surface_height_at(point)


## 脚骨贴真实地板或斜坡，屋外仍用压实支撑。
func get_support_height_at(point: Vector3) -> float:
	# 1. 地板碰撞已经抬起物理根，不再额外把视觉根抬高一次。
	var dry := _dry_height(point)
	return dry if dry < INF else super.get_support_height_at(point)


## 铺装视觉根相对偏移为零，户外继承M3有限压实偏移。
func get_height_at(point: Vector3) -> float:
	# 1. 动作、阻力和步距继续调用同一提供器，避免室内腿伸向屋下雪地。
	return 0.0 if is_dry_surface(point) else super.get_height_at(point)
