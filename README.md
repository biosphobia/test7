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
| ![A solid cube made of 1.6 million dots](docs/solid_shapes.png) | ![Shooting the cube: dots chip off, glowing core shows](docs/demo.png) |
| ![Dissolving cube](docs/dissolve.png) | Everything in these shots is dots, 10.8 million in the scene. Top left: an intact 1.6-million-dot cube. Top right: the same cube being shot, with dots flying off and its glowing interior showing. Bottom left: a dissolve. Record your own with `tests/demo_video.tscn` (see below). |

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
| [ / ] | halve / double the dots per point on the aimed object (1–16) |
| R | restore everything instantly |
| Esc | free the mouse (click to recapture) |

The scene holds about 3.6 million stored points drawn as about 10.8 million
dots: ground, a morphing cube, a textured crate, monoliths, a jelly orb, the
player and a skinned worm enemy that crawls around. Shoot the worm 15 times and it dissolves, then reassembles.

## How it works

```
PointCloudData  (Resource)     positions, colors, normals, optional bone weights
      │  made by
PointSampler    (static)       mesh → points: area-weighted, takes colour from material
      │  drawn by                 albedo/texture/vertex colours, copies skin weights
PointCloud      (GeometryInstance3D)
      │  uploads data to float textures, one texel per point
point_cloud.gdshader           draws `density` dots per point; each dot finds its point,
                               applies skinning, morph, effects, debris, ripples and
                               outputs a GL point sized in world units
```

* **Rendering.** One shared batch of 32,768 dummy points (`PRIMITIVE_POINTS`) is
  drawn instanced as many times as needed. Each dot works out its index from
  `INSTANCE_ID` and `VERTEX_ID`, looks up its data and sets `POINT_SIZE` so it
  keeps a constant world size. Memory doesn't grow with the dot count. Dots are
  opaque and lit (or `unshaded`), write depth and cast shadows like normal
  geometry.
* **Seamless surfaces.** The sampler spreads points evenly (stratified per
  triangle plus an R2 low-discrepancy sequence) instead of randomly, and picks
  a dot size that just closes the gaps. Interior points stay a few dot-widths
  below the surface so they can't show through.
* **Density: more dots for free.** `PointCloud.density` draws N dots per stored
  point, spread over that point's patch of surface (a golden-angle spiral in
  the tangent plane). Every dot has its own seed, so effects and debris act on
  each dot separately. Sampling time, CPU memory and carve cost stay the same:
  a 400k-point cube at density 4 is 1.6M independently moving dots.
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
cube.density = 8                       # 8 dots per stored point: finer, more seamless

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
`PointCloud.shader_override`. The function receives each dot's position,
normal, colour, size, rest position, random seed, its stored point's index,
which of that point's dots it is (`sub`), and the time. Anything
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
| `tests/` | `smoke_test.tscn` / `demo_capture.tscn` render screenshots headlessly; `demo_video.tscn` is a scripted showcase for Movie Maker |

## Recording a video

```sh
godot --path . --write-movie out.avi --fixed-fps 30 res://tests/demo_video.tscn
```

Movie Maker renders at a fixed frame rate however slow the machine is. The
point clouds' clock follows game time (`PointCloud.now()`), so all effects
stay in sync in the recording.

## Performance notes and limits

* GPU cost scales with the total dot count (stored points × density). Ten
  million dots or so should be fine on a desktop GPU; lower `density` for
  weaker hardware. Shadow-casting clouds are drawn again for each shadow
  cascade, so switch `cast_shadow` off where shadows aren't visible (the demo
  does this for the ground). Points beyond the camera's culling bounds are
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
