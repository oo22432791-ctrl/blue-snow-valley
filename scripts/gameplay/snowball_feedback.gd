extends Node3D
## 命中与落雪反馈使用独立小池，不冒充落脚、不写入脚印计数。

var sound_enabled: bool = true
var powder_enabled: bool = true
var total_impacts: int = 0
var _bursts: Array[GPUParticles3D] = []
var _voices: Array[AudioStreamPlayer3D] = []
var _material: StandardMaterial3D
var _cursor: int = 0


## 建立六组短雪粉和四个轻柔音效声部，复用项目自制压雪素材。
func _ready() -> void:
	# 1. 命中雪粉略多于脚步，仍保持短促和不投影。
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	var grain := SphereMesh.new()
	grain.radius = 0.032
	grain.height = 0.064
	grain.radial_segments = 6
	grain.rings = 2
	grain.material = _material
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0.9))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	for index in range(6):
		var material := ParticleProcessMaterial.new()
		material.direction = Vector3.UP
		material.spread = 65.0
		material.gravity = Vector3(0, -3.5, 0)
		material.initial_velocity_min = 0.65
		material.initial_velocity_max = 1.4
		material.scale_min = 0.5
		material.scale_max = 1.0
		material.color_ramp = ramp
		var burst := GPUParticles3D.new()
		burst.emitting = false
		burst.one_shot = true
		burst.explosiveness = 1.0
		burst.amount = 14
		burst.lifetime = 0.45
		burst.fixed_fps = 60
		burst.local_coords = false
		burst.visibility_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
		burst.process_material = material
		burst.draw_pass_1 = grain
		burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(burst)
		_bursts.append(burst)
	# 2. 声音池独立于脚步，避免命中抢占同一帧的靴底声音。
	for index in range(4):
		var voice := AudioStreamPlayer3D.new()
		voice.stream = preload("res://assets/audio/snow/snow_step_04.wav")
		voice.unit_size = 40.0
		voice.max_distance = 100.0
		voice.volume_db = -7.0
		voice.pitch_scale = 0.82
		voice.panning_strength = 0.55
		add_child(voice)
		_voices.append(voice)


## 在球的真实接触点播放一次轻柔反馈。
func play_impact(at: Vector3, actor_hit: bool) -> void:
	# 1. 六组雪粉循环复用，关闭P时不生成可见爆发。
	if powder_enabled:
		var burst := _bursts[_cursor % _bursts.size()]
		burst.visible = true
		burst.global_position = at + Vector3.UP * 0.04
		burst.amount = 14 if actor_hit else 9
		burst.restart()
		burst.emitting = true
	# 2. M开关同步控制命中音效，但不改变落脚统计。
	if sound_enabled:
		var voice := _voices[_cursor % _voices.size()]
		voice.global_position = at
		voice.play()
	_cursor += 1
	total_impacts += 1


## 与雪面同色系，白天与夜晚都保留少量亮粒。
func apply_color(color: Color) -> void:
	# 1. 不引入新的固定暖色光源。
	_material.albedo_color = color.lerp(Color.WHITE, 0.3)


## 控制两个独立反馈开关，并即时清理被关闭模块的残留。
func set_feedback(sound: bool, powder: bool) -> void:
	# 1. 关闭声音时停掉声尾；关闭雪粉时清掉当前爆发。
	sound_enabled = sound
	powder_enabled = powder
	if not sound:
		for voice in _voices:
			voice.stop()
	if not powder:
		for burst in _bursts:
			burst.emitting = false
			burst.visible = false


## 场景关闭时解除音频引用，由既有退出等待完成线程回收。
func _exit_tree() -> void:
	# 1. 不让正在播放的WAV引用跨越场景销毁。
	for voice in _voices:
		voice.stop()
		voice.stream = null
