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
## Node Controller limits.
const MAX_ROTATE := 70.0
## Traffic lights need a junction of at least this many roads.
const MIN_LIGHT_ROADS := 3
## Road length used for the width transition at a STRETCH node.
const STRETCH_NODE_LENGTH := 12.0
## Default lane connections skip turns sharper than this (degrees; U-turn = 180).
const MAX_DEFAULT_TURN := 135.0

## How a node joins its roads (Node Controller). MIDDLE and STRETCH only apply
## to nodes with exactly two roads; elsewhere they act like AUTO.
##   AUTO     junction surface sized automatically
##   MIDDLE   roads meet directly, no junction surface
##   STRETCH  long, smooth transition between two roads
##   UTURN    like AUTO, and every incoming lane may also turn around
enum NodeMode { AUTO, MIDDLE, STRETCH, UTURN }


## Node Controller settings for one road end. Sides are seen looking outward
## from the node along the road: positive = right.
class EndSettings:
	## Extra pull-back of the road end (m) on top of the automatic trim.
	var offset: float = 0.0
	## Sideways move of the road end (m).
	var shift: float = 0.0
	## Angle of the end edge (degrees); positive pulls the right corner back.
	var rotate: float = 0.0
	## Width change at the end: 0.2 = 20% wider, tapering back along the road.
	var stretch: float = 0.0
	## Curb radius (m) of the junction corner on this end's right side; < 0 = automatic.
	var radius: float = -1.0

	func is_default() -> bool:
		return offset == 0.0 and shift == 0.0 and rotate == 0.0 and stretch == 0.0 and radius < 0.0

	func copy() -> EndSettings:
		var s := EndSettings.new()
		s.offset = offset
		s.shift = shift
		s.rotate = rotate
		s.stretch = stretch
		s.radius = radius
		return s


class RoadNode:
	var id: int
	var position: Vector3
	var segment_ids: Array[int] = []
	## Overrides per incoming lane key: Array of outgoing lane keys.
	var custom_connections: Dictionary = {}
	## True if two joined lanes at this node run in opposite directions.
	var lane_mismatch: bool = false
	var mode: int = 0  # NodeMode
	## Traffic lights (only work at junctions of 3 or more roads).
	var traffic_lights: bool = false
	var mesh_instance: MeshInstance3D
	var warning_icon: Sprite3D


class RoadSegment:
	## Length over which a stretched end tapers back to the normal width.
	const STRETCH_TAPER := 15.0

	var id: int
	var start_id: int
	var end_id: int
	var curve: RoadCurve
	var type: RoadType
	## Distance cut from each end (at the center line) to make room for the junction surface.
	var trim_start: float = 0.0
	var trim_end: float = 0.0
	## Slant of each end edge: a point `x` m right of center (looking outward
	## from the node) is cut at trim + x * skew.
	var skew_start: float = 0.0
	var skew_end: float = 0.0
	## Where each end attaches relative to its node (non-zero when a narrower
	## road is snapped to one lane of a wider road, or the end is shifted).
	var start_offset: Vector3 = Vector3.ZERO
	var end_offset: Vector3 = Vector3.ZERO
	var start_settings := EndSettings.new()
	var end_settings := EndSettings.new()
	var mesh_instance: MeshInstance3D

	func offset_at(node_id: int) -> Vector3:
		return start_offset if node_id == start_id else end_offset

	func settings_at(node_id: int) -> EndSettings:
		return start_settings if node_id == start_id else end_settings

	## Trim at the end at `node_id`, `lateral` m right of center (looking outward).
	func trim_at(node_id: int, lateral: float) -> float:
		if node_id == start_id:
			return trim_start + lateral * skew_start
		return trim_end + lateral * skew_end

	## Distance along the curve from its start for a trim measured from the end at `node_id`.
	func distance_from_end(node_id: int, trim: float) -> float:
		return trim if node_id == start_id else curve.get_length() - trim

	## Width multiplier at distance `d` along the curve (stretched ends).
	func width_scale(d: float) -> float:
		var s := 1.0
		if start_settings.stretch != 0.0 or end_settings.stretch != 0.0:
			var length := curve.get_length()
			var taper := maxf(minf(STRETCH_TAPER, length * 0.4), 0.1)
			s += start_settings.stretch * (1.0 - smoothstep(0.0, 1.0, (d - trim_start) / taper))
			s += end_settings.stretch * (1.0 - smoothstep(0.0, 1.0, (length - trim_end - d) / taper))
		return s


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
	tail.end_settings = seg.end_settings
	segments[tail.id] = tail

	seg.curve = parts[0].with_endpoints(get_node_data(seg.start_id).position + seg.start_offset, get_node_data(mid_id).position)
	seg.end_id = mid_id
	seg.end_offset = Vector3.ZERO
	seg.end_settings = EndSettings.new()

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
	if type.lanes.size() > 1:
		# Multi-lane roads attach at node centers (plus any Node Controller shift).
		var start_off := _shift_vector(seg, seg.start_id)
		var end_off := _shift_vector(seg, seg.end_id)
		if not start_off.is_equal_approx(seg.start_offset) or not end_off.is_equal_approx(seg.end_offset):
			seg.start_offset = start_off
			seg.end_offset = end_off
			_update_segment_curve(seg)
	_segment_lanes_changed(seg)


