extends Node3D
## Demo world: everything you see is a PointCloud — the ground, the props, the
## player and the enemy. Aim at something and play with it.

const MORPH_POINTS := 400000
const GROUND_SIZE := 50.0
const GROUND_TILE := 5.0

var player: PointPlayer
var worm: PointWorm
var props: Array[StaticBody3D] = []
var target: PointCloud          # cloud under the crosshair
var target_body: CollisionObject3D
var target_hit := Vector3.ZERO

var quality: PointCloudQuality
var blend_post: ColorRect
var _ground_tiles: Array[PointCloud] = []
var _info: Label
var _status: Label
var _fire_cd := 0.0
var _paint_hue := 0.0
# Intro: everything starts packed into a singularity in the middle of the screen.
enum Intro { NONE, WAIT, BANG, ENTER }
var intro := Intro.NONE
## Set to 0..1 to drive the hover from code (tests); -1 = follow the mouse.
var intro_hover_override := -1.0
var _intro_cam: Camera3D
var _intro_centre := Vector3.ZERO
var _intro_prox := 0.0
var _intro_crack := 0.0
var _intro_jolt := 0.0
var _intro_shake := 0.0
var _intro_hush := 0.0
var _intro_enter_from := Vector3.ZERO
var _intro_flash := 0.0
var _intro_rays: ColorRect
var _hud_layer: CanvasLayer
const BULLET_SPEED := 90.0
const BULLET_POOL := 8
var _bullets: Array[Dictionary] = []   # pooled bullets, each a small cloud of atoms


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
		cloud.prepare_interaction()
	# Warm the morph cache in the background so E reacts instantly.
	for p in props:
		if not p.has_meta("shapes"):
			var cloud: PointCloud = p.get_meta("cloud")
			cloud.prepare_morph_target(_sphere_target(cloud))
	quality = PointCloudQuality.new()
	quality.name = "Quality"
	add_child(quality)
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Played when the demo is the game itself, not when a test embeds it.
	if get_parent() == get_tree().root:
		start_intro()


# ================================================================ intro

## Packs every atom in the scene (ground, props, worm, player) into a small
## swarming ball in the middle of the screen and waits for a click on it.
func start_intro() -> void:
	intro = Intro.WAIT
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.set_physics_process(false)
	_hud_layer.visible = false
	_intro_cam = Camera3D.new()
	_intro_cam.fov = 60.0
	_intro_cam.far = 300.0
	add_child(_intro_cam)
	# Straight behind the player's eyes, looking the same way: the whole
	# intro is seen along the player's own line of sight, and entering the
	# player at the end is a single move along that one axis.
	_intro_cam.global_transform = player.camera.global_transform
	_intro_cam.global_position += player.camera.global_basis.z * 6.5
	_intro_cam.current = true
	_intro_centre = _intro_cam.global_position - _intro_cam.global_basis.z * 7.0
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		var cloud := c as PointCloud
		cloud.gather_center = _intro_centre
		cloud.gather_reach = 50.0
		cloud.gather_burst = 70.0
		# The floor is laid first, then everything on it, then the player.
		if cloud in _ground_tiles:
			cloud.gather_window = Vector2(0.0, 0.17)
			cloud.gather_direct = true  # the scattered cloud falls straight into the floor
		elif player.is_ancestor_of(cloud):
			cloud.gather_window = Vector2(0.92, 1.0)
		else:
			cloud.gather_window = Vector2(0.4, 0.9)
		cloud.gather = 1.0
	# Beams of light that break out of the ball when it's clicked.
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	_intro_rays = ColorRect.new()
	_intro_rays.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro_rays.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro_rays.material = ShaderMaterial.new()
	(_intro_rays.material as ShaderMaterial).shader = preload("res://demo/singularity_rays.gdshader")
	layer.add_child(_intro_rays)


