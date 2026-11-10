// Shared body of point_cloud.gdshader (fast) and point_cloud_exact.gdshader.
// Include this from your own shader to customise it (see custom_effect()).

// ---------------------------------------------------------------- point data
uniform sampler2D pos_tex : filter_nearest, repeat_disable;   // xyz = rest position (RGB32F)
uniform sampler2D col_tex : filter_nearest, repeat_disable;   // rgba = sRGB colour (RGBA32F)
uniform sampler2D nrm_tex : filter_nearest, repeat_disable;   // xyz = normal (RGB32F)
uniform sampler2D curv_tex : filter_nearest, repeat_disable;  // curvature tensor, 2 texels per point
uniform sampler2D state_tex : filter_nearest, repeat_disable; // x = detach time (<0 attached), yzw = velocity
uniform int tex_width = 2048;
uniform int density = 1;            // dot slots per stored point this frame (amplification cap)
// Adaptive bead count: up close each stored point spawns extra beads around
// itself so beads stay about target_px apart on screen, wherever the camera
// is. Every bead decides for itself from its own distance; beads that aren't
// needed (or are off-screen / facing away) are skipped before any real work.
uniform bool amplify = true;
uniform float target_px = 2.0;
uniform int dot_count = 0;          // dots drawn this frame
// Points are stored [surface | interior]. Level of detail draws the first
// surface_drawn surface points, then (after them) a prefix of the interior.
uniform int surface_count = 2147483647;
uniform int surface_drawn = 2147483647;
// Skip surface dots that face away from the view (or light). They're hidden
// behind the front of a closed model anyway.
uniform bool backface_cull = true;
// Set while a flat proxy plane draws the intact surface: only dots that are
// part of a hole wall or flying debris are drawn.
uniform bool proxy_mode = false;
uniform float point_spacing = 0.01; // average distance between stored surface points
const int CHUNK = 32768;            // must match PointCloud.CHUNK
uniform float cloud_time = 0.0;
uniform vec3 bounds_min = vec3(-1.0);
uniform vec3 bounds_size = vec3(2.0);

// ---------------------------------------------------------------- appearance
uniform float point_size = 0.02;          // world-space diameter of one point
uniform float target_point_size = 0.02;   // the morph target's, blended per dot
uniform float target_interior_scale = 1.0;
uniform float lod_scale = 1.0;            // > 1 when level of detail draws fewer points
uniform float interior_scale = 1.0;       // interior dot size relative to surface dots
uniform float min_pixel_size = 1.0;
uniform float max_pixel_size = 256.0;
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
// How far morphing atoms stray from the straight path while they swarm.
uniform float morph_swarm = 0.7;
// Explosions: twist around the vertical axis and turbulent streams.
uniform float explode_swirl = 0.9;
uniform float explode_turbulence = 0.55;
// Loose atoms never draw wider than this, even when quality is turned down.
uniform float atom_max_px = 3.2;
// Share of an atom's colour that glows by itself in flight, so a cloud of
// atoms keeps its colour instead of flickering light and dark.
uniform float atom_glow = 0.55;

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
// Singularity: gather = 1 packs every atom into a small swarming ball at
// gather_center; animating it to 0 is the big bang: the ball bursts, then
// the atoms swarm to their places.
uniform float gather = 0.0;
uniform vec3 gather_center = vec3(0.0);   // local space
uniform float gather_radius = 0.4;
uniform float gather_reach = 30.0;        // distance at which the build finishes
uniform float gather_heat = 0.0;          // white-hot glow of gathered atoms
uniform float gather_agitate = 0.0;       // 0..1: the ball shakes
uniform float gather_burst = 11.0;        // how far the explosion throws atoms
uniform float gather_last = 0.0;          // 1 = this cloud is built last
// Element behaviour of loose atoms (see PointElement).
uniform bool debris_lands = false;     // collide with the ground plane
uniform float debris_floor_y = 0.0;    // ground height, local space
uniform float debris_bounce = 0.3;
uniform float debris_friction = 0.4;
uniform float debris_drag = 0.0;
uniform float debris_glow = 1.0;
uniform float heal : hint_range(0.0, 1.0) = 0.0;
uniform bool has_debris = false;  // skip the state lookup until something was carved

// Carves not yet folded into state_tex (see PointCloud.carve()). Same maths
// as PointCloud._apply_carve(), so baking a carve changes nothing on screen.
const float WALL_REACH = 1.7;
uniform int carve_count = 0;
uniform vec4 carve_a[48];  // xyz centre (rest space), w start time
uniform vec4 carve_b[48];  // x radius, y force, z raggedness, w seed
uniform vec4 carve_c[48];  // xyz kick: extra direction for the debris (local)
// How dark the inside of a hole gets (fake ambient occlusion).
uniform float cavity_strength : hint_range(0.0, 1.0) = 0.5;
// Directional shadow maps: dots are drawn as plain squares this much larger
// than surface dots (closes gaps whatever the shadow map's resolution), and
// pushed away from the light by about their radius so surfaces can't shadow
// themselves (no acne).
uniform float shadow_disc_scale = 2.6;
uniform float shadow_push = 0.75;

