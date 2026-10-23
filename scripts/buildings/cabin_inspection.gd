extends "res://scripts/world/snow_valley.gd"
## 独立M5模型检视场景；手动显示外壳，不代替M6的自动入屋淡出。

var _inspected: Node3D
var _focus: Node3D
var _centered: CheckButton
var _cutaway: CheckButton

## 复用实际山谷、角色、碰撞和镜头，仅增加明确标注的模型检视按钮。
func _ready() -> void:
	# 1. 不创建另一套假地板、无碰撞模型或不同的行走控制器。
	super._ready()
	# M5历史模型检视保留手动语义，不与M6自动淡出争夺外壳。
	interior.automatic_enabled=false
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := VBoxContainer.new()
	panel.position = Vector2(1090, 24)
	panel.add_theme_constant_override("separation", 10)
	layer.add_child(panel)
	var title := Label.new()
	title.text = "M5模型检视（手动外壳）"
	title.add_theme_font_size_override("font_size", 20)
	panel.add_child(title)
	var selector := OptionButton.new()
	for cabin: Node3D in landmarks.cabins:
		selector.add_item(String(cabin.get_meta("display_name")))
	selector.item_selected.connect(_select_cabin)
	panel.add_child(selector)
	_focus = Node3D.new()
	add_child(_focus)
	_centered = CheckButton.new()
	_centered.text = "房屋居中检视"
	_centered.toggled.connect(func(enabled: bool) -> void:
		camera_rig.tracked_actor = _focus if enabled else player
		camera_rig.snap_to_actor())
	panel.add_child(_centered)
	# 2. 开关仅改变可见性，实体门、墙体和家具碰撞一直保留。
	_cutaway = CheckButton.new()
	_cutaway.text = "隐藏近侧墙与屋顶"
	_cutaway.toggled.connect(func(enabled: bool) -> void: _inspected.set_inspection_cutaway(enabled))
	panel.add_child(_cutaway)
	var night := CheckButton.new()
	night.text = "夜晚配色预览"
	night.toggled.connect(set_preview_night)
	panel.add_child(night)
	_select_cabin(0)


## 检视器显式切换地点并定位门外，主游戏不使用这条定位路径。
func _select_cabin(index: int) -> void:
	# 1. 还原上一个模型外壳，避免另两屋被检视开关意外留成缺墙状态。
	if is_instance_valid(_inspected):
		_inspected.set_inspection_cutaway(false)
	_inspected = landmarks.cabins[index]
	_inspected.set_inspection_cutaway(_cutaway.button_pressed)
	_focus.global_position = _inspected.global_position + Vector3.UP * 1.4
	# 2. 这是带地点选择的模型检视，明确重定位；正常山谷移动没有瞬移入口。
	var approach: Array = _inspected.manifest.get("inspection_approach", [0,0.4,6.0])
	player.global_position = _inspected.to_global(Vector3(approach[0],approach[1],approach[2]))
	player.velocity = Vector3.ZERO
	input_router.set_context(input_router.context)
	camera_rig.tracked_actor = _focus if _centered.button_pressed else player
	camera_rig.snap_to_actor()
