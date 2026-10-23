extends "res://scripts/player/valley_player.gd"
## V3倒地实体保持原位置并使用坐地胶囊，站立仍复用原雪地移动。

var _blocked_shape: bool = false
var event_wind_velocity := Vector3.ZERO


## 每个实体拥有独立胶囊，不能因P2倒地改变P1的物理形状。
func _ready() -> void:
	# 1. 场景资源默认可共享，先复制再调整本角色高度。
	$BodyCollision.shape = $BodyCollision.shape.duplicate()
	super._ready()


## 倒地中只更新实际姿态，不消费键盘、惯性或导航移动。
func _physics_process(delta: float) -> void:
	# 1. 恢复时重新启用原站立胶囊，脚下位置由既有地形碰撞保持。
	_sync_life_shape()
	var blocked: bool = get_meta("life_blocked", false)
	if blocked:
		velocity = Vector3.ZERO
		horizontal_speed = 0.0
		is_running = false
		_visual.snow_surface = snow_surface
		_visual.position.y = snow_surface.get_height_at(global_position)
		_visual.update_motion(_phase, 0.0, false, delta)
		return
	super._physics_process(delta)


func _sync_life_shape() -> void:
	var blocked: bool = get_meta("life_blocked", false)
	if blocked != _blocked_shape:
		_blocked_shape = blocked
		$BodyCollision.shape.height = 1.05 if blocked else 1.5
		$BodyCollision.position.y = .525 if blocked else .75


## 冻结读档后立即使用保存胶囊和位置，胜利救起查询不能看到出生点旧实体。
func sync_restored_pose() -> void:
	_sync_life_shape()
	PhysicsServer3D.body_set_mode(get_rid(),PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_state(get_rid(),PhysicsServer3D.BODY_STATE_TRANSFORM,global_transform)
	PhysicsServer3D.body_set_mode(get_rid(),PhysicsServer3D.BODY_MODE_KINEMATIC)


## 阵风与玩家移动共同进入原CharacterBody物理，不以瞬移模拟侧推。
func _environment_velocity() -> Vector3:
	# 1. 倒地与失焦时不消费环境推力，恢复后由当前阵风重新计算。
	return event_wind_velocity if _input_active and not get_meta("life_blocked",false) else Vector3.ZERO
