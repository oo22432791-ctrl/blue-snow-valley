extends "res://scripts/v3/actors/valley_v3_survival.gd"
## 复用原事务与空间校验；公共资源引用主世界，P2只持有自己的行囊。

var primary: Node


## 绑定同一份公共字典，不重复生成目标、补给或炉火。
func _ready() -> void:
	# 1. 父类事务在本角色上下文执行，令牌和待提交槽为独立实例。
	actor_id = "p2"
	shared_world = world.shared_world
	stores = primary.stores
	resources = primary.resources
	heaters = primary.heaters
	targets = primary.targets
	last_thermal = {"weight": 0.0, "source": "", "sheltered": false, "rate": 0.0}


## P2暖意由主实例同帧积分，不重复消耗公共炉火。
func _advance(_delta: float, _elapsed: float) -> void:
	# 1. 本实例不推进公共燃料，避免两个角色让世界燃料消耗两次。
	pass


## 公共显示同步由主世界的唯一资源实例负责。
func _sync_resources() -> void:
	# 1. 事务提交修改共享数量后，原同步器会更新真实驻留节点。
	pass


## 世界补充期限只能由主世界推进一次。
func _respawn_due() -> void:
	# 1. P2不创建第二套刷新循环。
	pass


## 双人雪球入口由M7适配，不能用旧AI活动抢走真人P2的控制权。
func target_accessible(id: String) -> bool:
	# 1. 其余门、资源、仓储、燃料与弹药继续使用原真实距离和射线规则。
	if targets.has(id) and targets[id].kind == "snowball":
		return false
	return super.target_accessible(id)
