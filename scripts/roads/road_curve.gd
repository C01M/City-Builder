class_name RoadCurve
extends RefCounted
## Cubic Bezier curve on the ground plane. Straight and quadratic curves are
## stored as cubics too, so every segment uses the same math.
## Treat instances as immutable: the arc-length table is cached.

const LUT_STEPS := 64

var p0: Vector3
var p1: Vector3
var p2: Vector3
var p3: Vector3

var _length: float = -1.0
var _lut_d := PackedFloat32Array()


func _init(a: Vector3 = Vector3.ZERO, b: Vector3 = Vector3.ZERO, c: Vector3 = Vector3.ZERO, d: Vector3 = Vector3.ZERO) -> void:
	p0 = a
	p1 = b
	p2 = c
	p3 = d


static func straight(a: Vector3, b: Vector3) -> RoadCurve:
	return RoadCurve.new(a, a.lerp(b, 1.0 / 3.0), a.lerp(b, 2.0 / 3.0), b)


## Quadratic Bezier (start, control, end) converted to a cubic.
static func quadratic(a: Vector3, control: Vector3, b: Vector3) -> RoadCurve:
	return RoadCurve.new(a, a.lerp(control, 2.0 / 3.0), b.lerp(control, 2.0 / 3.0), b)


## Symmetric (near-circular) arc that leaves `a` along `dir` and ends at `b`.
static func arc(a: Vector3, dir: Vector3, b: Vector3) -> RoadCurve:
	var chord := b - a
	var chord_len := chord.length()
	if chord_len < 0.001 or dir.length_squared() < 0.0001:
		return straight(a, b)
	var d := dir.normalized()
	var cos_theta := maxf(d.dot(chord / chord_len), 0.2)
	return quadratic(a, a + d * (chord_len * 0.5 / cos_theta), b)


func reversed() -> RoadCurve:
	return RoadCurve.new(p3, p2, p1, p0)


## Copy with the end points moved; the inner control points move along with them.
func with_endpoints(start: Vector3, end: Vector3) -> RoadCurve:
	return RoadCurve.new(start, p1 + (start - p0), p2 + (end - p3), end)


func point(t: float) -> Vector3:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)


func derivative(t: float) -> Vector3:
	var u := 1.0 - t
	return (p1 - p0) * (3.0 * u * u) + (p2 - p1) * (6.0 * u * t) + (p3 - p2) * (3.0 * t * t)


func tangent(t: float) -> Vector3:
	var d := derivative(t)
	if d.length_squared() < 1e-8:
		d = point(minf(t + 0.001, 1.0)) - point(maxf(t - 0.001, 0.0))
	if d.length_squared() < 1e-12:
		d = p3 - p0
	d.y = 0.0
	return d.normalized()


func is_straight() -> bool:
	var line := p3 - p0
	var len_sq := line.length_squared()
	if len_sq < 1e-6:
		return true
	for c: Vector3 in [p1, p2]:
		var v := c - p0
		var proj := v.dot(line) / len_sq
		if proj < -0.001 or proj > 1.001:
			return false
		if (v - line * proj).length() > 0.01:
			return false
	return true


func get_length() -> float:
	_ensure_lut()
	return _length


func t_at_distance(dist: float) -> float:
	_ensure_lut()
	if dist <= 0.0:
		return 0.0
	if dist >= _length:
		return 1.0
	var lo := 0
	var hi := LUT_STEPS
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if _lut_d[mid] < dist:
			lo = mid
		else:
			hi = mid
	var span := _lut_d[hi] - _lut_d[lo]
	var f := 0.0 if span <= 0.0 else (dist - _lut_d[lo]) / span
	return (lo + f) / LUT_STEPS


func distance_at_t(t: float) -> float:
	_ensure_lut()
	var f := clampf(t, 0.0, 1.0) * LUT_STEPS
	var i := mini(int(f), LUT_STEPS - 1)
	return lerpf(_lut_d[i], _lut_d[i + 1], f - i)


## Parameter of the point on the curve closest to `pos` (ignoring height).
func closest_t(pos: Vector3) -> float:
	var target := Vector2(pos.x, pos.z)
	var best_t := 0.0
	var best_d := INF
	for i in LUT_STEPS + 1:
		var t := float(i) / LUT_STEPS
		var d := _flat(point(t)).distance_squared_to(target)
		if d < best_d:
			best_d = d
			best_t = t
	var step := 1.0 / LUT_STEPS
	for _i in 16:
		step *= 0.5
		for cand: float in [best_t - step, best_t + step]:
			var c := clampf(cand, 0.0, 1.0)
			var d := _flat(point(c)).distance_squared_to(target)
			if d < best_d:
				best_d = d
				best_t = c
	return best_t


## Splits the curve at `t` into two curves.
func split(t: float) -> Array[RoadCurve]:
	var a := p0.lerp(p1, t)
	var b := p1.lerp(p2, t)
	var c := p2.lerp(p3, t)
	var d := a.lerp(b, t)
	var e := b.lerp(c, t)
	var f := d.lerp(e, t)
	return [RoadCurve.new(p0, a, d, f), RoadCurve.new(f, e, c, p3)]


## `count + 1` points evenly spaced by distance.
func sample_points(count: int, y: float = 0.0) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var length := get_length()
	for i in count + 1:
		var p := point(t_at_distance(length * i / count))
		p.y = y
		pts.append(p)
	return pts


func bounds_2d() -> Rect2:
	var r := Rect2(_flat(p0), Vector2.ZERO)
	r = r.expand(_flat(p1))
	r = r.expand(_flat(p2))
	return r.expand(_flat(p3))


## Crossing points with another curve, as [t_self, t_other] pairs.
func intersections(other: RoadCurve) -> Array:
	var result := []
	if not bounds_2d().grow(0.1).intersects(other.bounds_2d().grow(0.1)):
		return result
	var a := _polyline()
	var b := other._polyline()
	var na := a.size() - 1
	var nb := b.size() - 1
	for i in na:
		for j in nb:
			var hit: Variant = Geometry2D.segment_intersects_segment(a[i], a[i + 1], b[j], b[j + 1])
			if hit == null:
				continue
			var h: Vector2 = hit
			var fa := a[i].distance_to(h) / maxf(a[i].distance_to(a[i + 1]), 1e-6)
			var fb := b[j].distance_to(h) / maxf(b[j].distance_to(b[j + 1]), 1e-6)
			result.append([(i + fa) / na, (j + fb) / nb])
	return result


func _polyline() -> PackedVector2Array:
	var n := clampi(ceili(get_length() / 2.0), 8, 128)
	var pts := PackedVector2Array()
	for i in n + 1:
		pts.append(_flat(point(float(i) / n)))
	return pts


func _ensure_lut() -> void:
	if _length >= 0.0:
		return
	_lut_d.resize(LUT_STEPS + 1)
	_lut_d[0] = 0.0
	var prev := p0
	var total := 0.0
	for i in range(1, LUT_STEPS + 1):
		var p := point(float(i) / LUT_STEPS)
		total += prev.distance_to(p)
		_lut_d[i] = total
		prev = p
	_length = total


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
