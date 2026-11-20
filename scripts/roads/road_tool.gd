class_name RoadTool
extends Node3D
## Mouse tools for the road network: drawing (straight / curved / freeform),
## upgrading or reversing, bulldozing, editing lane connections, and shaping
## junctions (Node Controller).

signal hint_changed(text: String)
## The Node Controller's selected node or align state changed.
signal node_tool_changed

enum Mode { STRAIGHT, CURVED, FREEFORM, UPGRADE, LANES, BULLDOZE, NODE }

const MAP_HALF_SIZE := 1000.0
const BORDER_SNAP_DISTANCE := 8.0
const NODE_SNAP_RADIUS := 5.0
const SEGMENT_SNAP_EXTRA := 1.0
const MIN_ROAD_LENGTH := 4.0
const MAX_TURN_DEGREES := 120.0
const MIN_JUNCTION_ANGLE := 25.0
## A road snapped to a lane may branch off at a shallow angle (like a ramp).
const MIN_LANE_BRANCH_ANGLE := 5.0
const MISMATCH_TEXT := "Lane direction mismatch: this road runs against the lane it joins"
const ANGLE_STEP := 15.0
const ANGLE_SNAP_TOLERANCE := 4.0
const LENGTH_STEP := 8.0
const LENGTH_SNAP_TOLERANCE := 1.5
const LANE_PICK_RADIUS := 1.4
const JUNCTION_PICK_RADIUS := 8.0

const COLOR_OK := Color(0.35, 0.7, 1.0, 0.55)
const COLOR_BAD := Color(1.0, 0.25, 0.2, 0.55)
const COLOR_GUIDE := Color(1, 1, 1, 0.7)
const COLOR_SNAP_NODE := Color(0.3, 1.0, 0.4, 0.9)
const COLOR_SNAP_SEGMENT := Color(0.3, 0.9, 1.0, 0.9)
const COLOR_SNAP_LANE := Color(1.0, 0.85, 0.2, 0.95)
const COLOR_SNAP_BORDER := Color(0.35, 0.7, 1.0, 0.95)
const COLOR_WARNING := Color(1.0, 0.77, 0.0)
const COLOR_LANE_IN := Color(1.0, 0.6, 0.1, 0.95)
const COLOR_LANE_OUT := Color(0.3, 0.95, 0.4, 0.95)
const COLOR_CONNECTION := Color(0.3, 0.85, 1.0, 0.35)
const COLOR_CONNECTION_SELECTED := Color(1.0, 1.0, 0.3, 0.95)
const COLOR_HANDLE_CENTER := Color(0.3, 0.7, 1.0, 0.95)
const COLOR_HANDLE_CORNER := Color(1.0, 0.85, 0.2, 0.95)
const COLOR_HANDLE_CURB := Color(0.35, 0.95, 0.45, 0.95)
const COLOR_ALIGN := Color(1.0, 0.5, 0.15, 1.0)
const COLOR_EDITED_NODE := Color(0.3, 0.7, 1.0, 0.6)
const HANDLE_PICK_RADIUS := 1.1
const HANDLE_Y := 0.12

const HINTS := {
	Mode.STRAIGHT: "Left click: start / place road  ·  Right click: stop  ·  Shift: no angle/length snapping  ·  Ends at the map edge bring traffic",
	Mode.CURVED: "Click start, then the curve's control point, then the end  ·  Right click: stop",
	Mode.FREEFORM: "Click start, then click to lay smoothly connected curves  ·  Right click: stop",
	Mode.UPGRADE: "Left click a road: change it to the selected type (same one-way type: reverse)  ·  Right click: reverse one-way",
	Mode.LANES: "Click a junction, then an incoming lane (orange), then outgoing lanes (green) to toggle  ·  R: reset junction  ·  Right click: back",
	Mode.BULLDOZE: "Left click a road to delete it",
	Mode.NODE: "Click a junction, then drag its handles (Shift: sideways)  ·  A: align corners  ·  Ctrl+C / V: copy / paste  ·  R: reset",
}

@export var network: RoadNetwork

var mode: Mode = Mode.STRAIGHT
var road_type: RoadType
var grid_snap: bool = true

