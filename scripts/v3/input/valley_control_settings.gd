extends RefCounted
## 本机操作配置与世界快照分离；设置菜单使用深拷贝草稿后显式提交。

const KEYS = preload("res://scripts/v3/input/valley_key_bindings.gd")
const ACTION_NAMES = {"forward":"前进", "back":"后退", "left":"向左", "right":"向右", "sprint":"跑步", "interact":"交互／救援", "reload":"装填", "snowball":"雪球装备", "rifle":"猎枪装备", "equipment":"切换装备", "pause":"暂停", "reset":"镜头复位", "command":"伙伴指令", "fire":"射击／投掷", "orbit":"拖动镜头", "target":"选择目标", "close":"关闭交互／退出活动", "look_up":"镜头上转", "look_down":"镜头下转", "look_left":"镜头左转", "look_right":"镜头右转", "zoom_in":"拉近", "zoom_out":"拉远"}
const PAD_DEFAULTS = {"sprint":JOY_BUTTON_LEFT_STICK, "reset":JOY_BUTTON_RIGHT_STICK, "fire":100+JOY_AXIS_TRIGGER_RIGHT, "target":JOY_BUTTON_LEFT_SHOULDER, "reload":JOY_BUTTON_X, "equipment":JOY_BUTTON_Y, "interact":JOY_BUTTON_A, "close":JOY_BUTTON_B, "zoom_in":JOY_BUTTON_DPAD_UP, "zoom_out":JOY_BUTTON_DPAD_DOWN}
var keyboard = KEYS.new()
var data: Dictionary
var directory: String = "user://settings/v3"
var load_message: String = ""


## 默认配置只描述本地设备，不携带世界槽位库存或控制来源。
func _init() -> void:
	data = defaults()


## 返回独立默认值，恢复某页时可保留其他页的配置。
func defaults() -> Dictionary:
	# 1. 每个设备页拥有独立镜头设置，键鼠页的鼠标映射只属于P1。
	var result := {"version":1, "keyboard":KEYS.new().bindings, "mouse":{"fire":MOUSE_BUTTON_LEFT,"orbit":MOUSE_BUTTON_RIGHT}, "gamepad":PAD_DEFAULTS.duplicate(), "cameras":{}}
	for page: String in ["p1.mouse","p2.keyboard","p2.gamepad"]:
		result.cameras[page] = {"rotation":1.0,"zoom":1.0,"invert":false,"deadzone":.2}
	return result


## 完整验证后才替换生效映射，坏配置不产生部分重绑。
func validate(value: Dictionary) -> String:
	# 1. 固定格式和动作集，使说明、输入消费者与持久设置一一对应。
	var expected := defaults()
	if value.get("version") != 1:
		return "操作设置版本不支持"
	for section: String in ["keyboard","mouse","gamepad","cameras"]:
		if not value.get(section) is Dictionary or value[section].size() != expected[section].size():
			return "操作设置不完整："+section
		for key: String in expected[section]:
			if not value[section].has(key):
				return "操作设置缺少动作："+key
	# 2. 所有物理键跨角色互斥，保留Esc与F12的明确出口。
	var used: Dictionary = {}
	for id: String in value.keyboard:
		var token = value.keyboard[id]
		if not token is int or token <= 0 or used.has(token):
			return "键盘动作冲突或无效："+id
		var code: int = token & 0xffffffff
		var location: int = token >> 32
		if code == KEY_F12 or (code == KEY_ESCAPE and id != "p1.pause") or location not in [0,1,2] or (location != 0 and code not in [KEY_SHIFT,KEY_CTRL]):
			return "此键保留或位置无效："+id
		used[token] = id
	# 3. 鼠标滚轮固定缩放；手柄Menu固定暂停，扳机编码与按钮互斥。
	used.clear()
	for action: String in value.mouse:
		var token = value.mouse[action]
		if not token is int or token not in [1,2,3,8,9] or used.has(token):
			return "鼠标按钮冲突或无效"
		used[token] = action
	used.clear()
	for action: String in value.gamepad:
		var token = value.gamepad[action]
		if not token is int or used.has(token) or (token not in [100+JOY_AXIS_TRIGGER_LEFT,100+JOY_AXIS_TRIGGER_RIGHT] and (token < 0 or token > JOY_BUTTON_DPAD_RIGHT or token in [JOY_BUTTON_START,JOY_BUTTON_BACK,JOY_BUTTON_GUIDE])):
			return "手柄按钮冲突、保留或无效："+action
		used[token] = action
	# 4. 拒绝非有限倍率，避免配置文件把镜头传入NaN或越过已确认范围。
	for page: String in expected.cameras:
		var camera = value.cameras[page]
		if not camera is Dictionary or camera.size() != 4 or not camera.get("invert") is bool:
			return "镜头设置不完整"
		for setting: String in ["rotation","zoom","deadzone"]:
			var number = camera.get(setting)
			if not (number is float or number is int) or not is_finite(float(number)):
				return "镜头设置数值无效"
			var low := .1 if setting == "deadzone" else .5
			var high := .35 if setting == "deadzone" else 2.0
			if float(number) < low or float(number) > high:
				return "镜头设置超出范围"
	return ""


