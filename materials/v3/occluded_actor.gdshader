shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform int occluded_view_mask = 0;
uniform vec4 outline_color : source_color = vec4(0.56, 0.80, 1.0, 0.52);
varying flat uint active_camera_mask;

void vertex() {
	// 1. 把当前相机渲染层带入片段阶段，两个视口不共用一个遮挡开关。
	active_camera_mask = CAMERA_VISIBLE_LAYERS;
}

void fragment() {
	// 2. 只有当前视图真实遮挡了此角色时才显示，另一屏不会出现透视轮廓。
	if ((active_camera_mask & uint(occluded_view_mask)) == 0u) {
		discard;
	}
	// 3. 原骨骼仍负责几何，只叠加边缘反馈，不改变深度或物理碰撞。
	float edge = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a * smoothstep(0.35, 0.85, edge);
}