## Lane edits for `edit_lanes`.
enum LaneEdit { ADD_LEFT, ADD_RIGHT, REMOVE, REVERSE }
## How far a lane edit reaches along the road.
##   SEGMENT  just this segment
##   ROAD     on through nodes joining exactly two roads (up to the next junctions)
##   STREET   also straight on through junctions
enum EditScope { SEGMENT, ROAD, STREET }


## Adds, removes or reverses a lane. `lane` is the lane index for REMOVE / REVERSE,
## counted left to right along `segment_id`. Every segment in `scope` with the same
## layout gets the same edit. Added and kept lanes stay where they are: the road
## widens or narrows on the edited side.
func edit_lanes(segment_id: int, edit: LaneEdit, lane: int = 0, scope: EditScope = EditScope.SEGMENT) -> bool:
	var seg := get_segment(segment_id)
	if seg == null:
		return false
	var base := seg.type.layout()
	var result: Array[bool] = base.duplicate()
	var lateral := 0.0  # center line move, m right of the segment direction
	var half := RoadType.LANE_WIDTH * 0.5
	match edit:
		LaneEdit.ADD_LEFT, LaneEdit.ADD_RIGHT:
			if base.size() >= RoadType.MAX_LANES:
				return false
			if edit == LaneEdit.ADD_LEFT:
				result.insert(0, base[0])
				lateral = -half
			else:
				result.append(base[base.size() - 1])
				lateral = half
		LaneEdit.REMOVE:
			if base.size() <= 1 or lane < 0 or lane >= base.size():
				return false
			result.remove_at(lane)
			lateral = half if lane == 0 else (-half if lane == base.size() - 1 else 0.0)
		LaneEdit.REVERSE:
			if lane < 0 or lane >= base.size():
				return false
			result[lane] = not result[lane]
	for part in lane_edit_reach(segment_id, scope):
		var s: RoadSegment = segments[part.segment_id]
		if part.aligned:
			_set_layout(s, result, lateral)
		else:
			_set_layout(s, RoadType.reversed_layout(result), -lateral)
	_rebuild_dirty()
	changed.emit()
	return true


## Segments a lane edit on `segment_id` reaches: [{segment_id, aligned}], where
## aligned = runs the same way as `segment_id`. Only segments whose layout matches
## (seen in the same direction) are included.
func lane_edit_reach(segment_id: int, scope: EditScope) -> Array[Dictionary]:
	var result: Array[Dictionary] = [{"segment_id": segment_id, "aligned": true}]
	var seg := get_segment(segment_id)
	if seg == null or scope == EditScope.SEGMENT:
		return result
	var layout := seg.type.layout()
	var seen := {segment_id: true}
	# Walk forward from the end node, then backward from the start node.
	for forward_walk: bool in [true, false]:
		var cur := seg
		var node_id := seg.end_id if forward_walk else seg.start_id
		while true:
			var next := _continuing_segment(node_id, cur, scope)
			if next == null or seen.has(next.id):
				break
			# The walk keeps going the same way: leaving node_id along `next`.
			var walk_forward := next.start_id == node_id
			var next_aligned := walk_forward == forward_walk
			var next_layout := next.type.layout() if next_aligned else RoadType.reversed_layout(next.type.layout())
			if next_layout != layout:
				break
			seen[next.id] = true
			result.append({"segment_id": next.id, "aligned": next_aligned})
			cur = next
			node_id = next.end_id if walk_forward else next.start_id
	return result


