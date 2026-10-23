extends Node3D
## M11机械骨骼、真实握点与有限声光反馈；不在此处扣弹或计算伤害。

const MODEL=preload("res://assets/models/v2/weapons/valley_rifle.glb")
const AMMO=preload("res://assets/models/v2/weapons/valley_ammo_box.glb")
const SOUNDS={"shot":preload("res://assets/audio/v2/rifle_shot.wav"),"reload":preload("res://assets/audio/v2/rifle_reload.wav"),"close":preload("res://assets/audio/v2/rifle_close.wav"),"empty":preload("res://assets/audio/v2/rifle_empty.wav")}
var world: Node3D
var weapon: Node3D
var gun: Node3D
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
var hand_contacts: Dictionary={}
var _markers: Dictionary={}
var _shoulder_offset:=Vector3(0,-.02,.07)
var _shoulder_rest:=Vector3.ZERO
var _pivot:=Vector3.ZERO
var _forward:=Vector3.FORWARD
var _flash: MeshInstance3D
var _light: OmniLight3D
var _impact: MeshInstance3D
var _trail: MeshInstance3D
var _line: ImmediateMesh
var _flash_age: float=0.0
var _impact_age: float=0.0
var _voices: Array[AudioStreamPlayer]=[]
var _last_empty: float=-1.0


## 读取可编辑机械源的导出和语义点，运行时不重新生成枪械几何。
func _ready() -> void:
	# 1. 用真实静置骨架把源指南转换为骨骼局部偏移，折管时枪口随Barrel移动。
	gun=MODEL.instantiate();add_child(gun)
	skeleton=gun.find_children("*","Skeleton3D",true,false)[0]
	animation_player=gun.find_children("*","AnimationPlayer",true,false)[0]
	animation_player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/v2/weapons/valley_rifle_manifest.json"))
	for name: String in manifest.markers:
		var record: Dictionary=manifest.markers[name];var at: Array=record.at
		var bone:=skeleton.find_bone(record.bone)
		_markers[name]={"bone":bone,"offset":skeleton.get_bone_global_rest(bone).affine_inverse()*Vector3(at[0],at[1],at[2])}
		if name=="shoulder":_shoulder_rest=Vector3(at[0],at[1],at[2])
	# 2. 枪口闪光、命中点和一条短轨迹固定复用，不为每发创建永久节点。
	_flash=_sphere(.035,Color("ffe4b0"));_impact=_sphere(.028,Color("e6f3ff"))
	_line=ImmediateMesh.new();_trail=MeshInstance3D.new();_trail.mesh=_line;_trail.material_override=_material(Color("f6e5c8"));_trail.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(_trail)
	_light=OmniLight3D.new();_light.light_color=Color("ffe5bb");_light.light_energy=.7;_light.omni_range=1.0;_light.shadow_enabled=false;add_child(_light)
	for index in range(2):
		var voice:=AudioStreamPlayer.new();voice.volume_db=-12 if index==0 else -18;add_child(voice);_voices.append(voice)


## 为很短的反馈建立无阴影材质，不改变正式环境和灯光资源。
func _material(color: Color) -> StandardMaterial3D:
	# 1. 原创轻量反馈不加血迹，不创建持续屏幕效果。
	var material:=StandardMaterial3D.new();material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;material.albedo_color=color
	return material


## 有限球形光点仅作枪口／撞击提示，不参与物理或命中。
func _sphere(radius: float,color: Color) -> MeshInstance3D:
	# 1. 复用同一节点的可见性和位置，不积累粒子实例。
	var instance:=MeshInstance3D.new();var mesh:=SphereMesh.new();mesh.radius=radius;mesh.height=radius*2;mesh.radial_segments=8;mesh.rings=4
	instance.mesh=mesh;instance.material_override=_material(color);instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(instance);instance.visible=false
	return instance


