extends Node
## Drives the demo without input and saves screenshots, for automated checks:
##   godot --path . res://tests/demo_capture.tscn -- --out=/some/dir
## It steps through: overview, shooting the cube, morphing, dissolving, the worm.

const MAIN := preload("res://demo/main.tscn")
var main: Node3D  # demo/main.gd
var out_dir := "user://"
var frame := 0
var t0 := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	t0 = Time.get_ticks_msec()
	main = MAIN.instantiate()
	add_child(main)
	print("demo built in ", Time.get_ticks_msec() - t0, " ms")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _shot(n: String) -> void:
	var p := out_dir.path_join(n + ".png")
	get_viewport().get_texture().get_image().save_png(p)
	print("shot ", p, "  fps=", Engine.get_frames_per_second(), "  target=", main.target_body.name if main.target else "-")


func _aim(at: Vector3) -> void:
	# Point the player's camera at a world position.
	var pl: PointPlayer = main.player
	var cam_pos := pl.camera.global_position
	var d := (at - cam_pos).normalized()
	pl.set("_yaw", atan2(-d.x, -d.z))
	pl.set("_pitch", asin(d.y))


func _process(_d: float) -> void:
	frame += 1
	var body: StaticBody3D = main.props[0]
	var cube: PointCloud = body.get_meta("cloud")
	# Effects are set directly (not tweened) so shots don't depend on frame rate.
	match frame:
		2:
			_aim(Vector3(0, 1.6, 0))
		4:
			_shot("01_overview")
			for i in 5:
				cube.carve(cube.to_global(Vector3(randf_range(-0.6, 0.6), 1.0, randf_range(-0.6, 0.6))), 0.35, 1.5)
			cube.carve(cube.to_global(Vector3(0.3, 0.2, 1.0)), 0.5, 1.5)
			cube.carve(cube.to_global(Vector3(-0.5, -0.3, 1.0)), 0.3, 1.5)
		6:
			_shot("02_carved")
		7:
			cube.restore()
			var shapes: Array[PointCloudData] = body.get_meta("shapes")
			cube.set_morph_target(shapes[2])
			cube.morph = 0.45
		8:
			_shot("03_morph_half")
			cube.morph = 0.0
			cube.dissolve_directional = 0.6
			cube.dissolve = 0.45
		9:
			_shot("04_dissolve")
			cube.dissolve = 0.0
			cube.explode_center = Vector3.ZERO
			cube.explode = 0.5
		10:
			_shot("05_explode")
			cube.explode = 0.0
			var w: PointCloud = main.worm.cloud
			_aim(w.global_transform * w.data.aabb.get_center())
		12:
			_shot("06_worm")
			get_tree().quit()
