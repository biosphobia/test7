// Point cloud renderer.
//
// Every point lives in a set of data textures (one texel per point) that are
// written by PointCloud.gd. The mesh that gets drawn is just N dummy vertices
// rendered as GL points; the vertex shader looks up its own point with
// VERTEX_ID and computes position / colour / size from the textures plus the
// effect uniforms below. Because everything happens here, effects cost no CPU
// time no matter how many points a cloud has.
//
// Want your own effect? Edit custom_effect() near the bottom, or copy this
// shader and assign it with PointCloud.shader_override.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Fast variant (default). point_cloud_exact.gdshader writes exact per-pixel
// depth instead; nicer where discs intersect, but much slower to fill.
#include "res://pointcloud/point_cloud.gdshaderinc"
