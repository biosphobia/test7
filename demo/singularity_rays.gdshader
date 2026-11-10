// Light breaking out of the singularity: a handful of beams, each starting
// at its own moment and growing to its own length, plus a flash for the bang.
shader_type canvas_item;
render_mode blend_add, unshaded;

uniform float crack = 0.0;      // 0..1 in five steps: each step is one crack
uniform float flash = 0.0;      // white-out at the moment of the bang
uniform vec2 centre = vec2(0.0); // screen position of the ball, pixels
uniform float ball_px = 20.0;   // radius of the ball, pixels
uniform float fade = 1.0;

float h(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void fragment() {
	vec2 d = (FRAGCOORD.xy - centre) / max(ball_px, 1.0);
	float r = length(d);
	float a = atan(d.y, d.x);
	float rays = 0.0;
	for (int i = 0; i < 10; i++) {
		float fi = float(i) + 1.0;
		// Spread all the way round, unevenly.
		float ai = (fi * 3.0 + 0.8 * h(fi * 1.7)) / 10.0 * TAU + sin(TIME * 0.4 + fi) * 0.04;
		// Each beam breaks out at its own moment and reaches its own length.
		// Two beams break out with each of the five cracks.
		float th = floor(float(i) / 2.0) / 5.0;
		float grown = smoothstep(th, th + 0.19, crack);
		float len = (5.0 + 60.0 * h(fi * 7.7) * h(fi * 2.3)) * grown;
		float w = 0.008 + 0.03 * h(fi * 5.3);
		float da = abs(mod(a - ai + PI, TAU) - PI);
		float beam = exp(-pow(da / (w * (1.0 + 1.5 / max(r, 0.4))), 2.0));
		float flicker = 0.75 + 0.25 * sin(TIME * (17.0 + fi * 3.0) + fi * 2.0);
		rays += beam * smoothstep(len, 0.0, r) * flicker * step(0.001, grown);
	}
	float core = crack * 0.25 / (1.0 + r * r * 1.2);
	vec3 col = vec3(1.0, 0.88, 0.62) * (rays * 1.3 + core) * fade + vec3(1.0, 0.97, 0.9) * flash;
	COLOR = vec4(col, 1.0);
}
