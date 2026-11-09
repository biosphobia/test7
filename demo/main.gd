extends Node3D
## Demo world: everything you see is a PointCloud — the ground, the props, the
## player and the enemy. Aim at something and play with it.

const MORPH_POINTS := 400000
## Dots drawn per stored point on most objects (see PointCloud.density).
const DETAIL := 4
const GROUND_DETAIL := 2

var player: PointPlayer
var worm: PointWorm
var props: Array[StaticBody3D] = []
var target: PointCloud          # cloud under the crosshair
var target_body: CollisionObject3D
var target_hit := Vector3.ZERO

var _info: Label
var _status: Label
var _fire_cd := 0.0
var _paint_hue := 0.0


func _ready() -> void:
	_setup_input()
	_setup_environment()
	_build_ground()
	_build_props()

	worm = PointWorm.new()
	worm.name = "Worm"
	add_child(worm)

	player = PointPlayer.new()
	player.name = "Player"
	player.position = Vector3(0, 0.1, 6.5)
	add_child(player)

	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		var cloud := c as PointCloud
		cloud.density = GROUND_DETAIL if cloud.get_parent().name == "Ground" else DETAIL
		cloud.prepare_interaction()
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ================================================================ world

func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.05, 0.07, 0.14)
	sky_mat.sky_horizon_color = Color(0.32, 0.26, 0.36)
	sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)
	sky_mat.ground_horizon_color = Color(0.32, 0.26, 0.36)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.2
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.fog_enabled = true
	env.fog_light_color = Color(0.2, 0.18, 0.26)
	env.fog_density = 0.012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.92, 0.82)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)


func _build_ground() -> void:
	var size := 50.0
	var body := StaticBody3D.new()
	body.name = "Ground"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	cs.shape = box
	cs.position.y = -0.5
	body.add_child(cs)
	add_child(body)

	var cloud := PointCloud.new()
	cloud.data = PointSampler.plane(Vector2(size, size), 1500000, {
		"fill": PointSampler.Fill.SHELL, "fill_fraction": 0.25, "thickness": 0.5,
		"color_fn": func(p: Vector3, _n, _c, inside: bool) -> Color:
			if inside:
				return Color(0.35, 0.12, 0.05).lerp(Color(1.0, 0.5, 0.1), clampf(-p.y * 2.0, 0.0, 1.0))
			return Color.WHITE,
	})
	# The grid comes from a texture sampled per pixel, so lines stay crisp.
	cloud.surface_texture = _grid_texture()
	cloud.texture_tile = Vector3(4, 4, 4)
	cloud.texture_offset = Vector3(-1, 0, -1)
	cloud.debris_gravity = Vector3(0, -8, 0)
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # nothing below it to shade
	body.add_child(cloud)
	body.set_meta("cloud", cloud)


