// ENHANCED sky (docs/implementation_plan.md §P): the DOS game has one sky
// for every outdoor map — a dark apocalyptic dusk with a moon. This
// reproduces it physically-ish: a red glow band at the horizon around the
// sun (LIGHT0 = the scene's DirectionalLight), fading through violet to a
// night zenith with stars and the moon (the `stars` panorama), a bright
// HDR sun disk for the glow pass. `night_mix` shifts the palette toward
// a blue night when a replacement sky texture is dark and neutral.
shader_type sky;

uniform sampler2D stars : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 zenith_color : source_color = vec3(0.02, 0.012, 0.045);
uniform vec3 horizon_color : source_color = vec3(0.36, 0.06, 0.05);
uniform vec3 glow_color : source_color = vec3(1.0, 0.48, 0.16);
uniform vec3 ground_color : source_color = vec3(0.09, 0.045, 0.035);
uniform float star_energy = 1.4;
uniform float sun_size = 0.035;
uniform float sun_energy = 3.5;
uniform float glow_strength = 0.55;

void sky() {
	vec3 d = EYEDIR;
	float el = d.y;
	vec3 col;
	if (el < 0.0) {
		col = mix(horizon_color, ground_color, clamp(-el * 5.0, 0.0, 1.0));
	} else {
		float t = pow(clamp(el, 0.0, 1.0), 0.42);
		col = mix(horizon_color, zenith_color, t);
	}
	// Glow around the sun, strongest at the horizon.
	float cosang = dot(d, LIGHT0_DIRECTION);
	float near = max(cosang, 0.0);
	float glow = pow(near, 5.0) * 0.5 + pow(near, 40.0) * 0.8;
	glow *= 0.45 + 0.55 * clamp(1.0 - el * 2.5, 0.0, 1.0);
	glow *= (el > -0.03) ? 1.0 : 0.25;
	col += glow_color * glow * glow_strength;
	// Sun disk (HDR, blooms).
	float disk = smoothstep(cos(sun_size * 1.5), cos(sun_size), cosang);
	col += LIGHT0_COLOR * disk * sun_energy * step(0.5, LIGHT0_ENABLED ? 1.0 : 0.0);
	// Stars and moon, hidden inside the horizon glow.
	vec3 st = texture(stars, SKY_COORDS).rgb;
	float vis = clamp((el - 0.10) * 3.0, 0.0, 1.0) * clamp(1.0 - glow * 2.0, 0.0, 1.0);
	col += st * star_energy * vis;
	COLOR = col;
}
