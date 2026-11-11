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
const GUN_HOME := Vector3(0.27, -0.25, -0.62)
const MORPH_TIME := 1.1                        # quicker than world morphs
const SHELLS := 6
const RELOAD_TIME := 1.3
const FIRE_INTERVAL := 0.45

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
var _blink := 0.0
var _next_blink := 2.0
var _kick := 0.0               # recoil
var _reload := 0.0             # 0..1 through the reload animation
var _fire_cd := 0.0
var _pending := 0


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


func _add_cloud(parent: Node3D, fairy: PointCloudData, gun: PointCloudData) -> PointCloud:
	var c := PointCloud.new()
	# She may need more atoms as a tool than as a fairy: start with enough.
	if fairy.size() < gun.size():
		fairy = fairy.resampled(gun.size())
	c.data = fairy
	c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	c.lod = false
	c.morph_stagger = 0.3
	# A tight, chunky burst: her atoms stay close and are big enough to see.
	c.morph_swarm = 0.07
	c.morph_arc = 0.05
	c.atom_min_px = 5.0
	c.atom_max_px = 6.0
	c.morph_flash = 0.8
	c.morph_reach_max = 0.07   # the same tight burst both ways (the gun is far bigger than she is)
	c.atom_depth = 7.0   # near atoms big and bright, far ones small and dim
	parent.add_child(c)
	_forms[c] = [fairy, gun]
	# Warm both shapes so switching starts at once.
	c.prepare_morph_target(gun)
	return c


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
		cloud.morph_to(_forms[c][1 if t == Tool.SHOTGUN else 0], MORPH_TIME)
	# She moves to the tool's position while her atoms are still a cloud, so
	# they land on a tool that is already where it will stay.
	create_tween().tween_property(self, "_gun", 1.0 if t == Tool.SHOTGUN else 0.0, MORPH_TIME * 0.55) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _on_morph_finished() -> void:
	busy = false
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
	return to_global(Vector3(0, 0.03, -0.48))


func _process(delta: float) -> void:
	_time += delta
	_fire_cd -= delta
	_kick = lerpf(_kick, 0.0, 1.0 - exp(-9.0 * delta))
	var fairy := 1.0 - _gun
	# Hover and bob as a fairy; held steady as a gun.
	var bob := Vector3(sin(_time * 1.3) * 0.012, sin(_time * 2.1) * 0.02, 0.0) * fairy
	position = HOME.lerp(GUN_HOME, _gun) + bob + Vector3(0, 0.01, 0.06) * _kick
	# Reload: the gun tilts over and dips, then comes back.
	var r := sin(_reload * PI)
	rotation = Vector3(0.12 * _kick - 0.18 * r, -0.35 * fairy + 0.05 * r, 0.3 * r)
	# Wings flap as a fairy and fold flat into the gun.
	var flap := (0.35 + 0.55 * sin(_time * 15.0)) * fairy
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
	var calm := 1.0 - 0.75 * sin(clampf(_gun, 0.0, 1.0) * PI)
	body.emission_strength = lerpf(0.12, 0.9, fairy) * calm
	wing_l.emission_strength = lerpf(0.1, 0.35, fairy) * calm
	wing_r.emission_strength = wing_l.emission_strength
