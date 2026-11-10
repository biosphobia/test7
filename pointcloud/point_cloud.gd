@tool
class_name PointCloud
extends GeometryInstance3D
## A model made entirely of points.
##
## Give it a PointCloudData (or a source mesh to sample) and it draws every
## point on the GPU. Points can be shaken, dissolved, exploded, morphed into
## another model, carved off by hits, repainted, skinned to a Skeleton3D, or
## edited one by one from code.
##
## Quick start:
##     var cloud := PointCloud.new()
##     cloud.data = PointSampler.box(Vector3.ONE * 2, 300_000)
##     add_child(cloud)
##     cloud.vibrate_amplitude = 0.02          # shiver
##     cloud.dissolve_out(3.0)                 # crumble away
##     cloud.morph_to(PointSampler.sphere(1.2, 1000), 2.0)
##     cloud.carve(hit_position, 0.4)          # knock points off

signal morph_started
signal morph_finished
signal heal_finished

const TEX_WIDTH := 2048
const MAX_IMPACTS := 8
const DEFAULT_SHADER := preload("res://pointcloud/point_cloud.gdshader")
const EXACT_SHADER := preload("res://pointcloud/point_cloud_exact.gdshader")
## LOD never draws fewer points than this per cloud.
const LOD_MIN_POINTS := 1500
## Shadows are cast by a hidden low-detail copy using this fraction of the
## points drawn on screen (shadow maps are blurry anyway, and every shadow
## cascade redraws all casters).
const SHADOW_DETAIL := 0.25
## Carves applied on the GPU before being folded into the debris texture.
const MAX_CARVES := 48
## Fold pending carves into the debris texture once this many accumulate (or
## shortly after the last shot).
const CARVE_BAKE_AT := 16
## Most morph targets kept on the GPU per cloud (oldest dropped first).
const MORPH_CACHE_SIZE := 8
const PROXY_SHADER := preload("res://pointcloud/flat_proxy.gdshader")
## Resolution of a flat proxy's hole mask and paint map.
const PROXY_RES := 128

## Level of detail, shared by all clouds: the on-screen spacing (pixels) to aim
## for between beads. Far away a cloud draws fewer points; up close every
## point spawns extra beads (see max_amplification), so beads stay this far
## apart at any distance. Raise it for speed (PointCloudQuality does this
## automatically), lower it for finer beads.
static var lod_spacing_px := 1.25
## Most beads one cloud may process per frame (caps amplification up close).
const MAX_DOTS_PER_CLOUD := 3000000
## Turns level of detail off everywhere (always draw every point).
static var lod_enabled := true

## Dots are drawn in instanced batches of this many points, so a cloud of
## any size costs one small shared vertex buffer.
const CHUNK := 32768

static var _clock := 0.0
static var _clock_frame := -1

## The points. Assigning new data re-uploads everything to the GPU.
@export var data: PointCloudData:
	set(v):
		data = v
		if not _swapping:
			_rebuild(false)

@export_group("Source Mesh")
## If set and `data` is empty, this mesh is sampled when the node is ready.
@export var source_mesh: Mesh
@export var source_point_count := 100000
@export var source_fill: PointSampler.Fill = PointSampler.Fill.SURFACE
@export_range(0.0, 1.0) var source_fill_fraction := 0.4
@export var source_thickness := 0.1
## Where the "Sample" button saves the result (.res recommended). Leave empty
## to keep the data inside the scene file (fine for small clouds only).
@export_file("*.res", "*.tres") var source_bake_path := ""
@export_tool_button("Sample source mesh", "PointMesh") var _sample_button := sample_source_mesh

@export_group("Appearance")
## Most beads one stored point may spawn when seen up close. Up close each
## point fills its patch of surface with extra beads so beads stay about
## `lod_spacing_px` apart on screen; this caps how many.
@export_range(1, 64) var max_amplification := 32:
	set(v):
		max_amplification = clampi(v, 1, 64)
		if data and data.size() > 0:
			_build_mesh(data.size())

@export var point_size := 0.0:
	set(v):
		point_size = v
		_update_point_size()
@export var point_size_multiplier := 1.0:
	set(v):
		point_size_multiplier = v
		_update_point_size()
@export var max_pixel_size := 256.0:
	set(v):
		max_pixel_size = v
		_sp(&"max_pixel_size", v)
## Draw every dot as a small lit bead (default). Resting beads overlap to
## close the surface; flying beads shrink. Size and shading change smoothly
## with how far a dot is "in flight", so morphs and debris never pop.
## Off = flat surface discs (see `splats`) while resting.
@export var beads := true:
	set(v):
		beads = v
		_sp(&"beads", v)
## Scales how much resting beads overlap. Lower = less overdraw (faster), but
## gaps can appear; evenly sampled flat surfaces can go a bit below 1.
@export_range(0.5, 2.0) var bead_overlap := 1.0:
	set(v):
		bead_overlap = v
		_sp(&"bead_overlap", v)
## Draw each dot as a disc lying on the surface with exact per-pixel depth,
## so dots fuse into a continuous, solid-looking surface.
@export var splats := true:
	set(v):
		splats = v
		_sp(&"splats", v)
## While at rest, trim dots at the bounding box so box edges stay sharp.
@export var clip_to_bounds := true:
	set(v):
		clip_to_bounds = v
		_sp(&"clip_to_bounds", v)
## Texture sampled per pixel (triplanar) and multiplied with the dot colours.
## Use it for fine detail (lines, text, grain) that should stay sharp.
@export var surface_texture: Texture2D:
	set(v):
		surface_texture = v
		_sp(&"surface_texture", v)
		_sp(&"use_surface_texture", v != null)
## Local size of one texture repeat along x, y, z.
@export var texture_tile := Vector3.ONE:
	set(v):
		texture_tile = v
		_sp(&"texture_tile", v)
@export var texture_offset := Vector3.ZERO:
	set(v):
		texture_offset = v
		_sp(&"texture_offset", v)
@export var round_points := true:
	set(v):
		round_points = v
		_sp(&"round_points", v)
@export var unshaded := false:
	set(v):
		unshaded = v
		_sp(&"unshaded", v)
@export_range(0.0, 1.0) var roughness := 0.75:
	set(v):
		roughness = v
		_sp(&"roughness", v)
@export_range(0.0, 1.0) var metallic := 0.0:
	set(v):
		metallic = v
		_sp(&"metallic", v)
@export var emission_strength := 0.0:
	set(v):
		emission_strength = v
		_sp(&"emission_strength", v)
@export var tint := Color.WHITE:
	set(v):
		tint = v
		_sp(&"tint", v)
@export_range(0.0, 1.0) var tint_amount := 0.0:
	set(v):
		tint_amount = v
		_sp(&"tint_amount", v)
## Extra room around the bounds so displaced points are not culled.
@export var cull_margin := 2.0:
	set(v):
		cull_margin = v
		_update_aabb()
## Use your own shader (include point_cloud.gdshaderinc to keep everything).
@export var shader_override: Shader:
	set(v):
		shader_override = v
		_apply_shader()
## Write each disc's exact per-pixel depth. Slightly nicer where surfaces
## meet, but disables the GPU's early depth test, so it's much slower.
@export var exact_depth := false:
	set(v):
		exact_depth = v
		_apply_shader()
## Draw fewer, larger points when the cloud is small on screen.
@export var lod := true
## Multiplies the level-of-detail spacing for this cloud. Flat surfaces whose
## detail comes from `surface_texture` (floors, walls) look the same with far
## fewer, bigger dots: try 2-3 there.
@export var lod_spacing_scale := 1.0
## For flat clouds (terrain tiles whose surface is the top of their bounding
## box, like PointSampler.plane()): while intact, draw the surface as one
## textured plane with the same look instead of dots. Shots cut holes into the
## plane and only the hole walls and debris are drawn as dots; morph, dissolve
## and other effects switch back to the full dot cloud. Saves most of the cost
## of large floors.
@export var flat_proxy := false

@export_group("Vibrate")
@export_range(0.0, 0.5, 0.001) var vibrate_amplitude := 0.0:
	set(v):
		vibrate_amplitude = v
		_sp(&"vibrate_amplitude", v)
