class_name RoadNetwork
extends Node3D
## Node/segment road graph. Segments are Bezier curves between nodes and carry
## lanes defined by their RoadType. Each node decides which incoming lanes
## connect to which outgoing lanes: defaults, or custom per incoming lane.

signal changed

const ROAD_Y := 0.03
## Crossings/endpoints closer than this to an existing node reuse that node.
const NODE_MERGE_DISTANCE := 4.0
## Extra space at junctions of 3+ roads, so corners can be rounded.
const JUNCTION_MARGIN := 2.0
const MAX_TRIM_FRACTION := 0.45
const LANE_BITS := 6
const LANE_MASK := 63
## Lanes of different segments closer than this at a node count as joined.
const LANE_ALIGN_DISTANCE := 0.5
const WARNING_ICON_PATH := "res://icons/lane_mismatch.svg"
const WARNING_ICON_HEIGHT := 5.0


class RoadNode:
	var id: int
	var position: Vector3
	var segment_ids: Array[int] = []
	## Overrides per incoming lane key: Array of outgoing lane keys.
	var custom_connections: Dictionary = {}
	## True if two joined lanes at this node run in opposite directions.
	var lane_mismatch: bool = false
	var mesh_instance: MeshInstance3D
	var warning_icon: Sprite3D


class RoadSegment:
	var id: int
	var start_id: int
	var end_id: int
	var curve: RoadCurve
	var type: RoadType
	## Distance cut from each end to make room for the junction surface.
	var trim_start: float = 0.0
	var trim_end: float = 0.0
	## Where each end attaches relative to its node (non-zero when a narrower
	## road is snapped to one lane of a wider road instead of its center).
	var start_offset: Vector3 = Vector3.ZERO
	var end_offset: Vector3 = Vector3.ZERO
	var mesh_instance: MeshInstance3D

	func offset_at(node_id: int) -> Vector3:
		return start_offset if node_id == start_id else end_offset


## One lane's end at a node (after trimming for the junction).
class LaneEnd:
	var key: int
	var segment_id: int
	var lane_index: int
	## True if traffic on this lane drives into the node.
	var incoming: bool
	var position: Vector3
	## Travel direction of the lane at this point.
	var direction: Vector3


var nodes: Dictionary = {}  # int -> RoadNode
var segments: Dictionary = {}  # int -> RoadSegment

var _next_node_id: int = 1
var _next_segment_id: int = 1
var _dirty_nodes: Dictionary = {}
var _material: StandardMaterial3D
var _warning_texture: Texture2D


func _init() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.16, 0.16, 0.17)
	_material.roughness = 0.9


# ---------------------------------------------------------------- lane keys

static func lane_key(segment_id: int, lane_index: int) -> int:
	return (segment_id << LANE_BITS) | lane_index


static func key_segment(key: int) -> int:
	return key >> LANE_BITS


static func key_lane(key: int) -> int:
	return key & LANE_MASK


# ---------------------------------------------------------------- queries

func get_node_data(node_id: int) -> RoadNode:
	return nodes.get(node_id) as RoadNode


func get_segment(segment_id: int) -> RoadSegment:
	return segments.get(segment_id) as RoadSegment


func find_node_near(pos: Vector3, radius: float) -> int:
	var best := -1
	var best_d := radius * radius
	for node: RoadNode in nodes.values():
		var d := _flat(node.position).distance_squared_to(_flat(pos))
		if d <= best_d:
			best_d = d
			best = node.id
	return best


## Closest segment within `radius` of its center line (plus half the road
## width if `include_width`). Returns {} or {segment_id, t, point, distance}.
func find_segment_near(pos: Vector3, radius: float, include_width: bool = false) -> Dictionary:
	var best := {}
	var best_d := INF
	for seg: RoadSegment in segments.values():
		var r := radius + (seg.type.width * 0.5 if include_width else 0.0)
		if not seg.curve.bounds_2d().grow(r).has_point(_flat(pos)):
			continue
		var t := seg.curve.closest_t(pos)
		var p := seg.curve.point(t)
		var d := _flat(p).distance_to(_flat(pos))
		if d <= r and d < best_d:
			best_d = d
			best = {"segment_id": seg.id, "t": t, "point": p, "distance": d}
	return best


