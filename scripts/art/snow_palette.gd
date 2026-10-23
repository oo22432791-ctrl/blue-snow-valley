extends Resource
## M0配色资源。方案1用于白天、方案3用于夜晚，方案2保留为对照。

@export var display_name: String = "白天 · 清透蓝"
@export_enum("day", "night", "comparison") var time_of_day: String = "day"
@export var description: String = "通透雪面，清晰的蓝色投影"
@export var snow: Color = Color("8bb8e8")
@export var shadow: Color = Color("4b7daf")
@export var wall: Color = Color("4d739b")
@export var roof: Color = Color("233b57")
@export var wood: Color = Color("284158")
@export var coat: Color = Color("355b85")
@export var scarf: Color = Color("a95850")
@export var warm: Color = Color("f5d3a0")
@export var ambient: Color = Color("92b8e4")
@export var sunlight: Color = Color("d6e6fc")
@export var light_energy: float = 0.85
@export var ambient_energy: float = 0.65
