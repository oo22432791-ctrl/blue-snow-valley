extends CanvasLayer
## M9冷暖与上下文操作界面；GUI只发事务意图，Esc关闭操作后再恢复探索。

var world: Node3D
var survival: Node
var opened: bool=false
var _hud: Label
var _hint: Label
var _overlay: Control
var _title: Label
var _description: Label
var _message: Label
var _actions: VBoxContainer
var _target_id: String=""
var _token: int=0
var _age: float=0.0


## 建立一次HUD与菜单，保持UI层独立，不把库存按钮混入瞄准与射击输入。
func _ready() -> void:
	# 1. 正式状态只显示暖意、数量、可理解的交互与燃料时间。
	layer=4
	var panel:=PanelContainer.new()
	panel.position=Vector2(28,740);panel.custom_minimum_size=Vector2(510,100)
	panel.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	_hud=Label.new();_hud.add_theme_font_size_override("font_size",24)
	_hud.add_theme_color_override("font_color",Color("eef7ff"));_hud.mouse_filter=Control.MOUSE_FILTER_IGNORE
	panel.add_child(_hud)
	_hint=Label.new();_hint.position=Vector2(28,850);_hint.add_theme_font_size_override("font_size",22)
	_hint.add_theme_color_override("font_color",Color("f4f8ff"));_hint.add_theme_color_override("font_shadow_color",Color("203850"));_hint.add_theme_constant_override("shadow_offset_x",2);_hint.add_theme_constant_override("shadow_offset_y",2)
	_hint.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(_hint)
	# 2. 全屏拦截鼠标，面板只在明确交互时显示，世界时间继续、角色停止。
	_overlay=ColorRect.new();_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.color=Color(.025,.06,.12,.7);_overlay.visible=false
	add_child(_overlay)
	var center:=CenterContainer.new();center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);_overlay.add_child(center)
	var background:=PanelContainer.new();background.custom_minimum_size=Vector2(620,0);center.add_child(background)
	var margin:=MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:margin.add_theme_constant_override(side,28)
	background.add_child(margin)
	var content:=VBoxContainer.new();content.add_theme_constant_override("separation",16);margin.add_child(content)
	_title=Label.new();_title.add_theme_font_size_override("font_size",30);content.add_child(_title)
	_description=Label.new();_description.add_theme_font_size_override("font_size",22);content.add_child(_description)
	_message=Label.new();_message.add_theme_color_override("font_color",Color("f1cd99"));content.add_child(_message)
	_actions=VBoxContainer.new();_actions.add_theme_constant_override("separation",10);content.add_child(_actions)
	var close_button:=Button.new();close_button.text="返回探索（Esc）";close_button.custom_minimum_size.y=48
	close_button.pressed.connect(close);content.add_child(close_button)
	var note:=Label.new();note.text="操作时世界时间继续；Esc关闭后可再次Esc暂停。";content.add_child(note)
	# 3. 模型提交完成后刷新一次会话，按钮不直接改数量，也不创建重复信号连接。
	survival.interaction_opened.connect(_show_target)
	survival.action_completed.connect(_completed)


## 正式状态低频刷新，避免每个渲染帧重建面板与按钮。
func _process(delta: float) -> void:
	# 1. 警戒阈值与9分钟校准一致；数字暖意仅放调试，正式使用易懂分级。
	_age+=delta
	if _age<.15:return
	_age=0.0
	var comfort: String="温暖" if survival.warmth>60 else ("渐冷" if survival.warmth>20 else ("寒冷 · 请尽快取暖" if survival.warmth>0 else "失温 · 寻找热源"))
	var warming: bool=float(survival.last_thermal.get("rate",0))>0
	_hud.text="  %s%s\n  随身柴火 %d / 20根" % [comfort," · 正在回暖" if warming else "",survival.carried]
	if not survival.nearest.is_empty() and not opened and world.input_router.context==world.input_router.Context.EXPLORATION:
		_hint.text="E："+("开关" if survival.nearest.kind=="door" else "查看")+String(survival.nearest.name)
	else:_hint.text=""
	# 2. 燃料与资源可能在菜单打开时耗尽或变化，描述读取即时值。
	if opened:
		var target: Dictionary=survival.describe(_target_id)
		if not target.is_empty():_description.text=_details(target)


