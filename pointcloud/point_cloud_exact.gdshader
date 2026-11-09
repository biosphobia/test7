// Exact-depth variant of point_cloud.gdshader. Select it with
// PointCloud.exact_depth = true.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

#define EXACT_DEPTH
#include "res://pointcloud/point_cloud.gdshaderinc"
