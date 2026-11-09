extends Control
## Self-updating start-up screen.
##
## Every push to GitHub makes CI publish a fresh `game.pck` (all game content)
## plus `version.json` to the repository's "latest" release. On start this
## launcher compares that version with the one it is running. If GitHub has a
## newer build it downloads only the pack, then restarts the executable on it
## (`--main-pack`). Downloaded packs are kept, so the game also starts offline.

const REPO := "biosphobia/test7"
const GAME_SCENE := "res://demo/main.tscn"
const UPDATE_DIR := "user://update"
const CACHED_PCK := "user://update/game.pck"
const CACHED_VERSION := "user://update/version.json"
const CHECK_TIMEOUT := 8.0
const SETTINGS := "user://settings.cfg"

var _label: Label
var _bar: ProgressBar
var _http: HTTPRequest


static func base_url() -> String:
	# Overridable for testing: PCW_UPDATE_URL=http://localhost:8000/
	var custom := OS.get_environment("PCW_UPDATE_URL")
	if custom != "":
		return custom
	return "https://github.com/%s/releases/download/latest/" % REPO


## The version baked into whatever pack is running right now.
static func running_version() -> Dictionary:
	return _read_json("res://version.json")


func _ready() -> void:
	var running := running_version()
	print("Point Cloud World build: ", running.get("commit", "dev"), " renderer: ", RenderingServer.get_current_rendering_method())
	# Started from the editor, or already relaunched on a downloaded pack.
	if OS.has_feature("editor") or "--updated" in OS.get_cmdline_user_args() \
			or "--no-update" in OS.get_cmdline_user_args():
		# Executables built before the renderer setting existed relaunch
		# without renderer arguments, so apply the preference here too.
		if not OS.has_feature("editor") and _relaunch_with_renderer():
			return
		_start_game.call_deferred()
		return
	_build_ui()
	_run.call_deferred(running)


func _run(running: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(UPDATE_DIR)
	var cached := _read_json(CACHED_VERSION)
	if not FileAccess.file_exists(CACHED_PCK):
		cached = {}

	_status("Checking for updates...")
	var remote := await _fetch_json(base_url() + "version.json")
	if _newer(remote, running) and _newer(remote, cached):
		_status("Downloading update %s..." % _short(remote))
		if await _download(base_url() + "game.pck", CACHED_PCK + ".part"):
			DirAccess.remove_absolute(CACHED_PCK)
			DirAccess.rename_absolute(CACHED_PCK + ".part", CACHED_PCK)
			_write_json(CACHED_VERSION, remote)
			cached = remote
		else:
			_status("Update failed, starting the installed version.")
	elif remote.is_empty():
		_status("Offline, starting the installed version.")

	# Restart the executable when it should run a downloaded pack and/or a
	# different renderer than the one it started with.
	var args := PackedStringArray()
	if _newer(cached, running):
		args.append_array(["--main-pack", ProjectSettings.globalize_path(CACHED_PCK)])
	args.append_array(renderer_args())
	if not args.is_empty():
		_status("Starting %s..." % _short(cached if _newer(cached, running) else running))
		args.append_array(["--", "--updated"])
		var pid := OS.create_process(OS.get_executable_path(), args)
		if pid > 0:
			get_tree().quit()
			return
		_status("Could not restart, starting the installed version.")
	_start_game()


# ---------------------------------------------------------------- renderer

## The renderer the player chose ("forward_plus" or "gl_compatibility"), or
## "" for the project default.
static func preferred_renderer() -> String:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	return str(cfg.get_value("video", "renderer", ""))


static func set_preferred_renderer(method: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("video", "renderer", method)
	cfg.save(SETTINGS)


## Command-line arguments that select the preferred renderer, if it differs
## from the running one.
static func renderer_args() -> PackedStringArray:
	var want := preferred_renderer()
	if want == "" or want == RenderingServer.get_current_rendering_method():
		return PackedStringArray()
	if want == "gl_compatibility":
		return PackedStringArray(["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"])
	return PackedStringArray(["--rendering-method", want])


## Restarts with the same engine arguments plus the preferred renderer, if it
## isn't the one running. Returns true if a restart was started.
func _relaunch_with_renderer() -> bool:
	var extra := renderer_args()
	if extra.is_empty() or "--renderer-applied" in OS.get_cmdline_user_args():
		return false
	var args := PackedStringArray()
	var skip := false
	for a in OS.get_cmdline_args():
		if skip:
			skip = false
			continue
		if a in ["--rendering-method", "--rendering-driver"]:
			skip = true
			continue
		args.append(a)
	args.append_array(extra)
	args.append_array(["--", "--updated", "--renderer-applied"])
	if OS.create_process(OS.get_executable_path(), args) > 0:
		get_tree().quit.call_deferred()
		return true
	return false


## Switches between Forward+ and the lighter Compatibility renderer, then
## restarts the game (which re-runs the update check too).
static func toggle_renderer_and_restart(tree: SceneTree) -> void:
	var now := RenderingServer.get_current_rendering_method()
	set_preferred_renderer("forward_plus" if now == "gl_compatibility" else "gl_compatibility")
	OS.set_restart_on_exit(true, PackedStringArray())
	tree.quit()


func _start_game() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


# ---------------------------------------------------------------- network

func _fetch_json(url: String) -> Dictionary:
	var http := _new_http()
	http.timeout = CHECK_TIMEOUT
	# Cache-buster so CDNs don't hand out a stale version file.
	if http.request(url + "?t=%d" % Time.get_unix_time_from_system()) != OK:
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return {}
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _download(url: String, path: String) -> bool:
	_http = _new_http()
	_http.download_file = path
	_http.timeout = 300.0
	if _http.request(url) != OK:
		return false
	var res: Array = await _http.request_completed
	_http.queue_free()
	_http = null
	return res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200 and FileAccess.file_exists(path) \
			and FileAccess.get_file_as_bytes(path).size() > 0


func _new_http() -> HTTPRequest:
	var http := HTTPRequest.new()
	http.max_redirects = 10
	add_child(http)
	return http


func _process(_delta: float) -> void:
	if _http and _bar:
		var total := _http.get_body_size()
		_bar.visible = total > 0
		if total > 0:
			_bar.value = 100.0 * _http.get_downloaded_bytes() / total


# ---------------------------------------------------------------- helpers

static func _newer(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty():
		return false
	if b.is_empty():
		return true
	return float(a.get("time", 0)) > float(b.get("time", 0)) and a.get("commit", "") != b.get("commit", "")


static func _short(v: Dictionary) -> String:
	return str(v.get("commit", "?")).substr(0, 7)


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(420, 0)
	box.position -= Vector2(210, 30)
	add_child(box)
	var title := Label.new()
	title.text = "POINT CLOUD WORLD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	box.add_child(title)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_label)
	_bar = ProgressBar.new()
	_bar.visible = false
	box.add_child(_bar)


func _status(text: String) -> void:
	print("[launcher] ", text)
	if _label:
		_label.text = text
