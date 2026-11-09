// Shared body of point_cloud.gdshader (fast) and point_cloud_exact.gdshader.
// Include this from your own shader to customise it (see custom_effect()).

// ---------------------------------------------------------------- point data
uniform sampler2D pos_tex : filter_nearest, repeat_disable;   // xyz = rest position (RGB32F)
uniform sampler2D col_tex : filter_nearest, repeat_disable;   // rgba = sRGB colour (RGBA32F)
uniform sampler2D nrm_tex : filter_nearest, repeat_disable;   // xyz = normal (RGB32F)
uniform sampler2D curv_tex : filter_nearest, repeat_disable;  // curvature tensor, 2 texels per point
uniform sampler2D state_tex : filter_nearest, repeat_disable; // x = detach time (<0 attached), yzw = velocity
uniform int tex_width = 2048;
uniform int density = 1;            // dots drawn per stored point
uniform int dot_count = 0;          // dots drawn this frame
// Points are stored [surface | interior]. Level of detail draws the first
// surface_drawn surface points, then (after them) a prefix of the interior.
uniform int surface_count = 2147483647;
uniform int surface_drawn = 2147483647;
// Skip surface dots that face away from the view (or light). They're hidden
// behind the front of a closed model anyway.
uniform bool backface_cull = true;
uniform float point_spacing = 0.01; // average distance between stored surface points
const int CHUNK = 32768;            // must match PointCloud.CHUNK
uniform float cloud_time = 0.0;
uniform vec3 bounds_min = vec3(-1.0);
uniform vec3 bounds_size = vec3(2.0);

// ---------------------------------------------------------------- appearance
uniform float point_size = 0.02;          // world-space diameter of one point
uniform float lod_scale = 1.0;            // > 1 when level of detail draws fewer points
uniform float min_pixel_size = 1.0;
uniform float max_pixel_size = 48.0;
uniform bool round_points = true;
// Surface splats: each dot is drawn as a small disc lying in the surface's
// tangent plane with exact per-pixel depth, so overlapping dots fuse into a
// continuous surface (no stipple, no interior dots showing through).
uniform bool splats = true;
// While a dot is at rest, cut its disc off at the cloud's bounding box. Makes
// box edges and flat borders razor sharp instead of fuzzy.
uniform bool clip_to_bounds = true;
uniform bool unshaded = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float emission_strength = 0.0;
uniform vec4 tint = vec4(1.0);
// Optional texture sampled per pixel (triplanar, from each disc's exact
// surface position) and multiplied with the dot colours. Fine detail such as
// lines, text or wood grain stays razor sharp however big the dots are.
// Dot colour alpha masks it (interior points use alpha 0).
uniform bool use_surface_texture = false;
uniform sampler2D surface_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 texture_tile = vec3(1.0);   // local size of one texture repeat per axis
uniform vec3 texture_offset = vec3(0.0);
uniform float tint_amount : hint_range(0.0, 1.0) = 0.0;

// ---------------------------------------------------------------- skinning
uniform bool use_skin = false;
uniform sampler2D bone_idx_tex : filter_nearest, repeat_disable;   // 4 bind indices per point
uniform sampler2D bone_wgt_tex : filter_nearest, repeat_disable;   // 4 weights per point
uniform sampler2D bone_xform_tex : filter_nearest, repeat_disable; // 3 texels (matrix rows) per bind

// ---------------------------------------------------------------- morph
uniform sampler2D target_pos_tex : filter_nearest, repeat_disable;
uniform sampler2D target_col_tex : filter_nearest, repeat_disable;
uniform sampler2D target_nrm_tex : filter_nearest, repeat_disable;
uniform sampler2D target_curv_tex : filter_nearest, repeat_disable;
// Splat discs are this much larger than plain dots so they overlap fully.
uniform float splat_scale = 1.6;
uniform float morph : hint_range(0.0, 1.0) = 0.0;
uniform float morph_stagger : hint_range(0.0, 0.95) = 0.5;
uniform float morph_arc = 0.3;

