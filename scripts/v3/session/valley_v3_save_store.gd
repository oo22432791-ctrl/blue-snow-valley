extends "res://scripts/session/valley_save_store.gd"
## V3磁盘边界：复用原子写入，但拒绝V2目录、V2载荷及未知开发阶段。

const SAVE_DIRECTORY: String = "user://saves/v3"
const VALIDATION_ROOT: String = "user://validation/v3"
const WORLD_ID_V3: String = "blue_snow_valley_v3"
const BOOTSTRAP_VERSION: int = 300
const ACTOR_VERSION: int = 302
const SURVIVAL_VERSION: int = 303
const RESCUE_VERSION: int = 306
const PARTNER_VERSION: int = 307
const EVENT_VERSION: int = 311
const BOSS_VERSION: int = 313
const JOURNEY_VERSION: int = 314


## 构造时即使用V3目录，避免独立使用存储器时落入V2默认目录。
func _init() -> void:
	# 1. 会话后续可显式指定V3测试子目录，不能指定其他版本目录。
	directory = SAVE_DIRECTORY


## 解析为规范绝对路径，拒绝通过父目录跳转绕过V3隔离边界。
func directory_is_allowed() -> bool:
	# 1. 正式存档只允许V3根目录；功能验证只允许独立测试子目录。
	var target := ProjectSettings.globalize_path(directory).simplify_path()
	var production := ProjectSettings.globalize_path(SAVE_DIRECTORY).simplify_path()
	var validation := ProjectSettings.globalize_path(VALIDATION_ROOT).simplify_path()
	return target == production or target.begins_with(validation + "/")


## 在打开文件之前检查路径，任何拒绝均不读取旧版存档。
func read_slot(backup: bool = false) -> Dictionary:
	# 1. 主档与备份共用相同路径约束，不因恢复入口而放宽。
	if not directory_is_allowed():
		return _directory_error()
	return super.read_slot(backup)


## 摘要校验后验证V3身份，不尝试识别或导入V2载荷。
func decode(raw: String) -> Dictionary:
	# 1. 复用长度外的封装校验与可选语义校验，再要求明确版本身份。
	var envelope_parser := JSON.new()
	if envelope_parser.parse(raw) != OK:
		return {"ok": false, "message": "存档损坏：文件未写完整，原文件已保留"}
	# 2. 显式解析错误作为可恢复结果，不把玩家坏档打印成引擎脚本错误。
	if envelope_parser.data is Dictionary and envelope_parser.data.get("payload") is String:
		var payload_parser := JSON.new()
		if payload_parser.parse(envelope_parser.data.payload) != OK:
			return {"ok": false, "message": "存档损坏：快照未写完整，原文件已保留"}
	var result: Dictionary = super.decode(raw)
	if result.ok and not _is_supported(result.snapshot):
		return {"ok": false, "message": "第三版存档格式不兼容，原文件已保留"}
	return result


## 写入前校验目录与版本，沿用临时文件、摘要及上次有效备份。
func write_snapshot(snapshot: Dictionary) -> Dictionary:
	# 1. 在创建目录或临时文件之前拒绝不兼容数据。
	if not directory_is_allowed():
		return _directory_error()
	if not _is_supported(snapshot):
		return {"ok": false, "message": "第三版存档格式不兼容，未写入文件"}
	return super.write_snapshot(snapshot)


## 显式保留坏档同样受目录约束，不允许借归档操作移动V2文件。
func archive_current(backup: bool = false) -> Error:
	# 1. 只有界面明确选择新局或恢复时，父类才保留当前问题文件。
	if not directory_is_allowed():
		return ERR_INVALID_PARAMETER
	return super.archive_current(backup)


## 识别历史M0过渡格式，M2将其作为明确的V3内部迁移输入。
func _is_bootstrap(data: Dictionary) -> bool:
	# 1. 不能用Godot隐式类型转换把未知版本或字符串当作兼容版本。
	var version: Variant = data.get("version")
	return (version is int or version is float) and version == BOOTSTRAP_VERSION and data.get("world") == WORLD_ID_V3 and data.get("implementation_stage") == "m0_bootstrap"


## 只支持明确登记的V3阶段，保留M0作为内部迁移输入。
func _is_supported(data: Dictionary) -> bool:
	# 1. 不以字符串或布尔版本号隐式匹配当前格式。
	var version: Variant = data.get("version")
	return _is_bootstrap(data) or ((version is int or version is float) and data.get("world") == WORLD_ID_V3 and ((version == ACTOR_VERSION and data.get("implementation_stage") == "m2_actors") or (version == SURVIVAL_VERSION and data.get("implementation_stage") == "m5_survival") or (version == RESCUE_VERSION and data.get("implementation_stage") == "m6_rescue") or (version == PARTNER_VERSION and data.get("implementation_stage") == "m7_partner") or (version == EVENT_VERSION and data.get("implementation_stage") == "m11_events") or (version == BOSS_VERSION and data.get("implementation_stage") == "m13_boss") or (version == JOURNEY_VERSION and data.get("implementation_stage") == "m14_journey")))


## 对玩家返回可解释的错误，技术路径只由开发文档和验收报告记录。
func _directory_error() -> Dictionary:
	# 1. 拒绝时既不读取也不创建任何目录或文件。
	return {"ok": false, "message": "第三版存档目录无效，未读取或修改任何进度"}