## 人物完成步态后从真实右肩定位枪托，再用机械姿态计算枪口与双手目标。
func update_frame(delta: float) -> void:
	# 1. 切回雪球时枪和短反馈立即隐藏，不再改动上身手骨。
	gun.visible=weapon.equipped==2
	_flash_age=maxf(0,_flash_age-delta);_impact_age=maxf(0,_impact_age-delta)
	_flash.visible=gun.visible and _flash_age>0;_light.visible=_flash.visible;_trail.visible=_flash.visible;_impact.visible=gun.visible and _impact_age>0
	if not gun.visible:return
	var visual: Node3D=world.player._visual
	var person: Skeleton3D=visual.skeleton
	var shoulder:=person.get_bone_global_pose(person.find_bone("Arm_R")).origin
	var chest:=person.find_bone("Chest")
	var torso_delta: Basis=person.get_bone_global_pose(chest).basis*person.get_bone_global_rest(chest).basis.inverse()
	_pivot=person.global_transform*shoulder+person.global_basis*torso_delta*_shoulder_offset
	var yaw: float=weapon.aim_yaw()
	var fallback:=Vector3(sin(yaw),0,cos(yaw))
	_forward=(world.aim_hit.position-_pivot).normalized() if not world.aim_hit.is_empty() and _pivot.distance_to(world.aim_hit.position)>.2 else fallback
	var right:=Vector3.UP.cross(_forward).normalized()
	if right.length_squared()<.001:right=visual.global_basis.x
	var up:=_forward.cross(right).normalized()
	gun.global_basis=Basis(right,up,_forward);gun.global_position=_pivot-gun.global_basis*_shoulder_rest
	# 2. 清除上一次机械采样再读取同一动作进度，既不积累位移也不重复推进世界钟。
	var state: Dictionary=weapon.pose_state()
	var clip: String={"RifleHold":"Hold","RifleFire":"Fire","RifleReload":"Reload"}[state.clip]
	for index in range(skeleton.get_bone_count()):skeleton.set_bone_pose(index,skeleton.get_bone_rest(index))
	if animation_player.current_animation!=clip:animation_player.play(clip)
	animation_player.seek(float(state.normalized)*animation_player.get_animation(clip).length,true);animation_player.advance(0)
	var left: Vector3=marker_position("left_grip")
	if weapon.reloading():
		var t: float=weapon.reload_fraction();var weight:=sin(PI*clampf((t-.16)/.72,0,1))
		left=left.lerp(_gun_point(Vector3(0,.025,.07),"Stock"),weight)
	# 3. 肘腕在原长内旋转到真实握点，源上身动作负责姿态，接触适配只补步态与瞄准差。
	_solve_arm(person,"R",marker_position("right_grip"))
	_solve_arm(person,"L",left)


## 从导出骨架读取当前机械语义点，真实射击和握持共用入口。
func marker_position(name: String) -> Vector3:
	# 1. 枪口随源动作移动，不能使用未开合枪管的静置坐标。
	var marker: Dictionary=_markers[name]
	return skeleton.global_transform*(skeleton.get_bone_global_pose(marker.bone)*marker.offset)


## 将临时装填目标映射到指定机械骨骼，不平移人物手骨。
func _gun_point(at: Vector3,bone_name: String) -> Vector3:
	# 1. 和源内指南使用同一静置变换定义。
	var bone:=skeleton.find_bone(bone_name)
	return skeleton.global_transform*(skeleton.get_bone_global_pose(bone)*(skeleton.get_bone_global_rest(bone).affine_inverse()*at))


## 固定原长的两段手臂IK，超出可达范围时只报告真实握点误差。
func _solve_arm(person: Skeleton3D,side: String,target_world: Vector3) -> void:
	# 1. 在人物骨架空间计算关节，不用缩放袖子或直接平移掌骨遮掩不可达。
	var upper:=person.find_bone("Arm_"+side);var fore:=person.find_bone("Forearm_"+side);var hand:=person.find_bone("Hand_"+side)
	var a:=person.get_bone_global_pose(upper);var b:=person.get_bone_global_pose(fore);var c:=person.get_bone_global_pose(hand)
	var target:=person.global_transform.affine_inverse()*target_world
	var first:=a.origin.distance_to(b.origin);var second:=b.origin.distance_to(c.origin)
	var axis: Vector3=target-a.origin;var reach:=clampf(axis.length(),absf(first-second)+.0001,first+second-.0001)
	axis=axis.normalized();var goal:=a.origin+axis*reach
	var pole:=b.origin-a.origin-axis*(b.origin-a.origin).dot(axis)
	if pole.length_squared()<.000001:
		var chest:=person.find_bone("Chest")
		var delta_basis:=person.get_bone_global_pose(chest).basis*person.get_bone_global_rest(chest).basis.inverse()
		pole=delta_basis*Vector3(-.4 if side=="L" else .4,-.8,-.1);pole-=axis*pole.dot(axis)
	pole=pole.normalized()
	var along: float=(first*first+reach*reach-second*second)/(2*reach)
	var knee:=a.origin+axis*along+pole*sqrt(maxf(0,first*first-along*along))
	a.basis=Basis(Quaternion((b.origin-a.origin).normalized(),(knee-a.origin).normalized()))*a.basis;person.set_bone_global_pose(upper,a)
	b=person.get_bone_global_pose(fore);var tip:=person.get_bone_global_pose(hand).origin
	b.basis=Basis(Quaternion((tip-b.origin).normalized(),(goal-b.origin).normalized()))*b.basis;person.set_bone_global_pose(fore,b)
	var actual: Vector3=person.global_transform*person.get_bone_global_pose(hand).origin
	hand_contacts[side]={"hand":actual,"target":target_world,"gap":actual.distance_to(target_world)}


