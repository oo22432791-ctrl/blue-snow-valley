extends "res://scripts/player/valley_character_visual.gd"
## V3生命姿态采样原蒙皮新增的完整动作，正常时沿用原踩雪和持枪层。

var life_pose: String = ""
var _pose_time: float = 0.0


## 切换完整姿态时释放旧步态锚点，不同时播放持枪与施救动作。
func set_life_pose(clip: String) -> void:
	# 1. 相同姿态不反复重启动作，呼吸和施救循环正常推进。
	if life_pose == clip:
		return
	life_pose = clip
	_pose_time = 0.0
	_anchors = [Vector3.ZERO, Vector3.ZERO]
	_planted = [false, false]
	contact_state = [{}, {}]
	if is_instance_valid(_held_ball):
		_held_ball.hide()
	animation_player.stop()
	_tree.active = clip.is_empty()


## 正常站立复用原步态；生命动作直接采样GLB中的可编辑源动画。
func update_motion(phase: float, speed: float, running: bool, delta: float) -> void:
	# 1. 完整生命姿态不做逐脚雪面修正，避免把坐地脚骨重新拉回站姿。
	if life_pose.is_empty():
		super.update_motion(phase, speed, running, delta)
		return
	_pose_time += delta
	animation_player.play(life_pose)
	animation_player.seek(fposmod(_pose_time, animation_player.get_animation(life_pose).length), true)
