@tool
class_name PointSampler
extends RefCounted
## Turns meshes into PointCloudData.
##
## Points are scattered over the triangles proportionally to their area, so
## density is even everywhere. Colour comes from the material (albedo colour,
## albedo texture, vertex colours), and skin weights are copied so animated
## characters keep animating.
##
## Options dictionary for from_mesh() and the shape helpers:
##   fill           Fill.SURFACE / Fill.SHELL / Fill.SOLID (see below)
##   fill_fraction  share of points placed inside the model (0..1, default 0.4)
##   thickness      depth of the SHELL fill (default 0.1)
##   materials      Array of Materials overriding the mesh's surface materials
##   color          a Color replacing material colours
##   color_fn       Callable(pos: Vector3, normal: Vector3, color: Color, inside: bool) -> Color
##   transform      Transform3D applied to the result
##   seed           random seed (default 1)

## Point diameter relative to the average spacing between surface points.
const SIZE_FACTOR := 1.6

enum Fill {
	## Points only on the surface: cheapest, looks identical while intact.
	SURFACE,
	## Some points pushed inward along the normal by up to `thickness`.
	## Works for any shape; gives holes a visible wall.
	SHELL,
	## Some points pulled towards the centre: a truly solid interior for
	## convex / star-shaped models (boxes, spheres, capsules...).
	SOLID,
}


static func from_mesh(mesh: Mesh, count: int, opts: Dictionary = {}) -> PointCloudData:
	if mesh == null or count <= 0:
		return PointCloudData.new()
	return from_snapshot(snapshot(mesh, opts.get("materials", [])), count, opts)


## Copies everything sampling needs out of a mesh: vertex arrays, material
## colours and albedo images. Reading meshes and textures talks to the
## RenderingServer, so call this on the main thread; the snapshot can then be
## sampled with from_snapshot() on any thread (e.g. a worker, without stalls).
static func snapshot(mesh: Mesh, materials: Array = []) -> Dictionary:
	var surfaces := []
	for s in mesh.get_surface_count():
		var mat: Material = materials[s] if s < materials.size() else null
		if mat == null:
			mat = mesh.surface_get_material(s)
		var info := {"albedo": Color.WHITE, "image": null, "uv_scale": Vector2.ONE,
			"uv_offset": Vector2.ZERO, "vcol": mat == null, "arrays": []}
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			info["albedo"] = bm.albedo_color
			info["vcol"] = bm.vertex_color_use_as_albedo
			info["image"] = _readable_image(bm.albedo_texture)
			info["uv_scale"] = Vector2(bm.uv1_scale.x, bm.uv1_scale.y)
			info["uv_offset"] = Vector2(bm.uv1_offset.x, bm.uv1_offset.y)
		elif mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			var a = sm.get_shader_parameter("albedo")
			if a is Color:
				info["albedo"] = a
			var t = sm.get_shader_parameter("texture_albedo")
			if t is Texture2D:
				info["image"] = _readable_image(t)
		if not (mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES):
			info["arrays"] = mesh.surface_get_arrays(s)
		surfaces.append(info)
	return {"surfaces": surfaces, "aabb": mesh.get_aabb()}


## True if every triangle edge is shared by another triangle (a watertight
## model). Open or thin-shell meshes can be seen from both sides.
static func is_closed(snap: Dictionary) -> bool:
	var edges := {}
	var q := 1.0 / maxf((snap["aabb"] as AABB).get_longest_axis_size() * 1e-5, 1e-9)
	for info in snap["surfaces"]:
		var arrays: Array = info["arrays"]
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index = arrays[Mesh.ARRAY_INDEX]
		var has_index: bool = index != null and index.size() > 0
		var n: int = index.size() if has_index else verts.size()
		var keys := PackedInt64Array()
		keys.resize(verts.size())
		for i in verts.size():
			# Weld by position: UV seams and hard edges duplicate vertices.
			keys[i] = hash(Vector3i((verts[i] * q).round()))
		for t in range(0, n - 2, 3):
			for e in 3:
				var a: int = keys[index[t + e] if has_index else t + e]
				var b: int = keys[index[t + (e + 1) % 3] if has_index else t + (e + 1) % 3]
				if a == b:
					continue
				var k := Vector2i(mini(a, b), maxi(a, b))
				edges[k] = edges.get(k, 0) + 1
	for k in edges:
		if edges[k] == 1:
			return false
	return not edges.is_empty()


