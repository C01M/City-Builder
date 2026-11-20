class_name TriBatch
extends RefCounted
## Collects colored triangles for debug/gizmo drawing into an ImmediateMesh.

var verts := PackedVector3Array()
var colors := PackedColorArray()


static func make_material(on_top: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if on_top:
		m.no_depth_test = true
		m.render_priority = 10
	return m


func tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	verts.append(a)
	verts.append(b)
	verts.append(c)
	colors.append(color)
	colors.append(color)
	colors.append(color)


## Flat band of `width` following `points`.
func ribbon(points: PackedVector3Array, width: float, color: Color) -> void:
	var n := points.size()
	if n < 2:
		return
	var half := width * 0.5
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in n:
		var dir := points[mini(i + 1, n - 1)] - points[maxi(i - 1, 0)]
		dir.y = 0.0
		if dir.length_squared() < 1e-8:
			dir = Vector3.RIGHT
		var side := dir.normalized().cross(Vector3.UP) * half
		var l := points[i] - side
		var r := points[i] + side
		if i > 0:
			tri(prev_l, prev_r, r, color)
			tri(prev_l, r, l, color)
		prev_l = l
		prev_r = r


func disc(center: Vector3, radius: float, color: Color, segments: int = 20) -> void:
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		tri(center, center + Vector3(cos(a0), 0, sin(a0)) * radius, center + Vector3(cos(a1), 0, sin(a1)) * radius, color)


func ring(center: Vector3, radius: float, thickness: float, color: Color, segments: int = 28) -> void:
	var r0 := radius - thickness * 0.5
	var r1 := radius + thickness * 0.5
	for i in segments:
		var d0 := Vector3(cos(TAU * i / segments), 0, sin(TAU * i / segments))
		var d1 := Vector3(cos(TAU * (i + 1) / segments), 0, sin(TAU * (i + 1) / segments))
		tri(center + d0 * r0, center + d0 * r1, center + d1 * r1, color)
		tri(center + d0 * r0, center + d1 * r1, center + d1 * r0, color)


## Arrowhead at `pos` pointing along `dir`.
func arrow(pos: Vector3, dir: Vector3, size: float, color: Color) -> void:
	var d := Vector3(dir.x, 0, dir.z).normalized()
	var side := d.cross(Vector3.UP) * size * 0.6
	tri(pos + d * size, pos - d * size * 0.5 + side, pos - d * size * 0.5 - side, color)


## Arrowheads every `spacing` meters along `points`.
func arrows_along(points: PackedVector3Array, spacing: float, size: float, color: Color) -> void:
	var next := spacing * 0.5
	var walked := 0.0
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var seg_len := a.distance_to(b)
		while seg_len > 0.0 and next <= walked + seg_len:
			arrow(a.lerp(b, (next - walked) / seg_len), b - a, size, color)
			next += spacing
		walked += seg_len


func commit(im: ImmediateMesh, material: Material) -> void:
	if verts.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for i in verts.size():
		im.surface_set_color(colors[i])
		im.surface_add_vertex(verts[i])
	im.surface_end()
