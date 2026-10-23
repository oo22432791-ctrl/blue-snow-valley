extends RefCounted
## M12完整快照的磁盘边界：长度／摘要校验、临时文件与上次有效备份。

const FORMAT_VERSION: int=1
const MAX_BYTES: int=2*1024*1024
var directory: String="user://saves/v2"
var snapshot_validator: Callable


## 只读取指定存档；损坏与不兼容返回明确错误，不自动覆盖或偷偷回退。
func read_slot(backup: bool=false) -> Dictionary:
	# 1. 文件大小先于JSON解析，避免截断或超大文件进入恢复流程。
	var path:=directory+("/previous.json" if backup else "/current.json")
	if not FileAccess.file_exists(path):return {"ok":false,"missing":true,"message":"没有可读取的"+("备份" if backup else "存档")}
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:return {"ok":false,"message":"无法读取存档（%d）" % FileAccess.get_open_error()}
	if file.get_length()>MAX_BYTES or file.get_length()<2:file.close();return {"ok":false,"message":"存档长度异常，原文件已保留"}
	var raw:=file.get_as_text();file.close()
	return decode(raw)


## 摘要保护的是原始载荷字符串，避免JSON键序或浮点重编码造成伪校验。
func decode(raw: String) -> Dictionary:
	# 1. 外层仅允许已支持的格式，未知版本不尝试局部读取。
	var parsed: Variant=JSON.parse_string(raw)
	if not parsed is Dictionary:return {"ok":false,"message":"存档损坏：外层不是有效JSON"}
	var envelope: Dictionary=parsed
	var version: Variant=envelope.get("format")
	if not (version is int or version is float) or version!=FORMAT_VERSION:return {"ok":false,"message":"存档版本不兼容，原文件已保留"}
	if not envelope.get("payload") is String or not envelope.get("sha256") is String:return {"ok":false,"message":"存档损坏：缺少完整快照"}
	var payload: String=envelope.payload
	if payload.sha256_text()!=envelope.sha256:return {"ok":false,"message":"存档损坏：摘要不匹配"}
	var value: Variant=JSON.parse_string(payload)
	if not value is Dictionary:return {"ok":false,"message":"存档损坏：快照格式异常"}
	if snapshot_validator.is_valid():
		var message: String=snapshot_validator.call(value)
		if not message.is_empty():return {"ok":false,"message":message}
	return {"ok":true,"snapshot":value}


## 验证临时内容后再替换主档；任何失败都保留主档或可恢复备份。
func write_snapshot(snapshot: Dictionary) -> Dictionary:
	# 1. 目录与序列化错误先返回；生产调用者须在写盘前完成语义校验。
	var error:=DirAccess.make_dir_recursive_absolute(directory)
	if error!=OK:return {"ok":false,"message":"无法建立存档目录（%d）" % error}
	var payload:=JSON.stringify(snapshot,"",true,true)
	var raw:=JSON.stringify({"format":FORMAT_VERSION,"sha256":payload.sha256_text(),"payload":payload})
	if raw.to_utf8_buffer().size()>MAX_BYTES:return {"ok":false,"message":"快照过大，旧档未改动"}
	var current:=directory+"/current.json";var temporary:=directory+"/pending.json";var previous:=directory+"/previous.json"
	# 2. 不允许用自动保存覆盖不可读旧档；恢复／新开始必须由界面显式处理。
	if FileAccess.file_exists(current) and not read_slot().ok:return {"ok":false,"message":"现有存档异常，先恢复备份或保留原档后重新开始"}
	var file:=FileAccess.open(temporary,FileAccess.WRITE)
	if file==null:return {"ok":false,"message":"写入失败，旧档保留（%d）" % FileAccess.get_open_error()}
	file.store_string(raw);file.flush();var write_error:=file.get_error();file.close()
	if write_error!=OK:return {"ok":false,"message":"写入未完成，旧档保留（%d）" % write_error}
	var check:=FileAccess.open(temporary,FileAccess.READ)
	if check==null:return {"ok":false,"message":"无法复核临时存档，旧档保留"}
	var verified:=decode(check.get_as_text());check.close()
	if not verified.ok:return {"ok":false,"message":"临时存档复核失败，旧档保留"}
	# 3. 先复制有效主档为备份，再同目录替换；失败不删除原档。
	if FileAccess.file_exists(current):
		error=DirAccess.copy_absolute(current,previous)
		if error!=OK:return {"ok":false,"message":"备份失败，主档未改动（%d）" % error}
		if not read_slot(true).ok:return {"ok":false,"message":"备份校验失败，主档未改动"}
	elif FileAccess.file_exists(previous) and not read_slot(true).ok:
		return {"ok":false,"message":"备份异常，保留文件后才能重新开始"}
	error=DirAccess.rename_absolute(temporary,current)
	if error!=OK:return {"ok":false,"message":"替换存档失败，请恢复备份（%d）" % error}
	return {"ok":true,"message":"已保存"}


## 用户明确选择新开始／恢复备份后，归档问题主档，不删除不可兼容进度。
func archive_current(backup: bool=false) -> Error:
	# 1. 独立时间戳与计数保证归档名唯一，绝不覆盖另一个问题文件。
	var current:=directory+("/previous.json" if backup else "/current.json")
	if not FileAccess.file_exists(current):return OK
	var name:=directory+"/preserved_"+str(int(Time.get_unix_time_from_system()))+"_"+str(Time.get_ticks_usec())+".json"
	return DirAccess.rename_absolute(current,name)