## Clicked: the ball cracks five times. With each crack two beams of light
## break out, the ball jolts and the camera moves in. Then it explodes, and
## the world is built from the scattered atoms, the player last. Finally the
## camera drops into the player's head and control begins.
func intro_bang() -> void:
	if intro != Intro.WAIT:
		return
	intro = Intro.BANG
	var tw := create_tween()
	var gaps := [0.0, 0.8, 0.65, 0.5, 0.4]
	for i in gaps.size():
		tw.tween_interval(gaps[i] + 0.001)
		tw.tween_callback(_intro_crack_step.bind(i))
	tw.tween_interval(0.5)
	# A held breath: the beams go out and the ball pulls tight and still...
	tw.tween_property(self, "_intro_crack", 0.0, 0.12)
	tw.parallel().tween_property(self, "_intro_hush", 1.0, 0.12)
	tw.tween_interval(0.75)
	# ...then it goes off.
	tw.tween_callback(_intro_release)
	# The flash of the explosion; the beams die with it.
	tw.tween_property(self, "_intro_flash", 0.0, 0.8).from(1.0).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(self, "_intro_crack", 0.0, 0.5)
	tw.tween_interval(8.0)
	tw.tween_callback(func():
		intro = Intro.ENTER
		_intro_enter_from = _intro_cam.global_position)
	# Into the player's eyes: one straight move along the line of sight.
	tw.tween_method(func(k: float):
		_intro_cam.global_position = _intro_enter_from.lerp(player.camera.global_position, k)
		_intro_cam.fov = lerpf(60.0, player.camera.fov, k), 0.0, 1.0, 1.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_end_intro)


func _intro_crack_step(i: int) -> void:
	_intro_jolt = 1.0
	var tw := create_tween()
	tw.tween_property(self, "_intro_crack", (i + 1) / 5.0, 0.12)
	_intro_shake = maxf(_intro_shake, 0.22)
	# The camera lurches closer: a quarter of the remaining distance each time.
	var to := _intro_cam.global_position.lerp(_intro_centre, 0.25)
	tw.parallel().tween_property(_intro_cam, "global_position", to, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _intro_release() -> void:
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		var cloud := c as PointCloud
		cloud.create_tween().tween_property(cloud, "gather", 0.0, 7.8)
	# The blast shakes the camera hard and throws it back.
	_intro_shake = 1.0
	var back := _intro_cam.global_position + _intro_cam.global_basis.z * 6.0
	create_tween().tween_property(_intro_cam, "global_position", back, 1.0) \
			.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		(c as PointCloud).gather_eye = back


func _end_intro() -> void:
	intro = Intro.NONE
	player.camera.current = true
	_intro_cam.queue_free()
	_intro_cam = null
	_intro_rays.get_parent().queue_free()
	_intro_rays = null
	player.set_physics_process(true)
	_hud_layer.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _update_intro(delta: float) -> void:
	# The ball loosens and glows as the mouse comes near the middle.
	var size := get_viewport().get_visible_rect().size
	var prox := intro_hover_override
	if prox < 0.0:
		var d := (get_viewport().get_mouse_position() - size * 0.5).length() / (size.y * 0.45)
		prox = clampf(1.0 - d, 0.0, 1.0)
	if intro != Intro.WAIT:
		prox = 0.0  # clicked: it pulls tight again before it cracks
	_intro_prox = lerpf(_intro_prox, prox, 1.0 - exp(-6.0 * delta))
	_intro_jolt = lerpf(_intro_jolt, 0.0, 1.0 - exp(-7.0 * delta))
	# Screen shake: a jolt per crack, a long violent one for the explosion.
	_intro_shake = lerpf(_intro_shake, 0.0, 1.0 - exp(-2.4 * delta))
	if _intro_cam:
		_intro_cam.h_offset = randf_range(-1.0, 1.0) * _intro_shake * 0.35
		_intro_cam.v_offset = randf_range(-1.0, 1.0) * _intro_shake * 0.35
	var cracking := clampf(0.12 * _intro_crack + _intro_jolt, 0.0, 1.0) * (1.0 - _intro_hush)
	var heat := 0.3 + 1.2 * _intro_prox + 0.5 * _intro_crack + 0.8 * _intro_jolt
	var radius := 0.15 * (1.0 + 0.7 * _intro_prox) * (1.0 - 0.45 * _intro_hush)
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		var cloud := c as PointCloud
		if cloud.gather <= 0.0:
			continue
		cloud.gather_center = _intro_centre  # (moving clouds: keep it in place)
		cloud.gather_radius = radius
		cloud.gather_heat = heat
		cloud.gather_agitate = cracking
	if _intro_rays and _intro_cam:
		var m := _intro_rays.material as ShaderMaterial
		var c2 := _intro_cam.unproject_position(_intro_centre)
		var edge := _intro_cam.unproject_position(_intro_centre + _intro_cam.global_basis.x * radius)
		# Canvas FRAGCOORD is in window pixels, y down like the canvas.
		m.set_shader_parameter(&"centre", c2)
		m.set_shader_parameter(&"ball_px", maxf(c2.distance_to(edge), 2.0))
		m.set_shader_parameter(&"crack", _intro_crack)
		m.set_shader_parameter(&"flash", _intro_flash)


func _intro_click_hits(pos: Vector2) -> bool:
	var size := get_viewport().get_visible_rect().size
	return (pos - size * 0.5).length() < size.y * 0.16


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

	# Light edge-aware smoothing over the 3D image (F9 toggles it).
	var post := CanvasLayer.new()
	post.layer = 0  # above the 3D view, below the HUD (layer 1)
	add_child(post)
	blend_post = ColorRect.new()
	blend_post.set_anchors_preset(Control.PRESET_FULL_RECT)
	blend_post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var post_mat := ShaderMaterial.new()
	post_mat.shader = preload("res://demo/blend_post.gdshader")
	blend_post.material = post_mat
	post.add_child(blend_post)
	blend_post.visible = false  # off by default: it would soften the beads

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.92, 0.82)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	# Two cascades over a shorter range: every cascade redraws all casters.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 35.0
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

	# The ground is split into tiles: tiles outside the view are culled and
	# distant ones draw fewer points (level of detail).
	var grid_tex := _grid_texture()
	var per_tile := int(1500000 * (GROUND_TILE * GROUND_TILE) / (size * size))
	var tiles := int(size / GROUND_TILE)
	for tz in tiles:
		for tx in tiles:
			var center := Vector3((tx + 0.5) * GROUND_TILE - size * 0.5, 0, (tz + 0.5) * GROUND_TILE - size * 0.5)
			var cloud := PointCloud.new()
			cloud.name = "Tile%d_%d" % [tx, tz]
			cloud.position = center
			cloud.data = PointSampler.plane(Vector2(GROUND_TILE, GROUND_TILE), per_tile, {
				"fill": PointSampler.Fill.SHELL, "fill_fraction": 0.3, "thickness": 0.25,
				"seed": tz * tiles + tx + 1,
				"color_fn": func(p: Vector3, _n, _c, inside: bool) -> Color:
					if inside:
						return Color(0.35, 0.12, 0.05).lerp(Color(1.0, 0.5, 0.1), clampf(-p.y * 4.0, 0.0, 1.0))
					return Color.WHITE,
			})
			# The grid comes from a texture sampled per pixel, so lines stay
			# crisp; the offset keeps the pattern continuous across tiles.
			cloud.surface_texture = grid_tex
			cloud.texture_tile = Vector3(4, 4, 4)
			cloud.texture_offset = Vector3(-1, 0, -1) - center
			cloud.debris_gravity = Vector3(0, -8, 0)
			cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # nothing below it to shade
			# Flat and textured: resting floor beads are invisible either way,
			# so a few extra beads up close are plenty.
			cloud.max_amplification = 1
			cloud.lod_spacing_scale = 4.0
			cloud.bead_overlap = 0.8  # evenly spread flat tiles: less overlap is enough
			body.add_child(cloud)
			_ground_tiles.append(cloud)
	body.set_meta("cloud", _ground_tiles[0])
	body.set_meta("cloud_at", func(pos: Vector3) -> PointCloud:
		var i := clampi(int((pos.x + size * 0.5) / GROUND_TILE), 0, tiles - 1)
		var j := clampi(int((pos.z + size * 0.5) / GROUND_TILE), 0, tiles - 1)
		return _ground_tiles[j * tiles + i])