@export var vibrate_frequency := 30.0:
	set(v):
		vibrate_frequency = v
		_sp(&"vibrate_frequency", v)

@export_group("Wobble")
@export_range(0.0, 1.0, 0.001) var wobble_amplitude := 0.0:
	set(v):
		wobble_amplitude = v
		_sp(&"wobble_amplitude", v)
@export var wobble_frequency := 3.0:
	set(v):
		wobble_frequency = v
		_sp(&"wobble_frequency", v)
@export var wobble_speed := 3.0:
	set(v):
		wobble_speed = v
		_sp(&"wobble_speed", v)

## Below 1 the cloud thins out evenly, atom by atom, until at 0 nothing of it
## is drawn in the view; its shadow stays. For letting a camera move into a
## model (e.g. into a first-person body).
@export_range(0.0, 1.0) var view_fade := 1.0:
	set(v):
		view_fade = v
		_sp(&"view_fade", v)

@export_group("Singularity")
## 1 = every atom is packed into a small swarming ball at gather_center.
## Animate it to 0: the ball explodes (every atom is hurled far out), then
## the model is built: atoms come back to their places along the axes,
## snapped to a grid like pixels, and finally take on their colours.
@export_range(0.0, 1.0) var gather := 0.0:
	set(v):
		var was := gather
		gather = v
		_sp(&"gather", v)
		if (was > 0.0) != (v > 0.0):
			_update_aabb()
## Where the ball is, in world space.
@export var gather_center := Vector3.ZERO:
	set(v):
		gather_center = v
		if is_inside_tree():
			_sp(&"gather_center", to_local(v))
			_sp(&"gather_floor", (floor_y - global_position.y) / maxf(_avg_scale(), 1e-6))
## Radius of the ball.
@export var gather_radius := 0.4:
	set(v):
		gather_radius = v
		_sp(&"gather_radius", v / maxf(_avg_scale(), 1e-6) if is_inside_tree() else v)
## Atoms this far from the ball are the last to leave it (sets the order in
## which a scene unfolds).
@export var gather_reach := 30.0:
	set(v):
		gather_reach = v
		_sp(&"gather_reach", v)
## How far the explosion throws the atoms.
@export var gather_burst := 11.0:
	set(v):
		gather_burst = v
		_sp(&"gather_burst", v)
## The build starts with the atoms farthest from this world position (the
## viewer) and works towards it; gather_reach is the distance of the farthest.
@export var gather_eye := Vector3.ZERO:
	set(v):
		gather_eye = v
		_sp(&"gather_eye", v)
## This cloud's share of the build, as (start, end) fractions of it: e.g.
## (0, 0.4) for a floor that is laid first, (0.9, 1) for something built last.
@export var gather_window := Vector2(0, 1):
	set(v):
		gather_window = v
		_sp(&"gather_window", v)
## How atoms reach their places in the build.
enum GatherMode {
	RAIN,    ## wait as a sparse scatter in the sky, then swoop down into place
	DIRECT,  ## glide straight out of the scattered cloud and settle: floors
	GROW,    ## the whole model rises through the floor (floor_y) in one piece
}
@export var gather_mode := GatherMode.RAIN:
	set(v):
		gather_mode = v
		_sp(&"gather_mode", int(v))
## 0..1: how violently the ball shakes.
@export var gather_agitate := 0.0:
	set(v):
		gather_agitate = v
		_sp(&"gather_agitate", v)
## White-hot glow of the gathered atoms.
@export var gather_heat := 0.0:
	set(v):
		gather_heat = v
		_sp(&"gather_heat", v)

@export_group("Explode")
@export var explode := 0.0:
	set(v):
		explode = v
		_sp(&"explode", v)
@export var explode_center := Vector3.ZERO:
	set(v):
		explode_center = v
		_sp(&"explode_center", v)

@export_group("Dissolve")
## 0 = intact, 1 = every point has flown away.
@export_range(0.0, 1.0) var dissolve := 0.0:
	set(v):
		dissolve = v
		_sp(&"dissolve", v)
## The dissolve front travels along this direction (when directional > 0).
@export var dissolve_direction := Vector3.DOWN:
	set(v):
		dissolve_direction = v
		_sp(&"dissolve_direction", v)
## 0 = points leave in random order, 1 = a clean sweeping front.
@export_range(0.0, 1.0) var dissolve_directional := 0.0:
	set(v):
		dissolve_directional = v
		_sp(&"dissolve_directional", v)
@export var dissolve_spread := 1.5:
	set(v):
		dissolve_spread = v
		_sp(&"dissolve_spread", v)
@export var dissolve_drift := Vector3(0, 0.6, 0):
	set(v):
		dissolve_drift = v
		_sp(&"dissolve_drift", v)
@export var dissolve_edge_color := Color(1.0, 0.45, 0.1):
	set(v):
		dissolve_edge_color = v
		_sp(&"dissolve_edge_color", v)
@export var glow_strength := 4.0:
	set(v):
		glow_strength = v
		_sp(&"glow_strength", v)

@export_group("Morph")
## 0 = current shape, 1 = morph target (see morph_to()).
@export_range(0.0, 1.0) var morph := 0.0:
	set(v):
		morph = v
		_sp(&"morph", v)
@export_range(0.0, 0.95) var morph_stagger := 0.5:
	set(v):
		morph_stagger = v
		_sp(&"morph_stagger", v)
@export var morph_arc := 0.3:
	set(v):
		morph_arc = v
		_sp(&"morph_arc", v)

@export_group("Debris")
@export var debris_lifetime := 2.0:
	set(v):
		debris_lifetime = v
		_sp(&"debris_lifetime", v)
## What this cloud's atoms are made of: how they behave once knocked loose
## (weight, bounce, whether they land and stay...). See PointElement.
## Null = glowing embers that drift off and fade, using the debris_* values.
@export var element: PointElement:
	set(v):
		element = v
		_apply_element()
## World height of the ground that loose atoms land on (elements with
## `lands`). The cloud is assumed to stand upright.
@export var floor_y := 0.0:
	set(v):
		floor_y = v
		_apply_element()
@export var debris_gravity := Vector3(0, -3, 0):
	set(v):
		debris_gravity = v
		_sp(&"debris_gravity", v)

@export_group("Skinning")
## Skeleton driving this cloud. Set automatically by from_mesh_instance().
@export var skeleton: Skeleton3D
## Skin (bind poses). Null = generated from the skeleton's rest pose.
@export var skin: Skin

var _mat: ShaderMaterial
var _mesh: ArrayMesh
var _multimesh: MultiMesh
var _mesh_count := -1
var _tex_h := 1
var _cur: _ShapeTex      # GPU textures of `data`
var _tgt: _ShapeTex      # GPU textures of the morph target
var _cache := {}         # morph target key -> _ShapeTex
var _cache_order := []
var _prep := []          # running morph-target preparations
var _queued_morph := []  # [key, duration] waiting for its preparation
var _swapping := false
var _state_tex: ImageTexture
var _bidx_tex: ImageTexture
var _bwgt_tex: ImageTexture
var _bone_tex: ImageTexture
var _bone_buf := PackedFloat32Array()
var _skin_in_use: Skin
var _bind_bones := PackedInt32Array()
var _bone_mats: Array[Transform3D] = []

var _shadow_mat: ShaderMaterial
var _finish_waiting := false   # morph done, waiting for the carve bake
var _finish_wait := 0.0
var _shadow_mm: MultiMesh
var _shadow_inst := RID()
## Beads per stored point this frame (set by level of detail).
var density := 1
var _target_px := -1.0
var _drawn := Vector3i(-1, -1, -1)         # surface points, interior points, beads per point
var _shadow_drawn := Vector3i(-1, -1, -1)
var _has_debris := false
var _state := PackedFloat32Array()
var _state_dirty := false
var _colors_dirty := false
var _carves: Array[PackedFloat32Array] = []  # cx, cy, cz, t0, radius, force, ragged, seed
var _carve_a := PackedVector4Array()
var _carve_b := PackedVector4Array()
var _carve_c := PackedVector4Array()   # xyz kick direction (local)
var _last_carve_time := -100.0
var _bake_task := -1
var _bake_job: _BakeJob
var _morph_tween: Tween
var _proxy_inst := RID()
var _proxy_mesh: PlaneMesh
var _proxy_mat: ShaderMaterial
var _proxy_for: PointCloudData
var _proxy_on := false
var _hole_img: Image
var _hole_tex: ImageTexture
var _paint_img: Image
var _paint_tex: ImageTexture
var _heal_tween: Tween

