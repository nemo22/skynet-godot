// ENHANCED explosion: a noise-displaced fireball on a sphere (docs §P.3).
// `t` runs 0 → 1 over the explosion's life: the ball swells, the colour
// cools from white-yellow through orange to sooty red, alpha fades.
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;

uniform float t : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float intensity = 1.0;

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise3(p);
		p = p * 2.1 + vec3(3.1, 1.7, 5.3);
		a *= 0.5;
	}
	return v;
}

varying float v_noise;

void vertex() {
	float n = fbm3(normalize(VERTEX) * 2.2 + seed + t * 1.5);
	v_noise = n;
	float grow = 0.35 + 0.85 * sqrt(clamp(t, 0.0, 1.0));
	VERTEX *= grow * (0.8 + 0.45 * n);
}

void fragment() {
	float n = fbm3(vec3(UV * 5.0, t * 2.5 + seed));
	float heat = clamp(1.0 - t * 1.2 + (n - 0.5) * 0.9 + (v_noise - 0.5) * 0.4, 0.0, 1.0);
	vec3 hot = vec3(1.0, 0.95, 0.72);
	vec3 mid = vec3(1.0, 0.45, 0.08);
	vec3 cool = vec3(0.32, 0.07, 0.02);
	vec3 col = heat > 0.6 ? mix(mid, hot, (heat - 0.6) / 0.4) : mix(cool, mid, heat / 0.6);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 1.5);
	float a = heat * (1.0 - t) * (0.55 + 0.45 * (1.0 - rim));
	ALBEDO = col * a * intensity * 3.0;
	ALPHA = a;
}