## Samples a snapshot() of a mesh. Pure data work: safe on worker threads.
static func from_snapshot(snap: Dictionary, count: int, opts: Dictionary = {}) -> PointCloudData:
	var out := PointCloudData.new()
	if count <= 0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts.get("seed", 1))
	var fill: int = opts.get("fill", Fill.SURFACE)
	var fill_fraction: float = clampf(opts.get("fill_fraction", 0.4), 0.0, 1.0)
	if fill == Fill.SURFACE:
		fill_fraction = 0.0
	var thickness: float = opts.get("thickness", 0.1)
	var has_override := opts.has("color")
	var override_color: Color = opts.get("color", Color.WHITE)
	var color_fn: Callable = opts.get("color_fn", Callable())
	var use_fn := color_fn.is_valid()

	# ---- Merge every triangle surface into flat arrays.
	var V := PackedVector3Array()
	var N := PackedVector3Array()
	var UV := PackedVector2Array()
	var C := PackedColorArray()
	var B := PackedInt32Array()     # 4 per vertex
	var W := PackedFloat32Array()   # 4 per vertex
	var tri := PackedInt32Array()   # 3 vertex indices per triangle
	var tri_surf := PackedInt32Array()
	var surf_color: Array[Color] = []
	var surf_image: Array[Image] = []
	var surf_uv_scale: Array[Vector2] = []
	var surf_uv_offset: Array[Vector2] = []
	var surf_vcol: Array[bool] = []
	var any_bones := false

	var snap_surfaces: Array = snap["surfaces"]
	for s in snap_surfaces.size():
		var info: Dictionary = snap_surfaces[s]
		surf_color.append(info["albedo"])
		surf_image.append(info["image"])
		surf_uv_scale.append(info["uv_scale"])
		surf_uv_offset.append(info["uv_offset"])
		surf_vcol.append(info["vcol"])
		var arr: Array = info["arrays"]
		if arr.is_empty():
			continue
		var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nv := sv.size()
		if nv == 0:
			continue
		var base := V.size()
		V.append_array(sv)

		var sn = arr[Mesh.ARRAY_NORMAL]
		if sn is PackedVector3Array and sn.size() == nv:
			N.append_array(sn)
		else:
			var z := PackedVector3Array()
			z.resize(nv)
			N.append_array(z)

		var suv = arr[Mesh.ARRAY_TEX_UV]
		if suv is PackedVector2Array and suv.size() == nv:
			UV.append_array(suv)
		else:
			var z := PackedVector2Array()
			z.resize(nv)
			UV.append_array(z)

		var sc = arr[Mesh.ARRAY_COLOR]
		if sc is PackedColorArray and sc.size() == nv:
			C.append_array(sc)
		else:
			var z := PackedColorArray()
			z.resize(nv)
			z.fill(Color.WHITE)
			C.append_array(z)

		var sb = arr[Mesh.ARRAY_BONES]
		var sw = arr[Mesh.ARRAY_WEIGHTS]
		var bpv := 0
		if sb is PackedInt32Array and sw is PackedFloat32Array and nv > 0:
			bpv = sb.size() / nv
		var b4 := PackedInt32Array()
		var w4 := PackedFloat32Array()
		b4.resize(nv * 4)
		w4.resize(nv * 4)
		if bpv >= 4:
			any_bones = true
			for v in nv:
				for k in 4:
					b4[v * 4 + k] = sb[v * bpv + k]
					w4[v * 4 + k] = sw[v * bpv + k]
		else:
			for v in nv:
				w4[v * 4] = 1.0
		B.append_array(b4)
		W.append_array(w4)

		var si = arr[Mesh.ARRAY_INDEX]
		if si is PackedInt32Array and si.size() >= 3:
			for i in range(0, si.size() - 2, 3):
				tri.append(base + si[i])
				tri.append(base + si[i + 1])
				tri.append(base + si[i + 2])
				tri_surf.append(s)
		else:
			for i in range(0, nv - 2, 3):
				tri.append(base + i)
				tri.append(base + i + 1)
				tri.append(base + i + 2)
				tri_surf.append(s)

	var tri_count := tri_surf.size()
	if tri_count == 0:
		return out

	# ---- Cumulative triangle areas for area-weighted picking.
	var cum := PackedFloat64Array()
	cum.resize(tri_count)
	var total := 0.0
	for t in tri_count:
		var a := V[tri[t * 3]]
		total += 0.5 * (V[tri[t * 3 + 1]] - a).cross(V[tri[t * 3 + 2]] - a).length()
		cum[t] = total
	if total <= 0.0:
		return out
	var center: Vector3 = (snap["aabb"] as AABB).get_center()

	# ---- Scatter.
	# Triangles are chosen stratified (each gets its fair share of points) and
	# points inside a triangle follow the R2 low-discrepancy sequence. That
	# spreads points far more evenly than plain random sampling, so surfaces
	# close up with smaller points.
	#
	# The output order is *progressive*: strata are visited in bit-reversed
	# order and each triangle hands out its R2 points in that order, so every
	# prefix of the list is itself evenly spread over the surface. Level of
	# detail draws such a prefix, and it stays gap-free at every detail level.
	out.positions.resize(count)
	out.normals.resize(count)
	out.colors.resize(count)
	out.curvatures.resize(count * 8)
	if any_bones:
		out.bone_indices.resize(count * 4)
		out.bone_weights.resize(count * 4)

	# Curvature tensor per triangle: the symmetric S that best explains how
	# the vertex normals change along the edges (dN = S dP), fitted by least
	# squares in the triangle's plane. 0 for flat faces, I/r on a sphere.
	var tri_s := PackedFloat32Array()
	tri_s.resize(tri_count * 8)
	for t in tri_count:
		var a0 := tri[t * 3]
		var fnorm := (V[a0] - V[tri[t * 3 + 2]]).cross(V[a0] - V[tri[t * 3 + 1]])
		if fnorm.length_squared() < 1e-20:
			continue
		fnorm = fnorm.normalized()
		var tx := (V[tri[t * 3 + 1]] - V[a0]).normalized()
		var ty := fnorm.cross(tx)
		var ee := Vector3.ZERO  # sum of e e^T: xx, xy, yy
		var de := [0.0, 0.0, 0.0, 0.0]  # sum of d e^T: 00, 01, 10, 11
		var ok := true
		for e in 3:
			var ia := tri[t * 3 + e]
			var ib := tri[t * 3 + (e + 1) % 3]
			if N[ia].length_squared() < 0.5 or N[ib].length_squared() < 0.5:
				ok = false
				break
			var dp := V[ia] - V[ib]
			var dn := N[ia] - N[ib]
			var ex := dp.dot(tx)
			var ey := dp.dot(ty)
			var dx := dn.dot(tx)
			var dy := dn.dot(ty)
			ee += Vector3(ex * ex, ex * ey, ey * ey)
			de[0] += dx * ex
			de[1] += dx * ey
			de[2] += dy * ex
			de[3] += dy * ey
		var det := ee.x * ee.z - ee.y * ee.y
		if not ok or absf(det) < 1e-20:
			continue
		# A = DE * EE^-1, then symmetrised.
		var i00 := ee.z / det
		var i01 := -ee.y / det
		var i11 := ee.x / det
		var a00: float = de[0] * i00 + de[1] * i01
		var a01: float = de[0] * i01 + de[1] * i11
		var a10: float = de[2] * i00 + de[3] * i01
		var a11: float = de[2] * i01 + de[3] * i11
		var sym := (a01 + a10) * 0.5
		# S = A00 tx tx^T + sym (tx ty^T + ty tx^T) + A11 ty ty^T
		var k := t * 8
		tri_s[k] = a00 * tx.x * tx.x + 2.0 * sym * tx.x * ty.x + a11 * ty.x * ty.x
		tri_s[k + 1] = a00 * tx.y * tx.y + 2.0 * sym * tx.y * ty.y + a11 * ty.y * ty.y
		tri_s[k + 2] = a00 * tx.z * tx.z + 2.0 * sym * tx.z * ty.z + a11 * ty.z * ty.z
		tri_s[k + 4] = a00 * tx.x * tx.y + sym * (tx.x * ty.y + ty.x * tx.y) + a11 * ty.x * ty.y
		tri_s[k + 5] = a00 * tx.x * tx.z + sym * (tx.x * ty.z + ty.x * tx.z) + a11 * ty.x * ty.z
		tri_s[k + 6] = a00 * tx.y * tx.z + sym * (tx.y * ty.z + ty.y * tx.z) + a11 * ty.y * ty.z

	var tri_counter := PackedInt32Array()
	tri_counter.resize(tri_count)
	# Surface points first (one evenly spread pass), then interior points.
	var n_inside := int(count * fill_fraction)
	# Output order: [surface | interior] (see PointCloudData.surface_count),
	# each part progressive.
	var n_surface := count - n_inside
	var surface_order := progressive_order(n_surface)
	var inside_order := progressive_order(n_inside)
	var skin_gap := sqrt(total / maxf(1.0, n_surface)) * SIZE_FACTOR * 1.5

	for o in count:
		var inside := o >= n_surface
		var r := (surface_order[o] + rng.randf()) * total / n_surface if not inside \
				else (inside_order[o - n_surface] + rng.randf()) * total / n_inside
		var t := mini(cum.bsearch(r), tri_count - 1)
		var i0 := tri[t * 3]
		var i1 := tri[t * 3 + 1]
		var i2 := tri[t * 3 + 2]
		var nth := tri_counter[t]
		tri_counter[t] = nth + 1
		var q1 := fposmod(t * 0.6180339887 + nth * 0.7548776662, 1.0)
		var q2 := fposmod(t * 0.4142135624 + nth * 0.5698402910, 1.0)
		# Area-preserving square -> triangle warp.
		var sq := sqrt(q1)
		var w := 1.0 - sq
		var u := sq * (1.0 - q2)
		var v := sq * q2
		var p := V[i0] * w + V[i1] * u + V[i2] * v
		var n := N[i0] * w + N[i1] * u + N[i2] * v
		if n.length_squared() < 1e-8:
			# Same winding convention as Godot's own normal generation.
			n = (V[i0] - V[i2]).cross(V[i0] - V[i1])
		n = n.normalized()

		var s := tri_surf[t]
		var col := surf_color[s]
		var img := surf_image[s]
		if img != null:
			var uv := (UV[i0] * w + UV[i1] * u + UV[i2] * v) * surf_uv_scale[s] + surf_uv_offset[s]
			var iw := img.get_width()
			var ih := img.get_height()
			var x := posmod(int(floor(uv.x * iw)), iw)
			var y := posmod(int(floor(uv.y * ih)), ih)
			col *= img.get_pixel(x, y)
		if surf_vcol[s]:
			col *= C[i0] * w + C[i1] * u + C[i2] * v
		if has_override:
			col = override_color

		if inside:
			# Interior points stay a few dot-widths under the surface so they
			# can't poke through between surface dots.
			if fill == Fill.SOLID:
				var dist := (p - center).length()
				var max_scale := maxf(0.0, 1.0 - skin_gap / maxf(dist, 1e-6))
				p = center + (p - center) * pow(rng.randf(), 1.0 / 3.0) * max_scale
				# Radial normal: exposed interior shades smoothly instead of
				# carrying the normal of whichever face the point came from.
				if (p - center).length_squared() > 1e-10:
					n = (p - center).normalized()
			else:
				p -= n * lerpf(minf(skin_gap, thickness), thickness, rng.randf())
		if use_fn:
			col = color_fn.call(p, n, col, inside)
		# Alpha masks PointCloud.surface_texture: off for interior points.
		col.a = 0.0 if inside else 1.0

		out.positions[o] = p
		out.normals[o] = n
		out.colors[o] = col
		if not inside:
			for c in 8:
				out.curvatures[o * 8 + c] = tri_s[t * 8 + c]
		if any_bones:
			var dom := i0
			if u >= w and u >= v:
				dom = i1
			elif v >= w and v >= u:
				dom = i2
			for k in 4:
				out.bone_indices[o * 4 + k] = float(B[dom * 4 + k])
				out.bone_weights[o * 4 + k] = W[dom * 4 + k]

	out.suggested_point_size = sqrt(total / maxf(1.0, n_surface)) * SIZE_FACTOR
	out.surface_count = n_surface
	if n_inside > 0:
		# Interior points fill a volume; size their dots for their own spacing
		# so a cut through the model (a hole) looks like solid material.
		var volume := total * thickness
		if fill == Fill.SOLID:
			var mean_r := 0.0
			for i in mini(n_surface, 512):
				mean_r += out.positions[i].distance_to(center)
			volume = total * (mean_r / maxf(mini(n_surface, 512), 1)) / 3.0  # cone-volume estimate
		out.interior_point_size = pow(volume / n_inside, 1.0 / 3.0) * 1.1

	if opts.has("transform"):
		var xf: Transform3D = opts["transform"]
		out.positions = xf * out.positions
		out.normals = Transform3D(xf.basis.orthonormalized(), Vector3.ZERO) * out.normals
		out.suggested_point_size *= xf.basis.get_scale().x
		out.interior_point_size *= xf.basis.get_scale().x
		out.curvatures = PointCloudData.transformed_tensors(out.curvatures, xf.basis)
	out.recompute_aabb()
	out.closed = is_closed(snap)
	return out


