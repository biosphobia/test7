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

## Download (Windows)

Get **PointCloudWorld.exe** from the
[latest release](https://github.com/biosphobia/test7/releases/tag/latest) and
run it. You only download it once. Every push to this repository rebuilds the
game on GitHub Actions, and the exe fetches the new content (a ~100 KB pack)
the next time it starts. If you're offline, it starts the last version it
downloaded. The build's commit is shown in the bottom-left corner.

How it works: `launcher/launcher.gd` is the startup scene. It compares
`version.json` on the release with the version it's running. If GitHub has a
newer build, it downloads `game.pck` and restarts the exe on it with
`--main-pack`. `.github/workflows/build.yml` produces those files.

## Running the demo

Open the folder in **Godot 4.4 or newer** and press Play (`demo/main.tscn`).

| Input | Action |
|---|---|
| WASD / Shift / Space / mouse | move, sprint, jump, look (first person) |
| LMB (hold) | shoot: knocks points off whatever you aim at |
| RMB (hold) | paint points with a cycling colour |
| E | morph (the shape-shifter cycles cube → sphere → torus → "POINTS"; anything else turns into a sphere and back) |
| Q | dissolve / reassemble |
| F | explode pulse |
| V / G | toggle vibrate / wobble |
| H | heal: carved-off points fly back into place |
| [ / ] | halve / double the dots per point on the aimed object (1–16) |
| - / = / 0 | less / more detail by hand, or back to automatic (targets 60 fps) |
| F10 | switch renderer: Compatibility (default, fastest) ↔ Forward+ |
| R | restore everything instantly |
| F9 | smoothing filter on/off (edge-aware blend over the 3D view) |
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
* **Solid surfaces, not dots.** Each dot is drawn as a small disc lying in
  the surface's tangent plane. The fragment shader intersects every pixel's
  view ray with that disc and writes the exact depth, so overlapping discs
  fuse into one continuous surface, like real geometry. Points are spread
  evenly (stratified per triangle plus an R2 low-discrepancy sequence).
* **Smooth shading.** Each point stores its surface's curvature tensor,
  fitted from the source mesh's vertex normals. The shader bends the normal
  across each disc with it, which reproduces the mesh's interpolated normals,
  so lighting is continuous across dots.
* **Sharp edges and detail.** Resting dots are trimmed at the cloud's bounding
  box, so box edges are crisp. Fine colour detail can come from
  `surface_texture`, sampled per pixel (triplanar, mip level from the exact
  pixel footprint) and multiplied with the dot colours. The demo floor grid
  and crate use it. Dot colour alpha masks it, so interior points stay plain.
* **Density: more dots for free.** `PointCloud.density` draws N dots per stored
  point, spread over that point's patch of surface (a golden-angle spiral in
  the tangent plane). Every dot has its own seed, so effects and debris act on
  each dot separately. Sampling time, CPU memory and carve cost stay the same:
  a 400k-point cube at density 4 is 1.6M independently moving dots.
* **Effects cost no CPU.** Vibrate, wobble, explode, dissolve, morph and ripples
  are shader uniforms. Every point gets a stable random seed from a hash of its
  index, which is what makes the motion look per-point.
* **Destruction is per point, with no stalls.** `carve()` hands the shader a
  carve sphere: the shader detaches the dots inside it, flies them
  ballistically as small lit beads and fades them out, and turns the dots
  around it into the hole's wall (normals facing into the hole, darkened
  like a cavity). A worker thread later folds batches of carves into a state
  texture with exactly the same maths (same hashes), so nothing changes on
  screen. `heal()` pulls the debris back.
* **Morphs never block.** `morph_to()` prepares the target on a worker thread
  (generating it too, if you pass a Callable), uploads its textures over a
  few frames and then starts. Targets stay cached on the GPU, and finishing a
  morph swaps textures instead of re-uploading. `prepare_morph_target()`
  warms the cache ahead of time.
