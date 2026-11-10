extends Node3D
## Checks that models other than simple solids hold up: an open, thin, curved
## shell (a vase made with SurfaceTool) and a figure built from several
## meshes with different materials, converted with PointCloud.convert_scene.
##   godot --path . res://tests/custom_model_test.tscn -- --out=/dir
## Saves: rest, the first frame of an explosion (should look like rest), mid
## explosion, mid morph, and after the morph.

var out_dir := "user://"
var clouds: Array[PointCloud] = []
var vase: PointCloud
var frame := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	PointCloud.lod_spacing_px = 1.25
	# An open vase: thin shell, visible inside and out.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 24
	var segs := 48
	for i in rings:
		for j in segs:
			var quad := []
			for c in [[0, 0], [1, 0], [1, 1], [0, 1]]:
				var v := float(i + c[0]) / rings
				var a := float(j + c[1]) / segs * TAU
				var r := 0.35 + 0.3 * sin(v * 3.6) + 0.12 * v
				quad.append([Vector3(cos(a) * r, v * 1.6, sin(a) * r), Color.from_hsv(0.08 + 0.1 * v, 0.7, 0.9)])
			for k in [0, 2, 1, 0, 3, 2]:
				st.set_color(quad[k][1])
				st.add_vertex(quad[k][0])
	st.generate_normals()
	var vase_mi := MeshInstance3D.new()
	vase_mi.mesh = st.commit()
	var vm := StandardMaterial3D.new()
	vm.vertex_color_use_as_albedo = true
	vm.cull_mode = BaseMaterial3D.CULL_DISABLED
	vase_mi.material_override = vm
	vase_mi.position = Vector3(-1.3, 0, 0)
	add_child(vase_mi)
	# A figure from several meshes and materials.
	var fig := Node3D.new()
	fig.position = Vector3(1.2, 0, 0)
	add_child(fig)
	var parts := [
		[CapsuleMesh.new(), Vector3(0, 0.8, 0), Vector3.ZERO, Color(0.2, 0.6, 0.9)],
		[SphereMesh.new(), Vector3(0, 1.75, 0), Vector3.ZERO, Color(0.95, 0.8, 0.65)],
		[BoxMesh.new(), Vector3(0.55, 1.0, 0), Vector3(0, 0, 0.6), Color(0.9, 0.3, 0.3)],
		[CylinderMesh.new(), Vector3(-0.55, 1.0, 0), Vector3(0, 0, -0.6), Color(0.3, 0.8, 0.4)],
	]
	(parts[0][0] as CapsuleMesh).radius = 0.35
	(parts[0][0] as CapsuleMesh).height = 1.6
	(parts[1][0] as SphereMesh).radius = 0.3
	(parts[1][0] as SphereMesh).height = 0.6
	(parts[2][0] as BoxMesh).size = Vector3(0.2, 0.9, 0.2)
	(parts[3][0] as CylinderMesh).top_radius = 0.1
	(parts[3][0] as CylinderMesh).bottom_radius = 0.1
	(parts[3][0] as CylinderMesh).height = 0.9
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[0]
		mi.position = p[1]
		mi.rotation = p[2]
		var m := StandardMaterial3D.new()
		m.albedo_color = p[3]
		mi.material_override = m
		fig.add_child(mi)
	clouds = PointCloud.convert_scene(self, 60000.0)
	vase = clouds[0]
	var cam := Camera3D.new()
	cam.position = Vector3(0.2, 2.3, 4.2)
	add_child(cam)
	cam.look_at(Vector3(0, 0.8, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.4, 0.4, 0.45)
	add_child(env)
	var floor_cloud := PointCloud.new()
	floor_cloud.data = PointSampler.plane(Vector2(8, 8), 200000, {"color": Color(0.5, 0.5, 0.55)})
	floor_cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_cloud)


func _shot(name: String) -> void:
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("custom_%s.png" % name))


func _process(_d: float) -> void:
	frame += 1
	match frame:
		8:
			_shot("1_rest")
			for c in clouds:
				c.explode = 0.000001
		12:
			_shot("2_effect_started")
			for c in clouds:
				c.explode = 0.5
		16:
			_shot("3_exploding")
			for c in clouds:
				c.explode = 0.0
			vase.morph_to(PointSampler.sphere(0.7, 1000, {"color": Color(0.9, 0.4, 0.8)}), 1.0)
			vase.morph_finished.connect(func(): frame = 1000)
		1004:
			_shot("5_morphed")
			get_tree().quit()
	if frame < 1000 and frame > 16 and vase.morph > 0.5 and not has_meta("mid"):
		set_meta("mid", true)
		_shot("4_morphing")
	if frame > 900 and frame < 1000:
		get_tree().quit()
