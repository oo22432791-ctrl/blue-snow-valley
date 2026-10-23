extends "res://scripts/gameplay/snowball.gd"
## V2球体只替换山谷雪面与活动边界，真实接触仍走原一次命中结算。


## 用世界雪高检测落雪，球不会因远离原地图原点立即消失。
func _physics_process(delta: float) -> void:
	# 1. 暂停和失焦冻结年龄、速度，不补算离线抛物线。
	if spent or _suspended: return
	age += delta
	var height: float = game.snow_surface.get_surface_height_at(global_position)
	if linear_velocity.y < 0 and global_position.y <= height + 0.115:
		game.resolve_impact(self, null, Vector3(global_position.x, height, global_position.z))
	# 2. 生命周期沿用2.5秒，空地外额外2米只允许在途球自然落地。
	elif age > 2.5 or not game.CLEARING.grow(2.0).has_point(Vector2(global_position.x, global_position.z)):
		game.retire_ball(self)
