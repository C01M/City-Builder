class_name TrafficGraph
extends RefCounted
## Drivable paths derived from the road network: lane pieces along segments and
## connection pieces through junctions, linked into a graph for routing.
## Rebuilt whenever the network changes.

## Comfortable sideways acceleration in curves (m/s²); sets curve speed limits.
const LATERAL_ACCEL := 7.0
## Where junction paths come closer than this (m, center line to center line),
## cars on them could touch: that stretch of both paths is a conflict zone.
const ZONE_DISTANCE := 2.8
## Road ends this close to the map edge count as outside connections.
const BORDER_TOLERANCE := 3.0


class Piece:
	var id: int
	var is_connection: bool
	## Lanes: the node the lane flows into. Connections: the junction node.
	var node_id: int
	## Lanes: the node the lane starts at.
	var from_node: int = -1
	var lane_key: int = -1
	var in_key: int = -1
	var out_key: int = -1
	var points := PackedVector3Array()
	## Distance along the piece at each point.
	var dist := PackedFloat32Array()
	## Max speed at each point, from curvature.
	var speed_limit := PackedFloat32Array()
	var length: float = 0.0
	var next: Array[int] = []
	## Connection pieces at the same junction that share a conflict zone with this one.
	var conflicts: Array[int] = []
	## Conflict zones along this connection, sorted by start:
	## {zone: zone id, side: 0 / 1 (which piece of the zone this is), start, end (distance along this piece)}.
	var zones: Array[Dictionary] = []
	var bounds: Rect2

	## Index of the polyline segment containing distance `s`.
	func index_at(s: float) -> int:
		var last := dist.size() - 2
		if s <= 0.0:
			return 0
		if s >= length:
			return last
		var lo := 0
		var hi := dist.size() - 1
		while hi - lo > 1:
			var mid := (lo + hi) / 2
			if dist[mid] <= s:
				lo = mid
			else:
				hi = mid
		return mini(lo, last)

	func position_at(s: float) -> Vector3:
		var i := index_at(s)
		var span := dist[i + 1] - dist[i]
		var f := 0.0 if span <= 0.0 else clampf((s - dist[i]) / span, 0.0, 1.0)
		return points[i].lerp(points[i + 1], f)

	func direction_at(s: float) -> Vector3:
		var i := index_at(s)
		var d := points[i + 1] - points[i]
		if d.length_squared() < 1e-8:
			d = points[points.size() - 1] - points[0]
		return d.normalized()

	## Closest point to `p`: Vector2(distance along piece, distance from piece).
	func project(p: Vector3) -> Vector2:
		var p2 := Vector2(p.x, p.z)
		var best := Vector2(0.0, INF)
		for i in points.size() - 1:
			var a := Vector2(points[i].x, points[i].z)
			var b := Vector2(points[i + 1].x, points[i + 1].z)
			var c := Geometry2D.get_closest_point_to_segment(p2, a, b)
			var d := c.distance_to(p2)
			if d < best.y:
				best = Vector2(dist[i] + a.distance_to(c), d)
		return best


