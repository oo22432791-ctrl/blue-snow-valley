shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 snow_color : source_color = vec4(0.545, 0.722, 0.91, 1.0);
uniform vec4 footprint_color : source_color = vec4(0.294, 0.49, 0.686, 1.0);
uniform sampler2D footprint_map : filter_linear, repeat_disable, hint_default_black;
uniform vec2 track_origin = vec2(-12.0);
uniform vec2 track_size = vec2(24.0);
uniform float track_time = 0.0;
uniform float recovery_seconds = 30.0;
uniform bool use_geometry = true;
varying vec2 snow_position;

// 深雪区与CPU阻力采样共用解析定义，白天和夜晚保持同一地形。
float fresh_depth(vec2 p) {
	vec2 a = p - vec2(4.8, 3.0);
	vec2 b = p - vec2(-6.0, 2.0);
	return clamp(0.08 + exp(-dot(a, a) / 9.68) * 0.18 + exp(-dot(b, b) / 8.0) * 0.12, 0.08, 0.28);
}

float edge_weight(vec2 p) {
	return 1.0 - smoothstep(10.0, 12.0, max(abs(p.x), abs(p.y)));
}

// 细节网格边缘平滑回到统一基面，外部低成本平面没有高度裂缝。
float base_height(vec2 p) {
	float variation = sin(p.x * 0.47) * cos(p.y * 0.38) * 0.028
		+ sin(p.x * 1.15 + p.y * 0.62) * 0.008;
	return 0.08 + (fresh_depth(p) + variation - 0.08) * edge_weight(p);
}

// R为强度，G为带权时间戳；重建时间后按30秒曲线逐渐恢复。
float impression_at(vec2 point) {
	vec2 uv = (point - track_origin) / track_size;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
		return 0.0;
	}
	vec2 data = textureLod(footprint_map, uv, 0.0).rg;
	if (data.r < 0.00001) {
		return 0.0;
	}
	float age = max(0.0, track_time - data.g / data.r);
	return data.r * (1.0 - smoothstep(0.0, recovery_seconds, age));
}

// 凹陷保持有界，邻域差形成脚印外沿少量隆起。
float deformed_height(vec2 p) {
	float h = impression_at(p);
	float neighbor = max(max(impression_at(p + vec2(0.045, 0.0)), impression_at(p - vec2(0.045, 0.0))),
		max(impression_at(p + vec2(0.0, 0.045)), impression_at(p - vec2(0.0, 0.045))));
	float depression = min(0.1, fresh_depth(p) * 0.42) * h;
	float rim = max(0.0, neighbor - h) * 0.018;
	return base_height(p) + (rim - depression) * edge_weight(p);
}

void vertex() {
	// 1. 使用同一世界映射读取足迹场，跨过旧64脚印限制后仍可连续记录。
	snow_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	// 2. 默认以细分几何压出脚印，法线对照仅用于效果与成本比较。
	VERTEX.y = use_geometry ? deformed_height(snow_position) : base_height(snow_position);
}

void fragment() {
	// 1. 保留大面积干净蓝调，细微起伏不改变已确认配色。
	float variation = sin(snow_position.x * 0.3 + snow_position.y * 0.15) * 0.015;
	vec3 color = snow_color.rgb * (1.0 + variation);
	float impression = impression_at(snow_position);
	// 2. 五点高度差重建足迹法线，凹陷依赖光照形成体积而非深色贴片。
	vec2 dx = vec2(0.035, 0.0);
	vec2 dz = vec2(0.0, 0.035);
	float left = impression_at(snow_position - dx);
	float right = impression_at(snow_position + dx);
	float front = impression_at(snow_position - dz);
	float back = impression_at(snow_position + dz);
	float hl = base_height(snow_position - dx) - min(0.1, fresh_depth(snow_position - dx) * 0.42) * left;
	float hr = base_height(snow_position + dx) - min(0.1, fresh_depth(snow_position + dx) * 0.42) * right;
	float hf = base_height(snow_position - dz) - min(0.1, fresh_depth(snow_position - dz) * 0.42) * front;
	float hb = base_height(snow_position + dz) - min(0.1, fresh_depth(snow_position + dz) * 0.42) * back;
	vec3 world_normal = normalize(vec3(hl - hr, 0.07, hf - hb));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	// 3. 保持已确认蓝色，少量色差和软亮边辅助读形，粗糙材质抑制塑料光泽。
	float rim = max(0.0, max(max(left, right), max(front, back)) - impression);
	ALBEDO = mix(color, footprint_color.rgb, impression * 0.24) + rim * 0.035;
	ROUGHNESS = 0.96;
	SPECULAR = 0.12;
}
