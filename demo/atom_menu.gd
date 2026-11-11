class_name AtomMenu
extends RefCounted
## A menu made of atoms. Holds the menu's shape as a set of points (title,
## button plates and labels) in two textures; PointCloud.set_menu() sends a
## cloud's atoms to those points. Menu space: x right, y up, z towards the
## viewer, in metres, centred on the menu.

const TEX_WIDTH := 512

var pos_tex: ImageTexture
var col_tex: ImageTexture
var count := 0
## name -> Rect2 in menu space (x, y).
var buttons := {}

var _pos := PackedFloat32Array()
var _col := PackedByteArray()
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 5


## A flat plate of `n` points.
func add_plate(rect: Rect2, z: float, color: Color, n: int) -> void:
	for i in n:
		_add(Vector3(rect.position.x + _rng.randf() * rect.size.x, rect.position.y + _rng.randf() * rect.size.y, z), color)


## Text fitted to `height`, centred on `at`.
func add_text(string: String, at: Vector2, height: float, z: float, color: Color, n: int) -> void:
	var d := PointSampler.text(string, n, 64, 0.05)
	var box := d.aabb
	var k := height / maxf(box.size.y, 1e-6)
	var mid := box.get_center()
	for p in d.positions:
		_add(Vector3(at.x + (p.x - mid.x) * k, at.y + (p.y - mid.y) * k, z), color)


func add_button(id: String, label: String, rect: Rect2, plate: Color, ink: Color) -> void:
	buttons[id] = rect
	add_plate(rect, 0.0, plate, 30000)
	add_text(label, rect.get_center(), rect.size.y * 0.42, 0.03, ink, 26000)


func _add(p: Vector3, c: Color) -> void:
	_pos.append_array([p.x, p.y, p.z, 1.0])
	_col.append_array([int(c.r8), int(c.g8), int(c.b8), 255])
	count += 1


## Call once everything is added.
func bake() -> void:
	var h := ceili(float(count) / TEX_WIDTH)
	_pos.resize(TEX_WIDTH * h * 4)
	_col.resize(TEX_WIDTH * h * 4)
	pos_tex = ImageTexture.create_from_image(Image.create_from_data(TEX_WIDTH, h, false, Image.FORMAT_RGBAF, _pos.to_byte_array()))
	col_tex = ImageTexture.create_from_image(Image.create_from_data(TEX_WIDTH, h, false, Image.FORMAT_RGBA8, _col))


## The button under a screen position, or "".
func button_at(screen: Vector2, cam: Camera3D, menu_world: Transform3D) -> String:
	for id in buttons:
		var r: Rect2 = buttons[id]
		var a := cam.unproject_position(menu_world * Vector3(r.position.x, r.position.y, 0.0))
		var b := cam.unproject_position(menu_world * Vector3(r.end.x, r.end.y, 0.0))
		if Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()).has_point(screen):
			return id
	return ""
