shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform bool externally_occluded = false;
uniform vec4 outline_color : source_color = vec4(0.56, 0.80, 1.0, 0.52);

void fragment() {
	// 1. 先由外部网格包络确认遮挡，人物自身部件交叠不触发提示。
	if (!externally_occluded) {
		discard;
	}
	// 2. 外部视线确实受阻时给人物边缘剪影，避免自身骨骼表面互相触发。
	float edge = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = smoothstep(0.35, 0.85, edge);
	// 3. 不读取或改写场景深度；门、家具和原人物仍保留原来的不透明绘制。
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a * rim;
}
