extends SceneTree
## Feeds PointCloudQuality synthetic frame times (no GPU timer, like the
## Compatibility renderer) and prints how it reacts.
##   godot --headless --path . -s res://tests/quality_sim.gd

func _initialize() -> void:
	var q := PointCloudQuality.new()
	root.add_child(q)
	q._vp = root  # the tree isn't running yet, so set what _ready() would

	var phases := [["start-up hitch", 3.0, 200.0], ["vsynced 60 fps", 3.0, 16.7], ["slow: 30 fps", 6.0, 33.0],
		["recovered, vsync-capped", 40.0, 16.7], ["slow again: 45 fps", 5.0, 22.0], ["capped", 30.0, 16.7]]
	for ph in phases:
		var t := 0.0
		while t < ph[1]:
			var dt: float = ph[2] / 1000.0
			q._process(dt)
			t += dt
		print("%-26s -> %s" % [ph[0], q.describe()])
	quit()
