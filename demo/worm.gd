class_name PointWorm
extends Node3D
## Enemy: a skinned mesh driven by a Skeleton3D, converted to points with
## PointCloud.from_mesh_instance(). The points follow the bones on the GPU,
## so any animated character (e.g. an imported .glb with an AnimationPlayer)
## works the same way.

signal died

const SEGMENTS := 8
const LENGTH := 4.2
const MAX_HP := 15

@export var path_radius := 10.0
@export var path_speed := 0.22

var skeleton: Skeleton3D
var cloud: PointCloud
var hitbox: StaticBody3D
var hp := MAX_HP

var _shapes: Array[CollisionShape3D] = []
var _t := 0.0
var _dead := false
var _center := Vector3.ZERO


func _ready() -> void:
	_center = position
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.position.y = 0.45
	add_child(skeleton)
	var seg := LENGTH / SEGMENTS
	for i in SEGMENTS + 1:
		skeleton.add_bone("seg%d" % i)
		if i > 0:
			skeleton.set_bone_parent(i, i - 1)
		skeleton.set_bone_rest(i, Transform3D(Basis(), Vector3.ZERO if i == 0 else Vector3(0, 0, seg)))
	skeleton.reset_bone_poses()

	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = _build_mesh()
	skeleton.add_child(mi)
	mi.skeleton = NodePath("..")

	cloud = PointCloud.from_mesh_instance(mi, 180000, {
		"fill": PointSampler.Fill.SHELL, "fill_fraction": 0.3, "thickness": 0.18,
	})
	cloud.cull_margin = LENGTH
	cloud.dissolve_directional = 0.5
	cloud.dissolve_direction = Vector3.FORWARD
	cloud.dissolve_edge_color = Color(0.7, 1.0, 0.2)
	cloud.debris_gravity = Vector3(0, -6, 0)

	hitbox = StaticBody3D.new()
	hitbox.name = "Worm"
	hitbox.set_meta("cloud", cloud)
	hitbox.set_meta("on_hit", _on_hit)
	skeleton.add_child(hitbox)
	for i in SEGMENTS + 1:
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.5 if i == SEGMENTS else 0.38
		cs.shape = sph
		hitbox.add_child(cs)
		_shapes.append(cs)


func _physics_process(delta: float) -> void:
	_t += delta
	if not _dead:
		# Crawl around a circle, head first (+Z is forward for this rig).
		var a := _t * path_speed
		var pos := _center + Vector3(cos(a), 0, sin(a)) * path_radius
		var tangent := Vector3(-sin(a), 0, cos(a))
		position = pos - tangent * LENGTH * 0.5
		basis = Basis.looking_at(tangent, Vector3.UP, true)

	# Slither: a travelling sine wave down the spine, plus a head bob.
	for i in range(1, SEGMENTS + 1):
		var yaw := sin(_t * 3.5 - i * 0.75) * 0.32
		var pitch := sin(_t * 2.0 - i * 0.5) * 0.06 if i < SEGMENTS else sin(_t * 2.6) * 0.25
		skeleton.set_bone_pose_rotation(i, Quaternion.from_euler(Vector3(pitch, yaw, 0)))

	for i in _shapes.size():
		_shapes[i].position = skeleton.get_bone_global_pose(i).origin


func _on_hit(_pos: Vector3) -> void:
	if _dead:
		return
	hp -= 1
	cloud.vibrate_amplitude = 0.03
	create_tween().tween_property(cloud, "vibrate_amplitude", 0.0, 0.35)
	if hp <= 0:
		_die()


func _die() -> void:
	_dead = true
	hitbox.collision_layer = 0
	died.emit()
	await cloud.dissolve_out(2.5).finished
	await get_tree().create_timer(1.5).timeout
	# Respawn: put carved points back while invisible, then fly everything in.
	cloud.restore()
	cloud.dissolve = 1.0
	await cloud.reassemble(2.5).finished
	hp = MAX_HP
	hitbox.collision_layer = 1
	_dead = false


# ---------------------------------------------------------------- mesh

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := LENGTH / SEGMENTS
	var rings := 64
	var sides := 32
	var verts: Array[Dictionary] = []
	for r in rings + 1:
		var z := LENGTH * r / rings
		var f := z / seg
		var b := clampi(int(f), 0, SEGMENTS - 1)
		var t := clampf(f - b, 0.0, 1.0)
		var radius := 0.22 + 0.2 * sqrt(sin(PI * clampf(z / LENGTH, 0.05, 1.0)))
		for s in sides:
			var a := TAU * s / sides
			var n := Vector3(cos(a), sin(a), 0)
			var stripe := int(z * 3.2) % 2 == 0
			var col := Color(0.55, 0.12, 0.6) if stripe else Color(0.95, 0.3, 0.75)
			if n.y < -0.4:
				col = Color(0.95, 0.85, 0.6)  # belly
			verts.append({"p": n * radius + Vector3(0, 0, z), "n": n, "c": col,
				"b": PackedInt32Array([b, b + 1, 0, 0]), "w": PackedFloat32Array([1.0 - t, t, 0, 0])})
	var quads := []
	for r in rings:
		for s in sides:
			var i0 := r * sides + s
			var i1 := r * sides + (s + 1) % sides
			var i2 := (r + 1) * sides + s
			var i3 := (r + 1) * sides + (s + 1) % sides
			quads.append_array([i0, i2, i1, i1, i2, i3])
	for i in quads:
		_emit(st, verts[i])

	# Tail cap, head and eyes, rigidly attached to the end bones.
	_emit_sphere(st, Vector3(0, 0, 0), 0.24, Color(0.55, 0.12, 0.6), 0)
	_emit_sphere(st, Vector3(0, 0.02, LENGTH), 0.46, Color(0.55, 0.12, 0.6), SEGMENTS)
	for x in [-0.2, 0.2]:
		_emit_sphere(st, Vector3(x, 0.2, LENGTH + 0.32), 0.12, Color(1.0, 0.95, 0.2), SEGMENTS)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


func _emit(st: SurfaceTool, v: Dictionary) -> void:
	st.set_color(v["c"])
	st.set_normal(v["n"])
	st.set_bones(v["b"])
	st.set_weights(v["w"])
	st.add_vertex(v["p"])


func _emit_sphere(st: SurfaceTool, center: Vector3, radius: float, col: Color, bone: int) -> void:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	var arr := sm.get_mesh_arrays()
	var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nv: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var bones := PackedInt32Array([bone, 0, 0, 0])
	var weights := PackedFloat32Array([1, 0, 0, 0])
	for i in idx:
		_emit(st, {"p": pv[i] + center, "n": nv[i], "c": col, "b": bones, "w": weights})