* **Dots in flight look like beads.** Debris, dissolving, exploding and
  mid-morph dots are drawn as small round dots with sphere-like shading
  instead of flat surface discs.
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
cube.morph_to(PointSampler.sphere(1.2, 1000), 2.0)   # counts matched; never blocks
cube.prepare_morph_target(other_shape)  # optional: warm up so the morph starts instantly
cube.carve(hit_position, 0.4)          # chip a hole; points fly off
cube.impact(hit_position)              # ripple through the surface
cube.paint(hit_position, 0.5, Color.RED)
cube.heal(1.5)
cube.density = 8                       # 8 dots per stored point: finer, more seamless
cube.surface_texture = load("res://wood.png")   # per-pixel detail on top of dot colours
cube.texture_tile = Vector3(2, 2, 2)

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

## Performance

The demo targets 60 fps on modest GPUs. It holds about 3.5 million stored
points but draws only around 0.5–1 million dots per frame, and auto quality
trades detail to hold the target. The main techniques:

* **Level of detail.** Points are stored in *progressive* order: every prefix
  of the list is evenly spread over the surface (bit-reversed strata plus
  per-triangle R2 sequences). Each frame a cloud estimates how big it is on
  screen and draws only the prefix it needs for `PointCloud.lod_spacing_px`
  (default 2 px) between points, enlarging them to keep the surface closed.
  It's a single `MultiMesh.visible_instance_count` change, with no CPU work
  per point.
* **Interior points only when exposed.** Points are stored as
  `[surface | interior]`; the interior fill is drawn only while something
  reveals it (carving, dissolve, explode, morph).
* **Back-facing dots are dropped** in the vertex shader (and for shadows,
  dots facing away from the light).
* **Cheap shadows.** A cloud doesn't cast shadows itself; a hidden copy with a
  quarter of the dots does, and the demo sun uses 2 cascades instead of 4.
* **Early depth test.** The default shader keeps each dot's flat depth, so the
  depth prepass rejects hidden pixels before they're shaded. Set
  `PointCloud.exact_depth = true` for the slower variant that writes exact
  per-pixel depth.
* **Smaller data.** 8-bit colours and half-float normals and curvature; the
  debris and ripple lookups are skipped while nothing is carved or hit.
* **Tiled terrain with a flat proxy.** The demo ground is split into tiles,
  and each tile has `flat_proxy` on: while intact it's drawn as one plane
  with exactly the dots' colour, texture and material. Shots cut holes into
  the plane (pending carves analytically, baked ones through a small mask)
  and only the hole walls and debris are drawn as dots. Effects such as
  morph or dissolve switch the tile back to full dots. Uncarved floor costs
  almost nothing.
* **Shadow maps.** Shadow-pass dots are plain squares sized to close gaps
  and pushed away from the light by about their radius, so shadows are solid
  and surfaces don't shadow themselves.
* **Lightweight renderer by default.** The project uses Godot's Compatibility
  (OpenGL) renderer, which is much cheaper on weak GPUs; it did a demo frame
  about 3.6× faster than Forward+ in testing. Press **F10** in game to switch
  to Forward+ (nicer, heavier). The launcher restarts the game with the
  chosen renderer and remembers it.
* **Auto quality.** `PointCloudQuality` measures GPU time and adjusts
  `lod_spacing_px` (and, if needed, the 3D render scale with FSR upscaling)
  to hold the target frame rate. Where the driver doesn't report GPU time
  (common with Compatibility), it works from frame time: it steps down when
  below target and periodically probes back up. In the demo, `-` / `=` set detail by hand and
  `0` returns to automatic. The HUD shows how many dots are drawn.

Measured with CPU-only software rendering (so only the ratio means
anything), a demo frame went from 9.6 s to about 0.45 s at the same detail,
roughly 20× less work per frame, before auto quality does anything.

`tests/hitch_test.tscn` measures how long gameplay actions block the main
thread (morphing, shooting); they are all well under a millisecond.

### Limits

* Startup samples every model in GDScript (about 1.5 µs per point), so the
  demo takes 10–15 s to build. Bake large clouds to `.res` files.
* Collision uses ordinary `CollisionShape3D`s and doesn't follow carved holes.
* Debris and dissolve are in the cloud's local space, so debris moves with the
  object.
* If you sort points yourself (e.g. `PointSampler.sort_spatially`), level of
  detail will thin them unevenly; use `match_order` for morph targets.