## 正式出枪方向用于近身反向射击校验。
func forward_direction() -> Vector3:
	# 1. 源枪口为+Z，与根朝向和骨骼开合共用轴向。
	return _forward


## 身体到枪口的防穿墙射线从右肩附近开始。
func shoulder_position() -> Vector3:
	# 1. 该点来自人物实际骨架，走跑和雪地屈身时同步更新。
	return _pivot


## 已结算的一发只触发一次短反馈，墙后枪口不生成穿墙轨迹。
func on_fired(from: Vector3,to: Vector3,blocked: bool,hit_bear: bool,has_impact: bool) -> void:
	# 1. 线段顶点使用世界坐标，节点自身保持单位变换。
	_flash.global_position=from;_light.global_position=from;_flash_age=.065
	_line.clear_surfaces()
	if not blocked:
		_line.surface_begin(Mesh.PRIMITIVE_LINES);_line.surface_add_vertex(from);_line.surface_add_vertex(to);_line.surface_end()
	_impact.global_position=to;_impact_age=(.18 if hit_bear else .10) if has_impact else 0.0
	play_sound(&"shot")


## 每类反馈复用固定声部，空枪连点有最小间隔，避免叠加噪声。
func play_sound(kind: StringName) -> void:
	# 1. 所有音效为仓库内原创合成WAV；玩家近身枪不受虚拟相机38米距离截断。
	if not SOUNDS.has(String(kind)):return
	if kind==&"empty":
		if world.world_clock.elapsed_seconds-_last_empty<.18:return
		_last_empty=world.world_clock.elapsed_seconds
	var voice: AudioStreamPlayer=_voices[0 if kind==&"shot" else 1]
	voice.stream=SOUNDS[String(kind)];voice.play()


## 小屋补给盒实例化实际Blender导出，不增加家具碰撞或额外拾取计时器。
func create_ammo_box(at: Vector3,yaw: float) -> Node3D:
	# 1. 三处共用网格资源，独立数量决定是否显示。
	var prop: Node3D=AMMO.instantiate();add_child(prop);prop.global_position=at;prop.global_rotation.y=yaw
	return prop


## 空盒保留，四枚独立弹壳按实际余量显示；补充只在远离／离开视野时出现。
func set_box_quantity(prop: Node3D,quantity: int) -> void:
	# 1. 不靠整体缩放假装余量，部分拾取也保留准确的源模型数量。
	for mesh: MeshInstance3D in prop.find_children("*","MeshInstance3D",true,false):
		var label:=String(mesh.name)
		if label.begins_with("BrassCase_") or label.begins_with("CaseBase_") or label.begins_with("SoftPoint_"):
			mesh.visible=label.get_slice("_",1).to_int()<quantity


## 有限声部和场景树一同暂停，恢复不重新触发音效。
func set_paused(value: bool) -> void:
	# 1. 单独冻结混音播放位置，视觉物理由场景树暂停负责。
	for voice: AudioStreamPlayer in _voices:voice.stream_paused=value


## 退出前释放音频流引用，避免源文件验证时残留混音线程引用。
func _exit_tree() -> void:
	# 1. 固定声部逐个停止，不更改其他模块音量或总线。
	for voice: AudioStreamPlayer in _voices:
		voice.stop();voice.stream=null


## 读档或失败返回时取消有限特效／声部，不补播旧世界的一枪。
func reset_feedback() -> void:
	# 1. 仅重置显示与声音，不转移任何弹药。
	_flash_age=0;_impact_age=0;_last_empty=-1;_flash.hide();_impact.hide();_trail.hide();_light.hide()
	for voice: AudioStreamPlayer in _voices:voice.stop()
