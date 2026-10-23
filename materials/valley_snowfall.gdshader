shader_type spatial;
render_mode unshaded,cull_disabled,blend_mix,depth_draw_never,shadows_disabled,fog_disabled;
#include "res://materials/weather_roofs.gdshaderinc"
uniform float weather_clock=0.0;
uniform float storm_strength=0.0;
uniform vec3 weather_center=vec3(0.0);
uniform vec2 wind_offset=vec2(0.0);
uniform vec4 snow_tint:source_color=vec4(0.88,0.94,1.0,1.0);
varying float flake_alpha;

void vertex() {
	// 1. 世界空间循环体积只在视野边缘回绕，行走时不会把整片雪粒拖着走。
	vec4 seed=INSTANCE_CUSTOM;
	vec3 point=vec3(mod(seed.x*32.0+wind_offset.x-weather_center.x+16.0,32.0)+weather_center.x-16.0,
		mod(seed.y*16.0-weather_clock*(3.6+seed.w*1.2)-weather_center.y+3.0,16.0)+weather_center.y-3.0,
		mod(seed.z*32.0+wind_offset.y-weather_center.z+16.0,32.0)+weather_center.z-16.0);
	float border=1.0-smoothstep(13.0,16.0,max(abs(point.x-weather_center.x),abs(point.z-weather_center.z)));
	flake_alpha=storm_strength*smoothstep(seed.w*.65,seed.w*.65+.25,storm_strength)*border;
	// 2. 屋盖下雪粒在绘制前被遮蔽，完全隐藏的室内屋顶仍提供相同遮蔽。
	if(weather_under_roof(point)) flake_alpha=0.0;
	flake_alpha*=weather_view_visibility(point,INV_VIEW_MATRIX[2].xyz);
	vec3 offset=INV_VIEW_MATRIX[0].xyz*VERTEX.x+INV_VIEW_MATRIX[1].xyz*VERTEX.y;
	POSITION=PROJECTION_MATRIX*VIEW_MATRIX*vec4(point+offset,1.0);
}

void fragment() {
	// 3. 柔软椭圆雪点；保留正常深度测试，树、人物和实体墙照常遮挡。
	float radius=length((UV-vec2(.5))*vec2(2.0,1.65));
	ALBEDO=snow_tint.rgb;
	ALPHA=(1.0-smoothstep(.45,.95,radius))*flake_alpha*.62;
	if(ALPHA<.008) discard;
}