# Drawing state. A snap is {pos, anchor, node, on_segment, lane_dir}:
#   pos      where the road end goes (a lane center when snapped to a lane)
#   anchor   the node position / center line point it attaches to
#   lane_dir travel direction of the snapped lane (zero if not lane-snapped)
var _has_start := false
var _start: Dictionary = {}
var _control: Variant = null
## Tangent the next freeform piece must leave the start with (zero = none).
var _start_tangent := Vector3.ZERO
## Reference direction for angle snapping.
var _start_ref := Vector3.ZERO
var _cursor := Vector3.ZERO
var _cursor_ok := false
var _snap: Dictionary = {}

# Hover / lane tool state.
var _hover_segment := -1
var _lane_node := -1
var _lane_selected := -1

# Node Controller state.
## Junction being edited (-1 = none).
var selected_node := -1
## True while picking two corners to align.
var aligning := false
var _align_source: Dictionary = {}
## Handle being dragged: {kind, segment_id, side, start, settings, info}.
var _drag: Dictionary = {}
var _clipboard: Dictionary = {}

var _preview: MeshInstance3D
var _gizmo: MeshInstance3D
var _gizmo_material := TriBatch.make_material(true)
var _label: Label


func _ready() -> void:
	road_type = RoadType.get_type(&"two_way")
	_preview = MeshInstance3D.new()
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_preview)
	_gizmo = MeshInstance3D.new()
	_gizmo.mesh = ImmediateMesh.new()
	_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_gizmo)
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)


func get_hint() -> String:
	return HINTS[mode]


func set_mode(new_mode: Mode) -> void:
	cancel()
	mode = new_mode
	hint_changed.emit(get_hint())


func set_road_type(type: RoadType) -> void:
	road_type = type


func cancel() -> void:
	_has_start = false
	_control = null
	_start_tangent = Vector3.ZERO
	_start_ref = Vector3.ZERO
	_lane_node = -1
	_lane_selected = -1
	_drag = {}
	if selected_node >= 0 or aligning:
		selected_node = -1
		aligning = false
		_align_source = {}
		node_tool_changed.emit()


func _process(_delta: float) -> void:
	_update_cursor()
	_update_visuals()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_update_cursor()
			if _cursor_ok:
				_on_left_click()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_update_cursor()
			_on_right_click()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed:
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and not _drag.is_empty():
			_drag = {}
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and not _drag.is_empty():
		_update_cursor()
		if _cursor_ok:
			_update_drag()
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			_on_right_click()
		elif key.keycode == KEY_R and mode == Mode.LANES and _lane_node >= 0:
			network.reset_connections(_lane_node)
		elif mode == Mode.NODE and selected_node >= 0:
			if key.keycode == KEY_R:
				reset_node()
			elif key.keycode == KEY_A:
				set_aligning(not aligning)
			elif key.keycode == KEY_C and key.ctrl_pressed:
				copy_node()
			elif key.keycode == KEY_V and key.ctrl_pressed:
				paste_node()


# ---------------------------------------------------------------- node controller

func select_node(node_id: int) -> void:
	if node_id == selected_node:
		return
	selected_node = node_id
	aligning = false
	_align_source = {}
	_drag = {}
	node_tool_changed.emit()


func set_aligning(on: bool) -> void:
	aligning = on and selected_node >= 0
	_align_source = {}
	node_tool_changed.emit()


func reset_node() -> void:
	if selected_node >= 0:
		network.reset_node(selected_node)


func copy_node() -> void:
	if selected_node >= 0:
		_clipboard = network.copy_node_settings(selected_node)
		node_tool_changed.emit()


func paste_node() -> void:
	if selected_node >= 0 and not _clipboard.is_empty():
		network.paste_node_settings(selected_node, _clipboard)


func has_clipboard() -> bool:
	return not _clipboard.is_empty()


