class_name Quw
extends Node3D
## Quw, the player's fairy assistant. Like everything else she is made of
## atoms: a small glowing ball with two flapping light-blue wings and two
## black line eyes. She hovers at the bottom right of the player's view and
## carries the inventory: switching tool (mouse wheel) morphs her atoms into
## that tool, and back. The first tool is a shotgun.
##
## Add her as a child of the player's camera.

signal tool_ready(tool: int)

enum Tool { NONE, SHOTGUN }

const HOME := Vector3(0.36, -0.24, -0.85)      # in the camera's space
## Where the shotgun sits relative to her: she stays where she is and the gun
## is assembled around her.
const GUN_OFFSET := Vector3(-0.09, -0.01, 0.23)
const MORPH_TIME := 1.3
## The two ends of the shotgun, in her space: she flies between them.
const MUZZLE_END := Vector3(-0.09, 0.02, -0.24)
const STOCK_END := Vector3(-0.09, -0.03, 0.56)
const T_START := 0.14   # of the morph: she has reached the end she starts from
const T_SWEEP := 0.5    # ...and takes this long to fly the gun's length
const SHELLS := 6
const RELOAD_TIME := 1.3
const FIRE_INTERVAL := 0.7     # a shot, then the pump has to be worked

var tool := Tool.NONE          # what she is, or is turning into
var busy := false              # mid-morph: tools can't be switched
var shells := SHELLS
var reloading := false

var body: PointCloud           # ball -> barrel, receiver
var eyes: PointCloud           # eyes -> sights
var wing_l: PointCloud         # left wing -> stock
var wing_r: PointCloud         # right wing -> pump
var _pivot_l: Node3D
var _pivot_r: Node3D
var _eye_node: Node3D
var _forms := {}               # cloud -> [fairy data, shotgun data]
var _time := 0.0
var _gun := 0.0                # 0 = fairy pose, 1 = gun pose
var _form := 0.0               # 0 = fairy, 1 = gun, over the whole switch (for her glow)
var _blink := 0.0
var _next_blink := 2.0
var _kick := 0.0               # recoil
var _reload := 0.0             # 0..1 through the reload animation
var _fire_cd := 0.0
var _pending := 0
var _light: OmniLight3D        # the glow of the switch (and a little of her own)
var _pump := 0.0               # 0..1 through the pump stroke after a shot
var _flash: PointCloud         # muzzle flash: a puff of white-hot atoms
var _flash_t := 1.0
var _pump_home := Vector3.ZERO
var _settle := 1.0             # eases her wing-beat back in after a switch


