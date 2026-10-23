extends Control
## 原生HUD线形图标，不依赖字体是否包含特殊符号。

var kind: String = "warmth"
var ink := Color("e9f3fb")


## 图标只显示状态身份，不接收玩法或菜单输入。
func _ready() -> void:
	custom_minimum_size = Vector2(24,24)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 冷暖、柴火与弹药使用不同轮廓，文字数值提供同义标签。
func _draw() -> void:
	match kind:
		"warmth":
			draw_circle(Vector2(10,18),5,ink)
			draw_line(Vector2(10,4),Vector2(10,18),ink,4,true)
			draw_line(Vector2(16,5),Vector2(20,5),ink,2,true)
			draw_line(Vector2(16,11),Vector2(19,11),ink,2,true)
		"wood":
			draw_line(Vector2(4,18),Vector2(19,5),ink,6,true)
			draw_line(Vector2(5,5),Vector2(20,18),ink,6,true)
		"ammo":
			draw_rect(Rect2(7,9,10,13),ink,false,2)
			draw_line(Vector2(7,9),Vector2(12,2),ink,2,true)
			draw_line(Vector2(12,2),Vector2(17,9),ink,2,true)