## Direction leaving `node_id` along `segment_id`.
func outward_direction(node_id: int, segment_id: int) -> Vector3:
	var seg: RoadSegment = segments[segment_id]
	return seg.curve.tangent(0.0) if seg.start_id == node_id else -seg.curve.tangent(1.0)


## For a node at the end of a single road, the direction that continues it.
func continue_direction(node_id: int) -> Vector3:
	var node := get_node_data(node_id)
	if node == null or node.segment_ids.size() != 1:
		return Vector3.ZERO
	return -outward_direction(node_id, node.segment_ids[0])


## Smallest angle (degrees) between a new road leaving `node_id` along `dir`
## (attached at `offset`, `half_width` wide) and the roads already there.
## Roads that sit fully side by side with it (e.g. on the other lane) are ignored.
func min_angle_at_node(node_id: int, dir: Vector3, offset: Vector3 = Vector3.ZERO, half_width: float = 0.0) -> float:
	var best := 180.0
	var node := get_node_data(node_id)
	if node == null:
		return best
	var across := dir.cross(Vector3.UP).normalized()
	for sid in node.segment_ids:
		var seg: RoadSegment = segments[sid]
		var separation := absf((offset - seg.offset_at(node_id)).dot(across))
		if separation >= half_width + seg.type.width * 0.5 - 0.1:
			continue
		best = minf(best, rad_to_deg(dir.angle_to(outward_direction(node_id, sid))))
	return best


