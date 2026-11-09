@tool
class_name PointCloudData
extends Resource
## The raw points of one model: one entry per point in each array.
##
## Positions and normals are in the cloud's local space (for skinned clouds:
## the mesh's bind pose). Colours are ordinary Godot Colors (sRGB).
##
## Editing by code: grab an array, change it, assign it back, then call
## PointCloud.commit() so the GPU copy is refreshed:
##     var p := cloud.data.positions
##     for i in p.size(): p[i].y += sin(p[i].x)
##     cloud.data.positions = p
##     cloud.commit()
## (Writing cloud.data.positions[i] = ... directly in a loop copies the whole
## array every time, which is very slow.)
##
## Save large clouds with ResourceSaver as binary ".res" files so they load
## instantly instead of being re-sampled at startup.

@export var positions := PackedVector3Array()
@export var colors := PackedColorArray()
@export var normals := PackedVector3Array()
## Surface curvature tensor per point, 8 floats each: xx, yy, zz, 0, xy, xz,
## yz, 0 of the symmetric matrix S with dNormal = S * dPosition along the
## surface (local space). The renderer uses it to bend normals across each
## dot exactly like a mesh's interpolated normals. Optional.
@export var curvatures := PackedFloat32Array()
## 4 skin bind indices per point (stored as floats). Empty when not skinned.
@export var bone_indices := PackedFloat32Array()
## 4 skin weights per point. Empty when not skinned.
@export var bone_weights := PackedFloat32Array()
## Bounding box of the positions. Call recompute_aabb() after moving points.
@export var aabb := AABB()
## Point diameter that makes the surface look closed at this density.
@export var suggested_point_size := 0.02


func size() -> int:
	return positions.size()


func is_skinned() -> bool:
	var n := size()
	return n > 0 and bone_indices.size() == n * 4 and bone_weights.size() == n * 4


func recompute_aabb() -> void:
	if positions.is_empty():
		aabb = AABB()
		return
	var mn := positions[0]
	var mx := mn
	for p in positions:
		mn = mn.min(p)
		mx = mx.max(p)
	aabb = AABB(mn, mx - mn)


## Returns a cloud with exactly `count` points: a prefix of this one when
## shrinking (sampled clouds are in random order, so a prefix is a random
## subset) and random repeats when growing.
func resampled(count: int, rng_seed := 7) -> PointCloudData:
	var n := size()
	if n == count or n == 0:
		return self
	var idx := PackedInt32Array()
	idx.resize(count)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	for i in count:
		idx[i] = i if i < n else rng.randi_range(0, n - 1)
	var out := picked(idx)
	out.suggested_point_size = suggested_point_size * sqrt(float(n) / float(count))
	return out


## Builds a new cloud from the points at the given indices (in that order).
func picked(indices: PackedInt32Array) -> PointCloudData:
	var out := PointCloudData.new()
	var count := indices.size()
	var has_n := normals.size() == size()
	var has_c := colors.size() == size()
	var has_k := curvatures.size() == size() * 8
	var skinned := is_skinned()
	out.positions.resize(count)
	if has_n:
		out.normals.resize(count)
	if has_c:
		out.colors.resize(count)
	if has_k:
		out.curvatures.resize(count * 8)
	if skinned:
		out.bone_indices.resize(count * 4)
		out.bone_weights.resize(count * 4)
	for i in count:
		var j := indices[i]
		out.positions[i] = positions[j]
		if has_n:
			out.normals[i] = normals[j]
		if has_c:
			out.colors[i] = colors[j]
		if has_k:
			for k in 8:
				out.curvatures[i * 8 + k] = curvatures[j * 8 + k]
		if skinned:
			for k in 4:
				out.bone_indices[i * 4 + k] = bone_indices[j * 4 + k]
				out.bone_weights[i * 4 + k] = bone_weights[j * 4 + k]
	out.aabb = aabb
	out.suggested_point_size = suggested_point_size
	return out


## Appends another cloud's points, optionally transformed. Useful for building
## one model out of several pieces. Skin data is dropped unless both are skinned.
func merge(other: PointCloudData, xform := Transform3D.IDENTITY) -> void:
	if other == null or other.size() == 0:
		return
	var n_before := size()
	var both_skinned := is_skinned() and other.is_skinned()
	_fill_defaults()
	var o := other.duplicate() as PointCloudData
	o._fill_defaults()
	positions.append_array(xform * o.positions)
	var rot := Transform3D(xform.basis.orthonormalized(), Vector3.ZERO)
	normals.append_array(rot * o.normals)
	colors.append_array(o.colors)
	curvatures.append_array(transformed_tensors(o.curvatures, xform.basis))
	if both_skinned:
		bone_indices.append_array(o.bone_indices)
		bone_weights.append_array(o.bone_weights)
	else:
		bone_indices = PackedFloat32Array()
		bone_weights = PackedFloat32Array()
	# Weighted average keeps the point size sensible for the combined model.
	var total := float(size())
	suggested_point_size = (suggested_point_size * n_before + o.suggested_point_size * o.size()) / total
	recompute_aabb()


func _fill_defaults() -> void:
	var n := size()
	if normals.size() != n:
		normals.resize(n)
	if colors.size() != n:
		colors.resize(n)
		colors.fill(Color.WHITE)
	if curvatures.size() != n * 8:
		curvatures.resize(n * 8)


## Curvature tensors re-expressed after transforming points by `b`
## (rotation + uniform scale): S' = R S R^T / scale.
static func transformed_tensors(a: PackedFloat32Array, b: Basis) -> PackedFloat32Array:
	var scale := b.get_scale().x
	var r := b.orthonormalized()
	if r.is_equal_approx(Basis.IDENTITY) and is_equal_approx(scale, 1.0):
		return a
	var rt := r.transposed()
	var out := a.duplicate()
	for i in range(0, out.size(), 8):
		var s := Basis(Vector3(a[i], a[i + 4], a[i + 5]), Vector3(a[i + 4], a[i + 1], a[i + 6]),
				Vector3(a[i + 5], a[i + 6], a[i + 2]))
		var t := r * s * rt
		out[i] = t.x.x / scale
		out[i + 1] = t.y.y / scale
		out[i + 2] = t.z.z / scale
		out[i + 4] = t.y.x / scale
		out[i + 5] = t.z.x / scale
		out[i + 6] = t.z.y / scale
	return out