## The segment continuing `from` through `node_id`: the only other one at a
## two-road node, or (STREET scope) the one straight ahead at a junction.
func _continuing_segment(node_id: int, from: RoadSegment, scope: EditScope) -> RoadSegment:
	var node := get_node_data(node_id)
	if node == null:
		return null
	var others: Array[int] = []
	for sid in node.segment_ids:
		if sid != from.id:
			others.append(sid)
	if others.size() == 1 and node.segment_ids.size() == 2:
		return segments[others[0]]
	if scope != EditScope.STREET:
		return null
	var ahead := -outward_direction(node_id, from.id)
	var best: RoadSegment = null
	var best_angle := 30.0
	for sid in others:
		var angle := rad_to_deg(ahead.angle_to(outward_direction(node_id, sid)))
		if angle < best_angle:
			best_angle = angle
			best = segments[sid]
	return best


## Gives a segment a new lane layout and moves its center line `lateral` m to
## the right (of the segment direction), so unchanged lanes stay in place.
func _set_layout(seg: RoadSegment, forwards: Array[bool], lateral: float) -> void:
	seg.type = RoadType.from_layout(forwards)
	if absf(lateral) > 1e-6:
		seg.start_offset += seg.curve.tangent(0.0).cross(Vector3.UP).normalized() * lateral
		seg.end_offset += seg.curve.tangent(1.0).cross(Vector3.UP).normalized() * lateral
		_update_segment_curve(seg)
	for nid: int in [seg.start_id, seg.end_id]:
		_drop_custom_for_segment(get_node_data(nid), seg.id)
		_dirty_nodes[nid] = true


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
	var settings := seg.start_settings
	seg.start_settings = seg.end_settings
	seg.end_settings = settings
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
		for i in seg.type.lanes.size():
			var lane: RoadType.LaneDef = seg.type.lanes[i]
			var d := _lane_end_distance(seg, node_id, lane.offset)
			var t := seg.curve.t_at_distance(d)
			var tan := seg.curve.tangent(t)
			var right := tan.cross(Vector3.UP).normalized()
			var e := LaneEnd.new()
			e.key = lane_key(seg.id, i)
			e.segment_id = seg.id
			e.lane_index = i
			e.incoming = lane.forward != at_start
			e.position = seg.curve.point(t) + right * lane.offset * seg.width_scale(d)
			e.position.y = ROAD_Y
			e.direction = tan if lane.forward else -tan
			result.append(e)
	return result


## Distance along the curve where a lane (`lane_offset` right of the center
## line, in the segment's direction) ends at `node_id`, following a slanted end edge.
func _lane_end_distance(seg: RoadSegment, node_id: int, lane_offset: float) -> float:
	var side := 1.0 if node_id == seg.start_id else -1.0
	var scale := seg.width_scale(seg.distance_from_end(node_id, seg.trim_at(node_id, 0.0)))
	return seg.distance_from_end(node_id, seg.trim_at(node_id, lane_offset * scale * side))


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
			result[e.key] = _default_outs(e, ends, node.mode == NodeMode.UTURN)
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


# ---------------------------------------------------------------- node controller

## The node's mode as it actually applies (MIDDLE / STRETCH need exactly two roads).
func effective_mode(node_id: int) -> NodeMode:
	var node := get_node_data(node_id)
	if node == null:
		return NodeMode.AUTO
	if (node.mode == NodeMode.MIDDLE or node.mode == NodeMode.STRETCH) and node.segment_ids.size() != 2:
		return NodeMode.AUTO
	return node.mode as NodeMode


func set_node_mode(node_id: int, mode: NodeMode) -> void:
	var node := get_node_data(node_id)
	if node == null or node.mode == mode:
		return
	node.mode = mode
	_dirty_nodes[node_id] = true
	_rebuild_dirty()
	changed.emit()


## True if the node has traffic lights switched on and enough roads for them.
func has_traffic_lights(node_id: int) -> bool:
	var node := get_node_data(node_id)
	return node != null and node.traffic_lights and node.segment_ids.size() >= MIN_LIGHT_ROADS


func set_traffic_lights(node_id: int, on: bool) -> void:
	var node := get_node_data(node_id)
	if node == null or node.traffic_lights == on:
		return
	node.traffic_lights = on
	changed.emit()


## A copy of the settings of the road end of `segment_id` at `node_id`.
func get_end_settings(node_id: int, segment_id: int) -> EndSettings:
	var seg := get_segment(segment_id)
	if seg == null:
		return EndSettings.new()
	return seg.settings_at(node_id).copy()


func set_end_settings(node_id: int, segment_id: int, settings: EndSettings) -> void:
	var seg := get_segment(segment_id)
	if seg == null or (seg.start_id != node_id and seg.end_id != node_id):
		return
	_apply_end_settings(seg, node_id, settings)
	_rebuild_dirty()
	changed.emit()