func _build_props() -> void:
	# The shape-shifter: a solid cube that morphs between several shapes.
	# All targets have the same count and are pre-sorted, so morphs are free.
	# Interior points get a hot glowing colour, revealed when you chip it.
	var hot_core := func(_p, _n, c: Color, inside: bool) -> Color:
		return Color(1.0, 0.85, 0.3) if inside else c
	var shapes: Array[PointCloudData] = [
		PointSampler.box(Vector3(2, 2, 2), MORPH_POINTS, {"color": Color(1.0, 0.5, 0.15), "color_fn": hot_core}),
		PointSampler.sphere(1.3, MORPH_POINTS, {"color_fn": func(p: Vector3, _n, _c, inside: bool) -> Color:
			return Color(1.0, 0.9, 0.4) if inside else Color.from_hsv(0.55 + p.y * 0.08, 0.75, 1.0)}),
		PointSampler.torus(0.7, 1.4, MORPH_POINTS, {"color_fn": func(p: Vector3, _n, _c, _in) -> Color:
			return Color.from_hsv(atan2(p.z, p.x) / TAU + 0.5, 0.75, 1.0),
			"transform": Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3.ZERO)}),
		PointSampler.text("POINTS", MORPH_POINTS, 96, 0.4, {"color": Color(0.3, 1.0, 0.6)}),
	]
	for i in shapes.size():
		shapes[i] = PointSampler.sort_spatially(shapes[i])
	var colliders: Array[Shape3D] = []
	for s in shapes:
		var b := BoxShape3D.new()
		b.size = s.aabb.size.max(Vector3.ONE * 0.3)
		colliders.append(b)
	var morpher := _make_prop("Shape-shifter", shapes[0], Vector3(0, 1.6, 0), colliders[0])
	morpher.set_meta("shapes", shapes)
	morpher.set_meta("colliders", colliders)
	morpher.set_meta("shape_index", 0)

	# A textured crate: colour comes from a procedural albedo texture.
	var crate_mat := StandardMaterial3D.new()
	crate_mat.albedo_texture = ImageTexture.create_from_image(_crate_image())
	var crate_mesh := BoxMesh.new()
	crate_mesh.size = Vector3(1.6, 1.6, 1.6)
	crate_mesh.material = crate_mat
	var crate := PointSampler.from_mesh(crate_mesh, 250000, {"fill": PointSampler.Fill.SOLID, "fill_fraction": 0.35,
		"color_fn": func(_p, _n, _c, inside: bool) -> Color: return Color(0.45, 0.28, 0.12) if inside else Color.WHITE})
	var cb := BoxShape3D.new()
	cb.size = crate_mesh.size
	var crate_cloud := _make_prop("Crate", crate, Vector3(-6, 0.8, -3), cb).get_meta("cloud") as PointCloud
	# One texture tile per face, sampled per pixel.
	crate_cloud.surface_texture = crate_mat.albedo_texture
	crate_cloud.texture_tile = crate_mesh.size
	crate_cloud.texture_offset = -crate_mesh.size * 0.5

	# Monoliths.
	var cols := [Color(0.3, 0.55, 1.0), Color(0.9, 0.25, 0.4), Color(0.4, 0.95, 0.5)]
	for i in 3:
		var d := PointSampler.box(Vector3(1.2, 4.0, 1.2), 200000, {"color": cols[i]})
		var mb := BoxShape3D.new()
		mb.size = Vector3(1.2, 4.0, 1.2)
		var p := _make_prop("Monolith %d" % (i + 1), d, Vector3(6 + i * 2.5, 2.0, -4 - i * 2.0), mb)
		p.rotation.y = 0.4 * i

	# A floating jelly orb that wobbles all the time.
	var orb := PointSampler.sphere(1.0, 250000, {"color_fn": func(p: Vector3, _n, _c, _in) -> Color:
		return Color(0.75, 0.35, 1.0).lerp(Color(0.2, 0.9, 1.0), clampf(p.y * 0.5 + 0.5, 0.0, 1.0))})
	var os := SphereShape3D.new()
	os.radius = 1.0
	var orb_body := _make_prop("Jelly orb", orb, Vector3(-4, 2.5, 4), os)
	var orb_cloud := orb_body.get_meta("cloud") as PointCloud
	orb_cloud.wobble_amplitude = 0.06
	orb_cloud.wobble_frequency = 2.5
	orb_cloud.emission_strength = 0.25