// ---------------------------------------------------------------- effects
uniform float vibrate_amplitude = 0.0;
uniform float vibrate_frequency = 30.0;

uniform float wobble_amplitude = 0.0;
uniform float wobble_frequency = 3.0;
uniform float wobble_speed = 3.0;

uniform float explode = 0.0;
uniform vec3 explode_center = vec3(0.0);

uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform vec3 dissolve_direction = vec3(0.0, 1.0, 0.0);
uniform float dissolve_directional : hint_range(0.0, 1.0) = 0.0;
uniform float dissolve_span = 0.4;
uniform float dissolve_spread = 1.5;
uniform vec3 dissolve_drift = vec3(0.0, 0.6, 0.0);
uniform vec4 dissolve_edge_color : source_color = vec4(1.0, 0.45, 0.1, 1.0);
uniform float glow_strength = 4.0;

uniform float debris_lifetime = 2.0;
uniform vec3 debris_gravity = vec3(0.0, -3.0, 0.0);
uniform float heal : hint_range(0.0, 1.0) = 0.0;
uniform bool has_debris = false;  // skip the state lookup until something was carved

// Ripple impacts: xyz = local position, w = start time (< 0 inactive).
uniform vec4 impact_pos[8];
// x = strength, y = speed, z = ring width, w = decay
uniform vec4 impact_params[8];
uniform float impacts_until = -1.0;  // skip the ripple loop after this time

varying vec4 v_color;
varying float v_glow;
varying float v_alive;
varying float v_px;
varying vec3 v_center;   // dot centre, view space
varying vec3 v_vnormal;  // dot normal, view space
varying vec3 v_local;    // dot centre, local space (for bounds clipping)
varying float v_radius;  // disc radius, view space
varying float v_sprite;  // half-size of the screen sprite, view space
varying float v_flags;   // 1 = orthographic, 2 = clip to bounds
varying float v_ysign;
varying mat3 v_shape;    // curvature tensor S (local): dNormal = S * dPosition
varying vec3 v_texpos;   // rest position, for the surface texture
varying vec3 v_lnormal;  // rest normal, for triplanar blending

// ---------------------------------------------------------------- helpers
uint pcg_hash(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float hash01(uint v) {
	return float(pcg_hash(v)) * (1.0 / 4294967295.0);
}

vec3 rand_dir(uint v) {
	float z = hash01(v) * 2.0 - 1.0;
	float a = hash01(v ^ 0x9E3779B9u) * TAU;
	float r = sqrt(max(1.0 - z * z, 0.0));
	return vec3(r * cos(a), z, r * sin(a));
}

vec3 srgb_to_linear(vec3 c) {
	vec3 lo = c / 12.92;
	vec3 hi = pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
	return mix(hi, lo, vec3(1.0) - step(vec3(0.04045), c));
}

void accum_bone(float bone, float w, vec3 p, vec3 n, inout vec3 sp, inout vec3 sn) {
	if (w <= 0.0) {
		return;
	}
	int b = int(bone + 0.5);
	vec4 r0 = texelFetch(bone_xform_tex, ivec2(0, b), 0);
	vec4 r1 = texelFetch(bone_xform_tex, ivec2(1, b), 0);
	vec4 r2 = texelFetch(bone_xform_tex, ivec2(2, b), 0);
	vec4 hp = vec4(p, 1.0);
	sp += vec3(dot(r0, hp), dot(r1, hp), dot(r2, hp)) * w;
	sn += vec3(dot(r0.xyz, n), dot(r1.xyz, n), dot(r2.xyz, n)) * w;
}

mat3 load_shape(sampler2D tex, ivec2 tc) {
	vec4 a = texelFetch(tex, ivec2(tc.x * 2, tc.y), 0);
	vec4 b = texelFetch(tex, ivec2(tc.x * 2 + 1, tc.y), 0);
	return mat3(vec3(a.x, b.x, b.y), vec3(b.x, a.y, b.z), vec3(b.y, b.z, a.z));
}

// Spreads the dots of one stored point evenly (golden-angle spiral) over a
// disk of the point's surface area, lying in the tangent plane.
vec3 sub_offset(vec3 n, int sub, float spin) {
	if (density <= 1) {
		return vec3(0.0);
	}
	vec3 t = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0)));
	vec3 b = cross(n, t);
	float r = sqrt((float(sub) + 0.5) / float(density)) * point_spacing * lod_scale * 0.6;
	float a = float(sub) * 2.39996323 + spin * TAU;
	return (t * cos(a) + b * sin(a)) * r;
}

