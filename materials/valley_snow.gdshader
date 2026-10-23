shader_type spatial;
render_mode world_vertex_coords, diffuse_burley;

uniform sampler2D depth_grid : filter_nearest, repeat_disable;
uniform sampler2D base_grid : filter_nearest, repeat_disable;
uniform vec2 map_origin = vec2(-224.0, -256.0);
uniform vec2 depth_size = vec2(897.0, 1025.0);
uniform vec2 base_size = vec2(225.0, 257.0);
uniform vec4 detail_bounds;
uniform vec4 detail_bounds_p2;
uniform bool dual_view_detail = false;
uniform bool fine_mesh = false;
uniform bool tracks_enabled = false;
uniform sampler2DArray track_atlas : filter_nearest, repeat_disable;
uniform sampler2D track_pages : filter_nearest, repeat_disable;
uniform float track_clock = 0.0;
uniform vec4 snow_color : source_color = vec4(0.545, 0.722, 0.91, 1.0);
uniform vec4 path_color : source_color = vec4(0.72, 0.83, 0.95, 1.0);
varying vec2 world_xz;
varying float fresh_depth;
varying vec2 macro_slope;
varying flat vec4 active_detail_bounds;

// 每个像素先恢复，再双线性插值；正负边缘及空白不混用时间戳。
float recovered(vec2 pixel) {
	return pixel.r*(1.0-smoothstep(0.0,180.0,max(0.0,track_clock-pixel.g)));
}

float track_at(vec2 p) {
	if (!tracks_enabled) { return 0.0; }
	ivec2 page = ivec2(floor((p-map_origin)/8.0));
	if (any(lessThan(page,ivec2(0))) || any(greaterThanEqual(page,ivec2(56,64)))) { return 0.0; }
	int layer = int(texelFetch(track_pages,page,0).r)-1;
	if (layer<0) { return 0.0; }
	vec2 origin = floor(p/8.0)*8.0;
	vec2 g = (p-origin)/0.03125+0.5;
	ivec2 cell = ivec2(floor(g));
	vec2 f = fract(g);
	float a = recovered(texelFetch(track_atlas,ivec3(cell,layer),0).rg);
	float b = recovered(texelFetch(track_atlas,ivec3(cell+ivec2(1,0),layer),0).rg);
	float c = recovered(texelFetch(track_atlas,ivec3(cell+ivec2(0,1),layer),0).rg);
	float d = recovered(texelFetch(track_atlas,ivec3(cell+ivec2(1,1),layer),0).rg);
	return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}

// 1. GPU与CPU读取同一浮点网格；显式插值避免纹理半像素偏移。
float depth_at(vec2 p) {
	vec2 g = clamp((p-map_origin)/0.5, vec2(0.0), depth_size-vec2(1.001));
	ivec2 cell = ivec2(floor(g));
	vec2 f = fract(g);
	float a = texelFetch(depth_grid, cell, 0).r;
	float b = texelFetch(depth_grid, cell+ivec2(1,0), 0).r;
	float c = texelFetch(depth_grid, cell+ivec2(0,1), 0).r;
	float d = texelFetch(depth_grid, cell+ivec2(1,1), 0).r;
	return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}

// 2. 基底沿用M2真实碰撞三角形的对角线，不能用双线性替代。
float base_at(vec2 p) {
	vec2 g = clamp((p-map_origin)/2.0, vec2(0.0), base_size-vec2(1.001));
	ivec2 cell = ivec2(floor(g));
	vec2 f = fract(g);
	float a = texelFetch(base_grid,cell,0).r;
	float b = texelFetch(base_grid,cell+ivec2(1,0),0).r;
	float c = texelFetch(base_grid,cell+ivec2(0,1),0).r;
	float d = texelFetch(base_grid,cell+ivec2(1,1),0).r;
	return f.x+f.y <= 1.0 ? a+(b-a)*f.x+(c-a)*f.y : d+(c-d)*(1.0-f.x)+(b-d)*(1.0-f.y);
}

float fresh_surface(vec2 p) { return base_at(p)+depth_at(p); }
float surface_at(vec2 p) { return base_at(p)+max(0.004,depth_at(p)+track_at(p)); }

// 3. 只在细节窗口外边缘渐变到远景三角形高度，内部块不降级。
float coarse_surface(vec2 p) {
	vec2 cell = floor((p-map_origin)/2.0)*2.0+map_origin;
	vec2 f = (p-cell)/2.0;
	float a = fresh_surface(cell);
	float b = fresh_surface(cell+vec2(2,0));
	float c = fresh_surface(cell+vec2(0,2));
	float d = fresh_surface(cell+vec2(2,2));
	return f.x+f.y <= 1.0 ? a+(b-a)*f.x+(c-a)*f.y : d+(c-d)*(1.0-f.x)+(b-d)*(1.0-f.y);
}

void vertex() {
	// 每屏选择自己的局部窗口；默认关闭时保持原单人采样。
	active_detail_bounds = dual_view_detail && (CAMERA_VISIBLE_LAYERS & 4u) != 0u ? detail_bounds_p2 : detail_bounds;
	world_xz = VERTEX.xz;
	fresh_depth = depth_at(world_xz);
	if (fine_mesh) {
		vec2 edge = min(world_xz-active_detail_bounds.xy, active_detail_bounds.zw-world_xz);
		float weight = smoothstep(0.0,2.0,min(edge.x,edge.y));
		VERTEX.y = mix(coarse_surface(world_xz),surface_at(world_xz),weight);
	} else {
		VERTEX.y += fresh_depth;
	}
	float e = 0.25;
	macro_slope = vec2(fresh_surface(world_xz-vec2(e,0))-fresh_surface(world_xz+vec2(e,0)),
		fresh_surface(world_xz-vec2(0,e))-fresh_surface(world_xz+vec2(0,e)))/(2.0*e);
	NORMAL = normalize(vec3(macro_slope.x,1.0,macro_slope.y));
}

void fragment() {
	// 4. 远景让出窗口，只有附近九块使用12.5厘米网格，避免叠面闪烁。
	if (!fine_mesh && all(greaterThan(world_xz,active_detail_bounds.xy)) && all(lessThan(world_xz,active_detail_bounds.zw))) { discard; }
	float path = 1.0-smoothstep(0.034,0.065,depth_at(world_xz));
	float grain = sin(world_xz.x*61.0+sin(world_xz.y*43.0))*sin(world_xz.y*57.0)*0.006;
	ALBEDO = mix(snow_color.rgb,path_color.rgb,path*0.55)*(1.0+grain);
	// 5. 近处压痕改变真实几何和细节法线，颜色只保留少量环境遮蔽，不画深蓝椭圆。
	if (fine_mesh && tracks_enabled) {
		float e = 0.03125;
		vec2 edge = min(world_xz-active_detail_bounds.xy,active_detail_bounds.zw-world_xz);
		float weight = smoothstep(0.0,2.0,min(edge.x,edge.y));
		vec2 slope = macro_slope+vec2(track_at(world_xz-vec2(e,0))-track_at(world_xz+vec2(e,0)),
			track_at(world_xz-vec2(0,e))-track_at(world_xz+vec2(0,e)))*weight/(2.0*e);
		NORMAL = normalize((VIEW_MATRIX*vec4(normalize(vec3(slope.x,1.0,slope.y)),0.0)).xyz);
		AO = 1.0-0.12*clamp(-track_at(world_xz)/max(depth_at(world_xz),0.01),0.0,1.0);
	}
	ROUGHNESS = 0.97;
}
