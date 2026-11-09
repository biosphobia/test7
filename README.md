# Point Cloud World

A Godot 4.4+ framework where every model — props, terrain, the player, enemies —
is a huge cloud of tiny points that looks solid but can be edited, animated
and destroyed point by point.

A cube looks like a normal lit cube, but it's 300,000 points. You can make the
points shiver, chip them off with gunfire, dissolve the whole thing into
drifting sparks, or have every point fly over and form a sphere, a torus or 3D
text, changing colour on the way.

| | |
|---|---|
| ![Demo: player, carved cube with glowing core, skinned worm](docs/demo.png) | ![Dissolving cube](docs/dissolve.png) |
| ![300k / 200k / 150k points that read as solid meshes](docs/solid_shapes.png) | Everything in these shots is points. Top left: the cube has been shot (its glowing interior shows through), and the worm is a skinned, animated mesh. Top right: a dissolve. Bottom: three point clouds that look like ordinary meshes. |

## Running the demo

Open the folder in **Godot 4.4 or newer** and press Play (`demo/main.tscn`).

| Input | Action |
|---|---|
| WASD / Shift / Space / mouse | move, sprint, jump, look (third person) |
| LMB (hold) | shoot: knocks points off whatever you aim at |
| RMB (hold) | paint points with a cycling colour |
| E | morph (the shape-shifter cycles cube → sphere → torus → "POINTS"; anything else turns into a sphere and back) |
| Q | dissolve / reassemble |
| F | explode pulse |
| V / G | toggle vibrate / wobble |
| H | heal: carved-off points fly back into place |
| R | restore everything instantly |
| Esc | free the mouse (click to recapture) |

The scene holds about 2.8 million points: ground, a morphing cube, a textured
crate, monoliths, a jelly orb, the player and a skinned worm enemy that crawls
around. Shoot the worm 15 times and it dissolves, then reassembles.

## How it works

```
PointCloudData  (Resource)     positions, colors, normals, optional bone weights
      │  made by
PointSampler    (static)       mesh → points: area-weighted, takes colour from material
      │  drawn by                 albedo/texture/vertex colours, copies skin weights
PointCloud      (GeometryInstance3D)
      │  uploads data to float textures, one texel per point
point_cloud.gdshader           vertex shader reads its point via VERTEX_ID and applies
                               skinning, morph, effects, debris, ripples; outputs a
                               GL point sized in world units
```

* **Rendering.** The drawn mesh is N dummy vertices with `PRIMITIVE_POINTS`.
  The shader looks up each point's data and sets `POINT_SIZE` so the point keeps
  a constant world size. The sampler picks a size from the point density, so
  surfaces close up and look solid. Points are opaque and lit (or `unshaded`),
  write depth and cast shadows like normal geometry.
* **Effects cost no CPU.** Vibrate, wobble, explode, dissolve, morph and ripples
  are shader uniforms. Every point gets a stable random seed from a hash of its
  index, which is what makes the motion look per-point.
* **Destruction is per point.** `carve()` uses a spatial grid (built on a worker
  thread) to find points near the hit. It writes a detach time and velocity
  into a state texture, and the shader then flies those points ballistically
  and fades them out. `heal()` pulls them back.
* **Animation.** Skinned meshes keep their bone indices and weights per point,
  and the bone matrices are uploaded each frame from the `Skeleton3D`. So an
  imported character with an `AnimationPlayer` animates as points without any
  extra work.
* **Solid interiors.** With `Fill.SOLID` or `Fill.SHELL`, part of the points go
  inside the model. When you chip at it there is material underneath (in the
  demo the cube has a hot glowing core).

## Using it in your game

```gdscript
# From primitives
var cube := PointCloud.new()
cube.data = PointSampler.box(Vector3(2, 2, 2), 300_000, {"color": Color.ORANGE})
add_child(cube)

# From any mesh / imported model (keeps textures and skeleton animation)
var character := load("res://enemy.glb").instantiate()
add_child(character)
PointCloud.convert_scene(character, 20000.0)   # points per m² of surface

# Effects — all animatable with Tweens/AnimationPlayer
cube.vibrate_amplitude = 0.02
cube.wobble_amplitude = 0.05
cube.dissolve_out(3.0)                 # then cube.reassemble(2.0)
cube.explode_pulse()
cube.morph_to(PointSampler.sphere(1.2, 1000), 2.0)   # counts are matched for you
cube.carve(hit_position, 0.4)          # chip a hole; points fly off
cube.impact(hit_position)              # ripple through the surface
cube.paint(hit_position, 0.5, Color.RED)
cube.heal(1.5)

# Edit individual points from code
var p := cube.data.positions
for i in p.size():
	p[i].y += sin(p[i].x * 4.0) * 0.1
cube.data.positions = p
cube.commit()
```

You can also add a `PointCloud` node in the editor, set **Source Mesh**, and
press **Sample source mesh**. Set **Source Bake Path** to a `.res` file so large
clouds are saved in binary form instead of inside the scene. Effect sliders
preview live in the editor.

### Writing your own point effects

Edit `custom_effect()` in `pointcloud/point_cloud.gdshader`. If you want
different effects on different objects, copy the shader and assign the copy to
`PointCloud.shader_override`. The function receives each point's position,
normal, colour, size, rest position, random seed, index and the time. Anything
you can write in GLSL runs on every point every frame.

## Files

| Path | What |
|---|---|
| `pointcloud/point_cloud.gd` | `PointCloud` node: upload, effects API, carving, skinning |
| `pointcloud/point_cloud.gdshader` | the per-point renderer and effects |
| `pointcloud/point_sampler.gd` | mesh → points, primitive shapes, 3D text, morph matching |
| `pointcloud/point_cloud_data.gd` | `PointCloudData` resource |
| `pointcloud/point_grid.gd` | spatial grid for carve/paint queries |
| `demo/` | the playable sandbox (player, worm enemy, props) |
| `tests/` | `smoke_test.tscn` / `demo_capture.tscn` render screenshots headlessly |

## Performance notes and limits

* GPU cost scales with the total point count. A few million points are
  comfortable on a desktop GPU. Points beyond the camera's culling bounds are
  free, because each cloud is culled as a whole.
* Sampling runs in GDScript at roughly 1 µs per point, so 300k points take about
  0.3 s. For big clouds, bake once and save the `.res` file.
* Carving/painting re-uploads that cloud's state/colour texture (16 bytes per
  point), at most once per frame.
* Collision uses ordinary `CollisionShape3D`s and doesn't follow carved holes.
* Debris and dissolve are in the cloud's local space, so the debris moves with
  the object.
* `point_size` is set in world units and clamped to `max_pixel_size`. In the
  Compatibility renderer, very close points top out at the driver's maximum
  point size.