// ---------------------------------------------------------------- your hook
// Runs for every dot, every frame, after all built-in effects.
//   p          position in the cloud's local space (writable)
//   n          normal (writable)
//   c          sRGB colour, alpha unused (writable)
//   size_scale multiply to grow/shrink the dot, <= 0.02 hides it
//   rest       the dot's undeformed rest position
//   seed       stable random number in [0, 1] for this dot
//   id         index of the stored point (PointCloudData) this dot belongs to
//   sub        which of that point's `density` dots this is
void custom_effect(inout vec3 p, inout vec3 n, inout vec4 c, inout float size_scale,
		vec3 rest, float seed, int id, int sub, float t) {
	// Example: uncomment for a twisting effect.
	// float a = rest.y * 0.8 * sin(t);
	// p.xz = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * p.xz;
}

void vertex() {
	// Which dot am I? Dots are drawn as instanced batches of CHUNK points.
	int gid = INSTANCE_ID * CHUNK + VERTEX_ID;
	bool padding = gid >= dot_count; // unused tail of the last batch
	if (padding) {
		gid = 0;
	}
	int k = gid / density;    // k-th drawn point
	int sub = gid % density;  // dot within that point
	int id = k < surface_drawn ? k : surface_count + (k - surface_drawn); // stored point
	bool on_surface = id < surface_count;
	uint uid = uint(gid);
	ivec2 tc = ivec2(id % tex_width, id / tex_width);
	float seed = hash01(uid);
	float spin = hash01(uint(id) * 7919u + 13u);

	vec3 n = texelFetch(nrm_tex, tc, 0).xyz;
	if (dot(n, n) < 0.01) {
		n = vec3(0.0, 1.0, 0.0);
	}
	vec3 rest = texelFetch(pos_tex, tc, 0).xyz + sub_offset(n, sub, spin);
	vec4 c = texelFetch(col_tex, tc, 0);
	mat3 shape = load_shape(curv_tex, tc);
	vec3 p = rest;
	float size_scale = 1.0;
	float glow = 0.0;
	bool still = morph == 0.0 && vibrate_amplitude == 0.0 && wobble_amplitude == 0.0
			&& explode == 0.0 && dissolve == 0.0;
	bool at_rest = still && !use_skin;

	// --- skeletal animation (linear blend skinning)
	if (use_skin) {
		vec4 bi = texelFetch(bone_idx_tex, tc, 0);
		vec4 bw = texelFetch(bone_wgt_tex, tc, 0);
		vec3 sp = vec3(0.0);
		vec3 sn = vec3(0.0);
		accum_bone(bi.x, bw.x, rest, n, sp, sn);
		accum_bone(bi.y, bw.y, rest, n, sp, sn);
		accum_bone(bi.z, bw.z, rest, n, sp, sn);
		accum_bone(bi.w, bw.w, rest, n, sp, sn);
		float wsum = bw.x + bw.y + bw.z + bw.w;
		if (wsum > 0.0) {
			p = sp / wsum;
			n = normalize(sn + vec3(1e-6));
		}
	}

	// --- morph into the target cloud, each point on its own schedule and arc
	if (morph > 0.0) {
		float t = clamp((morph - seed * morph_stagger) / (1.0 - morph_stagger), 0.0, 1.0);
		t = t * t * (3.0 - 2.0 * t);
		vec3 tn = texelFetch(target_nrm_tex, tc, 0).xyz;
		if (dot(tn, tn) < 0.01) {
			tn = vec3(0.0, 1.0, 0.0);
		}
		vec3 tp = texelFetch(target_pos_tex, tc, 0).xyz + sub_offset(tn, sub, spin);
		vec4 tcol = texelFetch(target_col_tex, tc, 0);
		p = mix(p, tp, t) + rand_dir(uid * 3u + 17u) * sin(t * PI) * morph_arc;
		c = mix(c, tcol, t);
		n = normalize(mix(n, tn, t) + vec3(1e-6));
		mat3 tshape = load_shape(target_curv_tex, tc);
		shape = mat3(mix(shape[0], tshape[0], t), mix(shape[1], tshape[1], t), mix(shape[2], tshape[2], t));
	}

	// --- vibrate: every point shivers around its own spot
	if (vibrate_amplitude != 0.0) {
		vec3 d = rand_dir(uid * 5u + 1u);
		p += d * sin(cloud_time * vibrate_frequency * (0.6 + 0.8 * seed) + seed * TAU) * vibrate_amplitude;
	}

	// --- wobble: smooth jelly waves travelling through the surface
	if (wobble_amplitude != 0.0) {
		float w = sin(dot(rest, vec3(1.3, 1.7, 1.1)) * wobble_frequency + cloud_time * wobble_speed)
				* cos(dot(rest, vec3(-1.1, 0.9, 1.5)) * wobble_frequency * 0.7 - cloud_time * wobble_speed * 0.8);
		p += n * w * wobble_amplitude;
	}

	// --- explode outward from a centre
	if (explode != 0.0) {
		vec3 d = normalize(p - explode_center + rand_dir(uid * 7u + 3u) * 0.35 + vec3(1e-5));
		p += d * explode * (0.4 + seed * 1.2);
	}

	// --- dissolve: points detach (randomly or as a sweeping front) and drift away
	if (dissolve > 0.0) {
		vec3 h3 = (rest - bounds_min) / max(bounds_size, vec3(1e-4)) - 0.5;
		vec3 dir = normalize(dissolve_direction + vec3(1e-6));
		float h01 = dot(h3, dir) / max(dot(abs(dir), vec3(1.0)), 1e-4) + 0.5;
		float threshold = mix(seed, h01 * 0.85 + seed * 0.15, dissolve_directional);
		float a = clamp((dissolve * (1.0 + dissolve_span) - threshold) / dissolve_span, 0.0, 1.0);
		if (a > 0.0) {
			p += (rand_dir(uid * 11u + 5u) + dissolve_drift) * dissolve_spread * a * a;
			size_scale *= 1.0 - smoothstep(0.55, 1.0, a);
			glow += 1.0 - smoothstep(0.0, 0.35, a);
		}
	}

	// --- debris: points knocked off by carve(), flying on their own velocity
	vec4 st = has_debris ? texelFetch(state_tex, tc, 0) : vec4(-1.0);
	if (st.x >= 0.0 && cloud_time >= st.x) {
		at_rest = false;
		still = false;
	}
	if (st.x >= 0.0) {
		float dt = max(cloud_time - st.x, 0.0);
		if (cloud_time >= st.x) {
			float life = clamp(dt / debris_lifetime, 0.0, 1.0);
			// Dots of one point share its velocity but scatter a little.
			vec3 vel = st.yzw + rand_dir(uid * 13u + 9u) * length(st.yzw) * 0.35 * float(min(density - 1, 1));
			vec3 off = vel * dt + 0.5 * debris_gravity * dt * dt;
			p += off * (1.0 - heal);
			size_scale *= mix(1.0 - life * life, 1.0, heal);
			glow += (1.0 - smoothstep(0.0, 0.25, life)) * (1.0 - heal);
		}
	}

	// --- ripples from impact()
	if (cloud_time < impacts_until) {
		for (int i = 0; i < 8; i++) {
			vec4 ip = impact_pos[i];
			vec4 pr = impact_params[i];
			if (ip.w < 0.0 || pr.x == 0.0) {
				continue;
			}
			float dt = cloud_time - ip.w;
			if (dt < 0.0 || dt > 4.0) {
				continue;
			}
			vec3 dv = p - ip.xyz;
			float d = length(dv);
			float x = (d - dt * pr.y) / max(pr.z, 1e-4);
			float env = exp(-x * x) * exp(-dt * pr.w) * pr.x;
			p += (dv / max(d, 1e-4)) * env;
			glow += env * 2.0;
		}
	}

	c.rgb = mix(c.rgb, tint.rgb, tint_amount);

	custom_effect(p, n, c, size_scale, rest, seed, id, sub, cloud_time);
	if (padding) {
		p = vec3(1e9); // far outside every frustum
		size_scale = 0.0;
	}

	VERTEX = p;
	NORMAL = n;

	// --- point size: constant world-space size, converted to pixels
	vec4 vp = MODELVIEW_MATRIX * vec4(p, 1.0);
	if (backface_cull && still && on_surface) {
		vec3 view_dir = PROJECTION_MATRIX[3][3] > 0.5 ? vec3(0.0, 0.0, -1.0) : normalize(vp.xyz);
		if (dot(normalize(mat3(MODELVIEW_MATRIX) * n), view_dir) > 0.25) {
			size_scale = 0.0;
			VERTEX = vec3(1e9); // facing away: push it out of every frustum
			vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		}
	}
	float obj_scale = length(MODELVIEW_MATRIX[0].xyz);
	float world_size = point_size * lod_scale * obj_scale * size_scale * (splats ? splat_scale : 1.0);
	// A tilted disc can poke slightly past a sprite of its own diameter, so
	// splat sprites are drawn a bit bigger than the disc.
	float sprite_size = world_size * (splats ? 1.2 : 1.0);
	// abs(): the Compatibility renderer flips Y (negative [1][1]) when
	// rendering to a texture.
	float px = sprite_size * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y;
	bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
	if (!ortho) {
		px /= max(-vp.z, 1e-3); // perspective
	}
	v_alive = size_scale > 0.02 ? 1.0 : 0.0;
	POINT_SIZE = v_alive > 0.5 ? clamp(px, min_pixel_size, max_pixel_size) : 1.0;
	v_px = POINT_SIZE;
	// Sizes in view space, corrected for the pixel clamp.
	float clamp_ratio = POINT_SIZE / max(px, 1e-4);
	v_sprite = 0.5 * sprite_size * clamp_ratio;
	v_radius = 0.5 * world_size * clamp_ratio;
	v_center = vp.xyz;
	v_vnormal = normalize(mat3(MODELVIEW_MATRIX) * n);
	v_local = p;
	v_flags = (ortho ? 1.0 : 0.0) + (clip_to_bounds && at_rest ? 2.0 : 0.0);
	v_ysign = PROJECTION_MATRIX[1][1] < 0.0 ? -1.0 : 1.0;
	v_shape = shape;
	v_texpos = rest;
	v_lnormal = texelFetch(nrm_tex, tc, 0).xyz;
	v_color = c;
	v_glow = glow;
}