## True if the node or any of its road ends has Node Controller settings.
func has_node_settings(node_id: int) -> bool:
	var node := get_node_data(node_id)
	if node == null:
		return false
	if node.mode != NodeMode.AUTO:
		return true
	for sid in node.segment_ids:
		if not (segments[sid] as RoadSegment).settings_at(node_id).is_default():
			return true
	return false


## Back to automatic: mode and every road end's settings.
func reset_node(node_id: int) -> void:
	var node := get_node_data(node_id)
	if node == null:
		return
	node.mode = NodeMode.AUTO
	for sid in node.segment_ids:
		_apply_end_settings(segments[sid], node_id, EndSettings.new())
	_dirty_nodes[node_id] = true
	_rebuild_dirty()
	changed.emit()


## The node's mode and road end settings, for paste_node_settings.
func copy_node_settings(node_id: int) -> Dictionary:
	var node := get_node_data(node_id)
	if node == null:
		return {}
	var ends: Array[EndSettings] = []
	for e in _segment_ends(node):
		ends.append((e.settings as EndSettings).copy())
	return {"mode": node.mode, "ends": ends, "traffic_lights": node.traffic_lights}


## Applies copied settings, matching road ends by their order around the node.
func paste_node_settings(node_id: int, data: Dictionary) -> void:
	var node := get_node_data(node_id)
	if node == null or data.is_empty():
		return
	node.mode = data.mode
	node.traffic_lights = data.get("traffic_lights", false)
	var copied: Array = data.ends
	var ends := _segment_ends(node)
	for i in ends.size():
		var s: EndSettings = (copied[i] as EndSettings).copy() if i < copied.size() else EndSettings.new()
		_apply_end_settings(ends[i].seg, node_id, s)
	_dirty_nodes[node_id] = true
	_rebuild_dirty()
	changed.emit()


