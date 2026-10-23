extends RefCounted
## 固定角色槽位的数据容器：不保存控制设备、视口、昵称或网络连接。

var slot_id: String
var data: Dictionary


## 每个槽位创建独立字典和枪械记录，不引用另一个角色的可变对象。
func _init(id: String = "p2") -> void:
	# 1. 两人按已确认的新局起点各带4根柴、1发膛内弹和5发备用弹。
	slot_id = id
	data = {"slot_id": id, "position": [0.0, 0.0, 0.0], "yaw": 0.0,
		"warmth": 100.0, "life": {"state": "standing", "reason": "", "remaining": 0.0}, "carried": 4, "protection_until": 0.0,
		"rifle": {"equipped": 2, "chamber": 1, "reserve": 5, "fire_serial": 0,
			"shots_fired": 0, "rounds_collected": 0, "rounds_given": 0, "rounds_received": 0, "reload_at": -1.0,
			"last_shot_at": -1.0, "aim_yaw": 0.0}}


## 捕获返回深副本，调用者无法通过修改快照改变运行中库存。
func capture() -> Dictionary:
	# 1. 位置和武器字典也必须隔离，避免浅复制导致串台。
	return data.duplicate(true)


## 只由已完成完整语义与物理校验的会话恢复角色状态。
func restore(validated: Dictionary) -> void:
	# 1. 角色身份由固定槽位决定，不允许读档把P1改成P2。
	assert(validated.slot_id == slot_id)
	data = validated.duplicate(true)
	# 2. 未完成装填不预扣弹，读档只清理动作，不补发物资。
	data.rifle.reload_at = -1.0
