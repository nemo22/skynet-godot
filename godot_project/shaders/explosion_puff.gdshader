// ENHANCED explosion puff (docs §P.5): one soft, noisy, camera-facing
// blob. Several are layered by explosion.gd and drift outward; `t` runs
// 0 → 1 over the explosion's life: white-hot core → orange → dark
// embers → thin smoke, alpha fading out. Mix blending so the smoke can
// darken what is behind it; HDR brightness early on feeds the glow.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform float t : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float intensity = 1.0;

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
		p = p * 2.05 + vec2(1.3, 7.1);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	// Full billboard, keeping the node scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 c = UV - 0.5;
	float r = length(c) * 2.0;                      // 0 centre .. 1 edge
	float n = fbm(UV * 3.0 + seed + vec2(t * 0.6, -t * 0.9));
	float n2 = fbm(UV * 6.5 - seed * 1.7 + vec2(-t * 0.4, t * 1.3));
	float shape = 1.0 - r + (n - 0.5) * 0.9 + (n2 - 0.5) * 0.35;
	float a = smoothstep(0.08, 0.5, shape) * (1.0 - smoothstep(0.45, 1.0, t)) * smoothstep(1.0, 0.5, r);
	float heat = clamp(1.0 - t * 1.45 - r * 0.45 + (n - 0.5) * 0.7, 0.0, 1.0);
	vec3 hot = vec3(1.0, 0.96, 0.78);
	vec3 mid = vec3(1.0, 0.48, 0.1);
	vec3 dark = vec3(0.28, 0.08, 0.03);
	vec3 smoke = vec3(0.06, 0.05, 0.05);
	vec3 col;
	if (heat > 0.6) {
		col = mix(mid, hot, (heat - 0.6) / 0.4);
	} else if (heat > 0.25) {
		col = mix(dark, mid, (heat - 0.25) / 0.35);
	} else {
		col = mix(smoke, dark, heat / 0.25);
	}
	float bright = 1.0 + 2.8 * heat * heat;
	ALBEDO = col * bright * intensity;
	ALPHA = a * (0.95 - 0.5 * t);
}
