extends "res://scripts/audio/footstep_audio.gd"
## 复用原有六个自制压雪样本与固定声部，按深雪负重改变音高与厚度。

var snow_surface: Node3D


## 一次统一落脚播放一次声音；深雪更厚更低，力度仍随真实速度变化。
func on_foot_landed(at: Vector3, yaw: float, left: bool, speed: float) -> void:
	# 1. 原固定池保留去重选样、空间位置和限幅，不修改第一版模块。
	super.on_foot_landed(at,yaw,left,speed)
	if not enabled:
		return
	# 2. 雪深来自同一查询，不把低走速深雪误当成更轻的浅雪。
	var deep := smoothstep(0.05,0.30,snow_surface.get_fresh_depth_at(at))
	var voice: AudioStreamPlayer3D = _voices[(_cursor+_voices.size()-1)%_voices.size()]
	voice.pitch_scale *= lerpf(1.0,0.83,deep)
	voice.volume_db = minf(-0.5,voice.volume_db+deep*1.8)
	_last_event["depth"] = snow_surface.get_fresh_depth_at(at)
	_last_event["pitch"] = voice.pitch_scale
	_last_event["volume_db"] = voice.volume_db