## Lane centers at a node where a one-lane road can attach, as
## [{pos: Vector3, dir: Vector3 lane travel direction}]. Only multi-lane roads offer them.
func node_lane_points(node_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var node := get_node_data(node_id)
	if node == null:
		return result
	for sid in node.segment_ids:
		var seg: RoadSegment = segments[sid]
		if seg.type.lanes.size() < 2:
			continue
		for lp in _lane_points_at(seg, 0.0 if seg.start_id == node_id else 1.0):
			var seen := false
			for existing in result:
				if (existing.pos as Vector3).distance_to(lp.pos) < LANE_ALIGN_DISTANCE:
					seen = true
			if not seen:
				result.append(lp)
	return result


## Lane centers across a segment at curve parameter `t` (see node_lane_points).
func segment_lane_points(segment_id: int, t: float) -> Array[Dictionary]:
	var seg := get_segment(segment_id)
	if seg == null or seg.type.lanes.size() < 2:
		return []
	return _lane_points_at(seg, t)


func has_lane_mismatch(node_id: int) -> bool:
	var node := get_node_data(node_id)
	return node != null and node.lane_mismatch


func _lane_points_at(seg: RoadSegment, t: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var p := seg.curve.point(t)
	var tan := seg.curve.tangent(t)
	var right := tan.cross(Vector3.UP).normalized()
	for lane in seg.type.lanes:
		result.append({"pos": p + right * lane.offset, "dir": tan if lane.forward else -tan})
	return result


# ---------------------------------------------------------------- editing

## Builds a road along `curve`. `start` / `end` describe what each end attaches to:
##   node: int        existing node to connect to (default -1)
##   on_segment: bool split the segment under `anchor` to make a junction
##   anchor: Vector3  node / center line point (default: the curve's end point)
## Otherwise the end gets a new node. If the curve's end point differs from the
## node's position (snapped to a lane), the segment keeps that offset.
## Existing roads that the curve crosses are split into junctions.
func build_road(curve: RoadCurve, type: RoadType, start: Dictionary = {}, end: Dictionary = {}) -> bool:
	var length := curve.get_length()
	if length < 1.0:
		return false

	# Find crossings against the network as it is now.
	var hits: Array[float] = []
	for seg: RoadSegment in segments.values():
		for pair: Array in curve.intersections(seg.curve):
			var d := curve.distance_at_t(pair[0])
			if d >= NODE_MERGE_DISTANCE and d <= length - NODE_MERGE_DISTANCE:
				hits.append(pair[0])
	hits.sort()

	var start_id := _resolve_point(start.get("anchor", curve.p0), start.get("node", -1), start.get("on_segment", false))
	var chain_nodes: Array[int] = [start_id]
	var chain_ts: Array[float] = []
	var last_d := 0.0
	for t in hits:
		var d := curve.distance_at_t(t)
		if d - last_d < NODE_MERGE_DISTANCE:
			continue
		var nid := _resolve_point(curve.point(t), -1, true)
		if nid == chain_nodes.back():
			continue
		chain_nodes.append(nid)
		chain_ts.append(t)
		last_d = d
	var end_id := _resolve_point(end.get("anchor", curve.p3), end.get("node", -1), end.get("on_segment", false))
	if chain_nodes.size() > 1 and chain_nodes.back() == end_id:
		chain_nodes.pop_back()
		chain_ts.pop_back()
	if chain_nodes.back() == end_id:
		_remove_orphan_nodes()
		_rebuild_dirty()
		return false
	chain_nodes.append(end_id)

	var pieces: Array[RoadCurve] = []
	var rest := curve
	var consumed := 0.0
	for t in chain_ts:
		var parts := rest.split((t - consumed) / (1.0 - consumed))
		pieces.append(parts[0])
		rest = parts[1]
		consumed = t
	pieces.append(rest)

	var last := pieces.size() - 1
	for i in pieces.size():
		var a := chain_nodes[i]
		var b := chain_nodes[i + 1]
		if a != b and not _has_similar_segment(a, b, pieces[i]):
			_create_segment(a, b, pieces[i], type,
				_end_offset(curve.p0, a) if i == 0 else Vector3.ZERO,
				_end_offset(curve.p3, b) if i == last else Vector3.ZERO)

	_remove_orphan_nodes()
	_rebuild_dirty()
	changed.emit()
	return true


## Splits a segment at curve parameter `t`; returns the new node's id.
func split_segment(segment_id: int, t: float) -> int:
	var seg: RoadSegment = segments[segment_id]
	var parts := seg.curve.split(t)
	var mid_id := _create_node(parts[0].p3)
	var end_node: RoadNode = nodes[seg.end_id]

	var tail := RoadSegment.new()
	tail.id = _next_segment_id
	_next_segment_id += 1
	tail.start_id = mid_id
	tail.end_id = seg.end_id
	tail.end_offset = seg.end_offset
	tail.curve = parts[1].with_endpoints(get_node_data(mid_id).position, end_node.position + tail.end_offset)
	tail.type = seg.type
	segments[tail.id] = tail

	seg.curve = parts[0].with_endpoints(get_node_data(seg.start_id).position + seg.start_offset, get_node_data(mid_id).position)
	seg.end_id = mid_id
	seg.end_offset = Vector3.ZERO

	end_node.segment_ids[end_node.segment_ids.find(segment_id)] = tail.id
	_remap_custom(end_node, segment_id, tail.id)
	get_node_data(mid_id).segment_ids.assign([segment_id, tail.id])

	_dirty_nodes[seg.start_id] = true
	_dirty_nodes[mid_id] = true
	_dirty_nodes[tail.end_id] = true
	return mid_id


func remove_segment(segment_id: int) -> void:
	var seg := get_segment(segment_id)
	if seg == null:
		return
	for nid: int in [seg.start_id, seg.end_id]:
		var node := get_node_data(nid)
		if node == null:
			continue
		node.segment_ids.erase(segment_id)
		_drop_custom_for_segment(node, segment_id)
		_dirty_nodes[nid] = true
	if seg.mesh_instance:
		seg.mesh_instance.queue_free()
	segments.erase(segment_id)
	_remove_orphan_nodes()
	_rebuild_dirty()
	changed.emit()


func set_segment_type(segment_id: int, type: RoadType) -> void:
	var seg := get_segment(segment_id)
	if seg == null or seg.type == type:
		return
	seg.type = type
	if type.lanes.size() > 1 and (seg.start_offset != Vector3.ZERO or seg.end_offset != Vector3.ZERO):
		# Multi-lane roads attach at node centers.
		seg.start_offset = Vector3.ZERO
		seg.end_offset = Vector3.ZERO
		seg.curve = seg.curve.with_endpoints(get_node_data(seg.start_id).position, get_node_data(seg.end_id).position)
	_segment_lanes_changed(seg)


## Flips a segment's direction (reverses one-way traffic).
func reverse_segment(segment_id: int) -> void:
	var seg := get_segment(segment_id)
	if seg == null:
		return
	seg.curve = seg.curve.reversed()
	var s := seg.start_id
	seg.start_id = seg.end_id
	seg.end_id = s
	var t := seg.trim_start
	seg.trim_start = seg.trim_end
	seg.trim_end = t
	var o := seg.start_offset
	seg.start_offset = seg.end_offset
	seg.end_offset = o
	_segment_lanes_changed(seg)


# ---------------------------------------------------------------- lanes

## All lane ends at a node: incoming lanes arriving and outgoing lanes leaving.
func get_lane_ends(node_id: int) -> Array[LaneEnd]:
	var result: Array[LaneEnd] = []
	var node := get_node_data(node_id)
	if node == null:
		return result
	for sid in node.segment_ids:
		var seg: RoadSegment = segments[sid]
		var at_start := seg.start_id == node_id
		var t := seg.curve.t_at_distance(seg.trim_start if at_start else seg.curve.get_length() - seg.trim_end)
		var p := seg.curve.point(t)
		var tan := seg.curve.tangent(t)
		var right := tan.cross(Vector3.UP).normalized()
		for i in seg.type.lanes.size():
			var lane: RoadType.LaneDef = seg.type.lanes[i]
			var e := LaneEnd.new()
			e.key = lane_key(seg.id, i)
			e.segment_id = seg.id
			e.lane_index = i
			e.incoming = lane.forward != at_start
			e.position = p + right * lane.offset
			e.position.y = ROAD_Y
			e.direction = tan if lane.forward else -tan
			result.append(e)
	return result


## Incoming lane key -> Array of outgoing lane keys it connects to.
func get_connections(node_id: int) -> Dictionary:
	var result := {}
	var node := get_node_data(node_id)
	if node == null:
		return result
	var ends := get_lane_ends(node_id)
	for e in ends:
		if not e.incoming:
			continue
		if node.custom_connections.has(e.key):
			result[e.key] = (node.custom_connections[e.key] as Array).duplicate()
		else:
			result[e.key] = _default_outs(e, ends)
	return result


func has_custom_connections(node_id: int) -> bool:
	var node := get_node_data(node_id)
	return node != null and not node.custom_connections.is_empty()


func set_connection(node_id: int, in_key: int, out_key: int, enabled: bool) -> void:
	var node := get_node_data(node_id)
	var conns := get_connections(node_id)
	if node == null or not conns.has(in_key):
		return
	var outs: Array = conns[in_key]
	if enabled and not outs.has(out_key):
		outs.append(out_key)
	elif not enabled:
		outs.erase(out_key)
	node.custom_connections[in_key] = outs
	changed.emit()


func toggle_connection(node_id: int, in_key: int, out_key: int) -> void:
	var conns := get_connections(node_id)
	if conns.has(in_key):
		set_connection(node_id, in_key, out_key, not (conns[in_key] as Array).has(out_key))


func reset_connections(node_id: int) -> void:
	var node := get_node_data(node_id)
	if node:
		node.custom_connections.clear()
		changed.emit()


## Path a vehicle takes through a junction from one lane to another.
static func connection_curve(from: LaneEnd, to: LaneEnd) -> RoadCurve:
	var k := maxf(from.position.distance_to(to.position) * 0.4, 1.5)
	return RoadCurve.new(from.position, from.position + from.direction * k,
		to.position - to.direction * k, to.position)


## Lane center line along the trimmed segment, in travel direction.
func lane_points(segment_id: int, lane_index: int, spacing: float = 2.0) -> PackedVector3Array:
	var seg: RoadSegment = segments[segment_id]
	var lane: RoadType.LaneDef = seg.type.lanes[lane_index]
	var from := seg.trim_start
	var to := seg.curve.get_length() - seg.trim_end
	var pts := PackedVector3Array()
	if to - from < 0.01:
		return pts
	var steps := maxi(1, ceili((to - from) / spacing))
	for i in steps + 1:
		var t := seg.curve.t_at_distance(lerpf(from, to, float(i) / steps))
		var p := seg.curve.point(t) + seg.curve.tangent(t).cross(Vector3.UP).normalized() * lane.offset
		p.y = ROAD_Y
		pts.append(p)
	if not lane.forward:
		pts.reverse()
	return pts


func _default_outs(incoming: LaneEnd, ends: Array[LaneEnd]) -> Array:
	var outs := []
	for e in ends:
		if not e.incoming and e.segment_id != incoming.segment_id:
			outs.append(e.key)
	if outs.is_empty():
		# Dead end: allow turning around.
		for e in ends:
			if not e.incoming:
				outs.append(e.key)
	return outs


# ---------------------------------------------------------------- internals

func _resolve_point(pos: Vector3, node_id: int, on_segment: bool) -> int:
	if node_id >= 0 and nodes.has(node_id):
		return node_id
	var near := find_node_near(pos, 0.5)
	if near >= 0:
		return near
	if on_segment:
		var hit := find_segment_near(pos, 0.75)
		if not hit.is_empty():
			var seg: RoadSegment = segments[hit.segment_id]
			var d := seg.curve.distance_at_t(hit.t)
			if d < NODE_MERGE_DISTANCE:
				return seg.start_id
			if d > seg.curve.get_length() - NODE_MERGE_DISTANCE:
				return seg.end_id
			return split_segment(seg.id, hit.t)
	return _create_node(pos)


func _create_node(pos: Vector3) -> int:
	var n := RoadNode.new()
	n.id = _next_node_id
	_next_node_id += 1
	n.position = Vector3(pos.x, 0.0, pos.z)
	nodes[n.id] = n
	return n.id


func _end_offset(point: Vector3, node_id: int) -> Vector3:
	var off := point - get_node_data(node_id).position
	off.y = 0.0
	return off if off.length() > 0.05 else Vector3.ZERO


func _create_segment(a: int, b: int, curve: RoadCurve, type: RoadType,
		start_offset: Vector3 = Vector3.ZERO, end_offset: Vector3 = Vector3.ZERO) -> int:
	var s := RoadSegment.new()
	s.id = _next_segment_id
	_next_segment_id += 1
	s.start_id = a
	s.end_id = b
	s.start_offset = start_offset
	s.end_offset = end_offset
	s.curve = curve.with_endpoints(get_node_data(a).position + start_offset, get_node_data(b).position + end_offset)
	s.type = type
	segments[s.id] = s
	get_node_data(a).segment_ids.append(s.id)
	get_node_data(b).segment_ids.append(s.id)
	_dirty_nodes[a] = true
	_dirty_nodes[b] = true
	return s.id


func _has_similar_segment(a: int, b: int, curve: RoadCurve) -> bool:
	var mid := curve.point(0.5)
	for sid in get_node_data(a).segment_ids:
		var seg: RoadSegment = segments[sid]
		if (seg.start_id == a and seg.end_id == b) or (seg.start_id == b and seg.end_id == a):
			if seg.curve.point(0.5).distance_to(mid) < 1.0:
				return true
	return false


func _remove_orphan_nodes() -> void:
	for node: RoadNode in nodes.values():
		if node.segment_ids.is_empty():
			if node.mesh_instance:
				node.mesh_instance.queue_free()
			if node.warning_icon:
				node.warning_icon.queue_free()
			nodes.erase(node.id)
			_dirty_nodes.erase(node.id)


func _segment_lanes_changed(seg: RoadSegment) -> void:
	for nid: int in [seg.start_id, seg.end_id]:
		_drop_custom_for_segment(get_node_data(nid), seg.id)
		_dirty_nodes[nid] = true
	_rebuild_dirty()
	changed.emit()


func _drop_custom_for_segment(node: RoadNode, segment_id: int) -> void:
	var kept := {}
	for in_key: int in node.custom_connections:
		if key_segment(in_key) == segment_id:
			continue
		var outs := []
		for out_key: int in node.custom_connections[in_key]:
			if key_segment(out_key) != segment_id:
				outs.append(out_key)
		kept[in_key] = outs
	node.custom_connections = kept


func _remap_custom(node: RoadNode, old_segment: int, new_segment: int) -> void:
	var remapped := {}
	for in_key: int in node.custom_connections:
		var outs := []
		for out_key: int in node.custom_connections[in_key]:
			outs.append(_remap_key(out_key, old_segment, new_segment))
		remapped[_remap_key(in_key, old_segment, new_segment)] = outs
	node.custom_connections = remapped


static func _remap_key(key: int, old_segment: int, new_segment: int) -> int:
	return lane_key(new_segment, key_lane(key)) if key_segment(key) == old_segment else key


# ---------------------------------------------------------------- geometry

func _rebuild_dirty() -> void:
	var dirty_segments := {}
	for nid: int in _dirty_nodes:
		var node := get_node_data(nid)
		if node:
			_compute_trims(node)
			for sid in node.segment_ids:
				dirty_segments[sid] = true
	for nid: int in _dirty_nodes:
		var node := get_node_data(nid)
		if node:
			_build_junction_mesh(node)
			_update_lane_mismatch(node)
	for sid: int in dirty_segments:
		_build_segment_mesh(segments[sid])
	_dirty_nodes.clear()


## Segment ends at a node, sorted by angle around it.
func _segment_ends(node: RoadNode) -> Array[Dictionary]:
	var ends: Array[Dictionary] = []
	for sid in node.segment_ids:
		var seg: RoadSegment = segments[sid]
		var dir := outward_direction(node.id, sid)
		var d2 := Vector2(dir.x, dir.z).normalized()
		var right := Vector2(-d2.y, d2.x)  # points toward increasing angle
		var off := seg.offset_at(node.id)
		var origin := Vector2(off.x, off.z)
		var angle := d2.angle()
		if angle < -PI + 0.01:
			angle += TAU
		ends.append({
			"seg": seg,
			"at_start": seg.start_id == node.id,
			"dir": d2,
			"right": right,
			"origin": origin,  # where the segment's center line starts, relative to the node
			"lateral": origin.dot(right),
			"half": seg.type.width * 0.5,
			"angle": angle,
			"trim": 0.0,
		})
	# Parallel roads side by side (e.g. one-ways on both lanes) sort by lateral position.
	ends.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a.angle - b.angle) > 0.01:
			return a.angle < b.angle
		return a.lateral < b.lateral)
	return ends


