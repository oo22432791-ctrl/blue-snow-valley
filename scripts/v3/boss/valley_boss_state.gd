extends RefCounted
## 313战斗状态的纯数据契约，历史311仅显式迁移到未开始的挑战。
const PHASES = ["rest","approach","reposition","turn","charge_warning","charge","slam","recover","weak","dead"]

static func initial(defeated: bool = false) -> Dictionary:
	return {"kind":"first","status":"won" if defeated else "idle","party":"solo","participants":[],"retired":[],"boxes":[16,16],"broken":0,"protection":{"p1":0.0,"p2":0.0},"boss":{"health":0 if defeated else 320,"maximum":320,"combat":"dead" if defeated else "rest","timer":0.0 if defeated else 2.0,"age":0.0,"position":[114.0,12.15,-178.0],"yaw":0.0,"goal":[0.0,0.0,0.0],"direction":[0.0,0.0,1.0],"charge_origin":[114.0,12.15,-178.0],"travel":0.0,"slam":[114.0,12.15,-175.8],"attack_serial":0,"victims":[],"shots":[],"combo":0,"next":"charge","target":"","turn_age":0.0}}

static func number(value: Variant, low: float, high: float, integral: bool = false) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value>=low and value<=high and (not integral or float(value)==floorf(value))

static func vector(value: Variant) -> bool:
	return value is Array and value.size()==3 and number(value[0],-1000,1000) and number(value[1],-200,500) and number(value[2],-1000,1000)

## 不用缺省值修补当前版本坏档，计时／去重集合必须完整存在。
static func validate(data: Variant, progress: Dictionary, checkpoint: Dictionary) -> String:
	if not data is Dictionary or data.size()!=9: return "Boss战斗状态不完整"
	if data.get("kind") not in ["first","memory"]: return "Boss挑战类型无效"
	if data.get("status") not in ["idle","entering","fighting","won"] or data.get("party") not in ["solo","ai","duo"]: return "Boss挑战阶段或人数无效"
	for key: String in ["participants","retired","boxes"]:
		if not data.get(key) is Array: return "Boss队伍或补给格式无效"
	if data.boxes.size()!=2 or not number(data.boxes[0],0,16,true) or not number(data.boxes[1],0,16,true) or not number(data.get("broken"),0,3,true): return "冰壁或场内弹药数量无效"
	if data.participants not in [[],["p1"],["p1","p2"]] or data.retired.size()>2: return "Boss参战队伍无效"
	var seen: Array = []
	for id: Variant in data.retired:
		if id not in data.participants or id in seen: return "Boss旁观角色无效"
		seen.append(id)
	var active: bool = data.status in ["entering","fighting"]
	if data.kind=="memory" and not active: return "回忆挑战必须处于有效入场或战斗状态"
	if active and (checkpoint.is_empty() or not progress.boss_unlocked or (progress.boss_defeated and data.kind!="memory")): return "Boss挑战缺少入场快照或解锁条件"
	if active and data.participants != (["p1"] if data.party=="solo" else ["p1","p2"]): return "Boss人数与队伍不一致"
	if not active and not checkpoint.is_empty(): return "非战斗状态不能持有Boss入场快照"
	if data.status=="won" and not progress.boss_defeated: return "Boss胜利标志不一致"
	if data.kind=="memory" and (not progress.boss_defeated or not progress.ending_seen): return "回忆挑战缺少首次通关结局"
	if data.status!="won" and progress.boss_defeated and data.kind!="memory": return "已胜利Boss不能继续战斗"
	if not data.get("protection") is Dictionary or data.protection.size()!=2: return "Boss受击保护状态不完整"
	for id: String in ["p1","p2"]:
		if not number(data.protection.get(id),0,1.501): return "Boss受击保护期限无效"
	var b: Variant = data.get("boss")
	if not b is Dictionary or b.size()!=19: return "雪熊动作快照不完整"
	if b.get("combat") not in PHASES or not number(b.get("maximum"),320,480,true) or int(b.maximum) not in [320,400,480] or not number(b.get("health"),0,b.maximum,true): return "雪熊生命或动作无效"
	if active and b.maximum!={"solo":320,"ai":400,"duo":480}[data.party]: return "雪熊入场生命与队伍不一致"
	if (data.status=="won") != (b.health==0 and b.combat=="dead"): return "雪熊死亡与挑战结果不一致"
	for key: String in ["position","goal","direction","charge_origin","slam"]:
		if not vector(b.get(key)): return "雪熊位置或方向无效"
	if absf(b.position[0]-112)>27 or absf(b.position[2]+166)>32: return "雪熊保存位置超出场地"
	for key: String in ["timer","age","yaw","travel","turn_age"]:
		if not number(b.get(key),-TAU if key=="yaw" else 0,TAU if key=="yaw" else (14.5 if key=="travel" else 1e12)): return "雪熊动作计时无效"
	if not number(b.get("attack_serial"),0,1e12,true) or not number(b.get("combo"),0,2,true) or b.get("next") not in ["charge","slam"] or b.get("target") not in ["","p1","p2"]: return "雪熊攻击序号无效"
	if not b.get("victims") is Array or b.victims.size()>2 or not b.get("shots") is Array or b.shots.size()>60: return "雪熊命中去重状态无效"
	seen.clear()
	for id: Variant in b.victims:
		if id not in data.participants or id in seen: return "雪熊攻击命中集合无效"
		seen.append(id)
	seen.clear()
	for token: Variant in b.shots:
		if not token is String or token in seen: return "雪熊射击去重集合无效"
		var pieces: PackedStringArray = token.split(":")
		if pieces.size()!=2 or pieces[0] not in data.participants or not pieces[1].is_valid_int() or int(pieces[1])<=0: return "雪熊射击序号格式无效"
		seen.append(token)
	return ""