func _click_node() -> void:
	if selected_node >= 0 and network.nodes.has(selected_node):
		var h := _handle_under_cursor(aligning)
		if not h.is_empty():
			if aligning:
				_click_align(h)
			else:
				var info: Dictionary = h.info
				_drag = {"kind": h.kind, "segment_id": h.segment_id, "side": h.side,
					"start": _cursor, "settings": (info.settings as RoadNetwork.EndSettings).copy(), "info": info}
			return
	var nid := _junction_under_cursor()
	if nid >= 0 and network.get_node_data(nid).segment_ids.size() < 2:
		nid = -1
	if nid >= 0 or not aligning:
		select_node(nid)


## First click picks the corner to move, the second the corner to move it onto.
func _click_align(h: Dictionary) -> void:
	if _align_source.is_empty():
		_align_source = h
		return
	if h.segment_id == _align_source.segment_id:
		_align_source = h  # pick a corner of another road end as the target
		return
	network.align_corner(selected_node, _align_source.segment_id, _align_source.side, h.pos, h.segment_id, h.side)
	set_aligning(false)


func _update_drag() -> void:
	if selected_node < 0 or not network.nodes.has(selected_node) or network.get_segment(_drag.segment_id) == null:
		_drag = {}
		return
	var info: Dictionary = _drag.info
	var s0: RoadNetwork.EndSettings = _drag.settings
	var s := s0.copy()
	var delta := _cursor - (_drag.start as Vector3)
	delta.y = 0.0
	match _drag.kind:
		"center":
			if Input.is_key_pressed(KEY_SHIFT):
				s.shift = snappedf(s0.shift + delta.dot(info.side), 0.05)
			else:
				s.offset = snappedf(s0.offset + delta.dot(info.out), 0.1)
		"corner":
			# Move one corner along its edge; the other corner stays put.
			var side: float = _drag.side
			var along := delta.dot(info.out_right if side > 0.0 else info.out_left)
			s.offset = s0.offset + along * 0.5
			var skew := tan(deg_to_rad(s0.rotate)) + side * along / (2.0 * float(info.half))
			s.rotate = snappedf(clampf(rad_to_deg(atan(skew)), -RoadNetwork.MAX_ROTATE, RoadNetwork.MAX_ROTATE), 0.5)
		"curb":
			var curb: Dictionary = info.curb
			var dist := (_cursor - (curb.x as Vector3)).dot(curb.bisector)
			s.radius = snappedf(maxf(0.0, dist / maxf(float(curb.factor), 0.05)), 0.25)
	network.set_end_settings(selected_node, _drag.segment_id, s)


## Draggable handles of the selected node: {kind, segment_id, side, pos, info}.
## Kinds: "center" (cut center), "corner" (side -1 left / 1 right), "curb".
func _node_handles() -> Array[Dictionary]:
	var handles: Array[Dictionary] = []
	if selected_node < 0 or not network.nodes.has(selected_node):
		return handles
	for info in network.node_end_info(selected_node):
		var sid: int = info.segment_id
		handles.append({"kind": "center", "segment_id": sid, "side": 0, "pos": info.center, "info": info})
		handles.append({"kind": "corner", "segment_id": sid, "side": -1, "pos": info.left, "info": info})
		handles.append({"kind": "corner", "segment_id": sid, "side": 1, "pos": info.right, "info": info})
		var curb: Dictionary = info.curb
		if not curb.is_empty():
			handles.append({"kind": "curb", "segment_id": sid, "side": 1, "pos": curb.mid, "info": info})
	return handles


func _handle_under_cursor(corners_only: bool = false) -> Dictionary:
	var best: Dictionary = {}
	var best_d := HANDLE_PICK_RADIUS
	for h in _node_handles():
		if corners_only and h.kind != "corner":
			continue
		var d := _flat_distance(_cursor, h.pos)
		if d < best_d:
			best_d = d
			best = h
	return best


# ---------------------------------------------------------------- clicks

func _on_left_click() -> void:
	match mode:
		Mode.STRAIGHT, Mode.CURVED, Mode.FREEFORM:
			_click_draw()
		Mode.UPGRADE:
			var seg := _segment_under_cursor()
			if seg:
				if seg.type != road_type:
					network.set_segment_type(seg.id, road_type)
				elif road_type.is_one_way():
					network.reverse_segment(seg.id)
		Mode.BULLDOZE:
			var seg := _segment_under_cursor()
			if seg:
				network.remove_segment(seg.id)
		Mode.LANES:
			_click_lanes()
		Mode.NODE:
			_click_node()