func _ready() -> void:
	position = HOME
	var glow := Color(1.0, 0.93, 0.62)
	var wing_col := Color(0.55, 0.85, 1.0)
	var metal := Color(0.36, 0.38, 0.44)
	var wood := Color(0.62, 0.4, 0.2)

	# --- the fairy
	var ball := PointSampler.sphere(0.055, 60000, {"color": glow})
	var eye_d := PointSampler.box(Vector3(0.008, 0.034, 0.004), 1500, {"color": Color(0.02, 0.02, 0.03)})
	var two_eyes := PointSampler.box(Vector3(0.008, 0.034, 0.004), 1500, {"color": Color(0.02, 0.02, 0.03),
			"transform": Transform3D(Basis(), Vector3(-0.02, 0, 0))})
	two_eyes.merge(eye_d, Transform3D(Basis(), Vector3(0.02, 0, 0)))
	# A wing: a flat leaf shape, root at the pivot, tip outwards.
	var wing := func(side: float) -> PointCloudData:
		return PointSampler.sphere(0.5, 14000, {"color_fn": func(p: Vector3, _n, _c, _in) -> Color:
				return wing_col.lerp(Color(0.85, 0.97, 1.0), clampf(absf(p.x), 0.0, 1.0)),
			"transform": Transform3D(Basis.from_scale(Vector3(0.11, 0.075, 0.006)), Vector3(side * 0.055, 0.02, 0))})

	# --- the shotgun, in Quw's own space (muzzle towards -z)
	var barrel := PointSampler.cylinder(0.014, 0.5, 30000, {"color": metal,
			"transform": Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 0.03, -0.22))})
	var receiver := PointSampler.box(Vector3(0.04, 0.06, 0.17), 30000, {"color": metal,
			"transform": Transform3D(Basis(), Vector3(0, 0.012, 0.06))})
	barrel.merge(receiver)
	var stock := PointSampler.box(Vector3(0.034, 0.075, 0.24), 14000, {"color": wood,
			"transform": Transform3D(Basis(Vector3.RIGHT, -0.16), Vector3(0, -0.02, 0.25))})
	var pump := PointSampler.cylinder(0.021, 0.15, 14000, {"color": wood,
			"transform": Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 0.0, -0.2))})
	var sights := PointSampler.box(Vector3(0.006, 0.012, 0.006), 1500, {"color": metal,
			"transform": Transform3D(Basis(), Vector3(0, 0.05, -0.45))})
	sights.merge(PointSampler.box(Vector3(0.012, 0.01, 0.006), 1500, {"color": metal}),
			Transform3D(Basis(), Vector3(0, 0.048, 0.0)))

	for part in [barrel, stock, pump, sights]:
		_shift_in_place(part, GUN_OFFSET)
	body = _add_cloud(self, ball, barrel)
	body.emission_strength = 0.9
	# The glow belongs to the fairy: it fades as she becomes the gun.
	_eye_node = Node3D.new()
	_eye_node.position = Vector3(0.0, 0.006, 0.053)
	add_child(_eye_node)
	eyes = _add_cloud(_eye_node, two_eyes, _shifted(sights, -_eye_node.position))
	_pivot_l = Node3D.new()
	_pivot_l.position = Vector3(-0.03, 0.02, -0.02)
	add_child(_pivot_l)
	wing_l = _add_cloud(_pivot_l, wing.call(-1.0), _shifted(stock, -_pivot_l.position))
	_pivot_r = Node3D.new()
	_pivot_r.position = Vector3(0.03, 0.02, -0.02)
	add_child(_pivot_r)
	wing_r = _add_cloud(_pivot_r, wing.call(1.0), _shifted(pump, -_pivot_r.position))
	for w in [wing_l, wing_r]:
		w.emission_strength = 0.35
	eyes.emission_strength = 0.0
	body.morph_finished.connect(_on_morph_finished)
	_pump_home = _pivot_r.position
	_flash = PointCloud.new()
	_flash.data = PointSampler.sphere(0.022, 2500, {"color": Color(1.0, 0.9, 0.6)})
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash.lod = false
	_flash.unshaded = true
	_flash.atom_min_px = 3.0
	_flash.atom_max_px = 6.0
	_flash.visible = false
	add_child(_flash)
	_light = OmniLight3D.new()
	_light.light_color = Color(0.8, 0.9, 1.0)
	_light.omni_range = 2.2
	_light.omni_attenuation = 1.4
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	add_child(_light)


func _add_cloud(parent: Node3D, fairy: PointCloudData, gun: PointCloudData) -> PointCloud:
	var c := PointCloud.new()
	# She may need more atoms as a tool than as a fairy: start with enough.
	if fairy.size() < gun.size():
		fairy = fairy.resampled(gun.size())
	# Nothing may change at the moment a switch completes, so the two things
	# that differ between "morphing" and "at rest" are off for her: trimming
	# at the bounding box, and dropping atoms that face away.
	fairy.closed = false
	gun.closed = false
	c.clip_to_bounds = false
	c.data = fairy
	c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	c.lod = false
	c.morph_stagger = 0.3
	# A tight, chunky burst: her atoms stay close and are big enough to see.
	c.morph_swarm = 0.07
	c.morph_arc = 0.035      # width of the spiral her atoms travel along
	c.atom_min_px = 5.0
	c.atom_max_px = 7.0
	c.morph_vortex = 0.085   # she dissolves into a whirling cloud first
	c.morph_linear = true    # ...at once, no slow wind-up
	# She reassembles: her atoms stream into the tool, which grows outwards
	# from where she is; going back, the far ends leave first.
	c.morph_stream = true
	c.morph_span = 0.62
	c.morph_timing = Vector3(T_START, T_SWEEP, 0.2)
	c.morph_flash = 0.25
	c.morph_reach_max = 0.07   # the same tight burst both ways (the gun is far bigger than she is)
	c.atom_depth = 7.0   # near atoms big and bright, far ones small and dim
	parent.add_child(c)
	_forms[c] = [fairy, gun]
	# Warm both shapes so switching starts at once.
	c.prepare_morph_target(gun)
	return c


