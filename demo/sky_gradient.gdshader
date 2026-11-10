// A plain vertical gradient with no horizon: the colour changes smoothly from
// overhead, through eye level, to below, with no line or band where sky would
// meet ground.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.05, 0.07, 0.14);
uniform vec3 low_color : source_color = vec3(0.32, 0.26, 0.36);

void sky() {
	COLOR = mix(low_color, top_color, smoothstep(-0.35, 0.9, EYEDIR.y));
}