func _build_props() -> void:
	# The shape-shifter: a solid cube that morphs between several shapes.
	# All targets have the same count and are matched to each other in a
	# chain up front, so morphs cost nothing at runtime. (match_order keeps the
	# random point order that level of detail relies on.)
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
	for i in range(1, shapes.size()):
		shapes[i] = PointSampler.match_order(shapes[i - 1], shapes[i])
	var colliders: Array[Shape3D] = []
	for s in shapes:
		var b := BoxShape3D.new()
		b.size = s.aabb.size.max(Vector3.ONE * 0.3)
		colliders.append(b)
	var morpher := _make_prop("Shape-shifter", shapes[0], Vector3(0, 1.6, 0), colliders[0])
	# Upload the other shapes to the GPU in the background, so every morph
	# starts instantly.
	var morph_cloud: PointCloud = morpher.get_meta("cloud")
	for i in range(1, shapes.size()):
		morph_cloud.prepare_morph_target(shapes[i], false)
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

	# A block of a different element: stone. Its atoms are heavy grains that
	# are thrown out by a hit, fall, bounce and stay where they land.
	var rock_rng := RandomNumberGenerator.new()
	rock_rng.seed = 11
	var rock := PointSampler.box(Vector3(2, 2, 2), 400000, {"fill": PointSampler.Fill.SOLID,
		"color_fn": func(_p, _n, _c, inside: bool) -> Color:
			var g := rock_rng.randf_range(0.42, 0.62) * (0.8 if inside else 1.0)
			return Color(g * 0.92, g * 0.97, g * 1.08)})
	var rb := BoxShape3D.new()
	rb.size = Vector3(2, 2, 2)
	var rock_body := _make_prop("Stone block", rock, Vector3(4.5, 1.0, 2.0), rb)
	var rock_cloud := rock_body.get_meta("cloud") as PointCloud
	rock_cloud.element = PointElement.stone()
	rock_cloud.roughness = 0.95

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
	if intro != Intro.NONE:
		_update_intro(delta)
		return
	_update_target()
	_update_bullets(delta)
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
	if intro != Intro.NONE:
		if intro == Intro.WAIT and event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT and _intro_click_hits(event.position):
			intro_bang()
		return
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
	if event.is_action_pressed("detail_down") or event.is_action_pressed("detail_up"):
		quality.enabled = false
		var f := 1.25 if event.is_action_pressed("detail_down") else 0.8
		PointCloud.lod_spacing_px = clampf(PointCloud.lod_spacing_px * f, 1.0, 10.0)
	elif event.is_action_pressed("res_down") or event.is_action_pressed("res_up"):
		var f := 0.85 if event.is_action_pressed("res_down") else 1.0 / 0.85
		quality.resolution_scale = clampf(quality.resolution_scale * f, 0.4, 1.0)
	elif event.is_action_pressed("detail_auto"):
		quality.enabled = not quality.enabled
	elif event.is_action_pressed("toggle_blend"):
		blend_post.visible = not blend_post.visible
	elif event.is_action_pressed("switch_renderer") and not OS.has_feature("editor"):
		preload("res://launcher/launcher.gd").toggle_renderer_and_restart(get_tree())
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
	if col.has_meta("cloud_at"):
		target = col.get_meta("cloud_at").call(hit["position"])
		target_body = col
		target_hit = hit["position"]
	elif col.has_meta("cloud"):
		target = col.get_meta("cloud")
		target_body = col
		target_hit = hit["position"]


