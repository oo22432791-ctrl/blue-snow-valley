extends RigidBody3D
## 有寿命、连续碰撞检测的实体雪球；每球至多结算一次命中。

var game: Node
var thrower: CharacterBody3D
var age: float = 0.0
var spent: bool = false
var _suspended: bool = false
var _saved_velocity := Vector3.ZERO


## 接入物理接触信号，发射者碰撞例外由游戏在生成前设置。
func _ready() -> void:
	# 1. 重复接触由spent锁保护，不依赖碰撞信号发送次数。
	body_entered.connect(_on_body_entered)


## 补充可见雪面接触与寿命限制，避免只撞到着色器下的平面地板。
func _physics_process(delta: float) -> void:
	# 1. 暂停或已结算的球不再推进寿命和雪面检查。
	if spent or _suspended:
		return
	age += delta
	var snow_height: float = game.snow_surface.get_height_at(global_position)
	if linear_velocity.y < 0.0 and global_position.y <= snow_height + 0.115:
		game.resolve_impact(self, null, Vector3(global_position.x, snow_height, global_position.z))
	elif age > 2.5 or absf(global_position.x) > 14.0 or absf(global_position.z) > 14.0:
		game.retire_ball(self)


## 角色与环境都阻挡雪球，评分由中央回合逻辑核验目标。
func _on_body_entered(body: Node) -> void:
	# 1. 不在物理回调中反弹或重新启用已结算的球。
	if not spent:
		game.resolve_impact(self, body, global_position)


## 失焦时冻结实体物理，恢复后续接原速度。
func set_suspended(value: bool) -> void:
	# 1. 只在状态改变时写速度，避免逐帧操控刚体积分。
	if value == _suspended or spent:
		return
	_suspended = value
	if value:
		_saved_velocity = linear_velocity
		freeze = true
	else:
		freeze = false
		linear_velocity = _saved_velocity
