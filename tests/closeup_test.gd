extends Node3D
## Renders a cube face from close up (the hardest case for point clouds) and
## saves a screenshot per distance:
##   godot --path . res://tests/closeup_test.tscn -- --out=/dir
## Prints how many bead slots the cube processed at each distance.

var out_dir := "user://"
var cube: PointCloud
var cam: Camera3D
var dists := [2.5, 1.0, 0.4, 0.15]
var step := 0
var frame := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	cube = PointCloud.new()
	cube.data = PointSampler.box(Vector3(2, 2, 2), 400000, {"color": Color(1.0, 0.5, 0.15)})
	add_child(cube)
	cam = Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.02
	add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 25, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.45, 0.45, 0.5)
	add_child(env)
	_place()


func _place() -> void:
	# Looking at the +Z face, slightly off-axis.
	cam.position = Vector3(0.25, 0.15, 1.0 + dists[step])
	cam.look_at(Vector3(0.1, 0.05, 1.0))


func _process(_d: float) -> void:
	frame += 1
	if frame % 4 != 0:
		return
	var path := out_dir.path_join("closeup_%s.png" % str(dists[step]))
	get_viewport().get_texture().get_image().save_png(path)
	print("CLOSEUP dist=%.2f m  beads/point=%d  bead slots=%d" % [dists[step], cube.density, cube.get_drawn_dot_count()])
	step += 1
	if step >= dists.size():
		get_tree().quit()
		return
	_place()