## Cuts segment ends back far enough that neighboring roads don't overlap.
func _compute_trims(node: RoadNode) -> void:
	var ends := _segment_ends(node)
	var n := ends.size()
	if n >= 2:
		for i in n:
			var a := ends[i]
			var b := ends[(i + 1) % n]
			# a's right edge faces b's left edge.
			var hit: Variant = _line_intersection(a.origin + a.right * a.half, a.dir, b.origin - b.right * b.half, b.dir)
			if hit != null and hit.x > 0.0 and hit.y > 0.0:
				a.trim = maxf(a.trim, hit.x)
				b.trim = maxf(b.trim, hit.y)
	var margin := JUNCTION_MARGIN if n >= 3 else 0.0
	# Centered roads of different widths get a taper; a road snapped to a lane doesn't need one.
	var width_change := n == 2 and absf(ends[0].half - ends[1].half) > 0.01 \
		and (ends[0].origin as Vector2).length() < 0.05 and (ends[1].origin as Vector2).length() < 0.05
	for e in ends:
		var trim: float = e.trim + margin
		if width_change:
			trim = maxf(trim, 3.0)  # room for a taper between different widths
		var seg: RoadSegment = e.seg
		trim = minf(trim, seg.curve.get_length() * MAX_TRIM_FRACTION)
		if e.at_start:
			seg.trim_start = trim
		else:
			seg.trim_end = trim