## A permutation of [0, n) in bit-reversed order (0, n/2, n/4, 3n/4, ...):
## every prefix samples the range evenly.
static func progressive_order(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	if n <= 1:
		return out
	var bits := 0
	while (1 << bits) < n:
		bits += 1
	var size := 1 << bits
	var rev := PackedInt32Array()
	rev.resize(size)
	var k := 0
	for i in size:
		var r := (rev[i >> 1] >> 1) | ((i & 1) << (bits - 1))
		rev[i] = r
		if r < n:
			out[k] = r
			k += 1
	return out


## Picks a point count from a surface density (points per square metre).
static func count_for_density(mesh: Mesh, points_per_m2: float, min_count := 1000, max_count := 4000000) -> int:
	var area := 0.0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and idx.size() >= 3:
			for i in range(0, idx.size() - 2, 3):
				area += 0.5 * (v[idx[i + 1]] - v[idx[i]]).cross(v[idx[i + 2]] - v[idx[i]]).length()
		else:
			for i in range(0, v.size() - 2, 3):
				area += 0.5 * (v[i + 1] - v[i]).cross(v[i + 2] - v[i]).length()
	return clampi(int(area * points_per_m2), min_count, max_count)


# ---------------------------------------------------------------- shapes
# Convenience wrappers around Godot's primitive meshes. All accept the same
# options as from_mesh().

static func box(size: Vector3, count: int, opts: Dictionary = {}) -> PointCloudData:
	var m := BoxMesh.new()
	m.size = size
	return from_mesh(m, count, _with(opts, {"fill": Fill.SOLID}))


static func sphere(radius: float, count: int, opts: Dictionary = {}) -> PointCloudData:
	return sphere_from_snapshot(snapshot(sphere_mesh(radius)), radius, count, opts)


static func sphere_mesh(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 48
	m.rings = 24
	return m


## sphere() for worker threads: take the snapshot of sphere_mesh(radius) on
## the main thread first.
static func sphere_from_snapshot(snap: Dictionary, radius: float, count: int, opts: Dictionary = {}) -> PointCloudData:
	var o := _with(opts, {"fill": Fill.SOLID})
	var data := from_snapshot(snap, count, o)
	# Snap surface points onto the true sphere so no facets show.
	var p := data.positions
	var nrm := data.normals
	var curv := data.curvatures
	for i in p.size():
		var l := p[i].length()
		if l > radius * 0.97:
			p[i] = p[i] / l * radius
			nrm[i] = p[i] / radius
			curv[i * 8] = 1.0 / radius
			curv[i * 8 + 1] = 1.0 / radius
			curv[i * 8 + 2] = 1.0 / radius
			for c in [4, 5, 6]:
				curv[i * 8 + c] = 0.0
	data.positions = p
	data.normals = nrm
	data.curvatures = curv
	return data


static func torus(inner_radius: float, outer_radius: float, count: int, opts: Dictionary = {}) -> PointCloudData:
	var m := TorusMesh.new()
	m.inner_radius = inner_radius
	m.outer_radius = outer_radius
	m.rings = 64
	m.ring_segments = 24
	return from_mesh(m, count, _with(opts, {"fill": Fill.SHELL, "thickness": (outer_radius - inner_radius) * 0.5}))


static func capsule(radius: float, height: float, count: int, opts: Dictionary = {}) -> PointCloudData:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = height
	return from_mesh(m, count, _with(opts, {"fill": Fill.SOLID}))


static func cylinder(radius: float, height: float, count: int, opts: Dictionary = {}) -> PointCloudData:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	return from_mesh(m, count, _with(opts, {"fill": Fill.SOLID}))


static func plane(size: Vector2, count: int, opts: Dictionary = {}) -> PointCloudData:
	var m := PlaneMesh.new()
	m.size = size
	return from_mesh(m, count, opts)


## Extruded 3D text, e.g. as a morph target.
static func text(string: String, count: int, font_size := 64, depth := 0.15, opts: Dictionary = {}) -> PointCloudData:
	var m := TextMesh.new()
	m.text = string
	m.font_size = font_size
	m.depth = depth
	m.pixel_size = 0.02
	return from_mesh(m, count, _with(opts, {"fill": Fill.SHELL, "thickness": depth * 0.5}))


# ---------------------------------------------------------------- morph helper

## Reorders `target` so that point i of `source` and point i of the result sit
## in similar relative places (sorted by height band, then angle). Morphs then
## look like the shape flowing into the new one instead of a random swarm.
static func match_order(source: PointCloudData, target: PointCloudData) -> PointCloudData:
	var n := source.size()
	if target.size() != n:
		target = target.resampled(n)
	var ns := source.get_surface_count()
	var idx := PackedInt32Array()
	idx.resize(n)
	if ns == target.get_surface_count():
		# Surface pairs with surface and interior with interior, so the result
		# keeps the [surface | interior] layout.
		for part in [[0, ns], [ns, n]]:
			var src_rank := _spatial_order(source, part[0], part[1])
			var dst_rank := _spatial_order(target, part[0], part[1])
			for k in src_rank.size():
				idx[src_rank[k]] = dst_rank[k]
		var out := target.picked(idx)
		out.surface_count = source.surface_count
		return out
	var src_all := _spatial_order(source)
	var dst_all := _spatial_order(target)
	for k in n:
		idx[src_all[k]] = dst_all[k]
	return target.picked(idx)


## Returns the cloud reordered by height band and angle. Clouds that were all
## sorted this way (and have equal counts) already pair up nicely, so you can
## call PointCloud.morph_to(target, duration, false) and skip match_order().
##
## Note: sorted clouds lose their progressive order, which level of detail relies
## on (it draws a prefix of the points). Prefer match_order().
static func sort_spatially(d: PointCloudData) -> PointCloudData:
	return d.picked(_spatial_order(d))


## Indices in [from, to) ordered by height band, then angle.
static func _spatial_order(d: PointCloudData, from := 0, to := -1) -> PackedInt32Array:
	if to < 0:
		to = d.size()
	var n := to - from
	var bands := 40
	var c := d.aabb.get_center()
	var inv := Vector3.ONE / d.aabb.size.max(Vector3.ONE * 1e-4)
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		var q := (d.positions[from + i] - c) * inv
		var band := clampi(int((q.y + 0.5) * bands), 0, bands - 1)
		var ang := clampi(int((atan2(q.z, q.x) / TAU + 0.5) * 65535.0), 0, 65535)
		keys[i] = (band << 40) | (ang << 24) | (from + i)
	keys.sort()
	var order := PackedInt32Array()
	order.resize(n)
	for k in n:
		order[k] = keys[k] & 0xFFFFFF
	return order


static func _with(opts: Dictionary, defaults: Dictionary) -> Dictionary:
	var o := defaults.duplicate()
	o.merge(opts, true)
	return o


static func _readable_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img = img.duplicate()
		if img.decompress() != OK:
			return null
	return img
