extends Node3D
## M4落脚声音：固定声部池播放轻柔压雪声，避免立即重复样本，不改变全局音量。

const SAMPLES: Array[AudioStream] = [
	preload("res://assets/audio/snow/snow_step_01.wav"),
	preload("res://assets/audio/snow/snow_step_02.wav"),
	preload("res://assets/audio/snow/snow_step_03.wav"),
	preload("res://assets/audio/snow/snow_step_04.wav"),
	preload("res://assets/audio/snow/snow_step_05.wav"),
	preload("res://assets/audio/snow/snow_step_06.wav"),
]
@export var enabled: bool = true
@export_range(-30.0, 0.0, 0.5) var walk_volume_db: float = -4.5
var total_plays: int = 0
var _voices: Array[AudioStreamPlayer3D] = []
var _cursor: int = 0
var _last_sample: int = -1
var _random := RandomNumberGenerator.new()
var _last_event: Dictionary = {}


## 预建六个空间声部，持续走跑期间不创建音频节点。
func _ready() -> void:
	# 1. 使用本地随机源，音色变化不影响其他游戏逻辑的随机数。
	_random.randomize()
	# 2. 俯视相机距场地约38米，补偿虚拟听点距离，避免脚边声音被过度衰减。
	for index in range(6):
		var voice := AudioStreamPlayer3D.new()
		voice.name = "StepVoice%d" % index
		voice.unit_size = 40.0
		voice.max_distance = 100.0
		voice.attenuation_filter_db = -6.0
		voice.max_db = 0.0
		voice.panning_strength = 0.55
		add_child(voice)
		_voices.append(voice)


## 每次有效落脚触发一次声音，力度只随真实速度略增。
func on_foot_landed(world_position: Vector3, _yaw: float, is_left: bool, speed: float) -> void:
	# 1. 静音只作用于本模块；同一个落脚仍能生成足迹和雪粉。
	if not enabled:
		return
	var sample := _random.randi_range(0, SAMPLES.size() - 2)
	if sample >= _last_sample:
		sample += 1
	_last_sample = sample
	# 2. 循环复用声部，轻微变化音高和响度，不连续播放背景循环。
	var voice: AudioStreamPlayer3D = _voices[_cursor]
	_cursor = (_cursor + 1) % _voices.size()
	voice.stop()
	voice.global_position = world_position
	voice.stream = SAMPLES[sample]
	var effort := clampf((speed - 2.0) / 1.6, 0.0, 1.0)
	voice.volume_db = walk_volume_db + effort * 3.0 + _random.randf_range(-0.7, 0.7)
	voice.pitch_scale = _random.randf_range(0.95, 1.05)
	voice.play()
	# 3. 仅保留最后事件与累计次数，供同步检查而不积累历史列表。
	total_plays += 1
	_last_event = {"position": world_position, "left": is_left, "speed": speed, "sample": sample, "volume_db": voice.volume_db, "pitch": voice.pitch_scale, "physics_frame": Engine.get_physics_frames()}


## 切换音效并立即停止已有声尾，便于独立比较踩雪反馈。
func set_enabled(value: bool) -> void:
	# 1. 不修改Master总线，后续其他声音仍可独立工作。
	enabled = value
	# 2. 禁用时停止池中所有活动声部。
	if not enabled:
		for voice in _voices:
			voice.stop()


## 返回最近一次落脚声音信息的副本。
func get_last_event() -> Dictionary:
	# 1. 防止调试读取者修改内部同步记录。
	return _last_event.duplicate(true)


## 场景卸载时显式停止声部，避免播放中的WAV仍持有混音线程引用。
func _exit_tree() -> void:
	# 1. 先停止正在播放的声尾，再交由场景树销毁节点。
	for voice in _voices:
		voice.stop()
		voice.stream = null