func _build_junction_mesh(node: RoadNode) -> void:
	var ends := _segment_ends(node)
	var n := ends.size()
	var mesh: ArrayMesh = null
	if n >= 2:
		var corners: Array = []  # [left, right, outward dir] per end
		for e in ends:
			var seg: RoadSegment = e.seg
			var t := seg.curve.t_at_distance(seg.trim_start if e.at_start else seg.curve.get_length() - seg.trim_end)
			var q := seg.curve.point(t)
			var out := seg.curve.tangent(t) * (1.0 if e.at_start else -1.0)
			var o2 := Vector2(out.x, out.z).normalized()
			var r2 := Vector2(-o2.y, o2.x) * float(e.half)
			corners.append([Vector2(q.x, q.z) - r2, Vector2(q.x, q.z) + r2, o2])
		var poly := PackedVector2Array()
		for i in n:
			var a: Array = corners[i]
			var b: Array = corners[(i + 1) % n]
			_append_unique(poly, a[0])
			_append_unique(poly, a[1])
			# Round the corner between a's right edge and b's left edge.
			var hit: Variant = _line_intersection(a[1], a[2], b[0], b[2])
			if hit != null and hit.x < 0.0 and hit.y < 0.0:
				var ctrl: Vector2 = a[1] + a[2] * hit.x
				for k in range(1, 6):
					var f := k / 6.0
					_append_unique(poly, (a[1] as Vector2).lerp(ctrl, f).lerp(ctrl.lerp(b[0], f), f))
		if poly.size() > 2 and poly[0].distance_to(poly[poly.size() - 1]) < 0.01:
			poly.remove_at(poly.size() - 1)
		if poly.size() >= 3 and absf(_polygon_area(poly)) > 0.05:
			mesh = RoadMeshBuilder.build_polygon(poly, ROAD_Y)
	node.mesh_instance = _apply_mesh(node.mesh_instance, mesh)