// Dots in flight (debris, dissolve, explode, mid-morph) are drawn as small
// round beads with their own sphere-like shading instead of flat surface
// discs. Size relative to a surface dot.
uniform float bead_size = 0.4;
// Draw every dot as a bead (default). Resting beads are sized to overlap and
// close the surface; in flight they shrink to bead_size. Size and shading
// follow the same continuous "in flight" amount, so morphs, debris and
// dissolves flow from surface to beads and back without anything popping.
// Off = flat surface discs (splats) while resting.
uniform bool beads = true;
// Resting bead diameter relative to point_size (must close the surface).
// Extra beads up close sit in overlapping random-ish clusters and need more
// overlap than the evenly spread stored points, hence two values.
uniform float bead_cover = 2.1;
uniform float bead_cover_single = 1.6;
uniform float bead_overlap = 1.0; // per-cloud multiplier on both
// How much each resting bead's own roundness shows in its shading (0 = flat:
// a resting surface looks like one smooth surface). Beads in flight are
// always full spheres; the look blends with how far a bead is in flight.
uniform float bead_bulge : hint_range(0.0, 1.0) = 0.0;
// Darkening towards the rim of beads in flight; defines individual beads.
uniform float bead_edge_shade : hint_range(0.0, 1.0) = 0.3;

// Ripple impacts: xyz = local position, w = start time (< 0 inactive).
uniform vec4 impact_pos[8];
// x = strength, y = speed, z = ring width, w = decay
uniform vec4 impact_params[8];
uniform float impacts_until = -1.0;  // skip the ripple loop after this time

varying vec4 v_color;
// Single-number varyings packed into vec4s: Forward+ allows only 32 varying
// slots and each float would take a whole one. Positions are passed in high
// precision: the Compatibility renderer otherwise uses half floats, and at
// grazing angles their error turns into visible texture smudges.
varying highp vec4 v_misc_a;
varying highp vec4 v_misc_b;
varying highp vec4 v_misc_c;
#define v_glow v_misc_a.x
#define v_alive v_misc_a.y
#define v_px v_misc_a.z
#define v_radius v_misc_a.w   // disc / bead radius, view space
#define v_sprite v_misc_b.x   // half-size of the screen sprite, view space
#define v_flags v_misc_b.y    // 1 = orthographic, 2 = clip to bounds
#define v_ysign v_misc_b.z
#define v_bead v_misc_b.w     // 1 = draw as a round bead
#define v_fly v_misc_c.x      // 0 = resting on the surface .. 1 = in flight
#define v_shadow v_misc_c.y   // 1 = drawing into a directional shadow map
varying highp vec3 v_center;   // dot centre, view space
varying highp vec3 v_vnormal;  // dot normal, view space
varying highp vec3 v_local;    // dot centre, local space (for bounds clipping)
varying mat3 v_shape;    // curvature tensor S (local): dNormal = S * dPosition
varying highp vec3 v_texpos;   // rest position, for the surface texture
varying highp vec3 v_lnormal;  // rest normal, for triplanar blending

// ---------------------------------------------------------------- helpers
// Smooth, divergence-free flow field (an ABC flow): atoms that are close
// together are carried the same way, so they move in streams and swarms
// instead of each on its own straight line.
vec3 flow(vec3 q, float t) {
	return vec3(sin(q.y * 1.7 + t) + cos(q.z * 1.3 - t * 0.7),
			sin(q.z * 1.5 + t * 0.8) + cos(q.x * 1.9 + t * 0.6),
			sin(q.x * 1.6 - t * 0.9) + cos(q.y * 1.4 + t * 0.5)) * 0.5;
}

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
float radical_inverse(int i, int base) {
	float inv = 1.0 / float(base);
	float f = inv;
	float r = 0.0;
	for (int k = 0; k < 8 && i > 0; k++) {
		r += f * float(i % base);
		i /= base;
		f *= inv;
	}
	return r;
}

// Where the extra beads of one stored point sit, over the point's patch of
// surface (a disk in its tangent plane): a Halton(2,3) sequence, randomly
// shifted per point so neighbouring clusters don't share a pattern. Bead
// `sub` always sits at the same spot and the first k beads are evenly spread
// for any k, so moving closer only adds beads, never moves them.
vec3 sub_offset(vec3 n, int sub, float spin, uint pid) {
	if (sub == 0) {
		return vec3(0.0);
	}
	vec3 t = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0)));
	vec3 b = cross(n, t);
	float u = fract(radical_inverse(sub, 2) + hash01(pid * 92821u + 7u));
	float v = fract(radical_inverse(sub, 3) + spin);
	float r = sqrt(u) * point_spacing * lod_scale * 1.25;
	float a = v * TAU;
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