## Fires a bullet (itself a little cloud of atoms) at whatever is under the
## crosshair. The hit lands when the bullet arrives.
func shoot() -> void:
	if target == null:
		return
	var cam := player.camera
	var from := cam.global_position + cam.global_basis * Vector3(0.16, -0.12, -0.6)
	var b := _free_bullet()
	if b.is_empty():
		_apply_hit(target, target_body, target_hit, (target_hit - from).normalized())
		return
	var cloud: PointCloud = b["cloud"]
	cloud.explode = 0.0
	cloud.global_position = from
	cloud.visible = true
	b["busy"] = true
	b["from"] = from
	b["to"] = target_hit
	b["t"] = 0.0
	b["dur"] = maxf(from.distance_to(target_hit) / BULLET_SPEED, 0.001)
	b["target"] = target
	b["body"] = target_body


func _free_bullet() -> Dictionary:
	for b in _bullets:
		if not b["busy"]:
			return b
	if _bullets.size() >= BULLET_POOL:
		return {}
	var cloud := PointCloud.new()
	cloud.data = _bullet_data()
	cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cloud.emission_strength = 0.8
	cloud.visible = false
	add_child(cloud)
	var b := {"cloud": cloud, "busy": false}
	_bullets.append(b)
	return b


func _bullet_data() -> PointCloudData:
	if not has_meta("bullet_data"):
		set_meta("bullet_data", PointSampler.sphere(0.05, 1500, {"color": Color(1.0, 0.82, 0.35)}))
	return get_meta("bullet_data")


