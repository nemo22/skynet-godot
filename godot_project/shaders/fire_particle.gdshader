// ENHANCED fire particle (docs §P.5): one soft flame blob on a
// camera-facing particle quad. The particle's age comes in through
// COLOR.a (a 1 → 0 alpha ramp on the process material): young = bright
// white-yellow core, old = thin red wisps. Additive, HDR for the glow.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float intensity : hint_range(0.0, 4.0) = 1.0;
uniform vec3 color_base : source_color = vec3(1.0, 0.32, 0.05);
uniform vec3 color_tip : source_color = vec3(1.0, 0.88, 0.5);

varying float v_age;
varying float v_seed;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p * 2.1 + vec2(3.7, 1.9);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	v_age = 1.0 - COLOR.a;
	v_seed = float(INSTANCE_ID) * 0.37;
	// Shrink with age, then face the camera keeping the particle scale.
	VERTEX *= 1.0 - 0.55 * v_age;
	mat4 mat_world = mat4(
		normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	mat_world = mat_world * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 c = UV - 0.5;
	float r = length(c) * 2.0;
	float n = fbm(UV * 2.6 + v_seed + vec2(0.0, -TIME * 1.1));
	float shape = (1.0 - r) + (n - 0.5) * 0.9;
	float a = smoothstep(0.15, 0.6, shape) * (1.0 - v_age * v_age) * smoothstep(1.0, 0.55, r);
	float heat = clamp((1.0 - v_age) * (1.0 - r * 0.7) + (n - 0.5) * 0.4, 0.0, 1.0);
	vec3 col = mix(color_base, color_tip, heat * heat) * (0.5 + 2.2 * heat);
	ALBEDO = col * a * intensity;
	ALPHA = a;
}