func _on_right_click() -> void:
	match mode:
		Mode.NODE:
			if not _drag.is_empty():
				# Undo the drag in progress.
				network.set_end_settings(selected_node, _drag.segment_id, _drag.settings)
				_drag = {}
			elif aligning:
				set_aligning(false)
			else:
				select_node(-1)
		Mode.UPGRADE:
			var seg := _segment_under_cursor()
			if seg and seg.type.is_one_way():
				network.reverse_segment(seg.id)
		Mode.LANES:
			if _lane_selected >= 0:
				_lane_selected = -1
			else:
				_lane_node = -1
		_:
			cancel()


func _click_draw() -> void:
	var placing_control := mode == Mode.CURVED and _has_start and _control == null
	_snap = _compute_snap(_cursor, not placing_control)
	if not _has_start:
		_start = _snap.duplicate()
		_has_start = true
		_control = null
		_init_start_directions()
		return
	if placing_control:
		if (_snap.pos as Vector3).distance_to(_start.pos) >= 1.0:
			_control = _snap.pos
		return
	var curve := _proposed_curve(_snap.pos)
	if _validate(curve, _snap) != "":
		return
	if not network.build_road(curve, road_type, _start, _snap):
		return
	# Keep drawing from the end of the new road.
	var end_node := network.find_node_near(_snap.anchor, 0.5)
	_start = {
		"pos": _snap.pos,
		"anchor": network.get_node_data(end_node).position if end_node >= 0 else _snap.pos,
		"node": end_node,
		"on_segment": false,
		"lane_dir": _snap.lane_dir,
	}
	_start_tangent = curve.tangent(1.0)
	_start_ref = _start_tangent
	_control = null


func _click_lanes() -> void:
	if _lane_node >= 0 and network.nodes.has(_lane_node):
		var e := _lane_end_under_cursor()
		if e:
			if e.incoming:
				_lane_selected = -1 if _lane_selected == e.key else e.key
			elif _lane_selected >= 0:
				network.toggle_connection(_lane_node, _lane_selected, e.key)
			return
	var nid := _junction_under_cursor()
	if nid != _lane_node:
		_lane_node = nid
		_lane_selected = -1


# ---------------------------------------------------------------- drawing helpers

func _init_start_directions() -> void:
	_start_tangent = Vector3.ZERO
	_start_ref = Vector3.ZERO
	if _start.node >= 0:
		_start_tangent = network.continue_direction(_start.node)
		_start_ref = _start_tangent
		if _start_ref == Vector3.ZERO:
			var node := network.get_node_data(_start.node)
			if node and not node.segment_ids.is_empty():
				_start_ref = network.outward_direction(node.id, node.segment_ids[0])
	elif _start.on_segment:
		var hit := network.find_segment_near(_start.anchor, 0.75)
		if not hit.is_empty():
			_start_ref = network.get_segment(hit.segment_id).curve.tangent(hit.t)


## Snaps to nodes and roads (and, for one-lane roads, to whichever lane center
## of a wider road is closest to the mouse), otherwise to the angle/length grid.
func _compute_snap(raw: Vector3, allow_network: bool) -> Dictionary:
	if allow_network:
		var lane_snapping := road_type.lanes.size() == 1
		var nid := network.find_node_near(raw, NODE_SNAP_RADIUS)
		if nid >= 0:
			var node_pos := network.get_node_data(nid).position
			var snap := _make_snap(node_pos, node_pos, nid, false)
			if lane_snapping:
				_snap_to_closest_lane(snap, raw, network.node_lane_points(nid))
			return snap
		var hit := network.find_segment_near(raw, SEGMENT_SNAP_EXTRA, true)
		if not hit.is_empty():
			var snap := _make_snap(hit.point, hit.point, -1, true)
			if lane_snapping:
				_snap_to_closest_lane(snap, raw, network.segment_lane_points(hit.segment_id, hit.t))
			return snap
	var pos := raw
	if _has_start and grid_snap and not Input.is_key_pressed(KEY_SHIFT):
		pos = _grid_snap(_snap_anchor(), raw)
	# Road ends near the map edge snap onto it and become outside connections.
	var on_border := false
	if allow_network:
		for axis in [0, 2]:
			if absf(pos[axis]) > MAP_HALF_SIZE - BORDER_SNAP_DISTANCE:
				pos[axis] = signf(pos[axis]) * MAP_HALF_SIZE
				on_border = true
	var snap := _make_snap(pos, pos, -1, false)
	snap.border = on_border
	return snap