func _update_bullets(delta: float) -> void:
	for b in _bullets:
		if not b["busy"] or not b.has("dur"):
			continue
		var cloud: PointCloud = b["cloud"]
		b["t"] += delta
		var k: float = b["t"] / b["dur"]
		if k < 1.0:
			cloud.global_position = (b["from"] as Vector3).lerp(b["to"], k)
			continue
		if b["dur"] > 0.0:
			# Arrived: hit the target, and the bullet itself bursts into its atoms.
			cloud.global_position = b["to"]
			var dir := ((b["to"] as Vector3) - (b["from"] as Vector3)).normalized()
			if is_instance_valid(b["target"]):
				_apply_hit(b["target"], b["body"], b["to"], dir)
			b["dur"] = -1.0
			var tw := cloud.create_tween()
			tw.tween_property(cloud, "explode", 0.45, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_callback(func():
				cloud.visible = false
				b["busy"] = false)


func _apply_hit(cloud: PointCloud, body: CollisionObject3D, hit: Vector3, dir: Vector3) -> void:
	# For elements with real physics, the blast is centred a little inside the
	# surface, so the chips are thrown back out towards the shooter.
	var physical := cloud.element != null and cloud.element.lands
	cloud.carve(hit + dir * 0.12 if physical else hit, 0.32, 2.5, 0.35, -dir * 1.1 if physical else Vector3.ZERO)
	if not physical:
		cloud.impact(hit, 0.1, 5.0, 0.3, 3.0)  # stone doesn't ripple
	if is_instance_valid(body) and body.has_meta("on_hit"):
		body.get_meta("on_hit").call(hit)


## The "turn into a sphere" target of a cloud: a Callable, so it is generated
## on a worker thread. The same Callable is reused as the cache key, so once
## prepared (see _ready) the morph starts instantly.
func _sphere_target(cloud: PointCloud) -> Callable:
	if not cloud.has_meta("sphere_gen"):
		var r := cloud.data.aabb.get_longest_axis_size() * 0.5
		var count := cloud.data.size()
		# Mesh access must happen on the main thread; the sampling itself
		# (the slow part) then runs on a worker.
		var snap := PointSampler.snapshot(PointSampler.sphere_mesh(r))
		cloud.set_meta("sphere_gen", func() -> PointCloudData:
			return PointSampler.sphere_from_snapshot(snap, r, count, {"color": Color(0.9, 0.9, 1.0)}))
	return cloud.get_meta("sphere_gen")


func morph_target() -> void:
	var body := target_body
	if not body.has_meta("shapes"):
		# Anything else morphs into a sphere and back to its own shape.
		if not target.has_meta("home"):
			target.set_meta("home", target.data)
			target.morph_to(_sphere_target(target), 3.2)
		else:
			target.morph_to(target.get_meta("home"), 3.2)
			target.remove_meta("home")
		return
	var shapes: Array[PointCloudData] = body.get_meta("shapes")
	var colliders: Array[Shape3D] = body.get_meta("colliders")
	var i: int = (body.get_meta("shape_index") + 1) % shapes.size()
	body.set_meta("shape_index", i)
	target.morph_to(shapes[i], 3.6, false)
	(body.get_child(0) as CollisionShape3D).shape = colliders[i]


# ================================================================ hud / input

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud_layer = layer
	_info = Label.new()
	_info.position = Vector2(16, 12)
	_info.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info.text = "\n".join([
		"WASD move · Shift sprint · Space jump · mouse look (first person)",
		"LMB shoot (chip points off) · RMB paint",
		"Aim at something, then:",
		"  E morph · Q dissolve / reassemble · F explode",
		"  V vibrate · G wobble · H heal holes",
		"[ / ] lower / raise resolution · - / = less / more detail",
		"0 automatic detail on/off (off by default)",
		"F9 smoothing filter on/off · F10 switch renderer (Compatibility is faster)",
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
	var drawn := 0
	for c in get_tree().get_nodes_in_group(&"point_clouds"):
		total += (c as PointCloud).get_dot_count()
		drawn += (c as PointCloud).get_drawn_dot_count()
	var aimed := "-"
	if target:
		aimed = target_body.name
		if target == worm.cloud:
			aimed += " (hp %d)" % worm.hp
	if target:
		aimed += "\n%s points · up to %d beads each" % [_group_digits(target.get_dot_count()), target.density]
	var renderer := RenderingServer.get_current_rendering_method()
	var hint := ""
	if quality.is_maxed_out() and renderer != "gl_compatibility":
		hint = "\nstill slow: press F10 for the lighter renderer"
	_status.text = "%d FPS · %s\n%s bead slots for %s points\n%s%s\ntarget: %s" % [Engine.get_frames_per_second(),
		renderer.replace("gl_", "").replace("_", " "), _group_digits(drawn), _group_digits(total),
		quality.describe(), hint, aimed]


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
		"detail_down": KEY_MINUS, "detail_up": KEY_EQUAL, "detail_auto": KEY_0,
		"res_down": KEY_BRACKETLEFT, "res_up": KEY_BRACKETRIGHT,
		"switch_renderer": KEY_F10, "toggle_blend": KEY_F9,
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