func _make_prop(prop_name: String, d: PointCloudData, pos: Vector3, shape: Shape3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = prop_name
	body.position = pos
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var cloud := PointCloud.new()
	cloud.data = d
	body.add_child(cloud)
	body.set_meta("cloud", cloud)
	add_child(body)
	props.append(body)
	return body


func _grid_texture() -> ImageTexture:
	# One 4 m tile: a 2x2 checker of 2 m cells with glowing borders.
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := float(x) / n * 2.0
			var v := float(y) / n * 2.0
			var checker := (int(u) + int(v)) & 1
			var c := Color(0.16, 0.17, 0.2) if checker == 0 else Color(0.12, 0.13, 0.16)
			var edge := minf(minf(fposmod(u, 1.0), 1.0 - fposmod(u, 1.0)), minf(fposmod(v, 1.0), 1.0 - fposmod(v, 1.0)))
			c = c.lerp(Color(0.2, 0.75, 0.9), 1.0 - smoothstep(0.012, 0.022, edge))
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _crate_image() -> Image:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var edge := x < 10 or x > 117 or y < 10 or y > 117 or absi(x - y) < 6 or absi(x + y - 127) < 6
			var grain := 0.85 + 0.15 * sin(y * 0.9 + sin(x * 0.15) * 3.0)
			var c := Color(0.85, 0.58, 0.3) * grain if not edge else Color(0.45, 0.28, 0.12)
			c.a = 1.0
			img.set_pixel(x, y, c)
	return img


# ================================================================ interaction

func _process(delta: float) -> void:
	_update_target()
	_fire_cd -= delta
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if Input.is_action_pressed("shoot") and _fire_cd <= 0.0:
			_fire_cd = 0.1
			shoot()
		if Input.is_action_pressed("paint") and target:
			_paint_hue = fmod(_paint_hue + delta * 0.25, 1.0)
			target.paint(target_hit, 0.45, Color.from_hsv(_paint_hue, 0.8, 1.0), 0.3)
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif target:
		if event.is_action_pressed("morph"):
			morph_target()
		elif event.is_action_pressed("dissolve"):
			if target.dissolve < 0.5:
				target.dissolve_out(2.5)
			else:
				target.reassemble(2.0)
		elif event.is_action_pressed("explode"):
			target.explode_pulse(1.2, 1.4)
		elif event.is_action_pressed("vibrate"):
			target.vibrate_amplitude = 0.0 if target.vibrate_amplitude > 0.0 else 0.025
		elif event.is_action_pressed("wobble"):
			target.wobble_amplitude = 0.0 if target.wobble_amplitude > 0.0 else 0.08
		elif event.is_action_pressed("heal"):
			target.heal(1.5)
		elif event.is_action_pressed("density_up"):
			target.density = mini(target.density * 2, 16)
		elif event.is_action_pressed("density_down"):
			target.density = maxi(target.density / 2, 1)
	if event.is_action_pressed("restore"):
		for c in get_tree().get_nodes_in_group(&"point_clouds"):
			(c as PointCloud).restore()


func _update_target() -> void:
	target = null
	var cam := player.camera
	var vp := get_viewport().get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(vp)
	var to := from + cam.project_ray_normal(vp) * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var col: Object = hit["collider"]
	if col.has_meta("cloud"):
		target = col.get_meta("cloud")
		target_body = col
		target_hit = hit["position"]


func shoot() -> void:
	if target == null:
		return
	target.carve(target_hit, 0.32, 2.5)
	target.impact(target_hit, 0.1, 5.0, 0.3, 3.0)
	if target_body.has_meta("on_hit"):
		target_body.get_meta("on_hit").call(target_hit)


func morph_target() -> void:
	var body := target_body
	if not body.has_meta("shapes"):
		# Anything else morphs into a sphere and back to its own shape.
		var own: PointCloudData = target.data
		if not target.has_meta("home"):
			target.set_meta("home", own)
			var r := own.aabb.get_longest_axis_size() * 0.5
			target.morph_to(PointSampler.sphere(r, own.size(), {"color": Color(0.9, 0.9, 1.0)}), 1.8)
		else:
			target.morph_to(target.get_meta("home"), 1.8)
			target.remove_meta("home")
		return
	var shapes: Array[PointCloudData] = body.get_meta("shapes")
	var colliders: Array[Shape3D] = body.get_meta("colliders")
	var i: int = (body.get_meta("shape_index") + 1) % shapes.size()
	body.set_meta("shape_index", i)
	target.morph_to(shapes[i], 2.2, false)
	(body.get_child(0) as CollisionShape3D).shape = colliders[i]


# ================================================================ hud / input

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_info = Label.new()
	_info.position = Vector2(16, 12)
	_info.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info.text = "\n".join([
		"WASD move · Shift sprint · Space jump · mouse look",
		"LMB shoot (chip points off) · RMB paint",
		"Aim at something, then:",
		"  E morph · Q dissolve / reassemble · F explode",
		"  V vibrate · G wobble · H heal holes",
		"  [ / ] fewer / more dots per point",
		"R restore everything · Esc free mouse",
	])
	layer.add_child(_info)
	_status = Label.new()
	_status.anchor_left = 1.0
	_status.anchor_right = 1.0
	_status.offset_left = -360
	_status.offset_right = -16
	_status.offset_top = 12
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_color_override("font_shadow_color", Color.BLACK)
	layer.add_child(_status)
	var build := Label.new()
	var v := _read_version()
	build.text = "build %s" % str(v.get("commit", "dev")).substr(0, 7)
	build.anchor_top = 1.0
	build.anchor_bottom = 1.0
	build.offset_left = 16
	build.offset_top = -34
	build.modulate = Color(1, 1, 1, 0.6)
	layer.add_child(build)
	var cross := Label.new()
	cross.text = "+"
	cross.add_theme_font_size_override("font_size", 28)
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	layer.add_child(cross)


func _update_hud() -> void:
	var total := 0
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		total += (c as PointCloud).get_dot_count()
	var aimed := "-"
	if target:
		aimed = target_body.name
		if target == worm.cloud:
			aimed += " (hp %d)" % worm.hp
	if target:
		aimed += "\n%s dots (%d per point)" % [_group_digits(target.get_dot_count()), target.density]
	_status.text = "%d FPS\n%s dots\ntarget: %s" % [Engine.get_frames_per_second(), _group_digits(total), aimed]


static func _read_version() -> Dictionary:
	if not FileAccess.file_exists("res://version.json"):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://version.json"))
	return parsed if parsed is Dictionary else {}


static func _group_digits(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _setup_input() -> void:
	var keys := {
		"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "morph": KEY_E, "dissolve": KEY_Q,
		"explode": KEY_F, "vibrate": KEY_V, "wobble": KEY_G, "heal": KEY_H, "restore": KEY_R,
		"density_down": KEY_BRACKETLEFT, "density_up": KEY_BRACKETRIGHT,
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action]
			InputMap.action_add_event(action, ev)
	for pair in [["shoot", MOUSE_BUTTON_LEFT], ["paint", MOUSE_BUTTON_RIGHT]]:
		if not InputMap.has_action(pair[0]):
			InputMap.add_action(pair[0])
			var mb := InputEventMouseButton.new()
			mb.button_index = pair[1]
			InputMap.action_add_event(pair[0], mb)
