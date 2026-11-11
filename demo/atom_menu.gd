class_name AtomMenu
extends RefCounted
## A menu made of atoms. Holds the menu's shape as a set of points with
## normals (title, button slabs and labels, all with real thickness) in
## textures; PointCloud.set_menu() sends a cloud's atoms to those points.
## Menu space: x right, y up, z towards the viewer, in metres, centred on the
## menu.

const TEX_WIDTH := 512

var pos_tex: ImageTexture
var col_tex: ImageTexture
var nrm_tex: ImageTexture
var count := 0
## name -> Rect2 in menu space (x, y).
var buttons := {}

var _pos := PackedFloat32Array()
var _col := PackedByteArray()
var _nrm := PackedByteArray()
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 5


## A slab: front face at `z`, `depth` thick, with its four sides.
func add_slab(rect: Rect2, z: float, depth: float, color: Color, n: int) -> void:
	var front := rect.get_area()
	var sides := (rect.size.x + rect.size.y) * 2.0 * depth
	var side_color := color.darkened(0.35)
	for i in n:
		if _rng.randf() * (front + sides) < front:
			_add(Vector3(rect.position.x + _rng.randf() * rect.size.x, rect.position.y + _rng.randf() * rect.size.y, z), color, Vector3.BACK)
			continue
		var back := z - _rng.randf() * depth
		var along := _rng.randf() * (rect.size.x + rect.size.y)
		var flip := _rng.randf() < 0.5
		if along < rect.size.x:
			_add(Vector3(rect.position.x + along, rect.end.y if flip else rect.position.y, back), side_color, Vector3.UP if flip else Vector3.DOWN)
		else:
			_add(Vector3(rect.end.x if flip else rect.position.x, rect.position.y + along - rect.size.x, back), side_color, Vector3.RIGHT if flip else Vector3.LEFT)


## Extruded text fitted to `height`, centred on `at`, its front at `z`.
func add_text(string: String, at: Vector2, height: float, z: float, color: Color, n: int) -> void:
	var d := PointSampler.text(string, n, 64, 0.3)
	var box := d.aabb
	var k := height / maxf(box.size.y, 1e-6)
	var mid := box.get_center()
	for i in d.get_surface_count():
		var p := d.positions[i]
		var nn := d.normals[i]
		_add(Vector3(at.x + (p.x - mid.x) * k, at.y + (p.y - mid.y) * k, z + (p.z - box.end.z) * k),
				color if nn.z > 0.5 else color.darkened(0.3), nn)


func add_button(id: String, label: String, rect: Rect2, plate: Color, ink: Color) -> void:
	buttons[id] = rect
	add_slab(rect, 0.0, 0.07, plate, 34000)
	add_text(label, rect.get_center(), rect.size.y * 0.42, 0.045, ink, 30000)


func _add(p: Vector3, c: Color, n: Vector3) -> void:
	_pos.append_array([p.x, p.y, p.z, 1.0])
	_col.append_array([int(c.r8), int(c.g8), int(c.b8), 255])
	_nrm.append_array([int(n.x * 127.0 + 128.0), int(n.y * 127.0 + 128.0), int(n.z * 127.0 + 128.0), 255])
	count += 1


## Call once everything is added.
func bake() -> void:
	var h := ceili(float(count) / TEX_WIDTH)
	_pos.resize(TEX_WIDTH * h * 4)
	_col.resize(TEX_WIDTH * h * 4)
	_nrm.resize(TEX_WIDTH * h * 4)
	pos_tex = ImageTexture.create_from_image(Image.create_from_data(TEX_WIDTH, h, false, Image.FORMAT_RGBAF, _pos.to_byte_array()))
	col_tex = ImageTexture.create_from_image(Image.create_from_data(TEX_WIDTH, h, false, Image.FORMAT_RGBA8, _col))
	nrm_tex = ImageTexture.create_from_image(Image.create_from_data(TEX_WIDTH, h, false, Image.FORMAT_RGBA8, _nrm))


## The button under a screen position, or "".
func button_at(screen: Vector2, cam: Camera3D, menu_world: Transform3D) -> String:
	for id in buttons:
		var r: Rect2 = buttons[id]
		var a := cam.unproject_position(menu_world * Vector3(r.position.x, r.position.y, 0.0))
		var b := cam.unproject_position(menu_world * Vector3(r.end.x, r.end.y, 0.0))
		if Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()).has_point(screen):
			return id
	return ""
