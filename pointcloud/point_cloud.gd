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

signal morph_finished
signal heal_finished

const TEX_WIDTH := 2048
const MAX_IMPACTS := 8
const DEFAULT_SHADER := preload("res://pointcloud/point_cloud.gdshader")

static var _clock_origin: int = Time.get_ticks_usec()

## The points. Assigning new data re-uploads everything to the GPU.
@export var data: PointCloudData:
	set(v):
		data = v
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
## World-space diameter of each point. 0 = use the data's suggested size.
@export var point_size := 0.0:
	set(v):
		point_size = v
		_update_point_size()
@export var point_size_multiplier := 1.0:
	set(v):
		point_size_multiplier = v
		_update_point_size()
@export var max_pixel_size := 48.0:
	set(v):
		max_pixel_size = v
		_sp(&"max_pixel_size", v)
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
## Use your own copy of point_cloud.gdshader (keep the uniforms).
@export var shader_override: Shader:
	set(v):
		shader_override = v
		if _mat:
			_mat.shader = v if v else DEFAULT_SHADER

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
var _mesh_count := -1
var _tex_h := 1
var _pos_tex: ImageTexture
var _col_tex: ImageTexture
var _nrm_tex: ImageTexture
var _state_tex: ImageTexture
var _tpos_tex: ImageTexture
var _tcol_tex: ImageTexture
var _tnrm_tex: ImageTexture
var _bidx_tex: ImageTexture
var _bwgt_tex: ImageTexture
var _bone_tex: ImageTexture
var _bone_buf := PackedFloat32Array()
var _skin_in_use: Skin
var _bind_bones := PackedInt32Array()
var _bone_mats: Array[Transform3D] = []

var _state := PackedFloat32Array()
var _state_dirty := false
var _colors_dirty := false
var _target: PointCloudData
var _morph_tween: Tween
var _heal_tween: Tween

var _impact_pos := PackedVector4Array()
var _impact_params := PackedVector4Array()
var _impact_next := 0

var _grid: PointGrid
var _grid_gen := 0
var _grid_task := -1
var _grid_job: _GridJob
var _pending: Array[Callable] = []


## Seconds since startup on the clock shared by all clouds and their shaders.
static func now() -> float:
	return float(Time.get_ticks_usec() - _clock_origin) / 1000000.0


func _init() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = DEFAULT_SHADER
	RenderingServer.instance_geometry_set_material_override(get_instance(), _mat.get_rid())
	_impact_pos.resize(MAX_IMPACTS)
	_impact_params.resize(MAX_IMPACTS)
	_impact_pos.fill(Vector4(0, 0, 0, -1))
	_sp(&"impact_pos", _impact_pos)
	_sp(&"impact_params", _impact_params)
	_sp(&"tex_width", TEX_WIDTH)
	for p in [&"max_pixel_size", &"round_points", &"unshaded", &"roughness", &"metallic",
			&"emission_strength", &"tint", &"tint_amount", &"vibrate_amplitude", &"vibrate_frequency",
			&"wobble_amplitude", &"wobble_frequency", &"wobble_speed", &"explode", &"explode_center",
			&"dissolve", &"dissolve_direction", &"dissolve_directional", &"dissolve_spread",
			&"dissolve_drift", &"dissolve_edge_color", &"glow_strength", &"morph", &"morph_stagger",
			&"morph_arc", &"debris_lifetime", &"debris_gravity"]:
		_sp(p, get(p))


func _enter_tree() -> void:
	add_to_group(&"point_clouds")


func _ready() -> void:
	if (data == null or data.size() == 0) and source_mesh and not Engine.is_editor_hint():
		data = _sample_source()
	if skeleton:
		bind_skeleton(skeleton, skin)


func _process(_delta: float) -> void:
	_sp(&"cloud_time", now())
	_poll_grid_task()
	if _state_dirty:
		_state_dirty = false
		_state_tex = _upload(_state_tex, _state.to_byte_array(), Image.FORMAT_RGBAF)
		_sp(&"state_tex", _state_tex)
	if _colors_dirty:
		_colors_dirty = false
		_col_tex = _upload_colors(_col_tex, data.colors)
		_sp(&"col_tex", _col_tex)
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

