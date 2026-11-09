class_name PointGrid
extends RefCounted
## Uniform grid over a cloud's rest positions so carve()/paint() only touch
## points near the hit instead of scanning millions. Built once per data set
## (on a worker thread by PointCloud).

const MAX_DIM := 64

var origin := Vector3.ZERO
var cell := 1.0
var dims := Vector3i.ONE
var starts := PackedInt32Array()  # per cell, offset into items (size cells + 1)
var items := PackedInt32Array()   # point indices sorted by cell
var positions := PackedVector3Array()


static func build(points: PackedVector3Array, bounds: AABB) -> PointGrid:
	var g := PointGrid.new()
	g.positions = points
	var b := bounds.grow(0.001)
	g.origin = b.position
	g.cell = maxf(b.get_longest_axis_size() / MAX_DIM, 1e-4)
	g.dims = Vector3i(
		clampi(ceili(b.size.x / g.cell), 1, MAX_DIM),
		clampi(ceili(b.size.y / g.cell), 1, MAX_DIM),
		clampi(ceili(b.size.z / g.cell), 1, MAX_DIM))
	var cells := g.dims.x * g.dims.y * g.dims.z
	var n := points.size()
	var cell_of := PackedInt32Array()
	cell_of.resize(n)
	var counts := PackedInt32Array()
	counts.resize(cells + 1)
	var inv := 1.0 / g.cell
	var dx := g.dims.x
	var dxy := g.dims.x * g.dims.y
	var mx := g.dims - Vector3i.ONE
	for i in n:
		var q := Vector3i(((points[i] - g.origin) * inv).floor()).clamp(Vector3i.ZERO, mx)
		var c := q.x + q.y * dx + q.z * dxy
		cell_of[i] = c
		counts[c + 1] += 1
	for c in cells:
		counts[c + 1] += counts[c]
	g.starts = counts.duplicate()
	g.items.resize(n)
	for i in n:
		var c := cell_of[i]
		g.items[counts[c]] = i
		counts[c] += 1
	return g


## Indices of all points within `radius` of `center` (rest space).
func query(center: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var inv := 1.0 / cell
	var mx := dims - Vector3i.ONE
	var lo := Vector3i(((center - Vector3.ONE * radius - origin) * inv).floor()).clamp(Vector3i.ZERO, mx)
	var hi := Vector3i(((center + Vector3.ONE * radius - origin) * inv).floor()).clamp(Vector3i.ZERO, mx)
	var r2 := radius * radius
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var c := x + y * dims.x + z * dims.x * dims.y
				for k in range(starts[c], starts[c + 1]):
					var i := items[k]
					if positions[i].distance_squared_to(center) <= r2:
						out.append(i)
	return out
