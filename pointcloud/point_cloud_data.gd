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
## Dot diameter for interior points, which are spread through a volume and
## usually sparser than the surface. 0 = same as suggested_point_size.
@export var interior_point_size := 0.0
## Points are stored as [surface points | interior points], each part in
## progressive order (every prefix is evenly spread). This is how many
## surface points come first; -1 = all points are surface. The renderer skips interior points until something exposes
## them (carving, dissolve, explode, morph), and level of detail draws a
## prefix of each part.
@export var surface_count := -1


func get_surface_count() -> int:
	var n := size()
	return n if surface_count < 0 or surface_count > n else surface_count


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


## Returns a cloud with exactly `count` points: a prefix of each part (surface
## and interior) when shrinking, since each part is in progressive order, and
## random repeats when growing. Keeps the surface/interior layout.
func resampled(count: int, rng_seed := 7) -> PointCloudData:
	var n := size()
	if n == count or n == 0:
		return self
	var ns := get_surface_count()
	var new_ns := clampi(roundi(float(count) * ns / n), 0, count)
	if ns == n:
		new_ns = count
	var idx := PackedInt32Array()
	idx.resize(count)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	for i in count:
		if i < new_ns:
			idx[i] = i if i < ns else rng.randi_range(0, maxi(ns - 1, 0))
		else:
			var k := i - new_ns
			idx[i] = ns + k if ns + k < n else rng.randi_range(mini(ns, n - 1), n - 1)
	var out := picked(idx)
	out.surface_count = new_ns if ns < n else -1
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
	# Restore the [surface | interior] layout, each part interleaved, so level of
	# detail still draws an even sample of every piece.
	var ns_a := n_before if surface_count < 0 else mini(surface_count, n_before)
	var ns_b := o.get_surface_count()
	var surf := PackedInt32Array()
	var inner := PackedInt32Array()
	for i in n_before:
		if i < ns_a:
			surf.append(i)
		else:
			inner.append(i)
	for i in o.size():
		if i < ns_b:
			surf.append(n_before + i)
		else:
			inner.append(n_before + i)
	# Interleave the two pieces evenly so any prefix samples both (keeps the
	# progressive order level of detail relies on, approximately).
	surf = _interleave(surf, ns_a)
	inner = _interleave(inner, n_before - ns_a)
	var order := surf.duplicate()
	order.append_array(inner)
	var re := picked(order)
	positions = re.positions
	normals = re.normals
	colors = re.colors
	curvatures = re.curvatures
	bone_indices = re.bone_indices
	bone_weights = re.bone_weights
	surface_count = surf.size()
	recompute_aabb()


## Merges a[0, split) and a[split, end) by their relative position, so a
## prefix of the result takes the same fraction of each.
static func _interleave(a: PackedInt32Array, split: int) -> PackedInt32Array:
	var na := split
	var nb := a.size() - split
	var out := PackedInt32Array()
	out.resize(a.size())
	var i := 0
	var j := 0
	for k in a.size():
		var take_a := j >= nb or (i < na and float(i) / maxf(na, 1) <= float(j) / maxf(nb, 1))
		if take_a:
			out[k] = a[i]
			i += 1
		else:
			out[k] = a[split + j]
			j += 1
	return out


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
