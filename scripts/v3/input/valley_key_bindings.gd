extends RefCounted
## 单人及同机键盘共用物理映射，左右修饰键和角色归属独立。

var bindings: Dictionary = {}
var _defaults: Dictionary = {}


## 默认映射先按角色分组，再保留动作的规范键用于输入消费者。
func _init() -> void:
	# 1. 左右修饰键分别编码，不占用数字小键盘。
	var roles := {
		"p1": {"forward": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D, "interact": KEY_E, "reload": KEY_R, "snowball": KEY_1, "rifle": KEY_2, "pause": KEY_ESCAPE, "reset": KEY_HOME, "command": KEY_Q},
		"p2": {"forward": KEY_UP, "back": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT, "look_up": KEY_I, "look_left": KEY_J, "look_down": KEY_K, "look_right": KEY_L, "zoom_in": KEY_U, "zoom_out": KEY_O, "reset": KEY_P, "interact": KEY_ENTER, "reload": KEY_PERIOD, "equipment": KEY_COMMA, "target": KEY_TAB, "close": KEY_BACKSPACE, "pause": KEY_PAUSE}}
	for actor: String in roles:
		for action: String in roles[actor]:
			_defaults[actor + "." + action] = int(roles[actor][action])
	_defaults["p1.sprint"] = KEY_SHIFT + (int(KEY_LOCATION_LEFT) << 32)
	_defaults["p2.sprint"] = KEY_SHIFT + (int(KEY_LOCATION_RIGHT) << 32)
	_defaults["p2.fire"] = KEY_CTRL + (int(KEY_LOCATION_RIGHT) << 32)
	restore_defaults()


## 更改一个动作前检查真实冲突，失败保持原映射不变。
func bind_key(actor: String, action: String, code: Key, location: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> Error:
	# 1. 不添加未消费的动作名；两角色不能拥有同一个物理键。
	var id := actor + "." + action
	if not bindings.has(id) or code == KEY_NONE:
		return ERR_INVALID_PARAMETER
	# Esc保留暂停出口；F12保留当前工程截图，不接受绑定为玩法操作。
	if code == KEY_F12 or (code == KEY_ESCAPE and id != "p1.pause"):
		return ERR_ALREADY_EXISTS
	var effective_location: int = KEY_LOCATION_LEFT if code in [KEY_CTRL, KEY_SHIFT] and location == KEY_LOCATION_UNSPECIFIED else location
	var token := int(code) + ((effective_location << 32) if code in [KEY_CTRL, KEY_SHIFT] else 0)
	for other: String in bindings:
		if other != id and bindings[other] == token:
			return ERR_ALREADY_EXISTS
	bindings[id] = token
	return OK


## 构造默认物理映射，不更改世界库存或角色身份；设置页按设备恢复草稿。
func restore_defaults() -> void:
	# 1. 调用者在变更前释放持续按键，持久化由本地操作配置负责。
	bindings = _defaults.duplicate()


## 查询实际物理事件的拥有者，供GUI前的P2设备隔离使用。
func owner(event: InputEventKey) -> String:
	# 1. 查不到的键没有游戏角色拥有权。
	var token := _token(event)
	for id: String in bindings:
		if bindings[id] == token:
			return id.get_slice(".", 0)
	return ""


## 将实际按键转换为规范动作键，连续与单次输入使用相同映射。
func translate(event: InputEventKey) -> InputEventKey:
	# 1. 原事件不被修改，其他模式和GUI仍能使用原始键值。
	var token := _token(event)
	for id: String in bindings:
		if bindings[id] != token:
			continue
		var canonical: int = _defaults[id]
		var copy := event.duplicate() as InputEventKey
		copy.physical_keycode = canonical & 0xffffffff
		copy.keycode = copy.physical_keycode
		copy.location = canonical >> 32
		return copy
	return null


## 已被重绑的旧默认键必须被消费，不能落回P1旧InputMap。
func was_default_key(event: InputEventKey) -> bool:
	# 1. 未绑定的普通键仍可交给其他界面。
	return _token(event) in _defaults.values()


## 平台未提供左右位置时按左修饰键解释，不猜测P2右修饰键。
func _token(event: InputEventKey) -> int:
	# 1. P2右修饰键必须有明确右侧位置，避免同一键广播给双方。
	var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	var location: int = event.location
	if code in [KEY_SHIFT, KEY_CTRL] and location == KEY_LOCATION_UNSPECIFIED:
		location = KEY_LOCATION_LEFT
	return code + ((location << 32) if code in [KEY_SHIFT, KEY_CTRL] else 0)