func _make_snap(pos: Vector3, anchor: Vector3, node: int, on_segment: bool) -> Dictionary:
	return {"pos": pos, "anchor": anchor, "node": node, "on_segment": on_segment, "lane_dir": Vector3.ZERO, "border": false}


## Moves the snap to a lane center if one is closer to the mouse than the road center.
func _snap_to_closest_lane(snap: Dictionary, raw: Vector3, lane_points: Array[Dictionary]) -> void:
	var best_d := _flat_distance(raw, snap.anchor)
	for lp in lane_points:
		var d := _flat_distance(raw, lp.pos)
		if d < best_d:
			best_d = d
			snap.pos = lp.pos
			snap.lane_dir = lp.dir


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


## True if a one-lane road leaving/arriving along `travel_dir` at a lane-snapped
## end runs against that lane's traffic.
static func _is_lane_mismatch(snap: Dictionary, travel_dir: Vector3) -> bool:
	var lane_dir: Vector3 = snap.lane_dir
	return lane_dir != Vector3.ZERO and travel_dir.dot(lane_dir) < -0.5


func _snap_anchor() -> Vector3:
	if mode == Mode.CURVED and _control != null:
		return _control
	return _start.pos


func _snap_reference() -> Vector3:
	if mode == Mode.CURVED and _control != null:
		return (_control as Vector3) - (_start.pos as Vector3)
	return _start_ref


## Soft-snaps the direction to 15° steps (relative to the previous road) and the length to 8 m steps.
func _grid_snap(anchor: Vector3, raw: Vector3) -> Vector3:
	var v := raw - anchor
	v.y = 0.0
	var length := v.length()
	if length < 0.01:
		return raw
	var ref := _snap_reference()
	if ref.length_squared() < 1e-6:
		ref = Vector3.RIGHT
	var ref_angle := atan2(ref.z, ref.x)
	var rel := wrapf(atan2(v.z, v.x) - ref_angle, -PI, PI)
	var step := deg_to_rad(ANGLE_STEP)
	var snapped_rel := roundf(rel / step) * step
	if absf(rel - snapped_rel) <= deg_to_rad(ANGLE_SNAP_TOLERANCE):
		rel = snapped_rel
	var snapped_len := roundf(length / LENGTH_STEP) * LENGTH_STEP
	if snapped_len > 0.0 and absf(length - snapped_len) <= LENGTH_SNAP_TOLERANCE:
		length = snapped_len
	var ang := ref_angle + rel
	return anchor + Vector3(cos(ang), 0.0, sin(ang)) * length


func _proposed_curve(end: Vector3) -> RoadCurve:
	var start: Vector3 = _start.pos
	if mode == Mode.CURVED and _control != null:
		return RoadCurve.quadratic(start, _control, end)
	if mode == Mode.FREEFORM and _start_tangent.length_squared() > 0.0001:
		return RoadCurve.arc(start, _start_tangent, end)
	return RoadCurve.straight(start, end)


## Returns "" if the road can be built, otherwise the reason it can't.
func _validate(curve: RoadCurve, end_snap: Dictionary) -> String:
	if curve.get_length() < MIN_ROAD_LENGTH:
		return "Too short"
	if _start.node >= 0 and _start.node == end_snap.node:
		return "Can't connect a node to itself"
	if rad_to_deg(curve.tangent(0.0).angle_to(curve.tangent(1.0))) > MAX_TURN_DEGREES:
		return "Curve too sharp"
	if _junction_angle(_start, curve.tangent(0.0)) < _min_angle_for(_start) \
			or _junction_angle(end_snap, -curve.tangent(1.0)) < _min_angle_for(end_snap):
		return "Angle to existing road too small"
	return ""