## Flags the node when lanes of different segments meet at the same spot but
## run in opposite directions (e.g. a one-way snapped to the wrong lane).
func _update_lane_mismatch(node: RoadNode) -> void:
	var lanes: Array[Dictionary] = []
	for sid in node.segment_ids:
		var seg: RoadSegment = segments[sid]
		for lp in _lane_points_at(seg, 0.0 if seg.start_id == node.id else 1.0):
			lp.segment_id = sid
			lanes.append(lp)
	node.lane_mismatch = false
	for i in lanes.size():
		for j in range(i + 1, lanes.size()):
			var a := lanes[i]
			var b := lanes[j]
			if a.segment_id != b.segment_id \
					and (a.pos as Vector3).distance_to(b.pos) < LANE_ALIGN_DISTANCE \
					and (a.dir as Vector3).dot(b.dir) < -0.5:
				node.lane_mismatch = true
	if node.lane_mismatch:
		if node.warning_icon == null:
			if _warning_texture == null:
				_warning_texture = load(WARNING_ICON_PATH)
			var icon := Sprite3D.new()
			icon.texture = _warning_texture
			icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			icon.no_depth_test = true
			icon.fixed_size = true
			icon.pixel_size = 0.0008
			icon.render_priority = 20
			add_child(icon)
			node.warning_icon = icon
		node.warning_icon.position = node.position + Vector3.UP * WARNING_ICON_HEIGHT
	elif node.warning_icon:
		node.warning_icon.queue_free()
		node.warning_icon = null


