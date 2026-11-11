class_name PauseMenu
extends Node
## The pause menu. Esc freezes the whole game (the scene tree is paused:
## physics, tweens, morphs in progress, projectiles, the atoms' own clock)
## and every atom the camera can see flies together to build the menu;
## resuming sends each one back and the game carries on exactly where it was.
## This node keeps running while everything else is paused.

const OPEN_TIME := 0.9
const DISTANCE := 2.0

var main: Node3D           # demo/main.gd
var open := false          # the menu is up (or opening)
var amount := 0.0          # 0 = world, 1 = menu
var menu: AtomMenu
var menu_world := Transform3D()

var _base := Transform3D()
var _clouds: Array[PointCloud] = []
var _tween: Tween
var _time := 0.0
var _lean := Vector2.ZERO
var _light: OmniLight3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_light = OmniLight3D.new()
	_light.omni_range = 6.0
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.light_color = Color(1.0, 0.97, 0.92)
	add_child(_light)
	menu = _build()   # built up front: no hitch the first time the game is paused


func _build() -> AtomMenu:
	var m := AtomMenu.new()
	m.add_slab(Rect2(-1.15, -0.8, 2.3, 1.6), -0.28, 0.1, Color(0.1, 0.11, 0.16), 90000)   # back panel, set well back
	m.add_text("PAUSED", Vector2(0, 0.45), 0.24, 0.0, Color(0.95, 0.97, 1.0), 60000)
	m.add_button("resume", "RESUME", Rect2(-0.55, -0.16, 1.1, 0.27), Color(0.15, 0.5, 0.75), Color.WHITE)
	m.add_button("quit", "QUIT", Rect2(-0.55, -0.56, 1.1, 0.27), Color(0.7, 0.22, 0.25), Color.WHITE)
	m.bake()
	return m


func _unhandled_input(event: InputEvent) -> void:
	if main.intro != main.Intro.NONE:
		return
	if event.is_action_pressed("ui_cancel"):
		set_open(not open)
		get_viewport().set_input_as_handled()
	elif open and amount > 0.95 and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		match menu.button_at(event.position, main.player.camera, menu_world):
			"resume":
				set_open(false)
			"quit":
				get_tree().quit()


func set_open(on: bool) -> void:
	if on == open or main.intro != main.Intro.NONE:
		return
	open = on
	if on:
		get_tree().paused = true   # everything stops, mid-morph and mid-shot included
		main._hud_layer.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if amount == 0.0:
			if menu == null:
				menu = _build()
			var cam: Camera3D = main.player.camera
			_base = Transform3D(cam.global_basis, cam.global_position - cam.global_basis.z * DISTANCE)
			menu_world = _base
			_lean = Vector2.ZERO
			# Only what the camera can see takes part.
			_clouds.clear()
			var planes := cam.get_frustum()
			for c in get_tree().get_nodes_in_group(&"point_clouds"):
				var cloud := c as PointCloud
				if cloud.data == null or not cloud.is_visible_in_tree() or (cam.cull_mask & cloud.layers) == 0:
					continue
				if _in_frustum(planes, cloud.global_transform * cloud.data.aabb):
					_clouds.append(cloud)
	if _tween:
		_tween.kill()
	_tween = create_tween()
	# Eased at both ends, and with no dead time: the game stops the instant the
	# menu is called and is running again the instant it is dismissed, while
	# the atoms are still on their way home.
	_tween.tween_property(self, "amount", 1.0 if on else 0.0, OPEN_TIME * maxf(absf((1.0 if on else 0.0) - amount), 0.3)) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if not on:
		get_tree().paused = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_tween.tween_callback(func(): main._hud_layer.visible = true)


static func _in_frustum(planes: Array[Plane], box: AABB) -> bool:
	for pl in planes:
		var inside := false
		for i in 8:
			if not pl.is_point_over(box.get_endpoint(i)):
				inside = true
				break
		if not inside:
			return false
	return true


func _process(delta: float) -> void:
	if not open and amount == 0.0:
		_light.light_energy = 0.0
		return
	_time += delta
	var cam: Camera3D = main.player.camera
	# Parallax: the menu leans and slides a little against the pointer, so its
	# layers (back panel, slabs, lettering) shift against each other.
	var size := get_viewport().get_visible_rect().size
	var m := (get_viewport().get_mouse_position() / size - Vector2(0.5, 0.5)) * 2.0
	_lean = _lean.lerp(m.clamp(Vector2(-1, -1), Vector2(1, 1)) if open else Vector2.ZERO, 1.0 - exp(-6.0 * delta))
	menu_world = _base * Transform3D(Basis.from_euler(Vector3(_lean.y * 0.1, _lean.x * 0.16, 0.0)),
			Vector3(-_lean.x * 0.06, _lean.y * 0.04, 0.0))
	var hover := Rect2()
	if open and amount > 0.95:
		var id := menu.button_at(get_viewport().get_mouse_position(), cam, menu_world)
		if id != "":
			hover = menu.buttons[id]
	for cloud in _clouds:
		if is_instance_valid(cloud):
			cloud.set_menu(menu, menu_world, hover, _time)
			cloud.menu_amount = amount
	# A light of its own, up and to the left of the viewer, so the menu's
	# slabs and letters are shaded whichever way the sun happens to fall.
	_light.global_position = _base * Vector3(-1.1, 1.0, 1.5)
	_light.light_energy = 2.6 * amount