class MinHeap:
	var keys := PackedFloat32Array()
	var vals := PackedInt32Array()
	var last_key: float = 0.0

	func is_empty() -> bool:
		return vals.is_empty()

	func push(key: float, val: int) -> void:
		keys.append(key)
		vals.append(val)
		var i := keys.size() - 1
		while i > 0:
			var parent := (i - 1) / 2
			if keys[parent] <= keys[i]:
				break
			_swap(i, parent)
			i = parent

	func pop() -> int:
		var top := vals[0]
		last_key = keys[0]
		var last := keys.size() - 1
		_swap(0, last)
		keys.resize(last)
		vals.resize(last)
		var i := 0
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var m := i
			if l < last and keys[l] < keys[m]:
				m = l
			if r < last and keys[r] < keys[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func _swap(a: int, b: int) -> void:
		var k := keys[a]
		keys[a] = keys[b]
		keys[b] = k
		var v := vals[a]
		vals[a] = vals[b]
		vals[b] = v


var pieces: Array[Piece] = []
## Number of conflict zones (ids 0 .. zone_count - 1).
var zone_count: int = 0
var lane_pieces: Dictionary = {}  # lane key -> piece id
## Dead-end nodes on the map border, where traffic enters and leaves.
var outside_nodes: Array[int] = []
var entry_pieces: Dictionary = {}  # outside node id -> Array of lane piece ids leaving it
var exit_pieces: Dictionary = {}  # outside node id -> Array of lane piece ids arriving at it
var _route_cache: Dictionary = {}


static func is_on_border(pos: Vector3, map_half_size: float) -> bool:
	return absf(pos.x) >= map_half_size - BORDER_TOLERANCE or absf(pos.z) >= map_half_size - BORDER_TOLERANCE


static func build(network: RoadNetwork, map_half_size: float, max_speed: float) -> TrafficGraph:
	var g := TrafficGraph.new()
	# Lanes along segments.
	for seg: RoadNetwork.RoadSegment in network.segments.values():
		for i in seg.type.lanes.size():
			var pts := network.lane_points(seg.id, i)
			if pts.size() < 2:
				continue
			var forward: bool = seg.type.lanes[i].forward
			var p := g._add_piece(pts, max_speed)
			p.lane_key = RoadNetwork.lane_key(seg.id, i)
			p.from_node = seg.start_id if forward else seg.end_id
			p.node_id = seg.end_id if forward else seg.start_id
			g.lane_pieces[p.lane_key] = p.id

	# Connections through nodes.
	for node_id: int in network.nodes:
		var by_key := {}
		for e in network.get_lane_ends(node_id):
			by_key[e.key] = e
		var conns := network.get_connections(node_id)
		var node_conns: Array[Piece] = []
		for in_key: int in conns:
			if not g.lane_pieces.has(in_key):
				continue
			for out_key: int in conns[in_key]:
				if not g.lane_pieces.has(out_key):
					continue
				var curve := RoadNetwork.connection_curve(by_key[in_key], by_key[out_key])
				var count := maxi(4, ceili(curve.get_length() / 1.5))
				var p := g._add_piece(curve.sample_points(count, RoadNetwork.ROAD_Y), max_speed)
				p.is_connection = true
				p.node_id = node_id
				p.in_key = in_key
				p.out_key = out_key
				p.next.append(g.lane_pieces[out_key])
				g.pieces[g.lane_pieces[in_key]].next.append(p.id)
				node_conns.append(p)
		g._find_conflicts(node_conns)

	# Outside connections: dead ends on the map border.
	for node: RoadNetwork.RoadNode in network.nodes.values():
		if node.segment_ids.size() == 1 and is_on_border(node.position, map_half_size):
			g.outside_nodes.append(node.id)
			g.entry_pieces[node.id] = []
			g.exit_pieces[node.id] = []
	for p in g.pieces:
		if p.is_connection:
			continue
		if g.entry_pieces.has(p.from_node):
			(g.entry_pieces[p.from_node] as Array).append(p.id)
		if g.exit_pieces.has(p.node_id):
			(g.exit_pieces[p.node_id] as Array).append(p.id)
	return g


## Shortest route (piece ids, starting with `start`) to a lane arriving at
## `dest_node`. Empty if there is none.
func route(start: int, dest_node: int) -> PackedInt32Array:
	var key := Vector2i(start, dest_node)
	if _route_cache.has(key):
		return _route_cache[key]
	var result := PackedInt32Array()
	var targets: Array = exit_pieces.get(dest_node, [])
	if not targets.is_empty() and start >= 0 and start < pieces.size():
		var n := pieces.size()
		var cost := PackedFloat32Array()
		cost.resize(n)
		cost.fill(INF)
		var prev := PackedInt32Array()
		prev.resize(n)
		prev.fill(-1)
		var heap := MinHeap.new()
		cost[start] = 0.0
		heap.push(0.0, start)
		while not heap.is_empty():
			var u := heap.pop()
			if heap.last_key > cost[u]:
				continue
			if targets.has(u):
				var path: Array[int] = []
				var cur := u
				while cur != -1:
					path.append(cur)
					cur = prev[cur]
				path.reverse()
				result = PackedInt32Array(path)
				break
			for nx in pieces[u].next:
				var c := cost[u] + pieces[nx].length
				if c < cost[nx]:
					cost[nx] = c
					prev[nx] = u
					heap.push(c, nx)
	_route_cache[key] = result
	return result


func _add_piece(pts: PackedVector3Array, max_speed: float) -> Piece:
	var p := Piece.new()
	p.id = pieces.size()
	p.points = pts
	p.dist.resize(pts.size())
	p.speed_limit.resize(pts.size())
	var total := 0.0
	p.dist[0] = 0.0
	var rect := Rect2(Vector2(pts[0].x, pts[0].z), Vector2.ZERO)
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
		p.dist[i] = total
		rect = rect.expand(Vector2(pts[i].x, pts[i].z))
	p.length = total
	p.bounds = rect
	for i in pts.size():
		var r := INF
		if pts.size() >= 3:
			var j := clampi(i, 1, pts.size() - 2)
			r = _circumradius(pts[j - 1], pts[j], pts[j + 1])
		p.speed_limit[i] = minf(max_speed, sqrt(LATERAL_ACCEL * r))
	pieces.append(p)
	return p


## Finds where pairs of paths through a junction come close (cross, merge into the
## same exit lane, or split from the same entry lane) and records a conflict zone
## on both. Cars on the very same path just follow each other.
func _find_conflicts(conns: Array[Piece]) -> void:
	for i in conns.size():
		for j in range(i + 1, conns.size()):
			var a := conns[i]
			var b := conns[j]
			var za := _close_stretch(a, b)
			var zb := _close_stretch(b, a)
			if za.x < 0.0 or zb.x < 0.0:
				continue
			# Paths from the same lane: a turning car's tail can still block a
			# follower going another way until the paths have split.
			if a.in_key == b.in_key:
				za.x = 0.0
				zb.x = 0.0
			# Paths into the same lane: the zone runs to the lane, where cars follow.
			if a.out_key == b.out_key:
				za.y = a.length
				zb.y = b.length
			var id := zone_count
			zone_count += 1
			a.zones.append({"zone": id, "side": 0, "start": za.x, "end": za.y})
			b.zones.append({"zone": id, "side": 1, "start": zb.x, "end": zb.y})
			a.conflicts.append(b.id)
			b.conflicts.append(a.id)
	for p in conns:
		p.zones.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.start < y.start)


