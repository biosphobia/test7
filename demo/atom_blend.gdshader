// Connects atoms. A full-screen pass over the finished 3D picture: wherever a
// pixel lies in a small gap between atoms that are closer to the viewer (the
// same nearer surface on two opposite sides of it), the gap is filled with
// their blended colour. Dense clouds of loose atoms fuse into soft, continuous
// shapes; a lone atom stays a dot, and solid surfaces are untouched.
// Up to 16 colour + depth reads per pixel.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
// Widest gap that gets bridged, in pixels (two rings are tested: half and full).
uniform float reach = 5.0;
uniform float strength : hint_range(0.0, 1.0) = 1.0;
uniform float out_gamma = 2.2;
uniform float out_gain = 1.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// (The depth texture may only be sampled inside fragment() itself in the
// Compatibility renderer, so the raw value is passed in.)
float lin_depth(float d, vec2 uv, mat4 inv_proj) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
#else
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
#endif
	return -v.z / v.w;
}

void fragment() {
	vec2 px = 1.0 / VIEWPORT_SIZE;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float dc = lin_depth(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX);
	vec3 sum = vec3(0.0);
	float w = 0.0;
	for (int ring = 0; ring < 2; ring++) {
		float r = reach * (ring == 0 ? 0.5 : 1.0);
		for (int i = 0; i < 4; i++) {
			float a = float(i) * 0.7853982 + float(ring) * 0.3926991;
			vec2 o = vec2(cos(a), sin(a)) * r * px;
			float d1 = lin_depth(texture(depth_tex, SCREEN_UV + o).r, SCREEN_UV + o, INV_PROJECTION_MATRIX);
			float d2 = lin_depth(texture(depth_tex, SCREEN_UV - o).r, SCREEN_UV - o, INV_PROJECTION_MATRIX);
			// Both sides nearer than this pixel, and at about the same depth as
			// each other: this pixel is a gap in one nearer cloud or surface.
			float near1 = step(d1, dc * 0.93);
			float near2 = step(d2, dc * 0.93);
			float same = 1.0 - smoothstep(0.08, 0.2, abs(d1 - d2) / max(min(d1, d2), 1e-3));
			float k = near1 * near2 * same * (ring == 0 ? 1.0 : 0.6);
			sum += (texture(screen_tex, SCREEN_UV + o).rgb + texture(screen_tex, SCREEN_UV - o).rgb) * 0.5 * k;
			w += k;
		}
	}
	// Only gap pixels are written; everything else keeps the original picture.
	if (w < 0.5) {
		discard;
	}
	vec3 col = mix(c, sum / w, strength);
	// The picture read back is display-encoded and already tone-mapped; undo
	// the encoding so that writing it out again leaves it unchanged.
	ALBEDO = out_gain * pow(col, vec3(out_gamma));
}
