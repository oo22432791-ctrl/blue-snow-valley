extends "res://scripts/player/player.gd"
## 第二版只替换雪地姿态适配；键盘、碰撞与落脚信号继续使用共享角色控制。


## 真实位移驱动短步深雪动作，身体只跟随压实支撑偏移。
func _update_visual_gait(distance: float, delta: float) -> void:
	# 1. 速度与周期都查询同一雪深，停止、碰墙时不推进相位。
	var stride: float = snow_surface.get_stride_at(global_position)
	if horizontal_speed>0.025:
		_phase += distance/stride*TAU
	# 2. 胶囊保持真实地形碰撞，视觉根只增加有限压实支撑与轻微深雪屈身。
	var depth: float = snow_surface.get_fresh_depth_at(global_position)
	var support: float = snow_surface.get_height_at(global_position)
	var crouch := 0.012*smoothstep(0.12,0.30,depth)
	_visual.position.y = lerpf(_visual.position.y,support-crouch,1.0-exp(-18.0*delta))
	# 3. 动画采样后修正实际脚骨，不添加代理靴子，也不把身体升到新雪顶面。
	_visual.snow_surface = snow_surface
	_visual.stride_scale = stride/0.72
	_visual.update_motion(_phase,horizontal_speed,is_running,delta)