## Stretch of `a` (Vector2(start, end) distance along it) within ZONE_DISTANCE of
## `b`, widened by one sample on each side. (-1, -1) if they never come close.
static func _close_stretch(a: Piece, b: Piece) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in a.points.size():
		var p := Vector2(a.points[i].x, a.points[i].z)
		for j in b.points.size() - 1:
			var b0 := Vector2(b.points[j].x, b.points[j].z)
			var b1 := Vector2(b.points[j + 1].x, b.points[j + 1].z)
			if Geometry2D.get_closest_point_to_segment(p, b0, b1).distance_to(p) < ZONE_DISTANCE:
				lo = minf(lo, a.dist[i])
				hi = maxf(hi, a.dist[i])
				break
	if lo == INF:
		return Vector2(-1.0, -1.0)
	var step := a.length / maxf(a.points.size() - 1, 1)
	return Vector2(maxf(lo - step, 0.0), minf(hi + step, a.length))


static func _circumradius(a: Vector3, b: Vector3, c: Vector3) -> float:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var ac := Vector2(c.x - a.x, c.z - a.z)
	var area2 := absf(ab.cross(ac))
	if area2 < 1e-6:
		return INF
	return ab.length() * ac.length() * Vector2(c.x - b.x, c.z - b.z).length() / (2.0 * area2)