void fragment() {
	if (v_alive < 0.5) {
		discard;
	}
	vec2 pc = POINT_COORD * 2.0 - 1.0;
	// Point on the sprite's plane (view space) that this pixel looks at.
	vec3 q = v_center + vec3(pc.x * v_sprite, -pc.y * v_sprite * v_ysign, 0.0);
	vec3 hit = q;
	vec3 texpos = v_texpos;
	bool ortho = mod(v_flags, 2.0) > 0.5;
	mat3 mv = mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX); // rotation * uniform scale
	float mv_scale = length(mv[0]);
	float grazing = 1.0;
	if (splats) {
		// Intersect this pixel's view ray with the dot's tangent-plane disc.
		vec3 ro = ortho ? vec3(q.xy, 0.0) : vec3(0.0);
		vec3 rd = ortho ? vec3(0.0, 0.0, -1.0) : normalize(q);
		float denom = dot(rd, v_vnormal);
		grazing = abs(denom);
		if (grazing < 0.02) {
			discard; // seen exactly edge-on: neighbouring discs cover this
		}
		hit = ro + rd * (dot(v_center - ro, v_vnormal) / denom);
		vec3 off = hit - v_center;
		if (dot(off, off) > v_radius * v_radius) {
			discard;
		}
		// This pixel's offset from the dot centre, in local space.
		vec3 local_off = (transpose(mv) * off) / (mv_scale * mv_scale);
		texpos += local_off;
		// Bend the normal across the disc with the surface's curvature tensor,
		// reproducing the source mesh's smoothly interpolated normals, so the
		// shading of neighbouring discs meets seamlessly.
		NORMAL = normalize(v_vnormal + mv * (v_shape * local_off) / mv_scale);
		if (v_flags > 1.5) {
			vec3 lo = v_local + local_off;
			vec3 eps = bounds_size * 0.0005 + vec3(1e-5);
			if (any(lessThan(lo, bounds_min - eps)) || any(greaterThan(lo, bounds_min + bounds_size + eps))) {
				discard;
			}
		}
	} else if (round_points && v_px > 3.5) {
		// Rounding only helps once a point covers several pixels; below that
		// it just punches holes in the surface.
		if (dot(pc, pc) > 1.0) {
			discard;
		}
	}
	// EXACT_DEPTH variant: write the disc's true depth at this pixel so discs
	// intersect like real geometry. It disables the GPU's early depth test
	// (every overlapping disc gets fully shaded), so the default variant
	// keeps each sprite's flat depth and lets the depth prepass reject
	// hidden pixels before shading.
