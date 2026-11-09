extends Node
## Scripted showcase of the demo, meant for Godot's Movie Maker mode:
##   godot --path . --write-movie out.avi --fixed-fps 30 res://tests/demo_video.tscn
## Movie Maker runs the game at a fixed frame rate however slowly the machine
## renders, so the result plays at real speed.

const MAIN := preload("res://demo/main.tscn")

var main: Node3D  # demo/main.gd
var cam: Camera3D
var caption: Label
var counter: Label
var t := 0.0
var _done := {}
var _shot_cd := 0.0
var _cam_pos := Vector3(0, 3, 8)
var _cam_look := Vector3(0, 1.5, 0)
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 42
	main = MAIN.instantiate()
	add_child(main)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for c in main.get_children():
		if c is CanvasLayer:
			c.visible = false
		elif c is DirectionalLight3D:
			# One shadow cascade instead of four: much faster to render offline.
			(c as DirectionalLight3D).directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.far = 300.0
	add_child(cam)
	cam.current = true
	_build_overlay()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	caption = Label.new()
	caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	caption.offset_top = -90
	caption.offset_bottom = -40
	caption.offset_left = -600
	caption.offset_right = 600
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 30)
	caption.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	caption.add_theme_constant_override("shadow_offset_x", 2)
	caption.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(caption)
	counter = Label.new()
	counter.position = Vector2(24, 18)
	counter.add_theme_font_size_override("font_size", 20)
	counter.add_theme_color_override("font_shadow_color", Color.BLACK)
	layer.add_child(counter)


func _once(key: String) -> bool:
	if _done.has(key):
		return false
	_done[key] = true
	return true


func _process(delta: float) -> void:
	t += delta
	var body: StaticBody3D = main.props[0]
	var cube: PointCloud = body.get_meta("cloud")
	var shapes: Array[PointCloudData] = body.get_meta("shapes")
	var target_pos := _cam_pos
	var target_look := _cam_look
	_shot_cd -= delta

	if t < 6.0:
		_say("Everything you see is made of points")
		var a := t * 0.35 + 0.3
		target_pos = Vector3(sin(a) * 6.5, 3.0, cos(a) * 6.5)
		target_look = Vector3(0, 1.4, 0)
	elif t < 9.5:
		_say("A solid cube: %s individual dots" % _digits(cube.get_dot_count()))
		var k := smoothstep(6.0, 9.5, t)
		target_pos = Vector3(1.4, 2.4, 2.4).lerp(Vector3(0.9, 2.0, 2.3), k) * lerpf(1.6, 1.0, k)
		target_look = Vector3(0, 1.6, 0)
	elif t < 14.0:
		_say("Shoot it: points chip off and fly")
		target_pos = Vector3(1.2, 2.4, 4.2)
		target_look = Vector3(0, 1.6, 0.5)
		if _shot_cd <= 0.0:
			_shot_cd = 0.22
			var hit := cube.to_global(Vector3(_rng.randf_range(-0.8, 0.8), _rng.randf_range(-0.8, 0.8), 1.0))
			cube.carve(hit, 0.3, 2.2)
			cube.impact(hit, 0.08, 5.0, 0.3, 3.0)
	elif t < 16.5:
		_say("...and heal")
		if _once("heal"):
			cube.heal(1.8)
	elif t < 26.0:
		_say("Morph: every point travels to a new shape")
		var d := 6.0 if t < 22.5 else 9.0
		var a := 0.5 + (t - 16.5) * 0.08
		target_pos = Vector3(sin(a) * d, 2.4, cos(a) * d)
		target_look = Vector3(0, 1.5, 0)
		if _once("m1"):
			_morph(body, cube, shapes, 1)
		if t > 19.5 and _once("m2"):
			_morph(body, cube, shapes, 2)
		if t > 22.5 and _once("m3"):
			_morph(body, cube, shapes, 3)
	elif t < 29.0:
		_say("...and back")
		if _once("m0"):
			_morph(body, cube, shapes, 0)
		target_pos = Vector3(3.0, 2.8, 5.0)
	elif t < 34.0:
		if t < 31.5:
			_say("Vibrate")
			cube.vibrate_amplitude = 0.03
		else:
			_say("Wobble")
			cube.vibrate_amplitude = 0.0
			cube.wobble_amplitude = 0.12
		target_pos = Vector3(2.6, 2.6, 4.2)
	elif t < 40.0:
		cube.wobble_amplitude = 0.0
		_say("Dissolve... and reassemble")
		if _once("dis"):
			cube.dissolve_directional = 0.6
			cube.dissolve_out(2.6)
		if t > 37.0 and _once("re"):
			cube.reassemble(2.6)
		target_pos = Vector3(3.0, 3.0, 5.5)
	elif t < 42.5:
		_say("Explode")
		if _once("ex"):
			cube.explode_pulse(1.4, 2.2)
	elif t < 52.0:
		_say("Skinned, animated enemy, also points")
		var w: PointWorm = main.worm
		var mid := w.global_position + w.global_basis.z * PointWorm.LENGTH * 0.5 + Vector3.UP * 0.5
		var out := Vector3(mid.x, 0, mid.z).normalized()
		target_pos = mid + out * 4.5 + Vector3.UP * 1.6 - w.global_basis.z * 1.5
		target_look = mid
		if _once("worm"):
			w.hp = 7
			_cam_pos = target_pos
			_cam_look = target_look
		if t > 44.0 and t < 47.0 and _shot_cd <= 0.0:
			_shot_cd = 0.25
			var bone := _rng.randi_range(1, PointWorm.SEGMENTS)
			var bp := w.skeleton.global_transform * w.skeleton.get_bone_global_pose(bone).origin
			var hit := bp + (target_pos - bp).normalized() * 0.35
			w.cloud.carve(hit, 0.3, 2.0)
			w.cloud.impact(hit, 0.08, 4.0, 0.3, 3.0)
			w.hitbox.get_meta("on_hit").call(hit)
	elif t < 58.0:
		_say("The player is points too  ·  so is the paint")
		var pl: PointPlayer = main.player
		if _once("walk"):
			pl.position = Vector3(-5.5, 0.1, 4.5)
			pl.walk_speed = 1.8
			pl.set("_yaw", -PI / 2.0)  # walk towards +x
			Input.action_press("move_forward")
		target_pos = pl.global_position + Vector3(0.5, 2.0, 5.0)
		target_look = pl.global_position.lerp(Vector3(0, 1.4, 0), 0.4) + Vector3(0, 0.8, 0)
		var u := clampf((t - 53.0) / 4.5, 0.0, 1.0)
		if u > 0.0:
			cube.paint(cube.to_global(Vector3(lerpf(-0.9, 0.9, u), sin(u * 25.0) * 0.6, 1.0)), 0.3,
				Color.from_hsv(u, 0.85, 1.0), 0.5)
	else:
		Input.action_release("move_forward")
		get_tree().quit()

	var s := 1.0 - exp(-3.0 * delta)
	_cam_pos = _cam_pos.lerp(target_pos, s)
	_cam_look = _cam_look.lerp(target_look, s)
	cam.global_position = _cam_pos
	cam.look_at(_cam_look)

	var total := 0
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		total += (c as PointCloud).get_dot_count()
	counter.text = "%s dots on screen" % _digits(total)


func _morph(body: StaticBody3D, cube: PointCloud, shapes: Array[PointCloudData], i: int) -> void:
	body.set_meta("shape_index", i)
	cube.morph_to(shapes[i], 2.4, false)


func _say(text: String) -> void:
	caption.text = text


static func _digits(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
