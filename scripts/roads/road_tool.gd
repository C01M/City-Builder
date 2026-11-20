class_name RoadTool
extends Node3D
## Mouse tools for the road network: drawing (straight / curved / freeform),
## upgrading or reversing, bulldozing, and editing lane connections.

signal hint_changed(text: String)

enum Mode { STRAIGHT, CURVED, FREEFORM, UPGRADE, LANES, BULLDOZE }

const MAP_HALF_SIZE := 1000.0
const NODE_SNAP_RADIUS := 5.0
const SEGMENT_SNAP_EXTRA := 1.0
const MIN_ROAD_LENGTH := 4.0
const MAX_TURN_DEGREES := 120.0
const MIN_JUNCTION_ANGLE := 25.0
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
const COLOR_LANE_IN := Color(1.0, 0.6, 0.1, 0.95)
const COLOR_LANE_OUT := Color(0.3, 0.95, 0.4, 0.95)
const COLOR_CONNECTION := Color(0.3, 0.85, 1.0, 0.35)
const COLOR_CONNECTION_SELECTED := Color(1.0, 1.0, 0.3, 0.95)

const HINTS := {
	Mode.STRAIGHT: "Left click: start / place road  ·  Right click: stop  ·  Hold Shift: no angle/length snapping",
	Mode.CURVED: "Click start, then the curve's control point, then the end  ·  Right click: stop",
	Mode.FREEFORM: "Click start, then click to lay smoothly connected curves  ·  Right click: stop",
	Mode.UPGRADE: "Left click a road: change it to the selected type (same one-way type: reverse)  ·  Right click: reverse one-way",
	Mode.LANES: "Click a junction, then an incoming lane (orange), then outgoing lanes (green) to toggle  ·  R: reset junction  ·  Right click: back",
	Mode.BULLDOZE: "Left click a road to delete it",
}

@export var network: RoadNetwork

var mode: Mode = Mode.STRAIGHT
var road_type: RoadType
var grid_snap: bool = true

# Drawing state. A snap is {pos: Vector3, node: int, on_segment: bool}.
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
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			_on_right_click()
		elif key.keycode == KEY_R and mode == Mode.LANES and _lane_node >= 0:
			network.reset_connections(_lane_node)


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


func _on_right_click() -> void:
	match mode:
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
	if not network.build_road(curve, road_type, _start.node, _snap.node, _start.on_segment, _snap.on_segment):
		return
	# Keep drawing from the end of the new road.
	var end_pos: Vector3 = _snap.pos
	var end_node := network.find_node_near(end_pos, 0.5)
	_start = {"pos": end_pos, "node": end_node, "on_segment": false}
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
		var hit := network.find_segment_near(_start.pos, 0.75)
		if not hit.is_empty():
			_start_ref = network.get_segment(hit.segment_id).curve.tangent(hit.t)


func _compute_snap(raw: Vector3, allow_network: bool) -> Dictionary:
	if allow_network:
		var nid := network.find_node_near(raw, NODE_SNAP_RADIUS)
		if nid >= 0:
			return {"pos": network.get_node_data(nid).position, "node": nid, "on_segment": false}
		var hit := network.find_segment_near(raw, SEGMENT_SNAP_EXTRA, true)
		if not hit.is_empty():
			return {"pos": hit.point, "node": -1, "on_segment": true}
	var pos := raw
	if _has_start and grid_snap and not Input.is_key_pressed(KEY_SHIFT):
		pos = _grid_snap(_snap_anchor(), raw)
	return {"pos": pos, "node": -1, "on_segment": false}


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
	if _junction_angle(_start, curve.tangent(0.0)) < MIN_JUNCTION_ANGLE \
			or _junction_angle(end_snap, -curve.tangent(1.0)) < MIN_JUNCTION_ANGLE:
		return "Angle to existing road too small"
	return ""


## Smallest angle between a new road leaving `snap` along `dir` and roads already there.
func _junction_angle(snap: Dictionary, dir: Vector3) -> float:
	if snap.node >= 0:
		return network.min_angle_at_node(snap.node, dir)
	if snap.on_segment:
		var hit := network.find_segment_near(snap.pos, 0.75)
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
	batch.commit(im, _gizmo_material)


func _draw_drawing(batch: TriBatch) -> void:
	var placing_control := mode == Mode.CURVED and _has_start and _control == null
	_snap = _compute_snap(_cursor, not placing_control)
	var p: Vector3 = _snap.pos
	var snap_color := COLOR_GUIDE
	if _snap.node >= 0:
		snap_color = COLOR_SNAP_NODE
	elif _snap.on_segment:
		snap_color = COLOR_SNAP_SEGMENT
	batch.ring(p, 1.6, 0.3, snap_color)
	if not _has_start:
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
	if error != "":
		text += "\n" + error
	_show_label(text)


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


func _preview_material(ok: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = COLOR_OK if ok else COLOR_BAD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 5
	return m


func _show_label(text: String) -> void:
	_label.text = text
	_label.position = get_viewport().get_mouse_position() + Vector2(18, 18)
	_label.visible = true