func _min_angle_for(snap: Dictionary) -> float:
	return MIN_LANE_BRANCH_ANGLE if (snap.lane_dir as Vector3) != Vector3.ZERO else MIN_JUNCTION_ANGLE


## Smallest angle between a new road leaving `snap` along `dir` and roads already there.
func _junction_angle(snap: Dictionary, dir: Vector3) -> float:
	if snap.node >= 0:
		return network.min_angle_at_node(snap.node, dir, (snap.pos as Vector3) - (snap.anchor as Vector3), road_type.width * 0.5)
	if snap.on_segment:
		var hit := network.find_segment_near(snap.anchor, 0.75)
		if not hit.is_empty():
			var tan := network.get_segment(hit.segment_id).curve.tangent(hit.t)
			return rad_to_deg(minf(dir.angle_to(tan), dir.angle_to(-tan)))
	return 180.0


func _segment_under_cursor() -> RoadNetwork.RoadSegment:
	var hit := network.find_segment_near(_cursor, 0.5, true)
	return null if hit.is_empty() else network.get_segment(hit.segment_id)


func _junction_under_cursor() -> int:
	return network.find_node_near(_cursor, JUNCTION_PICK_RADIUS)


func _lane_end_under_cursor() -> RoadNetwork.LaneEnd:
	var best: RoadNetwork.LaneEnd = null
	var best_d := LANE_PICK_RADIUS
	for e in network.get_lane_ends(_lane_node):
		var d := Vector2(e.position.x, e.position.z).distance_to(Vector2(_cursor.x, _cursor.z))
		if d < best_d:
			best_d = d
			best = e
	return best


# ---------------------------------------------------------------- visuals

func _update_cursor() -> void:
	var cam := get_viewport().get_camera_3d()
	_cursor_ok = false
	if cam == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))
	if hit == null:
		return
	var p: Vector3 = hit
	p.x = clampf(p.x, -MAP_HALF_SIZE, MAP_HALF_SIZE)
	p.z = clampf(p.z, -MAP_HALF_SIZE, MAP_HALF_SIZE)
	_cursor = p
	_cursor_ok = true


func _update_visuals() -> void:
	var im := _gizmo.mesh as ImmediateMesh
	im.clear_surfaces()
	_preview.visible = false
	_label.visible = false
	if not _cursor_ok or network == null:
		return
	var batch := TriBatch.new()
	match mode:
		Mode.STRAIGHT, Mode.CURVED, Mode.FREEFORM:
			_draw_drawing(batch)
		Mode.UPGRADE, Mode.BULLDOZE:
			_draw_segment_hover(batch)
		Mode.LANES:
			_draw_lanes(batch)
		Mode.NODE:
			_draw_node(batch)
	if not _label.visible:
		var hover := network.find_node_near(_cursor, NODE_SNAP_RADIUS)
		if hover >= 0 and network.has_lane_mismatch(hover):
			_show_label(MISMATCH_TEXT, COLOR_WARNING)
	batch.commit(im, _gizmo_material)