## Number of points.
func get_point_count() -> int:
	return data.size() if data else 0


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
		var cols := data.colors
		var pos := data.positions
		for i in hits:
			var f := 1.0 - pos[i].distance_to(local) / r
			cols[i] = cols[i].lerp(color, clampf(f / maxf(1.0 - hardness, 0.01), 0.0, 1.0))
		data.colors = cols
		_colors_dirty = true)


## Knocks points within `radius` of a world position off the model. They fly
## outward with speed `force`, tumble under debris_gravity and fade out over
## debris_lifetime. Returns immediately; the effect appears next frame.
func carve(world_pos: Vector3, radius: float, force := 2.0, ragged := 0.35) -> void:
	_when_grid_ready(func():
		var local := _world_to_rest(world_pos)
		var r := radius / _avg_scale()
		var hits := _grid.query(local, r)
		if hits.is_empty():
			return
		var t := now()
		var pos := data.positions
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(t)
		for i in hits:
			if _state[i * 4] >= 0.0:
				continue
			var d := pos[i].distance_to(local)
			# Ragged edge: some points near the rim survive.
			if d > r * (1.0 - ragged * rng.randf()):
				continue
			var dir := (pos[i] - local).normalized()
			if dir == Vector3.ZERO:
				dir = Vector3.UP
			var vel := (dir + _rand_unit(rng) * 0.6) * force * rng.randf_range(0.4, 1.4)
			var k := i * 4
			_state[k] = t + (d / r) * 0.08  # hole opens from the centre outward
			_state[k + 1] = vel.x
			_state[k + 2] = vel.y
			_state[k + 3] = vel.z
		_state_dirty = true)


## Sends a ripple through the points around a world position.
func impact(world_pos: Vector3, strength := 0.15, speed := 4.0, width := 0.25, decay := 2.5) -> void:
	var local := to_local(world_pos)
	_impact_pos[_impact_next] = Vector4(local.x, local.y, local.z, now())
	_impact_params[_impact_next] = Vector4(strength, speed, width, decay)
	_impact_next = (_impact_next + 1) % MAX_IMPACTS
	_sp(&"impact_pos", _impact_pos)
	_sp(&"impact_params", _impact_params)


## Instantly puts every carved point back and clears dissolve/explode.
func restore() -> void:
	if _heal_tween:
		_heal_tween.kill()
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
		_reset_state()
		_state_dirty = true
		_sp(&"heal", 0.0)
		heal_finished.emit())
	return _heal_tween


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
	tw.tween_property(self, "explode", 0.0, duration * 0.7).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tw


