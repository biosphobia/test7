class_name PointPlayer
extends CharacterBody3D
## Third-person player whose whole body is made of point clouds.
##
## Torso + head are one cloud built by merging several sampled shapes; arms and
## legs are separate clouds swung from code while walking.

@export var walk_speed := 5.0
@export var sprint_speed := 9.0
@export var jump_velocity := 5.5
@export var mouse_sensitivity := 0.0025

var camera: Camera3D
var visual: Node3D
var torso: PointCloud
var limbs: Array[Node3D] = []   # pivots: left leg, right leg, left arm, right arm

var _cam_pivot: Node3D
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _yaw := 0.0
var _pitch := -0.2
var _walk_phase := 0.0


func _ready() -> void:
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	add_child(col)

	visual = Node3D.new()
	visual.name = "Visual"
	add_child(visual)
	_build_body()

	_cam_pivot = Node3D.new()
	_cam_pivot.position.y = 1.6
	add_child(_cam_pivot)
	var arm := SpringArm3D.new()
	arm.spring_length = 4.2
	arm.margin = 0.2
	arm.position.x = 0.7
	arm.add_excluded_object(get_rid())
	_cam_pivot.add_child(arm)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 300.0
	arm.add_child(camera)
	camera.current = true


func _build_body() -> void:
	var suit := Color(0.85, 0.88, 0.92)
	var dark := Color(0.16, 0.18, 0.22)
	var glow := Color(0.2, 0.95, 1.0)

	# Torso + head + visor + backpack merged into one cloud.
	var d := PointSampler.capsule(0.3, 0.95, 80000, {"color_fn": func(p: Vector3, _n, _c, _in) -> Color:
		return dark if absf(p.y) > 0.3 or absf(p.x) > 0.24 else suit})
	var head := PointSampler.sphere(0.22, 35000, {"color": suit})
	d.merge(head, Transform3D(Basis(), Vector3(0, 0.68, 0)))
	var visor := PointSampler.box(Vector3(0.3, 0.09, 0.08), 6000, {"color": glow})
	d.merge(visor, Transform3D(Basis(), Vector3(0, 0.71, 0.18)))
	var pack := PointSampler.box(Vector3(0.38, 0.45, 0.16), 9000, {"color": dark})
	d.merge(pack, Transform3D(Basis(), Vector3(0, 0.1, -0.3)))
	torso = PointCloud.new()
	torso.name = "Torso"
	torso.data = d
	torso.position.y = 1.15
	torso.wobble_frequency = 5.0
	visual.add_child(torso)

	# Limbs: a pivot at the joint with a capsule cloud hanging below it.
	var specs := [
		[Vector3(-0.15, 0.72, 0), 0.12, 0.8],   # left leg
		[Vector3(0.15, 0.72, 0), 0.12, 0.8],    # right leg
		[Vector3(-0.42, 1.48, 0), 0.09, 0.72],  # left arm
		[Vector3(0.42, 1.48, 0), 0.09, 0.72],   # right arm
	]
	for i in specs.size():
		var pivot := Node3D.new()
		pivot.position = specs[i][0]
		visual.add_child(pivot)
		var limb := PointCloud.new()
		limb.name = ["LegL", "LegR", "ArmL", "ArmR"][i]
		limb.data = PointSampler.capsule(specs[i][1], specs[i][2], 20000, {"color_fn": func(p: Vector3, _n, _c, _in) -> Color:
			return dark if p.y < -0.25 else suit})
		limb.position.y = -specs[i][2] * 0.5 + 0.05
		pivot.add_child(limb)
		limbs.append(pivot)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.2, 0.9)


func _physics_process(delta: float) -> void:
	_cam_pivot.rotation = Vector3(_pitch, _yaw, 0)

	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (Basis(Vector3.UP, _yaw) * Vector3(input.x, 0, input.y))
	var sprinting := Input.is_action_pressed("sprint")
	var speed := sprint_speed if sprinting else walk_speed
	velocity.x = move_toward(velocity.x, dir.x * speed, speed * 8.0 * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, speed * 8.0 * delta)
	move_and_slide()

	# Face the movement direction.
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() > 0.2:
		var target_yaw := atan2(velocity.x, velocity.z)
		visual.rotation.y = lerp_angle(visual.rotation.y, target_yaw, 1.0 - exp(-12.0 * delta))

	# Walk cycle by rotating limb pivots.
	var moving := clampf(flat.length() / walk_speed, 0.0, 1.5)
	_walk_phase += delta * (6.0 + 4.0 * moving) * signf(moving)
	var swing := sin(_walk_phase) * 0.7 * minf(moving, 1.0)
	limbs[0].rotation.x = swing
	limbs[1].rotation.x = -swing
	limbs[2].rotation.x = -swing * 0.8
	limbs[3].rotation.x = swing * 0.8

	# The body's points react to what the player is doing.
	torso.wobble_amplitude = lerpf(torso.wobble_amplitude, 0.012 if moving < 0.1 else 0.0, 0.1)
	torso.vibrate_amplitude = lerpf(torso.vibrate_amplitude, 0.006 if sprinting and moving > 0.5 else 0.0, 0.2)
