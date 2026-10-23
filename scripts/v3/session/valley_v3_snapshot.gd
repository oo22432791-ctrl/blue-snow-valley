extends "res://scripts/session/valley_snapshot.gd"
## M0单角色过渡快照：显式V3身份；不是M2双角色或跨模式完成品。

const V3_STORE = preload("res://scripts/v3/session/valley_v3_save_store.gd")


## 从现有山谷能力捕获数据，再附加独立V3身份，禁止借目录区分版本。
func capture(world: Node3D, protection_until: float) -> Dictionary:
	# 1. 地形、天气、资源、枪械和普通熊仍使用当前已实现的规则。
	var data: Dictionary = super.capture(world, protection_until)
	# 2. 标明过渡阶段，后续不能把本快照误当成双角色完整快照。
	data.version = V3_STORE.BOOTSTRAP_VERSION
	data.world = V3_STORE.WORLD_ID_V3
	data["implementation_stage"] = "m0_bootstrap"
	return data


## 先拒绝旧版和未知V3格式，之后在内存副本上复用现有完整语义校验。
func validate(data: Dictionary, world: Node3D) -> String:
	# 1. 这一步先于任何世界恢复；不把V2数据转换为V3数据。
	var guard = V3_STORE.new()
	if not guard._is_bootstrap(data):
		return "第三版存档版本或开发阶段不兼容，原文件已保留"
	# 2. 仅为共享校验器构造临时视图，不改变原数据，也不写回V2格式。
	var validation_data := data.duplicate(true)
	validation_data.version = VERSION
	validation_data.world = WORLD_ID
	return super.validate(validation_data, world)
