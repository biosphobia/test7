// Edge-aware smoothing over the 3D view. Averages each pixel with neighbours
// of similar colour, which irons out leftover per-dot speckle on surfaces,
// while neighbours across a real edge (silhouettes, grid lines) are ignored
// so those stay sharp. 5 texture reads per pixel.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float strength : hint_range(0.0, 1.0) = 0.7;
// Colour difference at which a neighbour stops counting (0..1 per channel).
uniform float edge : hint_range(0.01, 0.5) = 0.07;

vec3 take(vec2 uv, vec3 c, inout float w) {
	vec3 n = texture(screen_tex, uv).rgb;
	float k = 1.0 - smoothstep(edge * 0.5, edge, distance(n, c));
	w += k;
	return n * k;
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float w = 1.0;
	vec3 sum = c;
	sum += take(SCREEN_UV + vec2(px.x, 0.0), c, w);
	sum += take(SCREEN_UV - vec2(px.x, 0.0), c, w);
	sum += take(SCREEN_UV + vec2(0.0, px.y), c, w);
	sum += take(SCREEN_UV - vec2(0.0, px.y), c, w);
	COLOR = vec4(mix(c, sum / w, strength), 1.0);
}
