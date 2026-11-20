class_name RoadMeshBuilder
extends RefCounted
## Builds flat road meshes: strips along curves and filled junction polygons.

const SAMPLE_SPACING := 2.0


## Road surface along `curve` between two distances from its start.
static func build_strip(curve: RoadCurve, from_d: float, to_d: float, width: float, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 1 if curve.is_straight() else maxi(1, ceili((to_d - from_d) / SAMPLE_SPACING))
	var half := width * 0.5
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in steps + 1:
		var t := curve.t_at_distance(lerpf(from_d, to_d, float(i) / steps))
		var p := curve.point(t)
		var right := curve.tangent(t).cross(Vector3.UP).normalized()
		var l := p - right * half
		var r := p + right * half
		l.y = y
		r.y = y
		if i > 0:
			add_tri(st, prev_l, prev_r, r)
			add_tri(st, prev_l, r, l)
		prev_l = l
		prev_r = r
	return st.commit()


## Road surface whose left and right sides start and end at their own distances
## along `curve` (slanted end edges). `half_width.call(d)` gives the half width
## at distance d; pass `varying_width` so straight roads still get enough samples.
static func build_strip_sides(curve: RoadCurve, from_l: float, from_r: float, to_l: float, to_r: float,
		half_width: Callable, y: float, varying_width: bool = false) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var span := maxf(to_l - from_l, to_r - from_r)
	var steps := 1 if curve.is_straight() and not varying_width else maxi(1, ceili(span / SAMPLE_SPACING))
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in steps + 1:
		var f := float(i) / steps
		var l := _edge_point(curve, lerpf(from_l, to_l, f), -1.0, half_width, y)
		var r := _edge_point(curve, lerpf(from_r, to_r, f), 1.0, half_width, y)
		if i > 0:
			add_tri(st, prev_l, prev_r, r)
			add_tri(st, prev_l, r, l)
		prev_l = l
		prev_r = r
	return st.commit()


static func _edge_point(curve: RoadCurve, d: float, side: float, half_width: Callable, y: float) -> Vector3:
	var t := curve.t_at_distance(d)
	var p := curve.point(t) + curve.tangent(t).cross(Vector3.UP).normalized() * side * float(half_width.call(d))
	p.y = y
	return p


## Filled polygon given as ground-plane (x, z) points. Returns null if it can't be triangulated.
static func build_polygon(points: PackedVector2Array, y: float) -> ArrayMesh:
	var indices := Geometry2D.triangulate_polygon(points)
	if indices.is_empty():
		points = Geometry2D.convex_hull(points)
		if points.size() > 1 and points[0].is_equal_approx(points[points.size() - 1]):
			points.remove_at(points.size() - 1)
		indices = Geometry2D.triangulate_polygon(points)
		if indices.is_empty():
			return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0, indices.size(), 3):
		add_tri(st,
			Vector3(points[indices[i]].x, y, points[indices[i]].y),
			Vector3(points[indices[i + 1]].x, y, points[indices[i + 1]].y),
			Vector3(points[indices[i + 2]].x, y, points[indices[i + 2]].y))
	return st.commit()


## Adds an upward-facing triangle (Godot treats clockwise as front-facing).
static func add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).y > 0.0:
		var tmp := b
		b = c
		c = tmp
	for v: Vector3 in [a, b, c]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z) / 3.0)
		st.add_vertex(v)
