extends RefCounted
## 只保留上一个旅程；主档和备份成组交换，不把角色或进度分开恢复。
const ARCHIVE := "previous_journey.json"
const LIMIT := 12*1024*1024
var session: Node

func _raw(name: String) -> Dictionary:
	var path: String = session.store.directory.path_join(name)
	if not FileAccess.file_exists(path): return {"ok":true,"raw":""}
	var file := FileAccess.open(path,FileAccess.READ)
	if file==null or file.get_length()>LIMIT: return {"ok":false,"message":"旅程文件无法读取，现有进度保留"}
	return {"ok":true,"raw":file.get_as_text()}

func read_previous() -> Dictionary:
	if not session.store.directory_is_allowed(): return {"ok":false,"message":"旅程目录无效"}
	var result := _raw(ARCHIVE)
	if not result.ok: return result
	if result.raw.is_empty(): return {"ok":false,"message":"尚无上一个旅程"}
	var parser := JSON.new()
	if parser.parse(result.raw)!=OK or not parser.data is Dictionary: return {"ok":false,"message":"上一个旅程归档损坏，当前旅程未改变"}
	var group: Dictionary = parser.data
	if group.get("format")!="v3_previous_journey_1" or not group.get("current") is String or not group.get("previous") is String:
		return {"ok":false,"message":"上一个旅程归档格式无效"}
	if group.current.to_utf8_buffer().size()>session.store.MAX_BYTES or group.previous.to_utf8_buffer().size()>session.store.MAX_BYTES:
		return {"ok":false,"message":"旅程归档长度异常"}
	var decoded: Dictionary = session.store.decode(group.current)
	if not decoded.ok: return decoded
	return {"ok":true,"snapshot":decoded.snapshot,"current":group.current,"previous":group.previous}

func _encode(snapshot: Dictionary) -> String:
	var payload := JSON.stringify(snapshot,"",true,true)
	return JSON.stringify({"format":session.store.FORMAT_VERSION,"sha256":payload.sha256_text(),"payload":payload})

## 所有目标内容先写完临时文件再替换；普通写入失败时补偿恢复已换文件。
func exchange(target: Dictionary, previous_raw: String = "", fresh: bool = false) -> Dictionary:
	if not session.store.directory_is_allowed(): return {"ok":false,"message":"旅程目录无效"}
	var problem: String = session.schema.validate(target,session.world)
	if not problem.is_empty(): return {"ok":false,"message":problem}
	var names: Array[String] = [ARCHIVE,"current.json","previous.json"]
	var old: Dictionary = {}
	for name: String in names:
		var result := _raw(name)
		if not result.ok: return result
		old[name] = result.raw
	if String(old["current.json"]).is_empty(): return {"ok":false,"message":"当前旅程尚未保存，不能替换"}
	var primary := _encode(target)
	var desired := {ARCHIVE:JSON.stringify({"format":"v3_previous_journey_1","current":old["current.json"],"previous":old["previous.json"]}),"current.json":primary,"previous.json":primary if fresh else previous_raw}
	for name: String in names:
		if String(desired[name]).is_empty(): continue
		var error := _stage(name,desired[name])
		if error!=OK:
			_clean_pending(names)
			return {"ok":false,"message":"无法准备旅程保存，现有旅程未替换"}
	var committed: Array[String] = []
	for name: String in names:
		var error := _commit(name,String(desired[name]).is_empty())
		if error!=OK:
			var recovered := true
			for changed: String in committed:
				if not String(old[changed]).is_empty():
					recovered = _stage(changed,old[changed])==OK and _commit(changed,false)==OK and recovered
				else: recovered = _commit(changed,true)==OK and recovered
			_clean_pending(names)
			return {"ok":false,"message":"旅程替换未完成，已恢复原旅程" if recovered else "旅程文件写入受阻，请保留现有文件并恢复有效备份"}
		committed.append(name)
	return {"ok":true}

func _stage(name: String, raw: String) -> Error:
	var path: String = session.store.directory.path_join(name+".m14_pending")
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: return FileAccess.get_open_error()
	file.store_string(raw)
	file.flush()
	var error := file.get_error()
	file.close()
	return error

func _commit(name: String, remove: bool) -> Error:
	var path: String = session.store.directory.path_join(name)
	if remove: return DirAccess.remove_absolute(path) if FileAccess.file_exists(path) else OK
	return DirAccess.rename_absolute(path+".m14_pending",path)

func _clean_pending(names: Array[String]) -> void:
	for name: String in names:
		var path: String = session.store.directory.path_join(name+".m14_pending")
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