## Road ends at a node in order around it, for drawing handles. Each entry:
##   segment_id, settings (copy), half (half width at the end), trim, skew,
##   center / left / right: cut center and corners (Vector3),
##   out / out_left / out_right: outward directions there, side: right of out,
##   curb: corner toward the next end, {} or {x, mid, bisector (Vector3), radius,
##         factor (distance x -> mid per meter of radius)}.
func node_end_info(node_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var node := get_node_data(node_id)
	if node == null or node.segment_ids.size() < 2:
		return result
	for e: Dictionary in _junction_shape(node).ends:
		var seg: RoadSegment = e.seg
		var info := {
			"segment_id": seg.id,
			"type_name": seg.type.display_name,
			"settings": (e.settings as EndSettings).copy(),
			"half": e.half,
			"trim": seg.trim_start if e.at_start else seg.trim_end,
			"skew": seg.skew_start if e.at_start else seg.skew_end,
			"center": _to_3d(e.center),
			"left": _to_3d(e.left),
			"right": _to_3d(e.right),
			"out": _dir_3d(e.out),
			"out_left": _dir_3d(e.out_left),
			"out_right": _dir_3d(e.out_right),
			"side": _dir_3d(Vector2(-(e.out as Vector2).y, (e.out as Vector2).x)),
			"curb": {},
		}
		var curb: Dictionary = e.curb
		if not curb.is_empty():
			info.curb = {"x": _to_3d(curb.x), "mid": _to_3d(curb.mid), "bisector": _dir_3d(curb.bisector),
				"radius": curb.radius, "factor": curb.factor}
		result.append(info)
	return result


## Moves one corner of a road end onto `target` by shifting the end sideways
## and pulling that corner back or forward (the other corner keeps its distance).
## `side`: -1 = left corner, 1 = right corner (looking outward from the node).
## If the target is a corner of another road end at this node (`target_segment`,
## `target_side`), that corner is held in place: its road's automatic trim would
## otherwise move when this end moves.
func align_corner(node_id: int, segment_id: int, side: int, target: Vector3,
		target_segment: int = -1, target_side: int = 0) -> void:
	var node := get_node_data(node_id)
	var seg := get_segment(segment_id)
	if node == null or seg == null or not node.segment_ids.has(segment_id):
		return
	var hold := get_segment(target_segment) if target_segment != segment_id else null
	if hold != null and not node.segment_ids.has(target_segment):
		hold = null
	var goal := _flat(target)
	for _i in 20:
		var moved := _move_corner_toward(node, seg, side, goal, true)
		if hold != null:
			moved = _move_corner_toward(node, hold, target_side, goal, false) or moved
		if not moved:
			break
	_rebuild_dirty()
	changed.emit()


## One step of align_corner: changes a road end's settings so its corner moves
## onto `goal` (sideways too if `allow_shift`). Returns false if already there.
func _move_corner_toward(node: RoadNode, seg: RoadSegment, side: int, goal: Vector2, allow_shift: bool) -> bool:
	var end: Dictionary = {}
	for e: Dictionary in _junction_shape(node).ends:
		if (e.seg as RoadSegment).id == seg.id:
			end = e
	var corner: Vector2 = end.right if side > 0 else end.left
	var out: Vector2 = end.out_right if side > 0 else end.out_left
	var diff := goal - corner
	var along := diff.dot(out)
	var across := diff.dot(Vector2(-out.y, out.x)) if allow_shift else 0.0
	if absf(along) < 0.002 and absf(across) < 0.002:
		return false
	var s := seg.settings_at(node.id).copy()
	s.shift += across
	s.offset += along * 0.5
	var skew := tan(deg_to_rad(s.rotate)) + side * along / (2.0 * float(end.half))
	s.rotate = clampf(rad_to_deg(atan(skew)), -MAX_ROTATE, MAX_ROTATE)
	_apply_end_settings(seg, node.id, s)
	_compute_trims(node)
	return true


func _apply_end_settings(seg: RoadSegment, node_id: int, settings: EndSettings) -> void:
	var shift_delta := settings.shift - seg.settings_at(node_id).shift
	if node_id == seg.start_id:
		seg.start_settings = settings.copy()
	else:
		seg.end_settings = settings.copy()
	if absf(shift_delta) > 1e-6:
		var move := outward_direction(node_id, seg.id).cross(Vector3.UP).normalized() * shift_delta
		if node_id == seg.start_id:
			seg.start_offset += move
		else:
			seg.end_offset += move
		_update_segment_curve(seg)
	_dirty_nodes[seg.start_id] = true
	_dirty_nodes[seg.end_id] = true


## Offset of a road end from its node caused by its shift setting.
func _shift_vector(seg: RoadSegment, node_id: int) -> Vector3:
	return outward_direction(node_id, seg.id).cross(Vector3.UP).normalized() * seg.settings_at(node_id).shift


## Moves the curve's end points to the nodes plus the segment's end offsets.
func _update_segment_curve(seg: RoadSegment) -> void:
	seg.curve = seg.curve.with_endpoints(get_node_data(seg.start_id).position + seg.start_offset,
		get_node_data(seg.end_id).position + seg.end_offset)


static func _to_3d(p: Vector2) -> Vector3:
	return Vector3(p.x, ROAD_Y, p.y)


static func _dir_3d(d: Vector2) -> Vector3:
	return Vector3(d.x, 0.0, d.y)


## Path a vehicle takes through a junction from one lane to another.
static func connection_curve(from: LaneEnd, to: LaneEnd) -> RoadCurve:
	# Handle length scales with the gap, so a zero-length connection (lanes that
	# meet exactly) stays a point instead of looping back on itself.
	var k := from.position.distance_to(to.position) * 0.45
	return RoadCurve.new(from.position, from.position + from.direction * k,
		to.position - to.direction * k, to.position)


## Lane center line along the trimmed segment, in travel direction.
func lane_points(segment_id: int, lane_index: int, spacing: float = 2.0) -> PackedVector3Array:
	var seg: RoadSegment = segments[segment_id]
	var lane: RoadType.LaneDef = seg.type.lanes[lane_index]
	var from := _lane_end_distance(seg, seg.start_id, lane.offset)
	var to := _lane_end_distance(seg, seg.end_id, lane.offset)
	var pts := PackedVector3Array()
	if to - from < 0.01:
		return pts
	var steps := maxi(1, ceili((to - from) / spacing))
	for i in steps + 1:
		var d := lerpf(from, to, float(i) / steps)
		var t := seg.curve.t_at_distance(d)
		var p := seg.curve.point(t) + seg.curve.tangent(t).cross(Vector3.UP).normalized() * lane.offset * seg.width_scale(d)
		p.y = ROAD_Y
		pts.append(p)
	if not lane.forward:
		pts.reverse()
	return pts


## Default lane connections for one incoming lane. The roads it may turn into are
## ordered from the sharpest right turn to the sharpest left. When its road brings
## several lanes in, the right lanes take the right turns and the left lanes the
## left ones (every lane gets a road, every road a lane), and lanes going into the
## same road keep their order. A single lane may take every road and lane.
func _default_outs(incoming: LaneEnd, ends: Array[LaneEnd], allow_u_turn: bool = false) -> Array:
	var in_dir := _flat(incoming.direction).normalized()
	var in_right := Vector2(-in_dir.y, in_dir.x)
	var min_dot := cos(deg_to_rad(MAX_DEFAULT_TURN))
	var gentle := {}  # segment id -> Array[LaneEnd]
	var sharp := {}
	for e in ends:
		if e.incoming or (e.segment_id == incoming.segment_id and not allow_u_turn):
			continue
		var ok := e.segment_id == incoming.segment_id or in_dir.dot(_flat(e.direction).normalized()) >= min_dot
		((gentle if ok else sharp).get_or_add(e.segment_id, []) as Array).append(e)
	# Leave out hairpins (e.g. from the main road back into a tight exit), unless
	# that's the only way on (a road that bends back sharply at a node).
	var targets: Dictionary = gentle if not gentle.is_empty() else sharp
	if targets.is_empty():
		# Dead end: allow turning around.
		for e in ends:
			if not e.incoming:
				(targets.get_or_add(e.segment_id, []) as Array).append(e)
	# Roads from the sharpest right turn to the sharpest left (a U-turn is last).
	var order: Array = targets.keys()
	var turn := {}
	for sid: int in order:
		var d := _flat((targets[sid][0] as LaneEnd).direction).normalized()
		turn[sid] = -PI if sid == incoming.segment_id else atan2(d.dot(in_right), d.dot(in_dir))
	order.sort_custom(func(a: int, b: int) -> bool: return turn[a] > turn[b])
	# This lane's place among its road's incoming lanes, right to left.
	var group: Array[LaneEnd] = []
	for e in ends:
		if e.incoming and e.segment_id == incoming.segment_id:
			group.append(e)
	_sort_right_to_left(group)
	var i := group.find(incoming)
	var m := group.size()
	var k := order.size()
	var outs := []
	for j in k:
		if not _shares_part(i, m, j, k):
			continue
		# The incoming lanes heading for road j, and this lane's place among them.
		var lanes_to_j := 0
		var p := 0
		for ii in m:
			if _shares_part(ii, m, j, k):
				if ii < i:
					p += 1
				lanes_to_j += 1
		var target_lanes: Array[LaneEnd] = []
		target_lanes.assign(targets[order[j]])
		_sort_right_to_left(target_lanes)
		var c := target_lanes.size()
		for q in c:
			if _shares_part(p, lanes_to_j, q, c):
				outs.append(target_lanes[q].key)
	return outs


## True if part `a` of `na` equal parts of [0, 1] overlaps part `b` of `nb`.
static func _shares_part(a: int, na: int, b: int, nb: int) -> bool:
	return a * nb < (b + 1) * na and b * na < (a + 1) * nb


## Sorts lane ends from the rightmost to the leftmost, looking along their travel direction.
static func _sort_right_to_left(lanes: Array[LaneEnd]) -> void:
	if lanes.is_empty():
		return
	var d := _flat(lanes[0].direction).normalized()
	var right := Vector2(-d.y, d.x)
	lanes.sort_custom(func(a: LaneEnd, b: LaneEnd) -> bool:
		return _flat(a.position).dot(right) > _flat(b.position).dot(right))


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
		var settings := seg.settings_at(node.id)
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
			"settings": settings,
			"at_start": seg.start_id == node.id,
			"dir": d2,
			"right": right,
			"origin": origin,  # where the segment's center line starts, relative to the node
			"lateral": origin.dot(right),
			"base_half": seg.type.width * 0.5,
			"half": seg.type.width * 0.5 * (1.0 + settings.stretch),
			"angle": angle,
			"hit": 0.0,
			"need": 0.0,
		})
	# Parallel roads side by side (e.g. one-ways on both lanes) sort by lateral position.
	ends.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a.angle - b.angle) > 0.01:
			return a.angle < b.angle
		return a.lateral < b.lateral)
	return ends


