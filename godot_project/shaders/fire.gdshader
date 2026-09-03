// ENHANCED fire: a procedural flame on a Y-billboard quad (docs §P.3).
// Value-noise FBM scrolled upward, tapered to a tongue, additive HDR
// emission so the glow pass blooms it. `seed` de-synchronises fires,
// `intensity` scales brightness, `width` the tongue's fatness.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float intensity : hint_range(0.0, 4.0) = 1.0;
uniform float speed = 1.3;
uniform float seed = 0.0;
uniform float width = 1.0;
uniform vec3 color_base : source_color = vec3(1.0, 0.30, 0.04);
uniform vec3 color_tip : source_color = vec3(1.0, 0.85, 0.45);

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
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	// Y-axis billboard (Godot's BILLBOARD_FIXED_Y), keeping the node scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(INV_VIEW_MATRIX[2].xyz), 0.0),
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 uv = UV;
	float y = 1.0 - uv.y;                    // 0 = base, 1 = tip
	float x = (uv.x - 0.5) * 2.0;            // -1 .. 1
	float t = TIME * speed + seed * 7.0;
	float taper = 1.0 - y * 0.72;
	float edge = 1.0 - abs(x) / max(taper * width, 0.05);
	vec2 p = vec2(uv.x * 2.5 + seed, y * 3.0 - t);
	float n = fbm(p);
	float n2 = fbm(p * 2.1 + vec2(3.7, -t * 0.7));
	float body = edge * (1.15 - y) + (n - 0.5) * 0.9 + (n2 - 0.5) * 0.35;
	// Fade to nothing at the quad's border so the card never shows.
	float border = smoothstep(0.0, 0.3, 1.0 - abs(x)) * smoothstep(0.0, 0.12, y) * smoothstep(1.0, 0.75, y);
	float f = smoothstep(0.25, 0.75, body) * border;
	float core = smoothstep(0.55, 1.0, body);
	vec3 col = mix(color_base, color_tip, core) * (0.6 + 1.6 * f);
	// unshaded: ALBEDO is the output (EMISSION is ignored); HDR values
	// above 1.0 feed the glow pass.
	ALBEDO = col * intensity * f * 2.0;
	ALPHA = f;
}