func _draw_drawing(batch: TriBatch) -> void:
	var placing_control := mode == Mode.CURVED and _has_start and _control == null
	_snap = _compute_snap(_cursor, not placing_control)
	var p: Vector3 = _snap.pos
	var snap_color := COLOR_GUIDE
	var lane_dir: Vector3 = _snap.lane_dir
	if lane_dir != Vector3.ZERO:
		snap_color = COLOR_SNAP_LANE
		batch.arrow(p + lane_dir * 2.4, lane_dir, 0.9, COLOR_SNAP_LANE)  # which way the lane flows
	elif _snap.node >= 0:
		snap_color = COLOR_SNAP_NODE
	elif _snap.on_segment:
		snap_color = COLOR_SNAP_SEGMENT
	elif _snap.border:
		snap_color = COLOR_SNAP_BORDER
	batch.ring(p, 1.6 if lane_dir == Vector3.ZERO else 1.2, 0.3, snap_color)
	if not _has_start:
		if _snap.border:
			_show_label("Outside connection", COLOR_SNAP_BORDER)
		return

	var start: Vector3 = _start.pos
	var curve := _proposed_curve(p)
	var error := "" if placing_control else _validate(curve, _snap)
	var length := curve.get_length()
	if length > 0.01:
		_preview.mesh = RoadMeshBuilder.build_strip(curve, 0.0, length, road_type.width, 0.08)
		_preview.material_override = _preview_material(error == "")
		_preview.visible = true
		if road_type.is_one_way():
			batch.arrows_along(curve.sample_points(maxi(2, ceili(length / 2.0)), 0.1), 6.0, 1.0, Color(1, 1, 1, 0.8))
	if mode == Mode.CURVED and _control != null:
		var c: Vector3 = _control
		batch.ribbon(PackedVector3Array([start, c, p]), 0.15, COLOR_GUIDE)
		batch.disc(c, 0.6, COLOR_GUIDE)

	var dir := p - (_snap_anchor() if placing_control or mode != Mode.CURVED else start)
	var ref := _snap_reference() if _snap_reference().length_squared() > 1e-6 else Vector3.RIGHT
	var angle := rad_to_deg(absf(wrapf(atan2(dir.z, dir.x) - atan2(ref.z, ref.x), -PI, PI)))
	var text := "%.0f m  ·  %.0f°" % [length, angle]
	var color := Color.WHITE
	if error != "":
		text += "\n" + error
	elif road_type.is_one_way() and (_is_lane_mismatch(_start, curve.tangent(0.0))
			or (not placing_control and _is_lane_mismatch(_snap, curve.tangent(1.0)))):
		text += "\n" + MISMATCH_TEXT
		color = COLOR_WARNING
	elif _snap.border and not placing_control:
		text += "\nOutside connection"
	_show_label(text, color)


func _draw_segment_hover(batch: TriBatch) -> void:
	var seg := _segment_under_cursor()
	if seg == null:
		return
	var length := seg.curve.get_length()
	_preview.mesh = RoadMeshBuilder.build_strip(seg.curve, 0.0, length, seg.type.width + 0.6, 0.09)
	_preview.material_override = _preview_material(mode == Mode.UPGRADE)
	_preview.visible = true
	var text := "Delete road"
	if mode == Mode.UPGRADE:
		if seg.type != road_type:
			text = "Change to %s" % road_type.display_name
		elif road_type.is_one_way():
			text = "Reverse direction"
		else:
			text = "Already a %s" % road_type.display_name.to_lower()
	if seg.type.is_one_way():
		batch.arrows_along(seg.curve.sample_points(maxi(2, ceili(length / 2.0)), 0.1), 6.0, 1.0, Color(1, 1, 1, 0.8))
	_show_label(text)


func _draw_lanes(batch: TriBatch) -> void:
	if _lane_node >= 0 and not network.nodes.has(_lane_node):
		_lane_node = -1
		_lane_selected = -1
	# Mark every node so junctions are easy to find.
	for node: RoadNetwork.RoadNode in network.nodes.values():
		if node.id != _lane_node:
			batch.disc(node.position, 1.0, Color(1, 1, 1, 0.35))
	if _lane_node < 0:
		var hover := _junction_under_cursor()
		if hover >= 0:
			batch.ring(network.get_node_data(hover).position, 3.0, 0.3, COLOR_GUIDE)
		return

	var ends := network.get_lane_ends(_lane_node)
	var by_key := {}
	for e in ends:
		by_key[e.key] = e
	var conns := network.get_connections(_lane_node)
	for in_key: int in conns:
		var selected := in_key == _lane_selected
		if _lane_selected >= 0 and not selected:
			continue
		for out_key: int in conns[in_key]:
			var curve := RoadNetwork.connection_curve(by_key[in_key], by_key[out_key])
			var pts := curve.sample_points(12, 0.1)
			batch.ribbon(pts, 0.25 if selected else 0.15, COLOR_CONNECTION_SELECTED if selected else COLOR_CONNECTION)
			batch.arrow(pts[pts.size() - 1], curve.tangent(1.0), 0.7, COLOR_CONNECTION_SELECTED if selected else COLOR_CONNECTION)
	var hovered := _lane_end_under_cursor()
	for e in ends:
		batch.disc(e.position, 0.9, COLOR_LANE_IN if e.incoming else COLOR_LANE_OUT)
		batch.arrow(e.position, e.direction, 0.6, Color(0, 0, 0, 0.8))
		if e.key == _lane_selected:
			batch.ring(e.position, 1.25, 0.25, Color.WHITE)
		elif e == hovered:
			batch.ring(e.position, 1.25, 0.2, Color(1, 1, 1, 0.6))
	if network.has_custom_connections(_lane_node):
		_show_label("Custom lane connections (R to reset)")