## Cuts segment ends back far enough that neighboring roads don't overlap,
## then applies the Node Controller settings (offset, rotate, curb radius).
func _compute_trims(node: RoadNode) -> void:
	var ends := _segment_ends(node)
	var n := ends.size()
	var mode := effective_mode(node.id)
	for e in ends:
		var seg: RoadSegment = e.seg
		if mode == NodeMode.MIDDLE:
			_set_trim(seg, e.at_start, 0.0, 0.0)
	if mode == NodeMode.MIDDLE:
		return
	if n >= 2:
		for i in n:
			var a := ends[i]
			var b := ends[(i + 1) % n]
			# a's right edge faces b's left edge.
			var hit: Variant = _line_intersection(a.origin + a.right * a.half, a.dir, b.origin - b.right * b.half, b.dir)
			if hit != null and hit.x > 0.0 and hit.y > 0.0:
				a.hit = maxf(a.hit, hit.x)
				b.hit = maxf(b.hit, hit.y)
				# A custom curb radius needs room for the curve before the roads start.
				var radius: float = (a.settings as EndSettings).radius
				if radius >= 0.0:
					var t := _fillet_tangent(radius, a.dir, b.dir)
					a.need = maxf(a.need, hit.x + t)
					b.need = maxf(b.need, hit.y + t)
	var margin := JUNCTION_MARGIN if n >= 3 else 0.0
	# Centered roads of different widths get a taper; a road snapped to a lane doesn't need one.
	var width_change := n == 2 and absf(ends[0].base_half - ends[1].base_half) > 0.01 \
		and (ends[0].origin as Vector2).length() < 0.05 and (ends[1].origin as Vector2).length() < 0.05
	for e in ends:
		var s: EndSettings = e.settings
		var seg: RoadSegment = e.seg
		var base := maxf(e.hit + margin, e.need)
		if width_change:
			base = maxf(base, 3.0)  # room for a taper between different widths
		if mode == NodeMode.STRETCH:
			base = maxf(base, STRETCH_NODE_LENGTH)
		var skew := tan(deg_to_rad(clampf(s.rotate, -MAX_ROTATE, MAX_ROTATE)))
		# Keep both corners of a slanted end on the road.
		var reach: float = e.half * absf(skew)
		var max_trim := seg.curve.get_length() * MAX_TRIM_FRACTION
		var trim := clampf(base + s.offset, reach, maxf(max_trim - reach, reach))
		_set_trim(seg, e.at_start, trim, skew)