// Where a loose atom is `t` seconds after leaving `start` with velocity
// `vel` (as an offset from start): free fall, a few bounces off the ground,
// then a short slide to rest. Closed form, so no state is kept per atom.
vec3 debris_path(vec3 start, vec3 vel, float t, uint key) {
	float g = max(-debris_gravity.y, 1e-3);
	// Air resistance: the launch speed dies away.
	vec3 v = vel;
	float tl = t; // time available to the launch velocity
	if (debris_drag > 0.0) {
		tl = (1.0 - exp(-debris_drag * t)) / debris_drag;
	}
	if (!debris_lands) {
		return v * tl + 0.5 * debris_gravity * t * t;
	}
	// Resting height: on the ground, each atom at a slightly different level
	// so a heap of them doesn't collapse into one flat sheet.
	float rest_y = debris_floor_y + point_spacing * (0.6 + 2.5 * hash01(key * 31u + 5u));
	float h = max(start.y - rest_y, 0.0);
	float e = debris_bounce * (0.6 + 0.8 * hash01(key * 17u + 3u));
	if (debris_drag > 0.0) {
		// Light atoms: no bouncing, they sink and settle.
		float fall = min(h, 0.5 * g * t * t / (1.0 + debris_drag * t));
		return vec3(v.x * tl, -fall + max(v.y, 0.0) * tl * exp(-t * 1.5), v.z * tl);
	}
	float vy = v.y;
	vec2 hv = v.xz;
	vec2 hp = vec2(0.0);
	for (int i = 0; i < 6; i++) {
		float vimp = sqrt(vy * vy + 2.0 * g * h);
		float th = (vy + vimp) / g; // time until it reaches the ground
		if (t < th) {
			return vec3(hp.x + hv.x * t, h + vy * t - 0.5 * g * t * t + rest_y - start.y, hp.y + hv.y * t);
		}
		hp += hv * th;
		t -= th;
		vy = vimp * e;
		h = 0.0;
		hv *= 1.0 - debris_friction;
		if (vy < 0.25) {
			break;
		}
	}
	// Sliding to a stop.
	hp += hv * 0.2 * (1.0 - exp(-t / 0.2));
	return vec3(hp.x, rest_y - start.y, hp.y);
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
	vec3 base = texelFetch(pos_tex, tc, 0).xyz;
	bool still = morph == 0.0 && vibrate_amplitude == 0.0 && wobble_amplitude == 0.0
			&& explode == 0.0 && dissolve == 0.0 && gather == 0.0;

	// --- early out: how many beads does this point need here?
	vec4 vp0 = MODELVIEW_MATRIX * vec4(base, 1.0);
	float proj_px = abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y;
	bool persp = PROJECTION_MATRIX[3][3] < 0.5;
	float spacing_px = point_spacing * lod_scale * length(MODELVIEW_MATRIX[0].xyz) * proj_px
			/ (persp ? max(-vp0.z, 1e-3) : 1.0);
	float d_need = amplify ? clamp(spacing_px * spacing_px / (target_px * target_px), 1.0, float(density)) : 1.0;
	bool cull = padding || float(sub) >= ceil(d_need);
	// Debris moves away from its rest position, so never pre-cull it.
	bool may_move = has_debris && texelFetch(state_tex, tc, 0).x >= 0.0;
	if (!cull && still && !use_skin && !may_move && carve_count == 0) {
		// Off-screen (with a margin for the bead's size)?
		vec4 cp = PROJECTION_MATRIX * vp0;
		float m = cp.w * 1.35 + 0.5;
		cull = persp && (abs(cp.x) > m || abs(cp.y) > m || cp.w < 0.0);
		// Facing away from the view?
		if (!cull && backface_cull && on_surface) {
			vec3 vd = persp ? normalize(vp0.xyz) : vec3(0.0, 0.0, -1.0);
			cull = dot(normalize(mat3(MODELVIEW_MATRIX) * n), vd) > 0.25;
		}
	}
	// A bead that has just become needed grows in instead of popping.
	float sub_fade = clamp(d_need - float(sub), 0.0, 1.0);

	vec3 rest = base + sub_offset(n, sub, spin, uint(id));
	vec4 c = texelFetch(col_tex, tc, 0);
	mat3 shape = beads ? mat3(0.0) : load_shape(curv_tex, tc); // beads don't need curvature
	vec3 p = rest;
	float size_scale = 1.0;
	float glow = 0.0;
	float fly = 0.0; // how much this dot is "in flight" (0 = on the surface)
	float disp = 0.0; // how far effects have carried it from its place
	bool at_rest = still && !use_skin;
	vec4 st = vec4(-1.0);
	float morph_t = 0.0; // this dot's progress towards the morph target

	if (!cull) { // ======== everything below only for beads that are drawn

	// --- carve state: baked (state_tex) plus carves still pending on the GPU
	st = has_debris ? texelFetch(state_tex, tc, 0) : vec4(-1.0);
	if (st.x < 0.0) {
		for (int i = 0; i < carve_count; i++) {
			vec4 ca = carve_a[i];
			vec4 cb = carve_b[i];
			vec3 dv = base - ca.xyz;
			float d = length(dv);
			if (d > cb.x * WALL_REACH) {
				continue;
			}
			uint key = uint(id) * 1664525u + uint(cb.w);
			float r_eff = cb.x * (1.0 - cb.z * hash01(key));
			if (d <= r_eff) {
				vec3 dir = d > 1e-6 ? dv / d : vec3(0.0, 1.0, 0.0);
				vec3 vel = (dir + rand_dir(key ^ 0x68E31DA4u) * 0.6 + carve_c[i].xyz) * cb.y * (0.4 + hash01(key + 7u));
				st = vec4(ca.w + d / cb.x * 0.08, vel);
				break;
			}
			float cav = 1.0 - smoothstep(r_eff, cb.x * WALL_REACH, d);
			if (cav > 0.0 && -1.0 - st.x < cav) {
				st = vec4(-1.0 - min(cav, 0.999), ca.xyz - base);
			}
		}
	}
	// Hole walls: dots around a hole face into it and darken with depth, so
	// holes read as cavities instead of a jumble of surface normals.
	if (st.x < -1.0) {
		float cav = (-1.0 - st.x) * (1.0 - heal);
		vec3 wall_n = normalize(st.yzw + vec3(1e-6));
		n = normalize(mix(n, wall_n, cav * (on_surface ? 0.35 : 1.0)) + vec3(1e-6));
		c.rgb *= 1.0 - cavity_strength * cav * (on_surface ? 0.4 : 1.0);
	}

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

	// --- morph into the target cloud. Three acts: the whole object comes apart
	// into a drifting cloud of atoms, hangs there, then the atoms swarm into
	// the new shape, clump by clump.
	if (morph > 0.0) {
		// Neighbouring atoms share a schedule, so they leave and land in clumps.
		float grp = 0.5 + 0.5 * flow(rest * 1.1, 0.0).x;
		float sched = mix(seed, grp, 0.65);
		float spread = min(morph_stagger, 0.5);
		float t_leave = sched * 0.24 * spread / 0.5;            // starts to shrink
		float t_gather = 0.46 + sched * 0.28 * spread / 0.5;    // starts to fly in
		float t_land = t_gather + 0.2;                          // at its new place
		// An atom shrinks where it sits before it moves, and grows only once it
		// has landed: nothing big is ever out of place.
		float s1 = clamp((morph - t_leave) / 0.33, 0.0, 1.0);
		s1 = 1.0 - (1.0 - s1) * (1.0 - s1) * (1.0 - s1);       // bursts out, then slows
		float t = clamp((morph - t_gather) / 0.2, 0.0, 1.0);
		t = t * t * (3.0 - 2.0 * t);
		morph_t = t;
		vec3 tn = texelFetch(target_nrm_tex, tc, 0).xyz;
		if (dot(tn, tn) < 0.01) {
			tn = vec3(0.0, 1.0, 0.0);
		}
		vec3 tp = texelFetch(target_pos_tex, tc, 0).xyz + sub_offset(tn, sub, spin, uint(id));
		vec4 tcol = texelFetch(target_col_tex, tc, 0);
		vec3 from = p;
		// Where this atom hangs in the cloud: pushed out from the middle, then
		// carried around by a slowly changing flow (streams plus eddies).
		vec3 mid = bounds_min + bounds_size * 0.5;
		float reach = length(bounds_size) * 0.3;
		vec3 out_dir = normalize(from - mid + rand_dir(uid * 3u + 17u) * 0.6 + vec3(1e-5));
		vec3 cloud = from + out_dir * reach * (0.35 + seed * 0.9);
		cloud += (flow(cloud * 0.8 + grp * 3.0, cloud_time * 1.1 + grp * 6.0)
				+ 0.45 * flow(cloud * 2.3 + seed, cloud_time * 1.9)) * (morph_swarm + morph_arc * 0.4);
		p = mix(from, cloud, s1);
		// Swarm in: curve towards the target along the flow, not straight.
		vec3 sw = flow(tp * 0.9 + grp * 4.0, cloud_time * 1.5) * morph_swarm * 0.6 * sin(t * PI);
		p = mix(p, tp, t) + sw;
		disp = max(disp, min(distance(p, from), distance(p, tp)));
		c = mix(c, tcol, t);
		n = normalize(mix(n, tn, t) + vec3(1e-6));
		if (!beads) {
			mat3 tshape = load_shape(target_curv_tex, tc);
			shape = mat3(mix(shape[0], tshape[0], t), mix(shape[1], tshape[1], t), mix(shape[2], tshape[2], t));
		}
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
		// An atom first shrinks where it sits, then moves; coming back it lands
		// first and grows after. Each has its own threshold, so the surface
		// breaks up and closes grain by grain and nothing big is out of place.
		float amount = abs(explode);
		vec3 d = normalize(p - explode_center + rand_dir(uid * 7u + 3u) * 0.35 + vec3(1e-5));
		float moved = amount * (0.4 + seed * 1.2);
		vec3 q = p + d * moved * sign(explode);
		// Twist around the vertical axis, more the further out an atom is...
		float ang = sign(explode) * amount * explode_swirl * (0.5 + seed);
		vec3 r = q - explode_center;
		q = explode_center + vec3(r.x * cos(ang) - r.z * sin(ang), r.y, r.x * sin(ang) + r.z * cos(ang));
		// ...and get carried by turbulent streams that keep drifting.
		float tb = explode_turbulence * min(moved, 1.5);
		q += (flow(q * 1.3, cloud_time * 0.9) + 0.4 * flow(q * 3.4 + seed, cloud_time * 1.7)) * tb;
		p = q;
		disp = max(disp, moved);
	}


	// --- dissolve: points detach (randomly or as a sweeping front) and drift away
	if (dissolve > 0.0) {
		vec3 h3 = (rest - bounds_min) / max(bounds_size, vec3(1e-4)) - 0.5;
		vec3 dir = normalize(dissolve_direction + vec3(1e-6));
		float h01 = dot(h3, dir) / max(dot(abs(dir), vec3(1.0)), 1e-4) + 0.5;
		float threshold = mix(seed, h01 * 0.85 + seed * 0.15, dissolve_directional);
		float a = clamp((dissolve * (1.0 + dissolve_span) - threshold) / dissolve_span, 0.0, 1.0);
		if (a > 0.0) {
			// Shrinks in place first (a < 0.12), then drifts off.
			float a2 = a;
			vec3 dv = (rand_dir(uid * 11u + 5u) + dissolve_drift) * dissolve_spread * a2 * a2;
			p += dv + flow((p + dv) * 1.5, cloud_time * 0.8) * dissolve_spread * 0.35 * a2 * a2;
			size_scale *= 1.0 - smoothstep(0.55, 1.0, a);
			glow += 1.0 - smoothstep(0.0, 0.35, a);
			disp = max(disp, length(dv));
		}
	}

	// --- debris: points knocked off by carve(), flying on their own velocity
	if (st.x >= 0.0 && cloud_time >= st.x) {
		at_rest = false;
		still = false;
	}
	if (st.x >= 0.0) {
		float dt = max(cloud_time - st.x, 0.0);
		if (cloud_time >= st.x) {
			float life = debris_lifetime > 0.0 ? clamp(dt / debris_lifetime, 0.0, 1.0) : 0.0;
			// Dots of one point share its velocity but scatter a little.
			vec3 vel = st.yzw + rand_dir(uid * 13u + 9u) * length(st.yzw) * 0.35 * (sub > 0 ? 1.0 : 0.0);
			vec3 off = debris_path(p, vel, dt, uid);
			p += off * (1.0 - heal);
			size_scale *= mix(1.0 - life * life, 1.0, heal);
			glow += (1.0 - smoothstep(0.0, 0.25, debris_lifetime > 0.0 ? life : dt)) * (1.0 - heal) * debris_glow;
			fly = max(fly, 1.0 - heal);
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
	} // ======== end of drawn-bead work
	// --- singularity / big bang (overrides where everything above put the atom)
	if (gather > 0.0 && !cull) {
		vec3 place = p;
		uint gk = uid * 41u + 11u;
		// In the ball every atom circles the centre on its own tilted orbit;
		// agitation makes it shake.
		vec3 ax = rand_dir(gk);
		vec3 perp = normalize(cross(ax, rand_dir(gk + 5u)) + vec3(1e-5));
		float ang = cloud_time * (1.2 + 3.5 * hash01(gk + 9u)) + seed * TAU;
		vec3 orb = perp * cos(ang) + cross(ax, perp) * sin(ang);
		vec3 sing = orb * gather_radius * pow(hash01(gk + 3u), 0.6)
				+ flow(orb * 3.0 + seed, cloud_time * 2.0) * gather_radius * 0.2
				+ rand_dir(gk + uint(cloud_time * 24.0) * 7919u) * gather_radius * 0.7 * gather_agitate;
		float x = 1.0 - gather;

		// Act 1, the explosion: everything is blown out of the ball at once.
		// Most atoms fly in a few dozen jets (dense streaks, each its own
		// length, curling as they slow), the rest as a fast loose spray.
		float s1 = clamp(x / 0.1, 0.0, 1.0);
		s1 = 1.0 - pow(1.0 - s1, 3.0);
		uint jet = pcg_hash(gk + 77u) % 44u;
		bool spray = hash01(gk + 21u) < 0.22;
		vec3 dirv = spray ? rand_dir(gk + 31u) : rand_dir(jet * 9781u + 5u);
		float len = spray ? 0.25 + 0.75 * hash01(gk + 13u)
				: (0.12 + 0.88 * pow(hash01(gk + 13u), 0.7)) * (0.55 + 0.45 * hash01(jet * 13u + 1u));
		len *= gather_burst;
		vec3 blown = dirv * len;
		blown += rand_dir(gk + 41u) * len * (spray ? 0.0 : 0.04);
		blown += flow(blown * 0.22 + float(jet), cloud_time * 0.5) * len * 0.14 * s1;
		vec3 from = gather_center + mix(sing, blown, s1);

		// Act 2, the world is built: atoms travel to their places the way a
		// digital world assembles: along the axes (x, then z, then y), snapped
		// to a coarse grid of "pixels" until they slot in. The build sweeps
		// outwards over the ground and climbs each object from the bottom.
		vec3 wplace = (MODEL_MATRIX * vec4(place, 1.0)).xyz;
		vec3 wcentre = (MODEL_MATRIX * vec4(gather_center, 1.0)).xyz;
		float order = 0.7 * clamp(length(wplace.xz - wcentre.xz) / gather_reach, 0.0, 1.0)
				+ 0.3 * clamp(wplace.y / 5.0, 0.0, 1.0);
		order = mix(order, 1.0, gather_last);
		// Each atom's trip is short, so at any moment most atoms are either
		// still in the blast's jets or already in place, not in between.
		float start = 0.2 + 0.68 * order + 0.02 * seed;
		float t = clamp((x - start) / 0.1, 0.0, 1.0);
		float tx = smoothstep(0.0, 1.0, clamp(t * 3.0, 0.0, 1.0));
		float tz = smoothstep(0.0, 1.0, clamp(t * 3.0 - 1.0, 0.0, 1.0));
		float ty = smoothstep(0.0, 1.0, clamp(t * 3.0 - 2.0, 0.0, 1.0));
		vec3 q = vec3(mix(from.x, place.x, tx), mix(from.y, place.y, ty), mix(from.z, place.z, tz));
		float cell = 0.22;
		float snap = smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.75, 1.0, t));
		q = mix(q, (floor(q / cell) + 0.5) * cell, snap);
		p = q;
		disp = max(disp, distance(p, place));
		// Hot in the ball and the first instant of the blast, then its own
		// colour; a cool flash as it slots into place.
		float heat = gather_heat * (1.0 - smoothstep(0.03, 0.22, x));
		c.rgb = mix(c.rgb, vec3(1.0, 0.9, 0.7), clamp(heat * 0.5, 0.0, 0.9));
		float slot = sin(clamp((t - 0.7) / 0.3, 0.0, 1.0) * PI);
		c.rgb = mix(c.rgb, vec3(0.55, 0.95, 1.0), slot * 0.7);
		glow += heat * 0.4;
	}

	if (cull) {
		p = vec3(1e9); // far outside every frustum: nothing is rasterised
		size_scale = 0.0;
	}

	if (proxy_mode && st.x < 0.0 && st.x >= -1.0) {
		size_scale = 0.0; // intact: the proxy plane draws this part
		p = vec3(1e9);
	}

	VERTEX = p;
	NORMAL = n;

	// --- point size: constant world-space size, converted to pixels
	vec4 vp = MODELVIEW_MATRIX * vec4(p, 1.0);
	// Skinned: the normal is known only now. Also: while an effect runs, atoms
	// it hasn't moved yet are culled exactly as at rest, so starting an effect
	// changes neither the picture nor the shadow.
	bool untouched = !still && disp == 0.0 && fly == 0.0 && morph_t == 0.0 && st.x < 0.0
			&& vibrate_amplitude == 0.0 && wobble_amplitude == 0.0;
	if (backface_cull && on_surface && !cull && (still ? use_skin : untouched)) {
		vec3 view_dir = PROJECTION_MATRIX[3][3] > 0.5 ? vec3(0.0, 0.0, -1.0) : normalize(vp.xyz);
		if (dot(normalize(mat3(MODELVIEW_MATRIX) * n), view_dir) > 0.25) {
			size_scale = 0.0;
			VERTEX = vec3(1e9); // facing away: push it out of every frustum
			vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		}
	}
	// Interior points only show as hole walls or as atoms in flight. Resting
	// inside the model they'd poke through the surface as blobs.
	// An atom is the same size wherever it is. Only its lighting changes, and
	// gradually with distance from its place: on the surface it is lit by the
	// surface's normal, far away as a free speck.
	float agap = point_spacing * lod_scale / sqrt(d_need);
	fly = max(fly, smoothstep(0.0, max(length(bounds_size) * 0.2, agap * 4.0), disp));
	if (!on_surface && st.x >= -1.0) {
		size_scale *= max(smoothstep(0.0, agap * 3.0, disp), st.x >= 0.0 ? 1.0 : 0.0);
	}
	float obj_scale = length(MODELVIEW_MATRIX[0].xyz);
	float ps = mix(point_size, target_point_size, morph_t);
	// More beads per point = smaller beads (same coverage).
	float amp_scale = sub_fade / sqrt(d_need);
	float cover = mix(bead_cover_single, bead_cover, clamp(d_need - 1.0, 0.0, 1.0)) * bead_overlap;
	float disc_size = ps * lod_scale * amp_scale * (beads ? cover : (splats ? splat_scale : 1.0))
			* (on_surface ? 1.0 : mix(interior_scale, target_interior_scale, morph_t));
	float world_size = disc_size * obj_scale * size_scale;
	bool shadow_pass = PROJECTION_MATRIX[3][3] > 0.5; // orthographic = directional shadow map
	if (shadow_pass) {
		// Loose atoms are specks: they cast no shadow (enlarged shadow dots
		// would turn a cloud of them into dark blotches on the ground).
		world_size *= shadow_disc_scale * (1.0 - max(smoothstep(0.0, point_spacing * lod_scale * 6.0, disp), fly));
		// Push away from the light (view -z) by about the dot's radius.
		VERTEX += transpose(mat3(MODELVIEW_MATRIX)) * vec3(0.0, 0.0, -world_size * shadow_push)
				/ max(obj_scale * obj_scale, 1e-8);
		vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	}
	bool bead = beads || fly > 0.5;
	// A tilted disc can poke slightly past a sprite of its own diameter, so
	// splat sprites are drawn a bit bigger than the disc.
	float sprite_size = world_size * (splats && !bead ? 1.2 : 1.0);
	// abs(): the Compatibility renderer flips Y (negative [1][1]) when
	// rendering to a texture.
	float px = sprite_size * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y;
	bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
	if (!ortho) {
		px /= max(-vp.z, 1e-3); // perspective
	}
	v_alive = size_scale > 0.02 ? 1.0 : 0.0;
	// On screen a resting atom is target_px * cover wide (that's what level of
	// detail aims for). Once loose it never draws bigger than that, however
	// close it flies to the camera or however sparse its part of the model.
	// (Interior points are always held to it: they never have to close a surface.)
	float loose = on_surface ? max(smoothstep(0.0, agap * 2.0, disp), fly) : 1.0;
	float px_cap = mix(max_pixel_size, clamp(target_px * cover, 1.5, atom_max_px), shadow_pass ? 0.0 : loose);
	POINT_SIZE = v_alive > 0.5 ? clamp(px, min_pixel_size, px_cap) : 1.0;
	v_px = POINT_SIZE;
	// Sizes in view space, corrected for the pixel clamp.
	float clamp_ratio = POINT_SIZE / max(px, 1e-4);
	v_sprite = 0.5 * sprite_size * clamp_ratio;
	v_radius = 0.5 * world_size * clamp_ratio;
	v_center = vp.xyz;
	v_vnormal = normalize(mat3(MODELVIEW_MATRIX) * n);
	v_local = p;
	// Trim at the bounding box while the bead sits untouched at its rest place
	// (also while an effect is running but hasn't reached this bead yet).
	bool in_place = disp == 0.0 && fly == 0.0 && morph_t == 0.0 && !use_skin && vibrate_amplitude == 0.0
			&& wobble_amplitude == 0.0 && st.x < 0.0;
	v_flags = (ortho ? 1.0 : 0.0) + (clip_to_bounds && in_place ? 2.0 : 0.0);
	v_bead = bead ? 1.0 : 0.0;
	v_fly = fly;
	v_shadow = shadow_pass ? 1.0 : 0.0;
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
	// Open, thin models are seen from both sides: light the side that faces us.
	vec3 vn = v_vnormal;
	if (!backface_cull && dot(vn, (mod(v_flags + 0.5, 2.0) >= 1.0) ? vec3(0.0, 0.0, -1.0) : v_center) > 0.0) {
		vn = -vn;
	}
	// Point on the sprite's plane (view space) that this pixel looks at.
	vec3 q = v_center + vec3(pc.x * v_sprite, -pc.y * v_sprite * v_ysign, 0.0);
	vec3 hit = q;
	vec3 texpos = v_texpos;
	// Round first: an interpolated 2.0 can arrive as 1.99999.
	int flags = int(v_flags + 0.5);
	bool ortho = (flags & 1) != 0;
	bool clip_bounds = (flags & 2) != 0;
	mat3 mv = mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX); // rotation * uniform scale
	float mv_scale = length(mv[0]);
	float grazing = 1.0;
	float bead_shade = 1.0;
	if (v_shadow > 0.5) {
		// Shadow map: plain square, flat depth (see shadow_disc_scale).
	} else if (v_bead > 0.5) {
		// A bead: round, shaded like a little sphere. Resting beads blend that
		// with the surface normal so the object keeps its shape and lighting;
		// beads in flight are full spheres. The blend follows v_fly, so the
		// look changes continuously.
		float r2 = dot(pc, pc);
		if (r2 > 1.0) {
			discard;
		}
		vec3 bn = vec3(pc.x, -pc.y * v_ysign, sqrt(1.0 - r2));
		// Beads only a few pixels wide can't show their roundness; their rims
		// would just beat against the pixel grid (moire). Fade the bead
		// shading in with on-screen size.
		float detail = smoothstep(4.0, 11.0, v_px);
		// Atoms in flight are lit as if facing the viewer: their own surface
		// normals point everywhere once they scatter, which would flicker.
		// (Tilted towards the sky, where the light usually is, so loose grains
		// are about as bright as the surface they came from.)
		vec3 free_n = normalize(vec3(0.0, 0.0, 1.0) + mat3(VIEW_MATRIX) * vec3(0.0, 1.6, 0.0));
		vec3 base_n = normalize(mix(vn, free_n, v_fly));
		NORMAL = normalize(mix(base_n, bn, mix(bead_bulge, 1.0, v_fly) * detail));
		bead_shade = mix(1.0, mix(1.0 - bead_edge_shade, 1.0, bn.z), detail * max(v_fly, bead_bulge));
		// The surface point under this pixel: intersect the pixel's view ray
		// with the bead's surface plane. Texture, box trimming, lighting and
		// shadows use it, so they're exact per pixel (crisp lines and shadow
		// edges even on a floor seen at a grazing angle).
		vec3 ro = ortho ? vec3(q.xy, 0.0) : vec3(0.0);
		vec3 rd = ortho ? vec3(0.0, 0.0, -1.0) : normalize(q);
		if (!ortho) {
			// The exact ray through this pixel, from its screen position. (The
			// sprite's own coordinate is rounded by some drivers, and at
			// grazing angles a fraction of a pixel is a long way across the
			// surface.)
			vec4 hv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
			rd = normalize(hv.xyz / hv.w);
		}
		float denom = dot(rd, vn);
		grazing = max(abs(denom), 0.05); // for the texture's mip level
		vec3 plane_off = q - v_center;
		if (abs(denom) > 0.05) {
			plane_off = ro + rd * (dot(v_center - ro, vn) / denom) - v_center;
		}
		plane_off -= vn * dot(plane_off, vn);
		// Resting beads light like the surface; beads in flight like spheres.
		hit = mix(v_center + plane_off, v_center + bn * v_radius, v_fly);
		vec3 local_off = (transpose(mv) * plane_off) / (mv_scale * mv_scale);
		texpos += local_off;
		if (clip_bounds) {
			vec3 lo = v_local + local_off;
			vec3 eps = bounds_size * 0.0005 + vec3(1e-5);
			// Only trim sideways: a surface lying against the box (a cube's face,
			// the spot where a sphere touches its box) must not be cut by the
			// wall it faces, or curved models get holes there.
			bvec3 side = lessThan(abs(normalize(v_lnormal + vec3(1e-6))), vec3(0.8));
			bvec3 outside = bvec3(lo.x < bounds_min.x - eps.x || lo.x > bounds_min.x + bounds_size.x + eps.x,
					lo.y < bounds_min.y - eps.y || lo.y > bounds_min.y + bounds_size.y + eps.y,
					lo.z < bounds_min.z - eps.z || lo.z > bounds_min.z + bounds_size.z + eps.z);
			if ((side.x && outside.x) || (side.y && outside.y) || (side.z && outside.z)) {
				discard;
			}
		}
	} else if (splats) {
		// Intersect this pixel's view ray with the dot's tangent-plane disc.
		vec3 ro = ortho ? vec3(q.xy, 0.0) : vec3(0.0);
		vec3 rd = ortho ? vec3(0.0, 0.0, -1.0) : normalize(q);
		float denom = dot(rd, vn);
		grazing = abs(denom);
		if (grazing < 0.02) {
			discard; // seen exactly edge-on: neighbouring discs cover this
		}
		hit = ro + rd * (dot(v_center - ro, vn) / denom);
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
		NORMAL = normalize(vn + mv * (v_shape * local_off) / mv_scale);
		if (clip_bounds) {
			vec3 lo = v_local + local_off;
			vec3 eps = bounds_size * 0.0005 + vec3(1e-5);
			// Only trim sideways: a surface lying against the box (a cube's face,
			// the spot where a sphere touches its box) must not be cut by the
			// wall it faces, or curved models get holes there.
			bvec3 side = lessThan(abs(normalize(v_lnormal + vec3(1e-6))), vec3(0.8));
			bvec3 outside = bvec3(lo.x < bounds_min.x - eps.x || lo.x > bounds_min.x + bounds_size.x + eps.x,
					lo.y < bounds_min.y - eps.y || lo.y > bounds_min.y + bounds_size.y + eps.y,
					lo.z < bounds_min.z - eps.z || lo.z > bounds_min.z + bounds_size.z + eps.z);
			if ((side.x && outside.x) || (side.y && outside.y) || (side.z && outside.z)) {
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
	col *= bead_shade;
	if (unshaded) {
		ALBEDO = vec3(0.0);
		EMISSION = col;
	} else {
		float self_lit = atom_glow * v_fly;
		ALBEDO = col * (1.0 - self_lit);
		EMISSION = col * (emission_strength + self_lit);
	}
	EMISSION += dissolve_edge_color.rgb * v_glow * glow_strength;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
