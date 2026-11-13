class_name Sfx
extends Node
## Sound effects and music, all synthesised at start-up (no audio files).
## Sfx.play("shot") from anywhere; it does nothing if no Sfx node exists.
## Keeps playing while the game is paused.

const RATE := 22050

static var instance: Sfx

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	instance = self
	_rng.seed = 3
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_music = AudioStreamPlayer.new()
	_music.volume_db = -15.0
	add_child(_music)
	_build()


func _exit_tree() -> void:
	if instance == self:
		instance = null


static func play(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	if instance == null or not instance._streams.has(sound):
		return
	var p := instance._players[instance._next]
	instance._next = (instance._next + 1) % instance._players.size()
	p.stream = instance._streams[sound]
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


static func music(on: bool) -> void:
	if instance == null:
		return
	if on and not instance._music.playing:
		instance._music.stream = instance._streams["music"]
		instance._music.play()
	elif not on:
		instance._music.stop()


# ---------------------------------------------------------------- synthesis

func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w


## `fn` maps time (s) to a sample; a one-pole low-pass smooths noise if lp > 0.
func _make(length: float, fn: Callable, lp := 0.0) -> PackedFloat32Array:
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var prev := 0.0
	for i in n:
		var v: float = fn.call(float(i) / RATE)
		if lp > 0.0:
			prev += (v - prev) * lp
			v = prev
		out[i] = v
	return out


func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)


func _build() -> void:
	# Shotgun: a hard noise crack over a falling thump.
	_streams["shot"] = _wav(_make(0.5, func(t: float) -> float:
		return _noise() * exp(-t * 16.0) * 0.8 + sin(TAU * (95.0 - 60.0 * t) * t) * exp(-t * 9.0) * 0.7, 0.55))
	# Pump: two short metallic clacks.
	_streams["pump"] = _wav(_make(0.34, func(t: float) -> float:
		var a := exp(-t * 60.0) + exp(-absf(t - 0.19) * 55.0) * (1.0 if t > 0.19 else 0.0)
		return (_noise() * 0.5 + sin(TAU * 1900.0 * t) * 0.3 + sin(TAU * 740.0 * t) * 0.3) * a * 0.5))
	_streams["reload"] = _wav(_make(0.5, func(t: float) -> float:
		var a := exp(-absf(t - 0.05) * 50.0) + exp(-absf(t - 0.3) * 45.0)
		return (_noise() * 0.5 + sin(TAU * 520.0 * t) * 0.4) * a * 0.45))
	# Stone: a low gritty crunch.
	_streams["stone"] = _wav(_make(0.6, func(t: float) -> float:
		return _noise() * exp(-t * 8.0) * (0.6 + 0.4 * sin(TAU * 37.0 * t)) * 0.9, 0.18))
	# Glass: bright ringing splinters.
	_streams["glass"] = _wav(_make(0.9, func(t: float) -> float:
		var ring := sin(TAU * 3100.0 * t) + sin(TAU * 4270.0 * t) + sin(TAU * 5830.0 * t) + sin(TAU * 7400.0 * t)
		return _noise() * exp(-t * 30.0) * 0.6 + ring * exp(-t * 7.0) * 0.12 + _noise() * exp(-t * 5.0) * 0.12 * absf(sin(TAU * 23.0 * t))))
	# A soft thud for things that only ripple.
	_streams["thud"] = _wav(_make(0.3, func(t: float) -> float:
		return sin(TAU * (120.0 - 150.0 * t) * t) * exp(-t * 14.0) * 0.7))
	# Atoms on the move: an airy swell (morphs, Quw, menus).
	_streams["whoosh"] = _wav(_make(1.1, func(t: float) -> float:
		return _noise() * pow(sin(PI * minf(t / 1.1, 1.0)), 2.0) * 0.5, 0.12))
	_streams["morph"] = _wav(_make(3.0, func(t: float) -> float:
		var env := pow(sin(PI * minf(t / 3.0, 1.0)), 1.5)
		return (_noise() * 0.35 + sin(TAU * (180.0 + 90.0 * t) * t) * 0.12) * env, 0.08))
	_streams["explode"] = _wav(_make(1.4, func(t: float) -> float:
		return _noise() * exp(-t * 3.5) * 0.9 + sin(TAU * 55.0 * t) * exp(-t * 5.0) * 0.6, 0.1))
	# Intro: a sharp crack, and the bang.
	_streams["crack"] = _wav(_make(0.35, func(t: float) -> float:
		return _noise() * exp(-t * 45.0) * 0.9 + sin(TAU * 2300.0 * t) * exp(-t * 25.0) * 0.25))
	_streams["bang"] = _wav(_make(3.2, func(t: float) -> float:
		return _noise() * exp(-t * 1.6) * 0.9 + sin(TAU * (48.0 - 6.0 * t) * t) * exp(-t * 1.2) * 0.8, 0.07))
	_streams["build"] = _wav(_make(5.0, func(t: float) -> float:
		var env := sin(PI * minf(t / 5.0, 1.0))
		return (sin(TAU * 220.0 * t) + sin(TAU * 330.0 * t) + sin(TAU * 440.0 * (1.0 + 0.02 * t) * t)) * 0.08 * env + _noise() * 0.1 * env, 0.2))
	_streams["ui"] = _wav(_make(0.12, func(t: float) -> float:
		return sin(TAU * 880.0 * t) * exp(-t * 30.0) * 0.4))
	# Music: a slow four-chord pad with a soft pulse, looping.
	var chords := [[110.0, 164.8, 220.0, 261.6], [87.3, 130.8, 174.6, 220.0], [130.8, 196.0, 261.6, 329.6], [98.0, 146.8, 196.0, 246.9]]
	var bar := 4.0
	var total := bar * chords.size()
	_streams["music"] = _wav(_make(total, func(t: float) -> float:
		var k := int(t / bar) % chords.size()
		var u := fmod(t, bar) / bar
		var env := minf(u * 8.0, 1.0) * minf((1.0 - u) * 8.0, 1.0)
		var v := 0.0
		for f in chords[k]:
			v += sin(TAU * f * t) + 0.4 * sin(TAU * f * 2.003 * t)
		var pulse := 0.6 + 0.4 * sin(TAU * 2.0 * t)
		return v * 0.05 * env * pulse + sin(TAU * chords[k][0] * 0.5 * t) * 0.12 * env), true)