## 仅读取本机配置；验证夹具使用自身目录，不读取玩家正式设置。
func load_local() -> void:
	# 1. 缺省配置无需首次启动写盘，损坏文件保留以供用户检查。
	var path := directory.path_join("controls.cfg")
	if not FileAccess.file_exists(path):
		return
	var config := ConfigFile.new()
	if config.load(path) != OK:
		load_message = "操作设置读取失败，本次使用默认设置"
		return
	var value = config.get_value("controls","profile",{})
	var problem: String = validate(value) if value is Dictionary else "操作设置格式错误"
	if not problem.is_empty():
		load_message = problem+"，本次使用默认设置"
		return
	activate(value)


## 保存成功才提交草稿，写入失败时当前游戏映射保持原样。
func apply(value: Dictionary) -> String:
	# 1. 校验整个草稿，先创建本地设置目录再提交到磁盘。
	var problem := validate(value)
	if not problem.is_empty():
		return problem
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if error != OK:
		return "无法创建操作设置目录：%d" % error
	var config := ConfigFile.new()
	config.set_value("controls","profile",value)
	error = config.save(directory.path_join("controls.cfg"))
	if error != OK:
		return "操作设置保存失败：%d" % error
	activate(value)
	return ""


## 深拷贝提交保证取消、恢复默认和后续编辑不改动当前生效配置。
func activate(value: Dictionary) -> void:
	data = value.duplicate(true)
	keyboard.bindings = data.keyboard.duplicate()


## 格式化物理键及左右修饰键，用于操作说明和临时提示。
func key_text(token: int) -> String:
	var code: int = token & 0xffffffff
	var location: int = token >> 32
	return ("右" if location == KEY_LOCATION_RIGHT else "左")+OS.get_keycode_string(code) if code in [KEY_SHIFT,KEY_CTRL] else OS.get_keycode_string(code)


## 同一手柄按钮名称供改键捕获、帮助与救援提示共用。
func pad_text(token: int) -> String:
	if token >= 100:
		return "LT" if token == 100+JOY_AXIS_TRIGGER_LEFT else "RT"
	return {JOY_BUTTON_A:"A",JOY_BUTTON_B:"B",JOY_BUTTON_X:"X",JOY_BUTTON_Y:"Y",JOY_BUTTON_LEFT_SHOULDER:"LB",JOY_BUTTON_RIGHT_SHOULDER:"RB",JOY_BUTTON_LEFT_STICK:"左摇杆按下",JOY_BUTTON_RIGHT_STICK:"右摇杆按下",JOY_BUTTON_DPAD_UP:"十字键↑",JOY_BUTTON_DPAD_DOWN:"十字键↓",JOY_BUTTON_DPAD_LEFT:"十字键←",JOY_BUTTON_DPAD_RIGHT:"十字键→"}.get(token,"按钮%d" % token)


## 角色当前设备决定提示，不将备用设备的键位混进游戏界面。
func hint(actor: String, action: String, gamepad: bool = false) -> String:
	if actor == "p2" and gamepad:
		return "Menu" if action == "pause" else pad_text(data.gamepad.get(action,-1))
	return key_text(keyboard.bindings.get(actor+"."+action,KEY_NONE))