static func _shift_in_place(d: PointCloudData, by: Vector3) -> void:
	var pos := d.positions
	for i in pos.size():
		pos[i] += by
	d.positions = pos
	d.recompute_aabb()


static func _shifted(d: PointCloudData, by: Vector3) -> PointCloudData:
	var out := PointCloudData.new()
	out.merge(d, Transform3D(Basis(), by))
	return out


## Switches to the next tool. Ignored while she is still forming.
func cycle_tool() -> bool:
	if busy or reloading:
		return false
	set_tool(Tool.SHOTGUN if tool == Tool.NONE else Tool.NONE)
	return true


func set_tool(t: int) -> void:
	if busy or t == tool:
		return
	tool = t
	busy = true
	_pending = _forms.size()
	for c in _forms:
		var cloud := c as PointCloud
		# The gun is laid down from the muzzle back to the stock, and gathered
		# up from the stock out to the muzzle.
		cloud.morph_focus = cloud.to_local(global_position)   # the tool grows outwards from her
		cloud.morph_reverse = t == Tool.NONE
		cloud.morph_to(_forms[c][1 if t == Tool.SHOTGUN else 0], MORPH_TIME)
	create_tween().tween_property(self, "_form", 1.0 if t == Tool.SHOTGUN else 0.0, MORPH_TIME)


func _on_morph_finished() -> void:
	busy = false
	_settle = 0.0
	for c in _forms:
		(c as PointCloud).set_morph_carry(Vector3.ZERO)
	# Keep the other form warm for the way back.
	for c in _forms:
		(c as PointCloud).prepare_morph_target(_forms[c][0 if tool == Tool.SHOTGUN else 1])
	tool_ready.emit(tool)


func has_gun() -> bool:
	return tool == Tool.SHOTGUN and not busy


## True if a shot may be fired now; takes a shell and kicks.
func try_fire() -> bool:
	if not has_gun() or reloading or _fire_cd > 0.0:
		return false
	if shells <= 0:
		reload()
		return false
	shells -= 1
	_fire_cd = FIRE_INTERVAL
	_kick = 1.0
	_flash_t = 0.0
	# Work the pump: back and forward again, a moment after the shot.
	var tw := create_tween()
	tw.tween_interval(0.16)
	tw.tween_property(self, "_pump", 1.0, 0.36).from(0.0)
	tw.tween_callback(func(): _pump = 0.0)
	if shells == 0:
		get_tree().create_timer(0.35).timeout.connect(reload)
	return true


func reload() -> void:
	if reloading or not has_gun() or shells == SHELLS:
		return
	reloading = true
	var tw := create_tween()
	tw.tween_property(self, "_reload", 1.0, RELOAD_TIME)
	tw.tween_callback(func():
		shells = SHELLS
		reloading = false
		_reload = 0.0)


## Where shots leave the gun, in world space.
func muzzle() -> Vector3:
	return to_global(Vector3(0, 0.03, -0.48) + GUN_OFFSET)


