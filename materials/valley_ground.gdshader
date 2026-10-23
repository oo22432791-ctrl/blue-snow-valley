shader_type spatial;
render_mode diffuse_burley;

uniform vec4 snow_color : source_color = vec4(0.545, 0.722, 0.91, 1.0);
uniform vec4 path_color : source_color = vec4(0.72, 0.83, 0.95, 1.0);
varying vec2 terrain_paint;

void vertex() {
	// 1. 离线顶点色只保存路面与地形信息，没有脚印或雪深模拟。
	terrain_paint = COLOR.rg;
}

void fragment() {
	// 2. 道路适度变浅，山脊轻微分色，仍保留统一蓝色画风。
	ALBEDO = mix(snow_color.rgb, path_color.rgb, terrain_paint.r * 0.55) * (1.0 - terrain_paint.g * 0.08);
	ROUGHNESS = 0.95;
}