func _draw_node(batch: TriBatch) -> void:
	if selected_node >= 0 and not network.nodes.has(selected_node):
		select_node(-1)
	# Mark every junction; edited ones in blue.
	for node: RoadNetwork.RoadNode in network.nodes.values():
		if node.id != selected_node and node.segment_ids.size() >= 2:
			var edited := network.has_node_settings(node.id)
			batch.disc(node.position, 1.0, COLOR_EDITED_NODE if edited else Color(1, 1, 1, 0.35))
	if selected_node < 0:
		var hover := _junction_under_cursor()
		if hover >= 0 and network.get_node_data(hover).segment_ids.size() >= 2:
			batch.ring(network.get_node_data(hover).position, 3.0, 0.3, COLOR_GUIDE)
		return

	var up := Vector3.UP * HANDLE_Y
	var hovered := {} if not _drag.is_empty() else _handle_under_cursor(aligning)
	for info in network.node_end_info(selected_node):
		var left: Vector3 = info.left + up
		var right: Vector3 = info.right + up
		batch.ribbon(PackedVector3Array([left, right]), 0.18, Color(1, 1, 1, 0.8))
		var curb: Dictionary = info.curb
		if not curb.is_empty() and not aligning:
			var custom: bool = float(curb.radius) >= 0.0
			batch.disc((curb.mid as Vector3) + up, 0.55, COLOR_HANDLE_CURB if custom else COLOR_HANDLE_CURB * Color(1, 1, 1, 0.55))
		if not aligning:
			batch.disc((info.center as Vector3) + up, 0.8, COLOR_HANDLE_CENTER)
			batch.arrow((info.center as Vector3) + up + (info.out as Vector3) * 1.6, info.out, 0.5, COLOR_HANDLE_CENTER)
		var corner_size := 0.7 if aligning else 0.5
		batch.disc(left, corner_size, COLOR_HANDLE_CORNER)
		batch.disc(right, corner_size, COLOR_HANDLE_CORNER)
	if not _align_source.is_empty():
		batch.ring((_align_source.pos as Vector3) + up, 1.0, 0.25, COLOR_ALIGN)
	if not hovered.is_empty():
		batch.ring((hovered.pos as Vector3) + up, 1.0, 0.2, Color.WHITE)

	if aligning:
		_show_label("Align: pick the corner to move" if _align_source.is_empty() else "Align: pick the corner to move it onto", COLOR_ALIGN)
	elif not _drag.is_empty():
		var s := network.get_end_settings(selected_node, _drag.segment_id)
		match _drag.kind:
			"center":
				_show_label("Shift %+.2f m" % s.shift if Input.is_key_pressed(KEY_SHIFT) else "Offset %+.1f m" % s.offset)
			"corner":
				_show_label("Rotate %+.1f°  ·  Offset %+.1f m" % [s.rotate, s.offset])
			"curb":
				_show_label("Curb radius %.2f m" % s.radius)
	elif not hovered.is_empty():
		match hovered.kind:
			"center":
				_show_label("Drag: pull the road end back / forward  ·  Shift+drag: move it sideways")
			"corner":
				_show_label("Drag: angle the road end")
			"curb":
				_show_label("Drag: curb radius (wider turn)")


func _preview_material(ok: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = COLOR_OK if ok else COLOR_BAD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 5
	return m


func _show_label(text: String, color: Color = Color.WHITE) -> void:
	_label.text = text
	_label.add_theme_color_override("font_color", color)
	_label.position = get_viewport().get_mouse_position() + Vector2(18, 18)
	_label.visible = true
