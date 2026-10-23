extends RefCounted
## 事件存档纯数据边界；动作队列、渲染角度、AI路线和未结算摔落不入档。

const SOLUTION = [0,2,3]
const INITIAL = [1,3,0]
const PERIOD: float = 12.0


## 旧V3显式迁移从未开始事件，既有已完成标记不被反向清除。
static func initial(progress: Dictionary = {}) -> Dictionary:
	# 1. 每个角色的站位记录独立，世界完成结果继续由共享progress保存。
	return {"discs":SOLUTION.duplicate() if progress.get("exploration_event",false) else INITIAL.duplicate(),"gust_phase":0.0,"actors":{"p1":actor_initial(),"p2":actor_initial()}}


## 未进入栈道的角色没有凭空获得检查点或完整通过记录。
static func actor_initial() -> Dictionary:
	return {"checkpoint":-1,"visited":0,"route_step":-1}


## 当前格式严格验证朝向、相位及角色路径记录，不以默认值修补损坏字段。
static func validate(value: Variant, progress: Dictionary) -> String:
	# 1. 固定动作集和有限数值，拒绝部分或未知事件快照。
	if not value is Dictionary or value.size() != 3 or not value.get("discs") is Array or value.discs.size() != 3 or not value.get("actors") is Dictionary or value.actors.size() != 2:
		return "前置事件状态不完整"
	for disc: Variant in value.discs:
		if not _integer(disc,0,3):
			return "石盘朝向无效"
	var phase: Variant = value.get("gust_phase")
	if not (phase is int or phase is float) or not is_finite(float(phase)) or phase < 0 or phase >= PERIOD:
		return "阵风相位无效"
	# 2. 每个角色分别校验已到平台，不能靠读档制造未走过的阶段。
	for id: String in ["p1","p2"]:
		var actor: Variant = value.actors.get(id)
		if not actor is Dictionary or actor.size() != 3 or not _integer(actor.get("checkpoint"),-1,2) or not _integer(actor.get("visited"),0,7) or not _integer(actor.get("route_step"),-1,2):
			return "栈道角色进度无效："+id
		if actor.checkpoint >= 0 and (int(actor.visited) & (1 << int(actor.checkpoint))) == 0:
			return "安全平台记录不一致："+id
		if actor.checkpoint == -1 and actor.visited != 0:
			return "缺少已到安全平台："+id
		var required: int = (1 << (int(actor.route_step)+1))-1 if actor.route_step >= 0 else 0
		if (int(actor.visited) & required) != required:
			return "栈道通过顺序不一致："+id
	# 3. 成功机关保持锁定；山门只由两项完成结果派生，不单独赠送解锁。
	if progress.get("exploration_event",false) and not aligned(value.discs):
		return "已完成石盘不能被改变"
	if progress.get("boss_unlocked",false) != (progress.get("exploration_event",false) and progress.get("traversal_event",false)):
		return "山门解锁与前置进度不一致"
	return ""


## JSON整值浮点与内存整数表示同一朝向，不以数组元素类型误拒有效存档。
static func aligned(discs: Array) -> bool:
	if discs.size() != 3:
		return false
	for index in range(3):
		if int(discs[index]) != SOLUTION[index]:
			return false
	return true


## JSON整数可解析为整值浮点数，但布尔、字符串和非有限值不是合法阶段。
static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value == floorf(value) and value >= minimum and value <= maximum