var _impact_pos := PackedVector4Array()
var _impact_params := PackedVector4Array()
var _impact_next := 0

var _grid: PointGrid
var _grid_gen := 0
var _grid_task := -1
var _grid_job: _GridJob
var _pending: Array[Callable] = []


## Seconds on the clock shared by all clouds and their shaders. It follows
## game time (process delta), so it respects Engine.time_scale, stops while
## paused and stays in sync in Movie Maker mode.
static func now() -> float:
	return _clock


func _init() -> void:
	_mat = ShaderMaterial.new()
	_shadow_mat = ShaderMaterial.new()
	_apply_shader()
	_shadow_mat.set_shader_parameter(&"amplify", false)
	RenderingServer.instance_geometry_set_material_override(get_instance(), _mat.get_rid())
	_impact_pos.resize(MAX_IMPACTS)
	_impact_params.resize(MAX_IMPACTS)
	_impact_pos.fill(Vector4(0, 0, 0, -1))
	_sp(&"impact_pos", _impact_pos)
	_sp(&"impact_params", _impact_params)
	_carve_a.resize(MAX_CARVES)
	_carve_b.resize(MAX_CARVES)
	_carve_c.resize(MAX_CARVES)
	_sp(&"carve_a", _carve_a)
	_sp(&"carve_b", _carve_b)
	_sp(&"carve_count", 0)
	_sp(&"tex_width", TEX_WIDTH)
	for p in [&"max_pixel_size", &"round_points", &"unshaded", &"roughness", &"metallic",
			&"emission_strength", &"tint", &"tint_amount", &"vibrate_amplitude", &"vibrate_frequency",
			&"wobble_amplitude", &"wobble_frequency", &"wobble_speed", &"explode", &"explode_center",
			&"dissolve", &"dissolve_direction", &"dissolve_directional", &"dissolve_spread",
			&"dissolve_drift", &"dissolve_edge_color", &"glow_strength", &"morph", &"morph_stagger",
			&"morph_arc", &"debris_lifetime", &"debris_gravity", &"beads", &"bead_overlap", &"splats", &"clip_to_bounds", &"texture_tile", &"texture_offset"]:
		_sp(p, get(p))
	_apply_element()


