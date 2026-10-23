shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha, shadows_disabled;
uniform float game_clock=0.0;
uniform float strength=0.0;
void fragment(){
	// 1. 显式统一时间产生温和摆动，暂停冻结，不使用内置TIME。
	float x=UV.x-.5+sin(UV.y*8.0-game_clock*3.2)*.06*UV.y;
	float width=mix(.42,.025,1.0-UV.y);
	float edge=1.0-smoothstep(width*.75,width,abs(x));
	float base=smoothstep(0.0,.12,UV.y);
	ALBEDO=mix(vec3(1.0,.30,.045),vec3(1.0,.80,.31),UV.y);
	EMISSION=ALBEDO*.8;
	ALPHA=edge*base*strength*.85;
}
