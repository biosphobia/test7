class_name PointCloudQuality
extends Node
## Sets the 3D render resolution for point clouds and, optionally, keeps the
## frame rate at `target_fps` by trading detail. Add one to your scene (the
## demo does).
##
## Resolution: atoms are sized in pixels, so the number drawn grows with the
## resolution. The 3D view is rendered at most `max_render_height` pixels high
## (times `resolution_scale`) and upscaled; the picture keeps its look while a
## 1440p screen costs no more than a 800p one.
##
## Automatic detail (`enabled`, off by default): detail never changes behind
## the player's back unless this is on.
## It measures the GPU's render time each frame. When over budget it steps
## down in the order that's least visible: fewer, larger points up to
## `soft_spacing_px`, then a lower 3D render scale (upscaled with FSR), then
## points up to `max_spacing_px`. With headroom it steps back up in reverse.

@export var target_fps := 60.0
## Fraction of the frame budget to aim for, leaving headroom for spikes.
@export_range(0.5, 1.0) var budget_fraction := 0.85
@export var min_spacing_px := 1.25
## Point spacing reached before resolution is lowered.
@export var soft_spacing_px := 2.5
@export var max_spacing_px := 6.0
@export var min_render_scale := 0.6
## Automatic detail. Off: detail and resolution stay where they were set.
@export var enabled := false
## The 3D view is rendered at most this many pixels high, then upscaled.
@export var max_render_height := 800.0
## Extra factor on the render resolution (an option for slow GPUs).
@export_range(0.4, 1.0) var resolution_scale := 1.0

var render_scale := 1.0
var _avg_ms := 0.0
var _budget := 16.0
var _cooldown := 0.0
var _warmup := 3.0
var _gpu_timed := false
var _good_time := 0.0
var _probe_interval := 2.0
var _since_degrade := 0.0
var _since_probe := 999.0
var _vp: Viewport


func _ready() -> void:
	_vp = get_viewport()
	RenderingServer.viewport_set_measure_render_time(_vp.get_viewport_rid(), true)
	# FSR upscaling needs Forward+/Mobile; Compatibility only does bilinear.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	else:
		_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	_apply()


func _process(delta: float) -> void:
	if not enabled:
		render_scale = base_scale()
		_avg_ms = delta * 1000.0 if _avg_ms == 0.0 else lerpf(_avg_ms, delta * 1000.0, 0.1)
		_apply()
		return
	if _warmup > 0.0:  # ignore start-up hitches
		_warmup -= delta
		return
	var frame_ms := 1000.0 / target_fps
	# GPU time where the driver reports it. Otherwise the frame time, which
	# vsync caps at the refresh rate, so then we only step down when clearly
	# below target and probe upwards from time to time.
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(_vp.get_viewport_rid())
	if gpu > 0.0:
		_gpu_timed = true
	var ms := gpu if _gpu_timed else delta * 1000.0
	_budget = frame_ms * budget_fraction if _gpu_timed else frame_ms * 1.08
	ms = minf(ms, _budget * 3.0)  # one hitch must not drop quality a lot
	_avg_ms = ms if _avg_ms == 0.0 else lerpf(_avg_ms, ms, 0.1)
	_since_degrade += delta
	_since_probe += delta
	if _since_degrade > 30.0:
		_probe_interval = 2.0
	_good_time = _good_time + delta if _avg_ms <= frame_ms * 1.02 else 0.0
	_cooldown -= delta
	if _cooldown > 0.0:
		return
	if _avg_ms > _budget:
		_degrade(_avg_ms / _budget)
		_cooldown = 0.3
		_since_degrade = 0.0
		if _since_probe < 3.0:
			# The last step up didn't fit: wait longer before trying again.
			_probe_interval = minf(_probe_interval * 2.0, 60.0)
			_since_probe = 999.0
	elif _gpu_timed and _avg_ms < _budget * 0.6:
		_improve()
		_cooldown = 1.0
	elif not _gpu_timed and _good_time > _probe_interval:
		_improve()
		_good_time = 0.0
		_since_probe = 0.0
		_cooldown = 0.5


func _degrade(over: float) -> void:
	var step := clampf(sqrt(over), 1.05, 1.5)
	var spacing := PointCloud.lod_spacing_px
	if spacing < soft_spacing_px:
		PointCloud.lod_spacing_px = minf(spacing * step, soft_spacing_px)
	elif render_scale > min_render_scale:
		render_scale = maxf(render_scale / step, min_render_scale)
	elif spacing < max_spacing_px:
		PointCloud.lod_spacing_px = minf(spacing * step, max_spacing_px)
	_apply()


func _improve() -> void:
	var spacing := PointCloud.lod_spacing_px
	if spacing > soft_spacing_px:
		PointCloud.lod_spacing_px = maxf(spacing / 1.15, soft_spacing_px)
	elif render_scale < base_scale():
		render_scale = minf(render_scale * 1.15, base_scale())
	elif spacing > min_spacing_px:
		PointCloud.lod_spacing_px = maxf(spacing / 1.15, min_spacing_px)
	_apply()


## Render scale that keeps the 3D view within max_render_height.
func base_scale() -> float:
	var h := float(_vp.get_visible_rect().size.y) if _vp else max_render_height
	return clampf(minf(1.0, max_render_height / maxf(h, 1.0)) * resolution_scale, 0.3, 1.0)


func _apply() -> void:
	if _vp:
		_vp.scaling_3d_scale = render_scale


## True when detail and resolution are both at their floor and the frame is
## still over budget.
func is_maxed_out() -> bool:
	return enabled and PointCloud.lod_spacing_px >= max_spacing_px and render_scale <= min_render_scale \
			and _avg_ms > _budget


## One-line summary for a HUD.
func describe() -> String:
	return ("auto · " if enabled else "manual · ") + "detail %.1f px · res %d%% · %s %.1f ms" % [
		PointCloud.lod_spacing_px, roundi(render_scale * 100.0), "gpu" if _gpu_timed else "frame", _avg_ms]
