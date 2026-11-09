// Stand-in for the intact surface of a flat point cloud (PointCloud.flat_proxy).
// Drawn with the same colour, texture and material as the dots, so it looks
// identical, but it's one plane instead of thousands of dots. Holes from
// carve() are cut out of it: pending carves analytically (same list as the
// dots), baked ones through a top-down mask. The dots draw the hole walls and
// debris; outside holes they're skipped entirely.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 base_color : source_color = vec4(1.0);
uniform bool use_surface_texture = false;
uniform sampler2D surface_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 texture_tile = vec3(1.0);
uniform vec3 texture_offset = vec3(0.0);
uniform sampler2D hole_mask : filter_linear, repeat_disable;   // r > 0.5 = hole
uniform sampler2D paint_tex : source_color, filter_linear, repeat_disable;
uniform vec3 bounds_min = vec3(-1.0);
uniform vec3 bounds_size = vec3(2.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
// Holes are cut out to this fraction of WALL_REACH (1.7 radii): the ring just
// inside it is drawn by the hole-wall dots, overlapping the plane slightly.
uniform float hole_reach = 1.6;
uniform int carve_count = 0;
uniform vec4 carve_a[48];  // xyz centre (local), w start time
uniform vec4 carve_b[48];  // x radius

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec2 uv = (v_local.xz - bounds_min.xz) / max(bounds_size.xz, vec2(1e-4));
	if (texture(hole_mask, uv).r > 0.5) {
		discard;
	}
	for (int i = 0; i < carve_count; i++) {
		vec4 ca = carve_a[i];
		float r = carve_b[i].x * hole_reach;
		float dy = v_local.y - ca.y;
		float rr = r * r - dy * dy;
		vec2 d = v_local.xz - ca.xz;
		if (rr > 0.0 && dot(d, d) < rr) {
			discard;
		}
	}
	vec3 col = base_color.rgb * texture(paint_tex, uv).rgb;
	if (use_surface_texture) {
		col *= texture(surface_texture, (v_local.xz - texture_offset.xz) / texture_tile.xz).rgb;
	}
	ALBEDO = col;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