static func _set_trim(seg: RoadSegment, at_start: bool, trim: float, skew: float) -> void:
	if at_start:
		seg.trim_start = trim
		seg.skew_start = skew
	else:
		seg.trim_end = trim
		seg.skew_end = skew


## Distance from the corner where two edges meet (running along `da` and `db`)
## to where a curb of `radius` touches them.
static func _fillet_tangent(radius: float, da: Vector2, db: Vector2) -> float:
	var half_angle := clampf(absf(da.angle_to(db)), 0.05, PI - 0.05) * 0.5
	return radius / tan(half_angle)


## Each road end at a node (sorted by angle) with its corners, and the junction
## outline. Per end: seg, settings, at_start, half, center (cut center),
## out (outward direction there), left / right corners with out_left / out_right,
## and curb: the corner toward the next end ({} if its edges don't meet):
## {x: where the edges meet, mid: middle of the curb, bisector, radius}.
func _junction_shape(node: RoadNode) -> Dictionary:
	var ends := _segment_ends(node)
	var n := ends.size()
	for e in ends:
		var seg: RoadSegment = e.seg
		for side: float in [-1.0, 0.0, 1.0]:
			var d := seg.distance_from_end(node.id, seg.trim_at(node.id, side * e.half))
			var t := seg.curve.t_at_distance(d)
			var q := seg.curve.point(t)
			var out := seg.curve.tangent(t) * (1.0 if e.at_start else -1.0)
			var o2 := Vector2(out.x, out.z).normalized()
			var half := seg.type.width * 0.5 * seg.width_scale(d)
			var p := Vector2(q.x, q.z) + Vector2(-o2.y, o2.x) * side * half
			if side < 0.0:
				e.left = p
				e.out_left = o2
			elif side > 0.0:
				e.right = p
				e.out_right = o2
			else:
				e.center = p
				e.out = o2
		e.curb = {}
	var poly := PackedVector2Array()
	var center := _flat(node.position)
	if n >= 2:
		for i in n:
			var a := ends[i]
			var b := ends[(i + 1) % n]
			_append_unique(poly, a.left)
			_append_unique(poly, a.right)
			# Round the corner between a's right edge and b's left edge.
			var hit: Variant = _line_intersection(a.right, a.out_right, b.left, b.out_left)
			if hit == null:
				continue
			var x: Vector2 = a.right + a.out_right * hit.x
			if (hit.x < 0.0) != (hit.y < 0.0):
				# Tight angle where one end couldn't be cut back far enough (short
				# segment): the edges cross past that end. Follow both edges to the
				# crossing so the gore between them stays paved.
				var reach := maxf((a.right as Vector2).distance_to(center), (b.left as Vector2).distance_to(center))
				if (a.out_right as Vector2).dot(b.out_left) > 0.0 and x.distance_to(center) <= reach + 0.5:
					_append_unique(poly, x)
				continue
			if hit.x >= 0.0:
				continue
			var radius: float = (a.settings as EndSettings).radius
			var pts := PackedVector2Array()
			if radius >= 0.0:
				pts = _fillet_points(x, a.out_right, b.out_left, radius, -hit.x, -hit.y)
			else:
				for k in range(1, 6):
					var f := k / 6.0
					pts.append((a.right as Vector2).lerp(x, f).lerp(x.lerp(b.left, f), f))
			for p in pts:
				_append_unique(poly, p)
			var bisector := ((a.out_right as Vector2) + (b.out_left as Vector2)).normalized()
			a.curb = {"x": x, "mid": _curb_middle(pts, x, bisector), "bisector": bisector, "radius": radius,
				"factor": _curb_factor(a.out_right, b.out_left)}
		if poly.size() > 2 and poly[0].distance_to(poly[poly.size() - 1]) < 0.01:
			poly.remove_at(poly.size() - 1)
	return {"ends": ends, "poly": poly}


