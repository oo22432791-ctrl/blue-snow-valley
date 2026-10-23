extends "res://scripts/snow/snow_powder.gd"
## 复用八个短爆发池；从新雪边缘上方喷出少量雪粉，不把世界Y误作相对偏移。


## 与脚印和声音共用落脚事件，深处略多，停止不持续刷粒子。
func on_foot_landed(at: Vector3, yaw: float, left: bool, speed: float) -> void:
	# 1. 深度和速度共同决定少量雪粉，池大小和寿命固定。
	if not enabled:
		return
	var burst: GPUParticles3D = _bursts[_cursor]
	var process: ParticleProcessMaterial = burst.process_material
	var depth: float = snow_surface.get_fresh_depth_at(at)
	var effort := clampf(speed/3.6,0,1)
	var deep := smoothstep(0.04,0.30,depth)
	# 2. 积雪在靴子周围被挤出，喷出点取新雪边缘高度，实际脚底仍单独记录。
	var outward := Vector3(cos(yaw),0,-sin(yaw))*(-1.0 if left else 1.0)
	var emission := at+outward*0.13
	emission.y = snow_surface.terrain.get_ground_height(Vector2(emission.x,emission.z))+snow_surface.get_fresh_depth_at(emission)+0.025
	burst.global_position = emission
	burst.rotation.y = yaw
	burst.amount = roundi(lerpf(4,10,clampf(deep*0.65+effort*0.35,0,1)))
	process.direction = Vector3(-0.45 if left else 0.45,1,-0.18)
	process.initial_velocity_max = lerpf(0.5,0.85,clampf(deep+effort*0.2,0,1))
	burst.visible = true
	burst.restart()
	burst.emitting = true
	_expires[_cursor] = _elapsed+burst_lifetime
	_cursor = (_cursor+1)%_bursts.size()
	# 3. 原始接触坐标和喷出点分别记录，验证同帧同步时不混淆两种高度。
	total_bursts += 1
	_last_event = {"position":at,"emission":emission,"left":left,"speed":speed,"depth":depth,"amount":burst.amount,"physics_frame":Engine.get_physics_frames()}