func _build_segment_mesh(seg: RoadSegment) -> void:
	var from := seg.trim_start
	var to := seg.curve.get_length() - seg.trim_end
	var mesh: ArrayMesh = null
	if to - from > 0.01:
		mesh = RoadMeshBuilder.build_strip(seg.curve, from, to, seg.type.width, ROAD_Y)
	seg.mesh_instance = _apply_mesh(seg.mesh_instance, mesh)


func _apply_mesh(mi: MeshInstance3D, mesh: ArrayMesh) -> MeshInstance3D:
	if mesh == null:
		if mi:
			mi.queue_free()
		return null
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	mi.mesh = mesh
	return mi


static func _line_intersection(pa: Vector2, da: Vector2, pb: Vector2, db: Vector2) -> Variant:
	var cross := da.cross(db)
	if absf(cross) < 1e-4:
		return null
	var w := pb - pa
	# Solve pa + da*t = pb + db*s for (t, s).
	return Vector2(w.cross(db) / cross, w.cross(da) / cross)


static func _append_unique(poly: PackedVector2Array, p: Vector2) -> void:
	if poly.is_empty() or poly[poly.size() - 1].distance_to(p) > 0.01:
		poly.append(p)


static func _polygon_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		area += poly[i].cross(poly[(i + 1) % poly.size()])
	return area * 0.5


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