## Points of a circular curb of `radius` between two edges that meet at `x`,
## running out along `ua` and `ub` (shrunk to fit within `max_a` / `max_b`).
static func _fillet_points(x: Vector2, ua: Vector2, ub: Vector2, radius: float, max_a: float, max_b: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var phi := absf(ua.angle_to(ub))
	if phi > PI - 0.05 or phi < 0.05:
		return pts
	var half_phi := phi * 0.5
	var t := minf(radius / tan(half_phi), minf(max_a, max_b))
	var r := t * tan(half_phi)
	var pa := x + ua * t
	var pb := x + ub * t
	pts.append(pa)
	if r > 0.01:
		var c := x + (ua + ub).normalized() * (r / sin(half_phi))
		var a0 := (pa - c).angle()
		var sweep := wrapf((pb - c).angle() - a0, -PI, PI)
		for k in range(1, 10):
			pts.append(c + Vector2.from_angle(a0 + sweep * k / 10.0) * r)
	pts.append(pb)
	return pts


## The curb point closest to the corner `x` along the bisector (its middle).
static func _curb_middle(pts: PackedVector2Array, x: Vector2, bisector: Vector2) -> Vector2:
	if pts.is_empty():
		return x
	var best := pts[0]
	var best_d := INF
	for p in pts:
		var d := (p - x).dot(bisector)
		if d < best_d:
			best_d = d
			best = p
	return best


## Distance from the corner to the middle of a curb, per meter of curb radius.
static func _curb_factor(ua: Vector2, ub: Vector2) -> float:
	var half_phi := clampf(absf(ua.angle_to(ub)), 0.05, PI - 0.05) * 0.5
	return 1.0 / sin(half_phi) - 1.0


func _build_junction_mesh(node: RoadNode) -> void:
	var mesh: ArrayMesh = null
	if node.segment_ids.size() >= 2 and effective_mode(node.id) != NodeMode.MIDDLE:
		var poly: PackedVector2Array = _junction_shape(node).poly
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
	var length := seg.curve.get_length()
	var half_start := seg.type.width * 0.5 * seg.width_scale(seg.trim_start)
	var half_end := seg.type.width * 0.5 * seg.width_scale(length - seg.trim_end)
	# Each side starts and ends where the (possibly slanted) end edges cross it.
	# At the end node, the segment's right side is the left side looking outward.
	var from_l := seg.trim_start - half_start * seg.skew_start
	var from_r := seg.trim_start + half_start * seg.skew_start
	var to_l := length - (seg.trim_end + half_end * seg.skew_end)
	var to_r := length - (seg.trim_end - half_end * seg.skew_end)
	var mesh: ArrayMesh = null
	if to_l - from_l > 0.01 and to_r - from_r > 0.01:
		var stretched := seg.start_settings.stretch != 0.0 or seg.end_settings.stretch != 0.0
		mesh = RoadMeshBuilder.build_strip_sides(seg.curve, from_l, from_r, to_l, to_r,
			func(d: float) -> float: return seg.type.width * 0.5 * seg.width_scale(d), ROAD_Y, stretched)
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