func _enter_tree() -> void:
	add_to_group(&"point_clouds")
	if not Engine.is_editor_hint() and not _shadow_inst.is_valid():
		_shadow_inst = RenderingServer.instance_create()
		RenderingServer.instance_set_scenario(_shadow_inst, get_world_3d().scenario)
		RenderingServer.instance_geometry_set_material_override(_shadow_inst, _shadow_mat.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(_shadow_inst,
				RenderingServer.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
		if _shadow_mm:
			RenderingServer.instance_set_base(_shadow_inst, _shadow_mm.get_rid())


func _ready() -> void:
	if (data == null or data.size() == 0) and source_mesh and not Engine.is_editor_hint():
		data = _sample_source()
	if skeleton:
		bind_skeleton(skeleton, skin)


func _process(delta: float) -> void:
	var frame := Engine.get_process_frames()
	if frame != _clock_frame:
		_clock_frame = frame
		_clock += delta
	_sp(&"cloud_time", now())
	_poll_grid_task()
	_poll_prep()
	_poll_bake()
	if _finish_waiting:
		_finish_wait += delta
		if (_carves.is_empty() and _bake_task < 0) or _finish_wait >= 1.0:
			_finish_morph()
	_sync_flat_proxy()
	_update_lod()
	_sync_shadow_proxy()
	if _state_dirty:
		_state_dirty = false
		_state_tex = _upload(_state_tex, _state.to_byte_array(), Image.FORMAT_RGBAF)
		_sp(&"state_tex", _state_tex)
		_sp(&"has_debris", _has_debris)
	if _colors_dirty and _cur:
		# Painted colours: upload the 8-bit buffer as is (no conversion).
		_colors_dirty = false
		_cur.col.update(Image.create_from_data(TEX_WIDTH, _tex_h, false, Image.FORMAT_RGBA8, _cur.col_bytes))
	if skeleton and _skin_in_use and is_instance_valid(skeleton):
		_update_bones()


# ============================================================== creation

## Samples a MeshInstance3D into a PointCloud that takes its place: same
## parent and transform, same skeleton (so animations keep playing), and the
## original mesh is hidden. Returns the new cloud.
static func from_mesh_instance(mi: MeshInstance3D, count: int, opts: Dictionary = {}) -> PointCloud:
	var mats := []
	for s in mi.mesh.get_surface_count():
		mats.append(mi.get_active_material(s))
	var o := opts.duplicate()
	if not o.has("materials"):
		o["materials"] = mats
	var cloud := PointCloud.new()
	cloud.name = mi.name + "Points"
	cloud.data = PointSampler.from_mesh(mi.mesh, count, o)
	cloud.transform = mi.transform
	mi.add_sibling(cloud)
	var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D
	if skel and cloud.data.is_skinned():
		cloud.bind_skeleton(skel, mi.skin)
	mi.visible = false
	return cloud


## Converts every MeshInstance3D under `root` (e.g. an imported .glb scene)
## into point clouds, with point counts based on surface area.
static func convert_scene(root: Node, points_per_m2 := 20000.0, opts: Dictionary = {}) -> Array[PointCloud]:
	var out: Array[PointCloud] = []
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	for mi in meshes:
		if mi.mesh == null or not mi.visible:
			continue
		var count := PointSampler.count_for_density(mi.mesh, points_per_m2)
		out.append(from_mesh_instance(mi, count, opts))
	return out


static func _collect_meshes(n: Node, into: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		into.append(n)
	for c in n.get_children():
		_collect_meshes(c, into)


func sample_source_mesh() -> void:
	if source_mesh == null:
		push_warning("PointCloud: no source mesh to sample.")
		return
	var d := _sample_source()
	if source_bake_path != "":
		var err := ResourceSaver.save(d, source_bake_path)
		if err != OK:
			push_error("PointCloud: could not save %s (%s)" % [source_bake_path, error_string(err)])
		else:
			d = load(source_bake_path)
	data = d


func _sample_source() -> PointCloudData:
	return PointSampler.from_mesh(source_mesh, source_point_count, {
		"fill": source_fill,
		"fill_fraction": source_fill_fraction,
		"thickness": source_thickness,
	})


# ============================================================== editing

## Number of stored points (entries in `data`).
func get_point_count() -> int:
	return data.size() if data else 0


## Number of stored points (each drawn as one or more beads).
func get_dot_count() -> int:
	return get_point_count()


## Upper bound of beads processed this frame (points drawn × beads per
## point; unneeded, off-screen and back-facing ones are skipped early).
func get_drawn_dot_count() -> int:
	if not is_visible_in_tree() or _drawn.x < 0:
		return 0
	return (_drawn.x + _drawn.y) * _drawn.z


## Re-uploads all point data after you changed `data` arrays from code.
func commit(recompute_bounds := true) -> void:
	if data and recompute_bounds:
		data.recompute_aabb()
	_rebuild(true)


## Recolours points within `radius` of a world position. `hardness` 0..1
## controls the soft edge.
func paint(world_pos: Vector3, radius: float, color: Color, hardness := 0.5) -> void:
	_when_grid_ready(func():
		var local := _world_to_rest(world_pos)
		var r := radius / _avg_scale()
		var hits := _grid.query(local, r)
		if hits.is_empty():
			return
		# Take the arrays out of their owners while editing so writes don't
		# trigger a copy of the whole array (copy-on-write).
		var cols := data.colors
		data.colors = PackedColorArray()
		var bytes := _cur.col_bytes
		_cur.col_bytes = PackedByteArray()
		var pos := data.positions
		var has_cols := cols.size() == pos.size()
		for i in hits:
			var f := 1.0 - pos[i].distance_to(local) / r
			var base := cols[i] if has_cols else Color.WHITE
			var c := base.lerp(color, clampf(f / maxf(1.0 - hardness, 0.01), 0.0, 1.0))
			c.a = base.a
			if has_cols:
				cols[i] = c
			var b := i * 4
			bytes[b] = c.r8
			bytes[b + 1] = c.g8
			bytes[b + 2] = c.b8
		data.colors = cols
		_cur.col_bytes = bytes
		_colors_dirty = true
		if _paint_img:
			_mask_circle(_paint_img, local, r, color, hardness)
			_paint_tex.update(_paint_img))


## Knocks points within `radius` of a world position off the model. They fly
## outward with speed `force`, tumble under debris_gravity and fade out over
## debris_lifetime; the dots around the hole become its wall (normals facing
## into it, darkened like a cavity).
##
## `kick` (world direction, length around 1) throws the debris that way on top
## of the outward burst: pass the reverse of a bullet's direction and the
## chips spray back out of the hole towards the shooter.
##
## Costs almost nothing on the main thread: the carve is handed to the shader
## as a sphere, and a worker thread later folds batches of carves into the
## debris texture using exactly the same maths.
func carve(world_pos: Vector3, radius: float, force := 2.0, ragged := 0.35, kick := Vector3.ZERO) -> void:
	if data == null or data.size() == 0:
		return
	if element:
		radius /= maxf(element.hardness, 0.05)
		force *= element.scatter
		_apply_element()  # the ground height follows the cloud's position
	if _carves.size() >= MAX_CARVES:
		_bake_now()
	var c := _world_to_rest(world_pos)
	var seed := randi() & 0xFFFFFF
	var lk := global_transform.basis.orthonormalized().inverse() * kick
	_carves.append(PackedFloat32Array([c.x, c.y, c.z, now(), radius / _avg_scale(), force, ragged, float(seed),
			lk.x, lk.y, lk.z]))
	_last_carve_time = now()
	_has_debris = true
	_sp(&"has_debris", true)
	_push_carves()
	prepare_interaction()  # make sure the grid exists for baking


func _apply_element() -> void:
	if _mat == null:
		return
	var e := element
	_sp(&"debris_lands", e != null and e.lands)
	_sp(&"debris_bounce", e.bounce if e else 0.3)
	_sp(&"debris_friction", e.friction if e else 0.4)
	_sp(&"debris_drag", e.drag if e else 0.0)
	_sp(&"debris_glow", e.glow if e else 1.0)
	_sp(&"debris_lifetime", e.lifetime if e else debris_lifetime)
	_sp(&"debris_gravity", Vector3(0, -e.gravity, 0) if e else debris_gravity)
	if is_inside_tree():
		_sp(&"debris_floor_y", (floor_y - global_position.y) / maxf(_avg_scale(), 1e-6))


func _push_carves() -> void:
	for i in MAX_CARVES:
		if i < _carves.size():
			var k := _carves[i]
			_carve_a[i] = Vector4(k[0], k[1], k[2], k[3])
			_carve_b[i] = Vector4(k[4], k[5], k[6], k[7])
			_carve_c[i] = Vector4(k[8], k[9], k[10], 0.0)
		else:
			_carve_a[i] = Vector4.ZERO
			_carve_b[i] = Vector4.ZERO
			_carve_c[i] = Vector4.ZERO
	_sp(&"carve_a", _carve_a)
	_sp(&"carve_b", _carve_b)
	_sp(&"carve_c", _carve_c)
	_sp(&"carve_count", _carves.size())
	if _proxy_mat:
		_proxy_mat.set_shader_parameter(&"carve_a", _carve_a)
		_proxy_mat.set_shader_parameter(&"carve_b", _carve_b)
		_proxy_mat.set_shader_parameter(&"carve_count", _carves.size())


func _poll_bake() -> void:
	if _bake_task >= 0:
		if not WorkerThreadPool.is_task_completed(_bake_task):
			return
		_finish_bake()
	if _carves.is_empty() or _grid == null:
		return
	if _carves.size() >= CARVE_BAKE_AT or now() - _last_carve_time > 0.75 or _finish_waiting:
		_start_bake()


func _start_bake() -> void:
	_bake_job = _BakeJob.new()
	_bake_job.grid = _grid
	_bake_job.gen = _grid_gen
	_bake_job.positions = data.positions
	_bake_job.state = _state
	_bake_job.carves = _carves.duplicate()
	_bake_job.tex_h = _tex_h
	_bake_task = WorkerThreadPool.add_task(_bake_job.run, true, "PointCloud carve bake")


func _finish_bake() -> void:
	WorkerThreadPool.wait_for_task_completion(_bake_task)
	_bake_task = -1
	var job := _bake_job
	_bake_job = null
	if job.gen != _grid_gen or job.image == null:
		return  # data changed meanwhile; the carves are still pending
	_state = job.state
	_state_tex = _upload_image(_state_tex, job.image)
	_sp(&"state_tex", _state_tex)
	if _hole_img:
		for c in job.carves:
			_mask_circle(_hole_img, Vector3(c[0], c[1], c[2]), c[4] * 1.6, Color.WHITE, 1.0)
		_hole_tex.update(_hole_img)
	# Those carves now live in the texture: drop them from the shader list
	# in the same frame, so nothing visibly changes.
	_carves = _carves.slice(job.carves.size())
	_push_carves()


## Folds every pending carve into the debris texture right now (used before
## the point layout changes, e.g. when a morph completes).
func _bake_now() -> void:
	if _carves.is_empty():
		return
	if _bake_task >= 0:
		_finish_bake()
	if _carves.is_empty():
		return
	if _grid == null:
		if _grid_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_grid_task)
			_poll_grid_task()
		if _grid == null:
			_grid = PointGrid.build(data.positions, data.aabb)
	_start_bake()
	_finish_bake()


## Sends a ripple through the points around a world position.
func impact(world_pos: Vector3, strength := 0.15, speed := 4.0, width := 0.25, decay := 2.5) -> void:
	var local := to_local(world_pos)
	_impact_pos[_impact_next] = Vector4(local.x, local.y, local.z, now())
	_impact_params[_impact_next] = Vector4(strength, speed, width, decay)
	_impact_next = (_impact_next + 1) % MAX_IMPACTS
	_sp(&"impact_pos", _impact_pos)
	_sp(&"impact_params", _impact_params)
	_sp(&"impacts_until", now() + 4.0)


## Instantly puts every carved point back and clears dissolve/explode.
func restore() -> void:
	if _heal_tween:
		_heal_tween.kill()
	_clear_carves()
	_reset_state()
	_state_dirty = true
	dissolve = 0.0
	explode = 0.0
	_sp(&"heal", 0.0)


## Animates carved-off points flying back into place.
func heal(duration := 1.5) -> Tween:
	if _heal_tween:
		_heal_tween.kill()
	_heal_tween = create_tween()
	_heal_tween.tween_method(func(v: float): _sp(&"heal", v), 0.0, 1.0, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_heal_tween.tween_callback(func():
		_clear_carves()
		_reset_state()
		_state_dirty = true
		_sp(&"heal", 0.0)
		heal_finished.emit())
	return _heal_tween


func _clear_carves() -> void:
	if _bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		_bake_job = null
	_carves.clear()
	_push_carves()
	if _hole_img:
		_hole_img.fill(Color.BLACK)
		_hole_tex.update(_hole_img)


## Crumbles the model away. Use reassemble() to bring it back.
func dissolve_out(duration := 2.5) -> Tween:
	var tw := create_tween()
	tw.tween_property(self, "dissolve", 1.0, duration * (1.0 - dissolve))
	return tw


## Reverses dissolve/explode so points fly back together.
func reassemble(duration := 2.0) -> Tween:
	var tw := create_tween().set_parallel()
	tw.tween_property(self, "dissolve", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "explode", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	return tw


## Blows the points outward and pulls them back in.
func explode_pulse(strength := 1.5, duration := 1.2) -> Tween:
	explode_center = data.aabb.get_center() if data else Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "explode", strength, duration * 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	# Settles without springing back and forth, so beads land once.
	tw.tween_property(self, "explode", 0.0, duration * 0.7).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	return tw


## Morphs into another model. `target` is a PointCloudData, or a Callable
## that returns one (it then runs on a worker thread, so generating the shape
## doesn't stall the game either; build meshes on the main thread and sample
## them with PointSampler.from_snapshot() inside the Callable). Point counts are matched automatically;
## with `match_shape` points are paired by position so the model flows into
## the new one.
##
## Never blocks: matching and texture preparation run on worker threads and
## the GPU upload is spread over a few frames, then the morph starts
## (`morph_started`). Targets stay cached on the GPU, so morphing to the same
## target again (or back) starts instantly. Use prepare_morph_target() to warm
## the cache ahead of time.
func morph_to(target: Variant, duration := 2.0, match_shape := true) -> void:
	if data == null or target == null:
		return
	_queued_morph = [target, duration]
	if is_morph_target_ready(target):
		_start_queued_morph()
	else:
		prepare_morph_target(target, match_shape)


## Prepares a morph target in the background (see morph_to()).
func prepare_morph_target(target: Variant, match_shape := true) -> void:
	if data == null or target == null or is_morph_target_ready(target):
		return
	for p in _prep:
		if p["key"] == target:
			return
	var job := _PrepJob.new()
	job.source = data
	job.target = target
	job.match_shape = match_shape
	job.count = data.size()
	job.tex_h = _tex_h
	_prep.append({"key": target, "job": job, "shape": null,
		"task": WorkerThreadPool.add_task(job.run, false, "PointCloud morph target")})


func is_morph_target_ready(target: Variant) -> bool:
	if not _cache.has(target):
		return false
	var sh: _ShapeTex = _cache[target]
	return sh.count == get_point_count() and sh.is_ready()


func _poll_prep() -> void:
	for p in _prep.duplicate():
		if p["shape"] == null:
			if not WorkerThreadPool.is_task_completed(p["task"]):
				continue
			WorkerThreadPool.wait_for_task_completion(p["task"])
			var job: _PrepJob = p["job"]
			if job.result == null or job.count != get_point_count():
				_prep.erase(p)
				continue
			p["shape"] = _ShapeTex.from_images(job.result, job.images)
		# One texture upload per frame keeps the GPU transfer from spiking.
		if (p["shape"] as _ShapeTex).upload_step():
			_prep.erase(p)
			_cache_put(p["key"], p["shape"])
			if not _queued_morph.is_empty() and _queued_morph[0] == p["key"]:
				_start_queued_morph()
		return


func _cache_put(key: Variant, sh: _ShapeTex) -> void:
	if not _cache.has(key):
		_cache_order.append(key)
	_cache[key] = sh
	while _cache_order.size() > MORPH_CACHE_SIZE:
		var old = _cache_order.pop_front()
		if _cache.get(old) != _cur and _cache.get(old) != _tgt:
			_cache.erase(old)
		else:
			_cache_order.append(old)
			break


func _start_queued_morph() -> void:
	var key = _queued_morph[0]
	var duration: float = _queued_morph[1]
	_queued_morph = []
	if _morph_tween and _morph_tween.is_running():
		_morph_tween.kill()
		_finish_morph()
	# Keep the current shape on the GPU too, so morphing back is instant.
	if _cur and data:
		_cache_put(data, _cur)
	_tgt = _cache[key]
	_bind_target(_tgt)
	if data:
		_set_custom_aabb(data.aabb.merge(_tgt.data.aabb))
	morph = 0.0
	_morph_tween = create_tween()
	_morph_tween.tween_property(self, "morph", 1.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_morph_tween.tween_callback(_finish_morph)
	morph_started.emit()


## Sets the morph target without animating; drive `morph` yourself (0..1).
## The target must have exactly get_point_count() points. Uploads right away
## (use morph_to() for the stutter-free path).
func set_morph_target(t: PointCloudData) -> void:
	assert(t.size() == get_point_count(), "Morph target must have the same point count")
	var sh := _ShapeTex.from_images(t, _shape_images(t, _tex_h))
	while not sh.upload_step():
		pass
	_cache_put(t, sh)
	_tgt = sh
	_bind_target(sh)
	if data:
		_set_custom_aabb(data.aabb.merge(t.aabb))


func _finish_morph() -> void:
	if _tgt == null:
		return
	# Pending carves refer to the old point positions: fold them in first, on
	# a worker thread. The morph stays at its last frame until that's done
	# (it looks the same), so shooting during a morph never stalls a frame.
	if not _carves.is_empty() and _finish_wait < 1.0:
		_finish_waiting = true
		return
	_finish_waiting = false
	_finish_wait = 0.0
	_bake_now()
	_cur = _tgt
	_tgt = null
	# Swap in the target's textures; nothing is re-uploaded.
	_swapping = true
	data = _cur.data
	_swapping = false
	_bind_current()
	morph = 0.0
	morph_finished.emit()


func _bind_current() -> void:
	_sp(&"pos_tex", _cur.pos)
	_sp(&"col_tex", _cur.col)
	_sp(&"nrm_tex", _cur.nrm)
	_sp(&"curv_tex", _cur.curv)
	if _tgt == null:
		_bind_target(_cur)
	_sp(&"use_skin", data.is_skinned() and _skin_in_use != null)
	_sp(&"point_spacing", data.suggested_point_size / PointSampler.SIZE_FACTOR)
	_sp(&"interior_scale", _interior_scale_for(data))
	_sp(&"backface_cull", data.closed and (_tgt == null or _tgt.data.closed))
	_sp(&"bounds_min", data.aabb.position)
	_sp(&"bounds_size", data.aabb.size)
	_update_point_size()
	_update_aabb()
	_drawn = Vector3i(-1, -1, -1)
	_shadow_drawn = Vector3i(-1, -1, -1)
	_grid = null
	_grid_gen += 1


func _bind_target(sh: _ShapeTex) -> void:
	# Dots blend to the target's dot size as they travel, so nothing changes
	# size when the morph completes and the target becomes the shape.
	_sp(&"backface_cull", data != null and data.closed and sh.data.closed)
	_sp(&"target_point_size", _point_size_for(sh.data))
	_sp(&"target_interior_scale", _interior_scale_for(sh.data))
	_sp(&"target_pos_tex", sh.pos)
	_sp(&"target_col_tex", sh.col)
	_sp(&"target_nrm_tex", sh.nrm)
	_sp(&"target_curv_tex", sh.curv)


# ============================================================== skinning

## Makes the cloud follow a skeleton. The data must carry bone indices/weights
## (PointSampler copies them from skinned meshes). `with_skin` = null uses the
## skeleton's rest pose as bind pose, like Godot does for MeshInstance3D.
func bind_skeleton(skel: Skeleton3D, with_skin: Skin = null) -> void:
	skeleton = skel
	skin = with_skin
	_skin_in_use = with_skin if with_skin else skel.create_skin_from_rest_transforms()
	var bc := _skin_in_use.get_bind_count()
	_bind_bones.resize(bc)
	for i in bc:
		var b := _skin_in_use.get_bind_bone(i)
		if b < 0:
			b = skel.find_bone(_skin_in_use.get_bind_name(i))
		_bind_bones[i] = b
	_bone_buf.resize(bc * 12)
	_bone_mats.resize(bc)
	_update_bones()
	_sp(&"use_skin", data != null and data.is_skinned())


func _update_bones() -> void:
	var bc := _bind_bones.size()
	for i in bc:
		var b := _bind_bones[i]
		var t := Transform3D.IDENTITY
		if b >= 0:
			t = skeleton.get_bone_global_pose(b) * _skin_in_use.get_bind_pose(i)
		_bone_mats[i] = t
		var k := i * 12
		var x := t.basis.x
		var y := t.basis.y
		var z := t.basis.z
		var o := t.origin
		_bone_buf[k] = x.x
		_bone_buf[k + 1] = y.x
		_bone_buf[k + 2] = z.x
		_bone_buf[k + 3] = o.x
		_bone_buf[k + 4] = x.y
		_bone_buf[k + 5] = y.y
		_bone_buf[k + 6] = z.y
		_bone_buf[k + 7] = o.y
		_bone_buf[k + 8] = x.z
		_bone_buf[k + 9] = y.z
		_bone_buf[k + 10] = z.z
		_bone_buf[k + 11] = o.z
	var img := Image.create_from_data(3, maxi(bc, 1), false, Image.FORMAT_RGBAF,
			_bone_buf.to_byte_array() if bc > 0 else PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]).to_byte_array())
	if _bone_tex and _bone_tex.get_height() == img.get_height():
		_bone_tex.update(img)
	else:
		_bone_tex = ImageTexture.create_from_image(img)
		_sp(&"bone_xform_tex", _bone_tex)


# ============================================================== internals

func _rebuild(keep_state: bool) -> void:
	if _mat == null:
		return
	var n := data.size() if data else 0
	if n == 0:
		set_base(RID())
		_mesh_count = -1
		return
	_tex_h = maxi(1, ceili(float(n) / TEX_WIDTH))
	var total := TEX_WIDTH * _tex_h
	if _mesh_count != n:
		_build_mesh(n)

	_cur = _ShapeTex.from_images(data, _shape_images(data, _tex_h))
	while not _cur.upload_step():
		pass

	if not keep_state or _state.size() != total * 4:
		_state.resize(total * 4)
		_reset_state()
	_state_tex = _upload(_state_tex, _state.to_byte_array(), Image.FORMAT_RGBAF)
	_sp(&"state_tex", _state_tex)

	if data.is_skinned():
		var bi := data.bone_indices.duplicate()
		var bw := data.bone_weights.duplicate()
		bi.resize(total * 4)
		bw.resize(total * 4)
		_bidx_tex = _upload(_bidx_tex, bi.to_byte_array(), Image.FORMAT_RGBAF)
		_bwgt_tex = _upload(_bwgt_tex, bw.to_byte_array(), Image.FORMAT_RGBAF)
		_sp(&"bone_idx_tex", _bidx_tex)
		_sp(&"bone_wgt_tex", _bwgt_tex)
	if not keep_state:
		_clear_carves()
	_bind_current()


func _build_mesh(n: int) -> void:
	# One shared batch of CHUNK dummy points, instanced as often as needed.
	# The shader finds its dot from INSTANCE_ID * CHUNK + VERTEX_ID.
	if _mesh == null:
		_mesh = _shared_chunk_mesh()
	for i in 2:
		var mm := _multimesh if i == 0 else _shadow_mm
		if mm == null:
			mm = MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _mesh
			if i == 0:
				_multimesh = mm
			else:
				_shadow_mm = mm
				if _shadow_inst.is_valid():
					RenderingServer.instance_set_base(_shadow_inst, mm.get_rid())
		var instances := ceili(float(n * (max_amplification if i == 0 else 1)) / CHUNK)
		if mm.instance_count != instances:
			mm.instance_count = instances
			for k in instances:
				mm.set_instance_transform(k, Transform3D.IDENTITY)
	_mesh_count = n
	_drawn = Vector3i(-1, -1, -1)
	_shadow_drawn = Vector3i(-1, -1, -1)
	_update_lod()
	_update_aabb()
	set_base(_multimesh.get_rid())


## Level of detail. Points are stored as [surface | interior], each part in
## progressive order (see PointSampler), so the first k points of a part are
## an even sample of it.
## Draw only as many surface points as the cloud's on-screen size needs (and
## scale them up to keep the surface closed), and interior points only while
## something exposes them.
func _update_lod() -> void:
	if _multimesh == null or data == null or data.size() == 0:
		return
	var n := data.size()
	var ns := data.get_surface_count()
	var ni := n - ns
	var f := 1.0
	if lod and lod_enabled and not Engine.is_editor_hint():
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam and (cam.cull_mask & layers) == 0:
			# The camera can't see this cloud (e.g. the first-person body):
			# its own draw costs nothing, so don't amplify it.
			f = 0.0
		elif cam:
			var box := global_transform * data.aabb
			var cp := cam.global_position
			var d := maxf(cp.distance_to(cp.clamp(box.position, box.end)), cam.near)
			# Atoms are sized in rendered pixels: count them at the 3D render scale.
			var view_h := get_viewport().get_visible_rect().size.y * get_viewport().scaling_3d_scale
			var px_per_unit := view_h / cam.size
			if cam.projection == Camera3D.PROJECTION_PERSPECTIVE:
				px_per_unit = view_h * 0.5 / tan(deg_to_rad(cam.fov) * 0.5) / d
			var spacing := data.suggested_point_size / PointSampler.SIZE_FACTOR * _avg_scale()
			f = pow(spacing * px_per_unit / (lod_spacing_px * lod_spacing_scale), 2.0)
			if f < 1.0:
				# Quantise to steps of 1/sqrt(2) so counts don't change every frame.
				f = pow(2.0, floorf(log(maxf(f, 1e-9)) / log(2.0) * 2.0) / 2.0)
	var target := lod_spacing_px * lod_spacing_scale
	if target != _target_px:
		_target_px = target
		_sp(&"target_px", target)
	# Closer than full detail: amplify (more, smaller beads per point).
	var amp := clampi(ceili(f), 1, max_amplification) if f > 1.0 else 1
	f = minf(f, 1.0)
	var interior := _has_debris or dissolve > 0.0 or explode != 0.0 or morph > 0.0 or gather > 0.0
	var a := clampi(ceili(ns * f), mini(ns, LOD_MIN_POINTS), ns)
	var b := ceili(ni * f) if interior else 0
	if _proxy_on and not _has_debris:
		a = 0  # the proxy plane shows the intact surface
		b = 0
	amp = mini(amp, maxi(1, MAX_DOTS_PER_CLOUD / maxi(a + b, 1)))
	density = amp
	_set_drawn(_multimesh, _mat, Vector3i(a, b, amp), ns, false)
	var sa := clampi(ceili(a * SHADOW_DETAIL), mini(ns, LOD_MIN_POINTS / 2), ns)
	_set_drawn(_shadow_mm, _shadow_mat, Vector3i(sa, ceili(b * SHADOW_DETAIL), 1), ns, true)


func _set_drawn(mm: MultiMesh, mat: ShaderMaterial, drawn: Vector3i, ns: int, shadow: bool) -> void:
	if mm == null or drawn == (_shadow_drawn if shadow else _drawn):
		return
	if shadow:
		_shadow_drawn = drawn
	else:
		_drawn = drawn
	var dots := (drawn.x + drawn.y) * drawn.z
	mm.visible_instance_count = mini(ceili(float(dots) / CHUNK), mm.instance_count)
	mat.set_shader_parameter(&"dot_count", dots)
	mat.set_shader_parameter(&"density", drawn.z)
	mat.set_shader_parameter(&"surface_count", ns)
	mat.set_shader_parameter(&"surface_drawn", drawn.x)
	mat.set_shader_parameter(&"lod_scale", sqrt(float(maxi(ns, 1)) / float(maxi(drawn.x, 1))))


## The visible cloud casts no shadow itself; a hidden low-detail copy does.
func _sync_shadow_proxy() -> void:
	if not _shadow_inst.is_valid():
		return
	var casts := cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and is_visible_in_tree() \
			and _shadow_mm != null and data != null and data.size() > 0
	RenderingServer.instance_set_visible(_shadow_inst, casts)
	if casts:
		RenderingServer.instance_set_transform(_shadow_inst, global_transform)
	RenderingServer.instance_geometry_set_cast_shadows_setting(get_instance(),
			RenderingServer.SHADOW_CASTING_SETTING_OFF)


## Shows the proxy plane while the flat surface is intact and undisturbed.
func _sync_flat_proxy() -> void:
	if not flat_proxy or Engine.is_editor_hint() or data == null or data.size() == 0 or not is_inside_tree():
		if _proxy_on:
			_set_proxy_on(false)
		return
	if not _proxy_inst.is_valid():
		_build_flat_proxy()
	var still := morph == 0.0 and _tgt == null and dissolve == 0.0 and explode == 0.0 \
			and vibrate_amplitude == 0.0 and wobble_amplitude == 0.0
	var on := still and data == _proxy_for and is_visible_in_tree()
	if on != _proxy_on:
		_set_proxy_on(on)
	if on:
		RenderingServer.instance_set_transform(_proxy_inst, global_transform)


func _set_proxy_on(on: bool) -> void:
	_proxy_on = on
	if _proxy_inst.is_valid():
		RenderingServer.instance_set_visible(_proxy_inst, on)
	_sp(&"proxy_mode", on)
	_drawn = Vector3i(-1, -1, -1)


func _build_flat_proxy() -> void:
	_proxy_for = data
	var box := data.aabb
	_proxy_mesh = PlaneMesh.new()
	_proxy_mesh.size = Vector2(box.size.x, box.size.z)
	_proxy_mesh.center_offset = Vector3(box.get_center().x, box.end.y, box.get_center().z)
	# Same look as the surface dots: their average colour, texture, material.
	var avg := Color(0, 0, 0, 0)
	var ns := data.get_surface_count()
	var step := maxi(1, ns / 2000)
	var taken := 0
	for i in range(0, ns, step):
		avg += data.colors[i] if data.colors.size() == data.size() else Color.WHITE
		taken += 1
	avg = avg / maxf(taken, 1.0)
	avg.a = 1.0
	_hole_img = Image.create(PROXY_RES, PROXY_RES, false, Image.FORMAT_L8)
	_hole_tex = ImageTexture.create_from_image(_hole_img)
	_paint_img = Image.create(PROXY_RES, PROXY_RES, false, Image.FORMAT_RGBA8)
	_paint_img.fill(Color.WHITE)
	_paint_tex = ImageTexture.create_from_image(_paint_img)
	_proxy_mat = ShaderMaterial.new()
	_proxy_mat.shader = PROXY_SHADER
	for kv in [["base_color", avg], ["use_surface_texture", surface_texture != null],
			["surface_texture", surface_texture], ["texture_tile", texture_tile],
			["texture_offset", texture_offset], ["hole_mask", _hole_tex], ["paint_tex", _paint_tex],
			["bounds_min", box.position], ["bounds_size", box.size], ["roughness", roughness],
			["metallic", metallic]]:
		_proxy_mat.set_shader_parameter(kv[0], kv[1])
	_proxy_mesh.material = _proxy_mat
	_proxy_inst = RenderingServer.instance_create2(_proxy_mesh.get_rid(), get_world_3d().scenario)
	RenderingServer.instance_set_layer_mask(_proxy_inst, layers)
	RenderingServer.instance_geometry_set_cast_shadows_setting(_proxy_inst,
			RenderingServer.SHADOW_CASTING_SETTING_OFF if cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else RenderingServer.SHADOW_CASTING_SETTING_ON)
	_push_carves()


## Rasterises a soft disc (top-down, in local xz) into a proxy map.
func _mask_circle(img: Image, center: Vector3, radius: float, color: Color, hardness: float) -> void:
	var box := _proxy_for.aabb if _proxy_for else data.aabb
	var sx := PROXY_RES / maxf(box.size.x, 1e-4)
	var sz := PROXY_RES / maxf(box.size.z, 1e-4)
	var cx := (center.x - box.position.x) * sx
	var cz := (center.z - box.position.z) * sz
	var rx := radius * sx
	for y in range(maxi(0, int(cz - radius * sz) - 1), mini(PROXY_RES, int(cz + radius * sz) + 2)):
		for x in range(maxi(0, int(cx - rx) - 1), mini(PROXY_RES, int(cx + rx) + 2)):
			var d := Vector2((x + 0.5 - cx) / sx, (y + 0.5 - cz) / sz).length() / maxf(radius, 1e-6)
			if d > 1.0:
				continue
			var f := clampf((1.0 - d) / maxf(1.0 - hardness, 0.01), 0.0, 1.0)
			img.set_pixel(x, y, img.get_pixel(x, y).lerp(color, f))


func _apply_shader() -> void:
	var sh: Shader = shader_override if shader_override else (EXACT_SHADER if exact_depth else DEFAULT_SHADER)
	if _mat:
		_mat.shader = sh
	if _shadow_mat:
		_shadow_mat.shader = shader_override if shader_override else DEFAULT_SHADER


static var _chunk_mesh: ArrayMesh

static func _shared_chunk_mesh() -> ArrayMesh:
	if _chunk_mesh == null:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var verts := PackedVector3Array()
		verts.resize(CHUNK)
		arrays[Mesh.ARRAY_VERTEX] = verts
		_chunk_mesh = ArrayMesh.new()
		_chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return _chunk_mesh


func _update_aabb() -> void:
	if data:
		var box := data.aabb
		if gather > 0.0 and is_inside_tree():
			# Gathered atoms are far from the model: keep the cloud from being
			# culled while they're out there.
			var r := (gather_burst * 1.4 + gather_radius) / maxf(_avg_scale(), 1e-6)
			box = box.merge(AABB(to_local(gather_center) - Vector3.ONE * r, Vector3.ONE * r * 2.0))
		_set_custom_aabb(box)


func _set_custom_aabb(box: AABB) -> void:
	for mm in [_multimesh, _shadow_mm]:
		if mm:
			mm.custom_aabb = box.grow(cull_margin)


func _update_point_size() -> void:
	_sp(&"point_size", _point_size_for(data))


static func _interior_scale_for(d: PointCloudData) -> float:
	if d and d.interior_point_size > 0.0 and d.suggested_point_size > 0.0:
		return d.interior_point_size / d.suggested_point_size
	return 1.0


func _point_size_for(d: PointCloudData) -> float:
	var s := point_size
	if s <= 0.0:
		s = d.suggested_point_size if d else 0.02
	# (Extra beads up close are shrunk in the shader.)
	return s * point_size_multiplier


func _reset_state() -> void:
	# Only x (detach time) matters while attached; -1 everywhere is fine.
	_state.fill(-1.0)
	_has_debris = false
	_sp(&"has_debris", false)


func _sp(param: StringName, value: Variant) -> void:
	if _mat:
		_mat.set_shader_parameter(param, value)
	if _shadow_mat:
		_shadow_mat.set_shader_parameter(param, value)


## CPU-side images for one point layout: position (RGB32F), colour (RGBA8),
## normal (RGBA16F) and curvature tensor (RGBA16F, two texels per point).
## Pure data work, safe on worker threads.
static func _shape_images(d: PointCloudData, tex_h: int) -> Dictionary:
	var total := TEX_WIDTH * tex_h
	var c := d.colors.duplicate()
	var had := c.size()
	c.resize(total)
	if had == 0:
		c.fill(Color.WHITE)
	var col := Image.create_from_data(TEX_WIDTH, tex_h, false, Image.FORMAT_RGBAF, c.to_byte_array())
	col.convert(Image.FORMAT_RGBA8)
	var nrm := Image.create_from_data(TEX_WIDTH, tex_h, false, Image.FORMAT_RGBF, _padded_v3(d.normals, total).to_byte_array())
	nrm.convert(Image.FORMAT_RGBAH)
	var k := d.curvatures.duplicate()
	k.resize(total * 8)
	var curv := Image.create_from_data(TEX_WIDTH * 2, tex_h, false, Image.FORMAT_RGBAF, k.to_byte_array())
	curv.convert(Image.FORMAT_RGBAH)
	return {
		"pos": Image.create_from_data(TEX_WIDTH, tex_h, false, Image.FORMAT_RGBF, _padded_v3(d.positions, total).to_byte_array()),
		"col": col, "nrm": nrm, "curv": curv,
	}


static func _padded_v3(arr: PackedVector3Array, total: int) -> PackedVector3Array:
	var a := arr.duplicate()
	a.resize(total)
	return a


func _upload_image(tex: ImageTexture, img: Image) -> ImageTexture:
	if tex and tex.get_width() == img.get_width() and tex.get_height() == img.get_height() \
			and tex.get_format() == img.get_format():
		tex.update(img)
		return tex
	return ImageTexture.create_from_image(img)


## Uploads raw data in format `fmt`, optionally converted (natively, fast)
## to a smaller GPU format `store`.
func _upload(tex: ImageTexture, bytes: PackedByteArray, fmt: Image.Format, store := -1) -> ImageTexture:
	var img := Image.create_from_data(TEX_WIDTH, _tex_h, false, fmt, bytes)
	if store >= 0:
		img.convert(store)
		fmt = store
	if tex and tex.get_width() == TEX_WIDTH and tex.get_height() == _tex_h and tex.get_format() == fmt:
		tex.update(img)
		return tex
	return ImageTexture.create_from_image(img)


func _avg_scale() -> float:
	var s := global_transform.basis.get_scale()
	return maxf((s.x + s.y + s.z) / 3.0, 1e-5)


## World position -> rest-space position. For skinned clouds the point is
## carried back through the nearest bone, which is exact for rigid parts and
## a close approximation near joints.
func _world_to_rest(world_pos: Vector3) -> Vector3:
	var local := to_local(world_pos)
	if not (skeleton and _skin_in_use and data.is_skinned()) or _bone_mats.is_empty():
		return local
	var best := 0
	var best_d := INF
	for i in _bind_bones.size():
		var b := _bind_bones[i]
		if b < 0:
			continue
		var d := skeleton.get_bone_global_pose(b).origin.distance_squared_to(local)
		if d < best_d:
			best_d = d
			best = i
	return _bone_mats[best].affine_inverse() * local


func _when_grid_ready(action: Callable) -> void:
	if data == null or data.size() == 0:
		return
	if _grid:
		action.call()
		return
	_pending.append(action)
	if _grid_task >= 0:
		return
	_grid_job = _GridJob.new()
	_grid_job.gen = _grid_gen
	_grid_job.positions = data.positions
	_grid_job.bounds = data.aabb
	_grid_task = WorkerThreadPool.add_task(_grid_job.run, true, "PointCloud grid")


func _poll_grid_task() -> void:
	if _grid_task < 0 or not WorkerThreadPool.is_task_completed(_grid_task):
		return
	WorkerThreadPool.wait_for_task_completion(_grid_task)
	_grid_task = -1
	var job := _grid_job
	_grid_job = null
	var queued := _pending.duplicate()
	_pending.clear()
	if job.gen == _grid_gen:
		_grid = job.grid
		for a in queued:
			a.call()
	else:
		# Data changed while building; rebuild for the new data.
		for a in queued:
			_when_grid_ready(a)


func _exit_tree() -> void:
	if _proxy_inst.is_valid():
		RenderingServer.free_rid(_proxy_inst)
		_proxy_inst = RID()
		_proxy_on = false
	if _shadow_inst.is_valid():
		RenderingServer.free_rid(_shadow_inst)
		_shadow_inst = RID()
	if _grid_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_grid_task)
		_grid_task = -1
		_grid_job = null
		_pending.clear()
	if _bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
	for p in _prep:
		WorkerThreadPool.wait_for_task_completion(p["task"])
	_prep.clear()


class _GridJob:
	extends RefCounted
	var gen := 0
	var positions: PackedVector3Array
	var bounds: AABB
	var grid: PointGrid

	func run() -> void:
		grid = PointGrid.build(positions, bounds)


## Builds the carve/paint lookup grid now (on a worker thread) so the first
## hit doesn't wait for it.
func prepare_interaction() -> void:
	_when_grid_ready(func(): pass)


static func _rand_unit(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf() * TAU
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(a), z, r * sin(a))


# ============================================================== jobs & helpers

## GPU textures for one point layout (current shape or a morph target).
class _ShapeTex:
	extends RefCounted
	var data: PointCloudData
	var count := 0
	var pos: ImageTexture
	var col: ImageTexture
	var nrm: ImageTexture
	var curv: ImageTexture
	var col_bytes := PackedByteArray()  # RGBA8 copy of the colours, for painting
	var _pending: Array = []

	static func from_images(d: PointCloudData, images: Dictionary) -> _ShapeTex:
		var sh := _ShapeTex.new()
		sh.data = d
		sh.count = d.size()
		sh.col_bytes = (images["col"] as Image).get_data()
		for f in ["pos", "col", "nrm", "curv"]:
			sh._pending.append([f, images[f]])
		return sh

	func is_ready() -> bool:
		return _pending.is_empty() and pos != null

	## Uploads one texture; returns true once all are on the GPU.
	func upload_step() -> bool:
		if not _pending.is_empty():
			var p: Array = _pending.pop_front()
			set(p[0], ImageTexture.create_from_image(p[1]))
		return _pending.is_empty()


## Builds a morph target off the main thread: generate (if a Callable),
## resample, match point order, and prepare the texture images.
class _PrepJob:
	extends RefCounted
	var source: PointCloudData
	var target: Variant
	var match_shape := true
	var count := 0
	var tex_h := 1
	var result: PointCloudData
	var images: Dictionary

	func run() -> void:
		var t: PointCloudData = target.call() if target is Callable else target
		if t == null or t.size() == 0:
			return
		t = t.resampled(count)
		if match_shape and source:
			t = PointSampler.match_order(source, t)
		images = PointCloud._shape_images(t, tex_h)
		result = t


## Folds a batch of carves into the debris state on a worker thread.
class _BakeJob:
	extends RefCounted
	var grid: PointGrid
	var gen := 0
	var positions: PackedVector3Array
	var state: PackedFloat32Array
	var carves: Array[PackedFloat32Array] = []
	var tex_h := 1
	var image: Image

	func run() -> void:
		for c in carves:
			PointCloud._apply_carve(state, positions, grid, c)
		image = Image.create_from_data(PointCloud.TEX_WIDTH, tex_h, false, Image.FORMAT_RGBAF, state.to_byte_array())


## How far around a carve its wall (darkened, inward-facing dots) reaches,
## relative to the radius. Must match the shader.
const WALL_REACH := 1.7

## Writes one carve into a debris state array. This is the same maths as the
## shader's carve loop (same hashes), so baking changes nothing on screen.
## State per point: x >= 0: detach time, yzw velocity. x == -1: intact.
## -2 < x < -1: hole wall, cavity = -1 - x, yzw = vector to the hole centre.
static func _apply_carve(state: PackedFloat32Array, positions: PackedVector3Array, grid: PointGrid, c: PackedFloat32Array) -> void:
	var center := Vector3(c[0], c[1], c[2])
	var t0 := c[3]
	var r := c[4]
	var force := c[5]
	var ragged := c[6]
	var seed := int(c[7])
	for i in grid.query(center, r * WALL_REACH):
		var k := i * 4
		if state[k] >= 0.0:
			continue
		var p := positions[i]
		var d := p.distance_to(center)
		var key := (i * 1664525 + seed) & 0xFFFFFFFF
		var r_eff := r * (1.0 - ragged * _hash01(key))
		if d <= r_eff:
			var dir := (p - center) / d if d > 1e-6 else Vector3.UP
			var vel := (dir + _rand_dir(key ^ 0x68E31DA4) * 0.6 + Vector3(c[8], c[9], c[10])) * force * (0.4 + _hash01(key + 7))
			state[k] = t0 + d / r * 0.08
			state[k + 1] = vel.x
			state[k + 2] = vel.y
			state[k + 3] = vel.z
		else:
			var cav := 1.0 - smoothstep(r_eff, r * WALL_REACH, d)
			if cav > 0.0 and -1.0 - state[k] < cav:
				var to_c := center - p
				state[k] = -1.0 - minf(cav, 0.999)
				state[k + 1] = to_c.x
				state[k + 2] = to_c.y
				state[k + 3] = to_c.z


static func _pcg(v: int) -> int:
	var st := (v * 747796405 + 2891336453) & 0xFFFFFFFF
	var word := ((((st >> ((st >> 28) + 4)) ^ st) & 0xFFFFFFFF) * 277803737) & 0xFFFFFFFF
	return ((word >> 22) ^ word) & 0xFFFFFFFF


static func _hash01(v: int) -> float:
	return float(_pcg(v & 0xFFFFFFFF)) / 4294967295.0


static func _rand_dir(v: int) -> Vector3:
	var z := _hash01(v) * 2.0 - 1.0
	var a := _hash01(v ^ 0x9E3779B9) * TAU
	var rr := sqrt(maxf(1.0 - z * z, 0.0))
	return Vector3(rr * cos(a), z, rr * sin(a))
