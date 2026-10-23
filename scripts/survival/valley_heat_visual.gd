extends Node3D
## M9热源反馈：复用现有炉窗，营火使用小型交叉火焰；所有时序随世界时钟。

const FIRE_SHADER=preload("res://materials/valley_fire.gdshader")
var world: Node3D
var survival: Node
var views: Dictionary={}
var _age: float=0.0


## 五个固定热源各创建有限显示对象，不改动模型源、语义调色或碰撞。
func _ready() -> void:
	# 1. 炉窗只覆盖本实例的fire表面，原共享配色材质仍供其他表面使用。
	for id: String in survival.heaters:
		var heater: Dictionary=survival.heaters[id]
		var holder:=Node3D.new();holder.position=heater.position;add_child(holder)
		var light:=OmniLight3D.new();light.light_color=Color("f6bd78");light.omni_range=3.2;light.light_energy=.7;light.shadow_enabled=false;holder.add_child(light)
		var windows: Array[StandardMaterial3D]=[]
		var flame: ShaderMaterial
		if heater.kind=="stove":
			for mesh: MeshInstance3D in heater.cabin.model.find_children("*","MeshInstance3D",true,false):
				for index in range(mesh.mesh.get_surface_count()):
					var source: Material=mesh.mesh.surface_get_material(index)
					if source==null or source.resource_name!="cabin_fire":continue
					var material:=StandardMaterial3D.new();material.roughness=.8;material.emission_enabled=true
					material.emission=Color("edb46e");mesh.set_surface_override_material(index,material);windows.append(material)
		else:
			# 2. 石圈已有木柴模型，此处只增加动态火焰，不额外制造障碍或覆盖地面。
			flame=ShaderMaterial.new();flame.shader=FIRE_SHADER
			for angle: float in [0.0,PI*.5]:
				var mesh:=MeshInstance3D.new();var quad:=QuadMesh.new();quad.size=Vector2(.65,.85)
				mesh.mesh=quad;mesh.material_override=flame;mesh.rotation.y=angle;mesh.position.y=-.05
				mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;holder.add_child(mesh)
		views[id]={"holder":holder,"light":light,"windows":windows,"flame":flame}
	world.world_clock.advanced.connect(_advance)
	_refresh()


## 每10分之一游戏秒更新有限热源材质，暖光不代表热量穿墙。
func _advance(delta: float, _elapsed: float) -> void:
	# 1. 温度由survival的物理遮挡决定；光只显示当前真正燃烧状态。
	_age+=delta
	if _age<.1:return
	_age=0.0;_refresh()


## 统一时钟提供火焰摆动和炉窗明暗，熄火立即变为冷炉窗。
func _refresh() -> void:
	# 1. 远处或不同房间关闭局部无阴影灯，避免穿墙暖光和无谓光源负载。
	var at: Vector3=world.player.global_position
	var shelter: Dictionary=world.interior.shelter_at(at)
	var seconds: float=world.world_clock.elapsed_seconds
	for id: String in views:
		var heater: Dictionary=survival.heaters[id]
		var view: Dictionary=views[id]
		var lit: bool=heater.permanent or heater.fuel_seconds>0.0
		var flicker: float=.94+.06*sin(seconds*4.3)
		view.light.visible=lit and at.distance_to(heater.position)<10 and (heater.kind=="camp" or String(shelter.building_id)==heater.site)
		view.light.light_energy=.7*flicker
		for window: StandardMaterial3D in view.windows:
			window.albedo_color=Color("ecb36e") if lit else Color("25384a")
			window.emission_energy_multiplier=.65*flicker if lit else 0.0
		if view.flame!=null:
			view.flame.set_shader_parameter("game_clock",seconds)
			view.flame.set_shader_parameter("strength",1.0 if lit else 0.0)