#ifdef EXACT_DEPTH
	vec4 clip = PROJECTION_MATRIX * vec4(hit, 1.0);
	float ndc_z = clip.z / clip.w;
#endif
#ifdef EXACT_DEPTH
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	DEPTH = ndc_z * 0.5 + 0.5;
#else
	DEPTH = ndc_z;
#endif
#endif
	LIGHT_VERTEX = hit; // per-pixel lighting and shadows across the disc
	vec3 col = srgb_to_linear(v_color.rgb);
	if (use_surface_texture && v_color.a > 0.0) {
		vec3 bw = pow(abs(normalize(v_lnormal + vec3(1e-6))), vec3(8.0));
		bw /= dot(bw, vec3(1.0));
		vec3 uvw = (texpos - texture_offset) / texture_tile;
		// Mip level from this pixel's exact footprint on the disc. GPU
		// derivatives are unreliable inside tiny point sprites.
		float wpp = 2.0 * v_sprite / max(v_px, 1.0) / mv_scale;
		if (!ortho) {
			wpp *= hit.z / v_center.z;
		}
		float footprint = wpp / sqrt(max(grazing, 0.05));
		float tile = min(texture_tile.x, min(texture_tile.y, texture_tile.z));
		float lod = log2(max(footprint / tile * float(textureSize(surface_texture, 0).x), 1e-6));
		vec3 tex;
		if (bw.y > 0.995) {
			tex = textureLod(surface_texture, uvw.xz, lod).rgb; // flat floors: one sample
		} else {
			tex = textureLod(surface_texture, uvw.zy, lod).rgb * bw.x
					+ textureLod(surface_texture, uvw.xz, lod).rgb * bw.y
					+ textureLod(surface_texture, uvw.xy, lod).rgb * bw.z;
		}
		col *= mix(vec3(1.0), tex, v_color.a);
	}
	if (unshaded) {
		ALBEDO = vec3(0.0);
		EMISSION = col;
	} else {
		ALBEDO = col;
		EMISSION = col * emission_strength;
	}
	EMISSION += dissolve_edge_color.rgb * v_glow * glow_strength;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
