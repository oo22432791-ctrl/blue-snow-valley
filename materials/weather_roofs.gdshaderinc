// M8保守屋盖遮蔽：读取不受淡出影响的源几何包络，五处静态遮盖。
uniform vec4 roof_masks[5]; // x,z中心及x,z半尺寸，单位米。
uniform float roof_tops[5];
uniform vec3 interior_min=vec3(0.0);
uniform vec3 interior_max=vec3(0.0);
uniform float interior_cutaway=0.0;

bool weather_under_roof(vec3 point) {
	for (int i=0; i<5; i++) {
		if (abs(point.x-roof_masks[i].x)<roof_masks[i].z && abs(point.z-roof_masks[i].y)<roof_masks[i].w && point.y<roof_tops[i]) return true;
	}
	return false;
}

// 隐藏屋顶上方的雪点也不能投影进室内；只裁雪，不向主场景写入屋顶深度。
float weather_view_visibility(vec3 point,vec3 view_direction) {
	vec3 direction=view_direction+vec3(.000001);
	vec3 first=(interior_min-point)/direction;
	vec3 second=(interior_max-point)/direction;
	vec3 low=min(first,second);
	vec3 high=max(first,second);
	bool projected=max(max(low.x,low.y),low.z)<=min(min(high.x,high.y),high.z);
	return projected ? 1.0-interior_cutaway : 1.0;
}