func _process(delta: float) -> void:
	_time += delta
	_fire_cd -= delta
	_kick = lerpf(_kick, 0.0, 1.0 - exp(-7.0 * delta))
	# Muzzle flash: a burst of atoms and a hard flare of light, gone in a blink.
	_flash_t += delta
	var fl := clampf(1.0 - _flash_t / 0.11, 0.0, 1.0)
	_flash.visible = fl > 0.0
	if fl > 0.0:
		_flash.position = Vector3(0, 0.03, -0.5) + GUN_OFFSET
		_flash.explode_center = Vector3.ZERO
		_flash.explode = 0.1 * (1.0 - fl * fl)
	# The pump slides back along the barrel and forward again.
	_pivot_r.position = _pump_home + Vector3(0, 0, 0.085) * sin(_pump * PI)
	# The shot kicks the view up; it settles back by itself.
	var cam := get_parent() as Camera3D
	if cam:
		cam.rotation.x = 0.045 * _kick
	# --- the switch: she bursts into a whirling cloud of atoms with a flash,
	# the cloud lunges, and it settles into the tool as the tool swings into
	# the hand. Back again: the gun bursts, the cloud twirls once around as it
	# gathers, and she pops up out of it.
	var m := body.morph if busy else 0.0
	var to_gun := tool == Tool.SHOTGUN
	var fairy := 0.0 if to_gun else 1.0   # how much she behaves like a fairy
	var move := Vector3.ZERO   # extra movement during the switch
	var turn := Vector3.ZERO
	var flash := 0.0
	if busy:
		flash = exp(-m * 14.0)   # a burst of light as she lets go
		if to_gun:
			fairy = 1.0 - smoothstep(0.0, 0.2, m)
			# The cloud lunges up and forward, then the gun swings down into
			# the hand and snaps home with a little overshoot.
			move = Vector3(0.0, 0.06, -0.1) * sin(clampf(m / 0.5, 0.0, 1.0) * PI)
			var k := clampf((m - 0.5) / 0.5, 0.0, 1.0) - 1.0
			var away := -(2.7 * k * k * k + 1.7 * k * k) * smoothstep(0.0, 0.3, m)   # 1 -> 0, overshooting
			turn = Vector3(0.55, -0.25, 0.9) * away
			move += Vector3(0.05, 0.05, 0.08) * away
		else:
			fairy = smoothstep(0.75, 1.0, m)
			# The cloud twirls once around as it gathers, and she pops up out
			# of it and drops back to her spot.
			turn = Vector3(0.0, TAU * (1.0 - smoothstep(0.05, 0.9, m)), 0.0)
			move = Vector3(0.0, 0.08, 0.0) * pow(sin(clampf((m - 0.4) / 0.6, 0.0, 1.0) * PI), 2.0)   # (comes to rest gently)
	_gun = 1.0 - fairy
	# Hover and bob as a fairy; held steady as a gun.
	var bob := Vector3(sin(_time * 1.3) * 0.012, sin(_time * 2.1) * 0.02, 0.0) * fairy
	position = HOME + bob + Vector3(0, 0.025, 0.13) * _kick + Vector3(0, -0.01, 0.015) * sin(_pump * PI) + move
	# Reload: the gun tilts over and dips, then comes back.
	var r := sin(_reload * PI)
	rotation = Vector3(0.3 * _kick - 0.18 * r - 0.05 * sin(_pump * PI), 0.05 * r, 0.3 * r + 0.06 * sin(_pump * PI)) + turn
	# Wings flap as a fairy and fold flat into the gun.
	# (Not mid-switch: the wings' atoms are busy, and their pivots must hold still.)
	_settle = minf(_settle + delta * 3.0, 1.0)
	var flap := (0.35 + 0.55 * sin(_time * 15.0)) * (0.0 if busy else fairy) * smoothstep(0.0, 1.0, _settle)
	_pivot_l.rotation.z = -flap
	_pivot_r.rotation.z = flap
	# Blink.
	_next_blink -= delta
	if _next_blink <= 0.0:
		_next_blink = randf_range(2.0, 5.0)
		_blink = 1.0
	_blink = maxf(_blink - delta * 7.0, 0.0)
	_eye_node.scale.y = lerpf(1.0, 0.12, sin(_blink * PI) * fairy)
	# (dimmer while her atoms are loose: a bright cloud would wash out to white)
	var calm := 1.0 + 1.2 * flash
	# Light: her own soft glow, and a swell of light through the switch that
	# falls on the forming tool and whatever is near.
	# (It rises and falls smoothly, and the same soft light stays on whatever
	# she is, so nothing changes when the switch completes.)
	var surge := pow(sin(m * PI), 2.0) if busy else 0.0
	_light.light_energy = 0.3 + 2.0 * surge + 5.0 * fl
	_light.light_color = Color(1.0, 0.93, 0.7).lerp(Color(0.75, 0.88, 1.0), surge)
	body.emission_strength = lerpf(0.9, 0.12, _form) * calm
	wing_l.emission_strength = lerpf(0.35, 0.1, _form) * calm
	wing_r.emission_strength = wing_l.emission_strength
