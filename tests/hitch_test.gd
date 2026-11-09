extends Node
## Measures how long the main thread is blocked by gameplay actions
## (morph, carve, ...). Headless is fine: it measures CPU-side stalls.
##   godot --headless --path . res://tests/hitch_test.tscn

const MAIN := preload("res://demo/main.tscn")
var main: Node3D
var frame := 0
var worst := {}
var _last := 0
var _label := ""


func _ready() -> void:
	main = MAIN.instantiate()
	add_child(main)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _act(label: String, body: StaticBody3D, fn: Callable) -> void:
	main.target = body.get_meta("cloud")
	main.target_body = body
	main.target_hit = body.global_position + Vector3(0, 0, 1.0)
	_label = label
	var t0 := Time.get_ticks_usec()
	fn.call()
	print("HITCH %-28s call=%6.1f ms" % [label, (Time.get_ticks_usec() - t0) / 1000.0])


func _process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	# Longest frame within the window after each action (catches deferred work).
	if _label != "" and frame > 5:
		var ms := (now - _last) / 1000.0
		worst[_label] = maxf(worst.get(_label, 0.0), ms)
	_last = now
	frame += 1
	if frame % 20 == 0:
		print("frame ", frame, " t=", Time.get_ticks_msec())
	var shifter: StaticBody3D = main.props[0]
	var crate: StaticBody3D = main.props[1]
	match frame:
		30:
			_act("morph shape-shifter", shifter, main.morph_target)
		200:
			_act("morph crate (to sphere)", crate, main.morph_target)
		400:
			_act("shoot shape-shifter", shifter, main.shoot)
		420:
			_act("shoot 10x", shifter, func():
				for i in 10:
					main.target_hit = shifter.global_position + Vector3(randf_range(-0.8, 0.8), randf_range(-0.8, 0.8), 1.0)
					main.shoot())
		150, 260, 900:
			var c: PointCloud = (shifter if frame == 150 else crate).get_meta("cloud")
			print("CHECK frame %d %s morph=%.2f" % [frame, "shifter" if frame == 150 else "crate", c.morph])
		545:
			var c: PointCloud = shifter.get_meta("cloud")
			print("CHECK carves pending=%d (baked into the state texture once 0)" % c.get("_carves").size())
		1000:
			var c: PointCloud = shifter.get_meta("cloud")
			print("CHECK after bake: carves pending=%d" % c.get("_carves").size())
			for k in worst:
				print("WORST-FRAME %-22s %6.1f ms" % [k, worst[k]])
			get_tree().quit()
