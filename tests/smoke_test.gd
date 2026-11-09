extends Node3D
## Renders a few clouds and saves a screenshot. Run with:
##   godot --path . res://tests/smoke_test.tscn -- --shot=out.png

var frames := 0
var shot_path := "user://smoke.png"

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
	var t0 := Time.get_ticks_msec()
	var cube := PointCloud.new()
	cube.data = PointSampler.box(Vector3(2, 2, 2), 300000, {"color": Color(1.0, 0.55, 0.2)})
	print("box 300k sample+upload: ", Time.get_ticks_msec() - t0, " ms")
	cube.position = Vector3(-2.5, 0, 0)
	add_child(cube)

	t0 = Time.get_ticks_msec()
	var sph := PointCloud.new()
	sph.data = PointSampler.sphere(1.2, 200000, {"color": Color(0.3, 0.7, 1.0)})
	print("sphere 200k: ", Time.get_ticks_msec() - t0, " ms")
	add_child(sph)

	t0 = Time.get_ticks_msec()
	var tor := PointCloud.new()
	tor.data = PointSampler.torus(0.6, 1.0, 150000, {"color_fn": func(p, n, c, inside): return Color.from_hsv(atan2(p.z, p.x) / TAU + 0.5, 0.7, 1.0)})
	print("torus 150k: ", Time.get_ticks_msec() - t0, " ms")
	tor.position = Vector3(2.8, 0, 0)
	tor.rotation_degrees = Vector3(70, 0, 0)
	add_child(tor)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.5, 5.5)
	add_child(cam)
	cam.look_at(Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.08, 0.09, 0.11)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.4, 0.4, 0.45)
	add_child(env)

	t0 = Time.get_ticks_msec()
	var g := PointGrid.build(cube.data.positions, cube.data.aabb)
	print("grid 300k: ", Time.get_ticks_msec() - t0, " ms")
	t0 = Time.get_ticks_msec()
	var m := PointSampler.match_order(cube.data, sph.data)
	print("match_order 300k: ", Time.get_ticks_msec() - t0, " ms")

	cube.carve(cube.to_global(Vector3(0.5, 1.0, 1.0)), 0.6, 1.0)
	sph.vibrate_amplitude = 0.01

func _process(_d: float) -> void:
	frames += 1
	if frames == 30:
		var img := get_viewport().get_texture().get_image()
		img.save_png(shot_path)
		print("saved ", shot_path)
		get_tree().quit()
