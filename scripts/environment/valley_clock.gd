extends Node
## M8统一游戏时钟：正常速度推进，可暂停；昼夜偏移与累计游戏时间分开。

signal advanced(delta: float, elapsed: float)
signal phase_changed(phase: StringName)
const CYCLE_SECONDS: float=1440.0
var elapsed_seconds: float=0.0
var cycle_offset: float=120.0
var debug_rate: float=1.0
var _phase: StringName=&"day"


## 所有订阅者接收同一帧的游戏秒数，场景暂停时不发出推进信号。
func _process(delta: float) -> void:
	# 1. 不读取现实离线间隔；默认1倍，测试加速必须显式调用调试接口。
	var game_delta:=delta*debug_rate
	elapsed_seconds+=game_delta
	var next:=get_phase()
	if next!=_phase:
		_phase=next
		phase_changed.emit(next)
	# 2. 天气先订阅、足迹随后订阅，恢复倍率使用同帧天气状态。
	advanced.emit(game_delta,elapsed_seconds)


## 显式加速验证世界时间，默认1倍；不修改引擎物理或渲染帧率。
func debug_set_rate(value: float) -> void:
	# 1. 仅改变统一时钟订阅者的游戏秒数，禁止非有限值或倒退倍率。
	if not is_finite(value):return
	debug_rate=clampf(value,1.0,60.0)


## 返回本日秒数，完整循环保持1440秒。
func get_day_seconds() -> float:
	# 1. 负数偏移也使用正模，避免调试切换产生负时刻。
	return fposmod(elapsed_seconds+cycle_offset,CYCLE_SECONDS)


## 按确认的2／14／2／6分钟划分时段。
func get_phase() -> StringName:
	# 1. 阶段标签和连续光照读取同一日内时间。
	var at:=get_day_seconds()
	if at<120.0:return &"dawn"
	if at<960.0:return &"day"
	if at<1080.0:return &"dusk"
	return &"night"


## 清晨和黄昏使用零端点导数渐变，夜晚保留已确认可见度。
func get_daylight() -> float:
	# 1. 只返回光照权重，不重置天气或累计时间。
	var at:=get_day_seconds()
	if at<120.0:return smoothstep(0.0,120.0,at)
	if at<960.0:return 1.0
	if at<1080.0:return 1.0-smoothstep(960.0,1080.0,at)
	return 0.0


## 调试定位日内阶段，不快进世界模拟，也不消耗足迹或燃料时间。
func debug_set_day_seconds(value: float) -> void:
	# 1. 保存累计秒数，未来存档可分别保存偏移与累计时间。
	cycle_offset=fposmod(value,CYCLE_SECONDS)-elapsed_seconds
	_phase=get_phase()
	phase_changed.emit(_phase)


## 提供未来会话模块可读取的状态，此阶段不执行磁盘存档。
func get_state() -> Dictionary:
	# 1. 固定字段不依赖节点路径或系统时间。
	return {"elapsed_seconds":elapsed_seconds,"cycle_offset":cycle_offset,"cycle_seconds":CYCLE_SECONDS,"debug_rate":debug_rate}


## 从完整快照恢复游戏时间，现实退出间隔与调试倍率都不补进模拟。
func restore_state(data: Dictionary) -> void:
	# 1. 仅会话的整体验证通过后调用，恢复后始终正常1倍。
	elapsed_seconds=float(data.elapsed_seconds);cycle_offset=float(data.cycle_offset);debug_rate=1.0
	_phase=get_phase();phase_changed.emit(_phase)
