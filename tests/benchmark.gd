extends Node
## Frame-time benchmark of the demo scene:
##   godot --path . res://tests/benchmark.tscn -- --frames=10
## Renders a few warm-up frames, then times `frames` frames by wall clock.

const MAIN := preload("res://demo/main.tscn")
var main: Node3D
var warmup := 3
var frames := 8
var _n := 0
var _start := 0
var _worst := 0
var _last := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = int(a.substr(9))
	main = MAIN.instantiate()
	add_child(main)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var args := OS.get_cmdline_user_args()
	if "--hide-clouds" in args:
		for c in get_tree().get_nodes_in_group(&"point_clouds"):
			(c as Node3D).visible = false
	if "--hide-ground" in args:
		for c in get_tree().get_nodes_in_group(&"point_clouds"):
			if c.name.begins_with("Tile"):
				(c as Node3D).visible = false
	if "--no-shadows" in args:
		for c in main.get_children():
			if c is DirectionalLight3D:
				c.shadow_enabled = false
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var q = main.get_node_or_null("Quality")
	if q and "--no-auto" in OS.get_cmdline_user_args():
		q.enabled = false


func _process(_delta: float) -> void:
	var pl = main.player
	pl.set("_yaw", float(pl.get("_yaw")) + 0.05)  # turn a little each frame
	_n += 1
	var now := Time.get_ticks_usec()
	if _n == warmup:
		_start = now
	elif _n > warmup:
		_worst = maxi(_worst, now - _last)
	_last = now
	if _n == warmup + frames:
		var ms := float(now - _start) / frames / 1000.0
		var drawn := 0
		var total := 0
		for c in get_tree().get_nodes_in_group(&"point_clouds"):
			total += (c as PointCloud).get_dot_count()
			if c.has_method("get_drawn_dot_count"):
				drawn += c.get_drawn_dot_count()
			else:
				drawn += (c as PointCloud).get_dot_count()
		print("BENCH avg_ms=%.0f worst_ms=%.0f drawn_dots=%d total_dots=%d gpu_ms=%.1f renderer=%s" % [ms, _worst / 1000.0, drawn, total,
			RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()),
			RenderingServer.get_current_rendering_method()])
		get_tree().quit()