## 显示一个已由物理帧验证的对象，第一次打开时清理行走惯性。
func _show_target(target: Dictionary, token: int) -> void:
	# 1. 同一操作结果的刷新不重复切输入上下文，取消动作不穿透至世界。
	if not opened:
		opened=true
		world.input_router.set_context(world.input_router.Context.UI)
	_overlay.visible=true
	_target_id=target.id;_token=token
	_title.text=target.name;_description.text=_details(target)
	for child: Node in _actions.get_children():_actions.remove_child(child);child.queue_free()
	# 2. 按对象类型生成有限操作；容量仍由模型二次核验，不信任按钮显示状态。
	match String(target.kind):
		"ammo":
			_button("收取可携带的子弹","ammo",12,target.quantity<=0 or target.reserve>=target.capacity)
		"snowball":
			_button("开始雪球比赛","snowball",1,false)
		"resource":
			_button("拾取可携带的木柴","pickup",60,target.quantity<=0 or survival.carried>=20)
		"store":
			_button("存入1根","deposit",1,survival.carried<=0 or target.stored>=60)
			_button("存入全部可存木柴","deposit",60,survival.carried<=0 or target.stored>=60)
			_button("取出1根","withdraw",1,target.stored<=0 or survival.carried>=20)
			_button("取出可携带的木柴","withdraw",60,target.stored<=0 or survival.carried>=20)
		"heater":
			if not target.permanent:
				_button("添1根柴（3分钟）","fuel",1,survival.carried<=0 or target.fuel_seconds>720.001)
				_button("添满可用柴火（最多5根）","fuel",5,survival.carried<=0 or target.fuel_seconds>720.001)


## 创建一次信号连接，待提交时禁用当前全部按钮，避免同帧重复操作。
func _button(text: String, action: String, amount: int, disabled: bool) -> void:
	# 1. 捕获当前令牌作为这批按钮身份；模型还会检查会话和当前位置。
	var button:=Button.new();button.text=text;button.custom_minimum_size.y=48;button.disabled=disabled
	var token:=_token
	button.pressed.connect(func() -> void:
		if survival.submit_action(token,action,amount):
			for other: Button in _actions.get_children():other.disabled=true
	)
	_actions.add_child(button)


## 根据对象类型说明当前数量，燃料用向上取整分钟／秒显示。
func _details(target: Dictionary) -> String:
	# 1. 每屋仓储独立，避免把存柴数量误认为当前炉子燃料。
	var common: String="随身 %d / 20根" % survival.carried
	match String(target.kind):
		"snowball":return "先到5分 · 鼠标瞄准、左键投掷\n双方仍可移动，比赛期间锁定雪球。\n退出按钮或离开空地即结束；冷暖照常，可随时回屋。"
		"ammo":return "备用子弹 %d / %d发\n盒内 %d发" % [target.reserve,target.capacity,target.quantity]+(" · 已取空，离开后等待补充" if target.quantity<=0 else "")
		"resource":return common+"\n可拾 %d根" % target.quantity+(" · 已采空，离开后等待补充" if target.quantity<=0 else "")
		"store":return common+"\n此屋存放 %d / 60根（独立存放，不会自动燃烧）" % target.stored
		"heater":
			if target.permanent:return common+"\n安全屋持续温暖，无需柴火。"
			var seconds:=ceili(float(target.fuel_seconds))
			return common+"\n"+("火已熄灭，添柴即可点燃。" if seconds<=0 else "剩余燃烧 %d分%02d秒" % [seconds/60,seconds%60])+"\n每根3分钟，最多容纳5根；靠近热源回暖。"
	return common


## 事务结束后只重建当前有效会话，走远时关闭，拒绝远程库存操作。
func _completed(result: Dictionary) -> void:
	# 1. 先保存结果提示，再请求新的单次令牌；失败不修改库存或燃料。
	if not opened:return
	_message.text=result.message
	if not survival.open_session(_target_id):close()


## 关闭菜单恢复探索并撤销未提交动作；暂停请求先关闭菜单，不立即切错上下文。
func close() -> void:
	# 1. 已提交事务不回滚，未提交点击作废，不改变暖意、世界时间或门状态。
	if not opened:return
	opened=false;_overlay.visible=false;_message.text=""
	survival.close_session()
	world.input_router.set_context(world.input_router.Context.EXPLORATION)