## Morphs into another model. Point counts are matched automatically. With
## `match_shape` the points are paired by position so the model flows into
## the new one; without it they swarm randomly. When finished, `data` becomes
## the target.
func morph_to(target: PointCloudData, duration := 2.0, match_shape := true) -> Tween:
	if data == null or target == null:
		return null
	if _morph_tween and _morph_tween.is_running():
		_morph_tween.kill()
		_finish_morph()
	var t := target.resampled(data.size())
	if match_shape:
		t = PointSampler.match_order(data, t)
	set_morph_target(t)
	morph = 0.0
	_morph_tween = create_tween()
	_morph_tween.tween_property(self, "morph", 1.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_morph_tween.tween_callback(_finish_morph)
	return _morph_tween


## Sets the morph target without animating; drive `morph` yourself (0..1).
## The target must have exactly get_point_count() points.
func set_morph_target(t: PointCloudData) -> void:
	assert(t.size() == get_point_count(), "Morph target must have the same point count")
	_target = t
	var total := TEX_WIDTH * _tex_h
	_tpos_tex = _upload(_tpos_tex, _padded_v3(t.positions, total).to_byte_array(), Image.FORMAT_RGBF)
	_tcol_tex = _upload_colors(_tcol_tex, t.colors)
	_tnrm_tex = _upload(_tnrm_tex, _padded_v3(t.normals, total).to_byte_array(), Image.FORMAT_RGBF)
	_sp(&"target_pos_tex", _tpos_tex)
	_sp(&"target_col_tex", _tcol_tex)
	_sp(&"target_nrm_tex", _tnrm_tex)
	# Grow culling bounds to cover both shapes during the morph.
	if data:
		_set_custom_aabb(data.aabb.merge(t.aabb))


func _finish_morph() -> void:
	if _target == null:
		return
	var t := _target
	_target = null
	_tpos_tex = null
	_tcol_tex = null
	_tnrm_tex = null
	var old_state := _state
	data = t          # re-uploads; also clears skinning if the target isn't skinned
	if old_state.size() == _state.size():
		_state = old_state  # carved holes survive the morph
		_state_dirty = true
	morph = 0.0
	morph_finished.emit()


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
		_mesh = null
		_mesh_count = -1
		return
	_tex_h = maxi(1, ceili(float(n) / TEX_WIDTH))
	var total := TEX_WIDTH * _tex_h
	if _mesh_count != n:
		_build_mesh(n)

	_pos_tex = _upload(_pos_tex, _padded_v3(data.positions, total).to_byte_array(), Image.FORMAT_RGBF)
	_col_tex = _upload_colors(_col_tex, data.colors)
	_nrm_tex = _upload(_nrm_tex, _padded_v3(data.normals, total).to_byte_array(), Image.FORMAT_RGBF)
	_sp(&"pos_tex", _pos_tex)
	_sp(&"col_tex", _col_tex)
	_sp(&"nrm_tex", _nrm_tex)
	if not _target:
		_sp(&"target_pos_tex", _pos_tex)
		_sp(&"target_col_tex", _col_tex)
		_sp(&"target_nrm_tex", _nrm_tex)

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
	_sp(&"use_skin", data.is_skinned() and _skin_in_use != null)

	_sp(&"bounds_min", data.aabb.position)
	_sp(&"bounds_size", data.aabb.size)
	_update_point_size()
	_update_aabb()
	_grid = null
	_grid_gen += 1


func _build_mesh(n: int) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	verts.resize(n)
	arrays[Mesh.ARRAY_VERTEX] = verts
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	_mesh_count = n
	set_base(_mesh.get_rid())


func _update_aabb() -> void:
	if data:
		_set_custom_aabb(data.aabb)


func _set_custom_aabb(box: AABB) -> void:
	if _mesh:
		_mesh.custom_aabb = box.grow(cull_margin)


func _update_point_size() -> void:
	var s := point_size
	if s <= 0.0:
		s = data.suggested_point_size if data else 0.02
	_sp(&"point_size", s * point_size_multiplier)


func _reset_state() -> void:
	# Only x (detach time) matters while attached; -1 everywhere is fine.
	_state.fill(-1.0)


func _sp(param: StringName, value: Variant) -> void:
	if _mat:
		_mat.set_shader_parameter(param, value)


static func _padded_v3(arr: PackedVector3Array, total: int) -> PackedVector3Array:
	var a := arr.duplicate()
	a.resize(total)
	return a


func _upload_colors(tex: ImageTexture, cols: PackedColorArray) -> ImageTexture:
	var total := TEX_WIDTH * _tex_h
	var c := cols.duplicate()
	var had := c.size()
	c.resize(total)
	if had == 0:
		c.fill(Color.WHITE)
	return _upload(tex, c.to_byte_array(), Image.FORMAT_RGBAF)


func _upload(tex: ImageTexture, bytes: PackedByteArray, fmt: Image.Format) -> ImageTexture:
	var img := Image.create_from_data(TEX_WIDTH, _tex_h, false, fmt, bytes)
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
	_grid_task = WorkerThreadPool.add_task(_grid_job.run, false, "PointCloud grid")


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
	if _grid_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_grid_task)
		_grid_task = -1
		_grid_job = null
		_pending.clear()


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
