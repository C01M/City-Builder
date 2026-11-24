extends SceneTree
## Headless tests for the road network. Run from the project folder:
##   godot --headless --path . -s res://tests/test_roads.gd
## Prints "ROAD TESTS: PASS" and exits 0 on success.

var _failures := 0
var _two: RoadType
var _one: RoadType


func _initialize() -> void:
	_two = RoadType.get_type(&"two_way")
	_one = RoadType.get_type(&"one_way")
	_test_crossing()
	_test_t_junction_and_lane_connections()
	_test_remove_and_reverse()
	_test_curved_crossing()
	_test_upgrade()
	_test_lane_snapping()
	_test_tight_exit()
	_test_slip_lanes()
	_test_lane_editing()
	_test_lane_edit_scope()
	_test_multi_lane_connections()
	_test_node_offset_rotate_shift()
	_test_curb_radius()
	_test_align_corner()
	_test_node_modes()
	_test_node_settings_survive_edits()
	print("ROAD TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		print("FAIL: " + msg)


func _new_net() -> RoadNetwork:
	var net := RoadNetwork.new()
	root.add_child(net)
	return net


func _outs(net: RoadNetwork, node_id: int, in_key: int) -> Array:
	return net.get_connections(node_id).get(in_key, [])


func _incoming_key(net: RoadNetwork, node_id: int, segment_id: int) -> int:
	for e in net.get_lane_ends(node_id):
		if e.incoming and e.segment_id == segment_id:
			return e.key
	return -1


func _outgoing_key(net: RoadNetwork, node_id: int, segment_id: int) -> int:
	for e in net.get_lane_ends(node_id):
		if not e.incoming and e.segment_id == segment_id:
			return e.key
	return -1


func _test_crossing() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3(50, 0, 0)), _two)
	_check(net.nodes.size() == 2 and net.segments.size() == 1, "single road: 2 nodes, 1 segment")
	var a := net.find_node_near(Vector3(-50, 0, 0), 0.1)
	var conns := net.get_connections(a)
	_check(conns.size() == 1, "dead end has 1 incoming lane")
	for k: int in conns:
		_check((conns[k] as Array).size() == 1, "dead end allows a U-turn")

	net.build_road(RoadCurve.straight(Vector3(0, 0, -50), Vector3(0, 0, 50)), _two)
	_check(net.nodes.size() == 5, "crossing: 5 nodes (got %d)" % net.nodes.size())
	_check(net.segments.size() == 4, "crossing: 4 segments (got %d)" % net.segments.size())
	var c := net.find_node_near(Vector3.ZERO, 0.5)
	_check(c >= 0, "junction node at the crossing")
	if c < 0:
		return
	var node := net.get_node_data(c)
	_check(node.segment_ids.size() == 4, "4 segments at the junction")
	var cc := net.get_connections(c)
	_check(cc.size() == 4, "4 incoming lanes at the junction")
	for k: int in cc:
		_check((cc[k] as Array).size() == 3, "each incoming lane connects to 3 outgoing lanes")
	_check(node.mesh_instance != null, "junction has a surface mesh")
	for sid in node.segment_ids:
		var seg := net.get_segment(sid)
		var trim := seg.trim_start if seg.start_id == c else seg.trim_end
		_check(is_equal_approx(trim, 5.0), "4-way trim is half width + margin (got %.2f)" % trim)
		_check(seg.mesh_instance != null, "segment has a mesh")
	net.free()


func _test_t_junction_and_lane_connections() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3(50, 0, 0)), _two)
	# One-way road from the north, ending on the middle of the two-way road.
	net.build_road(RoadCurve.straight(Vector3(20, 0, -40), Vector3(20, 0, 0)), _one, {}, {"on_segment": true})
	_check(net.nodes.size() == 4 and net.segments.size() == 3, "T junction: 4 nodes, 3 segments")
	var j := net.find_node_near(Vector3(20, 0, 0), 0.5)
	_check(j >= 0, "T junction node exists")
	if j < 0:
		return
	var ends := net.get_lane_ends(j)
	var incoming := ends.filter(func(e: RoadNetwork.LaneEnd) -> bool: return e.incoming).size()
	_check(incoming == 3 and ends.size() - incoming == 2, "T junction: 3 incoming, 2 outgoing lanes")

	var west := -1
	var oneway := -1
	for sid in net.get_node_data(j).segment_ids:
		var seg := net.get_segment(sid)
		if seg.type == _one:
			oneway = sid
		elif net.get_node_data(seg.start_id if seg.end_id == j else seg.end_id).position.x < 0:
			west = sid
	var in_key := _incoming_key(net, j, oneway)
	var west_out := _outgoing_key(net, j, west)
	_check(_outs(net, j, in_key).size() == 2, "one-way lane turns both ways by default")

	net.set_connection(j, in_key, west_out, false)
	_check(_outs(net, j, in_key).size() == 1, "lane connection removed")
	_check(not _outs(net, j, in_key).has(west_out), "removed connection is gone")

	# Crossing the west segment splits it; the custom connection must survive the split.
	net.build_road(RoadCurve.straight(Vector3(-20, 0, -30), Vector3(-20, 0, 30)), _two)
	var outs := _outs(net, j, in_key)
	_check(outs.size() == 1, "custom connection kept after the neighbor segment was split")
	var new_west := -1
	for sid in net.get_node_data(j).segment_ids:
		var seg := net.get_segment(sid)
		var other := seg.start_id if seg.end_id == j else seg.end_id
		if net.get_node_data(other).position.x < 0:
			new_west = sid
	_check(not outs.has(_outgoing_key(net, j, new_west)), "split segment's lane still excluded")

	net.reset_connections(j)
	_check(_outs(net, j, in_key).size() == 2, "reset restores default connections")
	net.free()


func _test_remove_and_reverse() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3(50, 0, 0)), _two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -40), Vector3(0, 0, 0)), _one, {}, {"on_segment": true})
	var j := net.find_node_near(Vector3.ZERO, 0.5)
	var oneway := -1
	for sid in net.get_node_data(j).segment_ids:
		if net.get_segment(sid).type == _one:
			oneway = sid
	_check(_incoming_key(net, j, oneway) >= 0, "one-way flows into the junction")
	net.reverse_segment(oneway)
	_check(_incoming_key(net, j, oneway) < 0 and _outgoing_key(net, j, oneway) >= 0, "reversed one-way flows out of the junction")

	net.remove_segment(oneway)
	_check(net.find_node_near(Vector3(0, 0, -40), 0.5) < 0, "removing a road deletes its unused end node")
	_check(net.get_node_data(j).segment_ids.size() == 2, "junction keeps the two remaining segments")
	_check(net.nodes.size() == 3, "3 nodes left (got %d)" % net.nodes.size())
	net.free()


func _test_curved_crossing() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-60, 0, 0), Vector3(60, 0, 0)), _two)
	# Dips below z = 0 in the middle, so it crosses the straight road twice.
	net.build_road(RoadCurve.quadratic(Vector3(-30, 0, 20), Vector3(0, 0, -40), Vector3(30, 0, 20)), _one)
	_check(net.nodes.size() == 6, "curve crossing twice: 6 nodes (got %d)" % net.nodes.size())
	_check(net.segments.size() == 6, "curve crossing twice: 6 segments (got %d)" % net.segments.size())
	var junctions := 0
	for node: RoadNetwork.RoadNode in net.nodes.values():
		if node.segment_ids.size() == 4:
			junctions += 1
			_check(node.mesh_instance != null, "curved junction has a mesh")
	_check(junctions == 2, "two 4-way junctions (got %d)" % junctions)
	net.free()


func _test_upgrade() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(0, 0, 0), Vector3(40, 0, 0)), _two)
	var sid: int = net.segments.keys()[0]
	net.set_segment_type(sid, _one)
	_check(net.get_segment(sid).type == _one, "segment upgraded to one-way")
	var end_node := net.get_segment(sid).end_id
	_check(net.get_connections(end_node).size() == 1, "one-way ends with one incoming lane")
	net.free()


func _test_lane_snapping() -> void:
	var net := _new_net()
	# Two-way road heading east, ending at the origin. Its eastbound lane is at z = +1.5.
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3.ZERO), _two)
	var n := net.find_node_near(Vector3.ZERO, 0.1)
	var two_way: int = net.get_node_data(n).segment_ids[0]
	_check(net.node_lane_points(n).size() == 2, "two-way end offers 2 lane snap points")
	var at_node := {"node": n, "anchor": Vector3.ZERO}

	# Divided road: one-way continuing the eastbound lane, one-way feeding the westbound lane.
	net.build_road(RoadCurve.straight(Vector3(0, 0, 1.5), Vector3(40, 0, 10)), _one, at_node)
	net.build_road(RoadCurve.straight(Vector3(40, 0, -10), Vector3(0, 0, -1.5)), _one, {}, at_node)
	_check(net.nodes.size() == 4, "lane-snapped roads share the existing node (got %d nodes)" % net.nodes.size())
	_check(net.get_node_data(n).segment_ids.size() == 3, "node has the two-way and both one-ways")
	_check(not net.has_lane_mismatch(n), "matching lane directions: no warning")
	_check(net.get_node_data(n).warning_icon == null, "no warning icon without a mismatch")

	var eastbound := -1
	for sid in net.get_node_data(n).segment_ids:
		var seg := net.get_segment(sid)
		if seg.type == _one and seg.start_id == n:
			eastbound = sid
			_check(seg.start_offset.distance_to(Vector3(0, 0, 1.5)) < 0.01, "one-way keeps its lane offset (got %s)" % seg.start_offset)
	var outs := _outs(net, n, _incoming_key(net, n, two_way))
	_check(outs.size() == 1 and RoadNetwork.key_segment(outs[0]) == eastbound,
		"eastbound lane continues only into the eastbound one-way")

	# Flip the eastbound one-way: it now runs against the lane it's attached to.
	net.reverse_segment(eastbound)
	_check(net.has_lane_mismatch(n), "reversed one-way on the lane: mismatch detected")
	_check(net.get_node_data(n).warning_icon != null, "mismatch shows a warning icon")
	net.reverse_segment(eastbound)
	_check(not net.has_lane_mismatch(n) and net.get_node_data(n).warning_icon == null, "fixing the direction clears the warning")

	# A one-way attached at the road's center never counts as a mismatch.
	var c := _new_net()
	c.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3.ZERO), _two)
	var cn := c.find_node_near(Vector3.ZERO, 0.1)
	c.build_road(RoadCurve.straight(Vector3(40, 0, 0), Vector3.ZERO), _one, {}, {"node": cn})
	_check(not c.has_lane_mismatch(cn), "center-attached one-way: no mismatch")
	_check(c.get_segment(c.get_node_data(cn).segment_ids[1]).end_offset == Vector3.ZERO, "center attach has no offset")
	net.free()
	c.free()


## A one-way leaving the right lane of a two-way at a small angle, with a short
## first segment (so its end can't be cut back to where the roads separate).
## The road surface must have no holes in the gore and pave no grass.
func _test_tight_exit() -> void:
	var exits := [[Vector3(4.5, 0, -6), Vector3(5.5, 0, -60), _one, Vector3(1.5, 0, 0)],
		[Vector3(6, 0, -14), Vector3(8, 0, -60), _one, Vector3(1.5, 0, 0)],
		[Vector3(5, 0, -8), Vector3(12, 0, -60), _two, Vector3.ZERO]]
	for ex: Array in exits:
		var net := _new_net()
		net.build_road(RoadCurve.straight(Vector3(0, 0, 60), Vector3(0, 0, -60)), _two)
		net.build_road(RoadCurve.straight(ex[3], ex[0]), ex[2], {"on_segment": true, "anchor": Vector3.ZERO})
		net.build_road(RoadCurve.straight(ex[0], ex[1]), ex[2], {"node": net.find_node_near(ex[0], 0.5)})
		var result := _surface_check(net)
		_check(result.x == 0, "tight exit to %s: no holes in the road surface (%d points)" % [ex[0], result.x])
		_check(result.y == 0, "tight exit to %s: junction paves no grass (%d points)" % [ex[0], result.y])
		# Traffic coming down the main road can't hairpin back into the exit.
		var n := net.find_node_near(Vector3.ZERO, 0.1)
		var north := -1
		var exit := -1
		for sid in net.get_node_data(n).segment_ids:
			var seg := net.get_segment(sid)
			if seg.type == ex[2] and seg.start_id == n and seg.end_id != net.find_node_near(Vector3(0, 0, -60), 0.5):
				exit = sid
			elif seg.start_id == n:
				north = sid
		var exit_lanes := _outs(net, n, _incoming_key(net, n, north)).filter(
			func(k: int) -> bool: return RoadNetwork.key_segment(k) == exit)
		_check(exit_lanes.is_empty(), "tight exit to %s: no hairpin from the main road into the exit" % ex[0])
		var south := -1
		for sid in net.get_node_data(n).segment_ids:
			if sid != north and sid != exit:
				south = sid
		var from_south := _outs(net, n, _incoming_key(net, n, south)).filter(
			func(k: int) -> bool: return RoadNetwork.key_segment(k) == exit)
		_check(not from_south.is_empty(), "tight exit to %s: traffic heading north can take the exit" % ex[0])
		net.free()
	# A road that bends back sharply at a node still connects.
	var bend := _new_net()
	bend.build_road(RoadCurve.straight(Vector3(-40, 0, 0), Vector3.ZERO), _two)
	var b := bend.find_node_near(Vector3.ZERO, 0.1)
	bend.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(-40, 0, 15)), _two, {"node": b})
	var first: int = bend.get_node_data(b).segment_ids[0]
	var second: int = bend.get_node_data(b).segment_ids[1]
	var outs := _outs(bend, b, _incoming_key(bend, b, first))
	_check(outs.size() == 1 and RoadNetwork.key_segment(outs[0]) == second, "sharp bend: lanes still continue around it")
	bend.free()


## Lane positions (z at x = 0) and directions of an east-west segment, left to right.
func _lanes_across(net: RoadNetwork, sid: int) -> Array:
	var seg := net.get_segment(sid)
	var result := []
	for i in seg.type.lanes.size():
		var pts := net.lane_points(sid, i)
		var mid := pts[pts.size() / 2]
		result.append([snappedf(mid.z, 0.01), seg.type.lanes[i].forward])
	return result


func _test_lane_editing() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3(50, 0, 0)), _two)
	var sid: int = net.segments.keys()[0]
	# Heading east, the right side is +z: westbound lane at z = -1.5, eastbound at +1.5.
	_check(_lanes_across(net, sid) == [[-1.5, false], [1.5, true]], "two-way lanes before editing")
	net.edit_lanes(sid, RoadNetwork.LaneEdit.ADD_RIGHT)
	_check(_lanes_across(net, sid) == [[-1.5, false], [1.5, true], [4.5, true]],
		"added lane on the right; the others stay put (got %s)" % [_lanes_across(net, sid)])
	_check(net.get_segment(sid).type.width == 9.0, "road is 9 m wide with 3 lanes")
	net.edit_lanes(sid, RoadNetwork.LaneEdit.ADD_LEFT)
	_check(_lanes_across(net, sid) == [[-4.5, false], [-1.5, false], [1.5, true], [4.5, true]],
		"added lane on the left (got %s)" % [_lanes_across(net, sid)])
	_check(net.get_segment(sid).type == RoadType.get_type(&"four_lane"), "2 + 2 lanes is the four-lane preset")
	net.edit_lanes(sid, RoadNetwork.LaneEdit.REVERSE, 1)
	_check(_lanes_across(net, sid) == [[-4.5, false], [-1.5, true], [1.5, true], [4.5, true]],
		"reversed the second lane (got %s)" % [_lanes_across(net, sid)])
	net.edit_lanes(sid, RoadNetwork.LaneEdit.REMOVE, 0)
	_check(_lanes_across(net, sid) == [[-1.5, true], [1.5, true], [4.5, true]],
		"removed the left lane; the others stay put (got %s)" % [_lanes_across(net, sid)])
	_check(net.get_segment(sid).type.is_one_way(), "three eastbound lanes make a one-way")
	net.edit_lanes(sid, RoadNetwork.LaneEdit.REMOVE, 1)
	_check(_lanes_across(net, sid) == [[0.0, true], [3.0, true]],
		"removing a middle lane closes the gap from both sides (got %s)" % [_lanes_across(net, sid)])
	net.edit_lanes(sid, RoadNetwork.LaneEdit.REMOVE, 0)
	_check(not net.edit_lanes(sid, RoadNetwork.LaneEdit.REMOVE, 0), "the last lane can't be removed")
	for i in RoadType.MAX_LANES - 1:
		net.edit_lanes(sid, RoadNetwork.LaneEdit.ADD_RIGHT)
	_check(not net.edit_lanes(sid, RoadNetwork.LaneEdit.ADD_RIGHT), "at most %d lanes" % RoadType.MAX_LANES)
	_check(RoadType.from_layout([true, false, true]) == RoadType.from_layout([true, false, true]), "one type per layout")
	net.free()


## Road: (-100) -- n1 (-40) -- crossing (30) -- (100) along x, the first piece drawn backwards.
func _test_lane_edit_scope() -> void:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-40, 0, 0), Vector3(-100, 0, 0)), _two)
	var n1 := net.find_node_near(Vector3(-40, 0, 0), 0.1)
	net.build_road(RoadCurve.straight(Vector3(-40, 0, 0), Vector3(100, 0, 0)), _two, {"node": n1})
	net.build_road(RoadCurve.straight(Vector3(30, 0, -60), Vector3(30, 0, 60)), _two)
	var west := _seg_at(net, Vector3(-70, 0, 0))
	var middle := _seg_at(net, Vector3(0, 0, 0))
	var east := _seg_at(net, Vector3(60, 0, 0))
	net.edit_lanes(middle, RoadNetwork.LaneEdit.ADD_RIGHT, 0, RoadNetwork.EditScope.ROAD)
	_check(net.get_segment(middle).type.lanes.size() == 3 and net.get_segment(west).type.lanes.size() == 3,
		"road scope: the lane is added up to the junction")
	_check(net.get_segment(east).type.lanes.size() == 2, "road scope: stops at the crossing")
	_check(net.get_segment(west).type.layout() == RoadType.reversed_layout(net.get_segment(middle).type.layout()),
		"a segment drawn the other way gets the mirrored layout")
	_check(_lanes_meet(net, n1), "lanes still meet at the node between the edited segments")
	net.edit_lanes(middle, RoadNetwork.LaneEdit.ADD_RIGHT, 0, RoadNetwork.EditScope.SEGMENT)
	_check(net.get_segment(middle).type.lanes.size() == 4 and net.get_segment(west).type.lanes.size() == 3,
		"segment scope: only the clicked segment")
	net.edit_lanes(east, RoadNetwork.LaneEdit.ADD_RIGHT, 0, RoadNetwork.EditScope.STREET)
	net.edit_lanes(middle, RoadNetwork.LaneEdit.REMOVE, 3, RoadNetwork.EditScope.SEGMENT)
	net.edit_lanes(middle, RoadNetwork.LaneEdit.REVERSE, 0, RoadNetwork.EditScope.STREET)
	_check(net.get_segment(east).type.layout() == [true, true, true] and net.get_segment(west).type.layout() == [false, false, false],
		"street scope: through the crossing and the node (east %s, west %s)" % [net.get_segment(east).type.layout(), net.get_segment(west).type.layout()])
	net.free()


## True if every lane end of one segment at the node has a lane end of the other at the same spot.
func _lanes_meet(net: RoadNetwork, node_id: int) -> bool:
	var ends := net.get_lane_ends(node_id)
	for a in ends:
		var found := false
		for b in ends:
			if b.segment_id != a.segment_id and a.position.distance_to(b.position) < 0.1 and a.incoming != b.incoming:
				found = true
		if not found:
			return false
	return true


func _test_multi_lane_connections() -> void:
	var four := RoadType.get_type(&"four_lane")
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-60, 0, 0), Vector3(60, 0, 0)), four)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -60), Vector3(0, 0, 60)), four)
	var c := net.find_node_near(Vector3.ZERO, 0.1)
	var west := _seg_at(net, Vector3(-30, 0, 0))
	var east := _seg_at(net, Vector3(30, 0, 0))
	var north := _seg_at(net, Vector3(0, 0, -30))
	var south := _seg_at(net, Vector3(0, 0, 30))
	# Eastbound lanes arriving from the west, right lane (z = 4.5) first.
	var lanes: Array = net.get_lane_ends(c).filter(func(e: RoadNetwork.LaneEnd) -> bool: return e.incoming and e.segment_id == west)
	lanes.sort_custom(func(a: RoadNetwork.LaneEnd, b: RoadNetwork.LaneEnd) -> bool: return a.position.z > b.position.z)
	var right_outs := _outs(net, c, lanes[0].key)
	var left_outs := _outs(net, c, lanes[1].key)
	var segs := func(outs: Array) -> Array:
		var s := []
		for k: int in outs:
			if not s.has(RoadNetwork.key_segment(k)):
				s.append(RoadNetwork.key_segment(k))
		s.sort()
		return s
	# Heading east, a right turn goes south (+z).
	var right_expected := [east, south]
	right_expected.sort()
	_check(segs.call(right_outs) == right_expected, "right lane: right turn and straight on (got %s)" % [segs.call(right_outs)])
	var left_expected := [east, north]
	left_expected.sort()
	_check(segs.call(left_outs) == left_expected, "left lane: straight on and left turn (got %s)" % [segs.call(left_outs)])
	var straight_right := right_outs.filter(func(k: int) -> bool: return RoadNetwork.key_segment(k) == east)
	var straight_left := left_outs.filter(func(k: int) -> bool: return RoadNetwork.key_segment(k) == east)
	_check(straight_right.size() == 1 and straight_left.size() == 1 and straight_right[0] != straight_left[0],
		"straight on, each lane keeps to its own lane")
	_check(net.get_lane_ends(c).filter(func(e: RoadNetwork.LaneEnd) -> bool: return e.key == straight_right[0])[0].position.z > 2.0,
		"the right lane continues in the right lane")
	net.free()


## Corner slip lanes: road V runs north into a corner, road H east out of it. A
## one-way leaves V's northbound lane(s) tangentially and joins H's eastbound
## lane(s) tangentially, cutting the corner. With `wide`, both roads have four
## lanes and the slip road two.
func _test_slip_lanes() -> void:
	for wide: bool in [false, true]:
		var road := RoadType.get_type(&"four_lane") if wide else _two
		var slip := RoadType.get_type(&"one_way_2") if wide else _one
		var lateral := 3.0 if wide else 1.5  # center of the lanes the slip road uses
		var name := "wide slip" if wide else "slip lane"
		var net := _new_net()
		net.build_road(RoadCurve.straight(Vector3(0, 0, 100), Vector3.ZERO), road)
		var corner := net.find_node_near(Vector3.ZERO, 0.1)
		net.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(100, 0, 0)), road, {"node": corner})
		var v_in := _seg_at(net, Vector3(0, 0, 70))
		var points := net.segment_lane_points(v_in, 0.6, slip.lanes.size())
		_check(points.size() == 2, "%s: the road offers 2 snap spots for it (got %d)" % [name, points.size()])
		var built := net.build_road(RoadCurve.quadratic(Vector3(lateral, 0, 40), Vector3(lateral, 0, lateral), Vector3(40, 0, lateral)), slip,
			{"on_segment": true, "anchor": Vector3(0, 0, 40)}, {"on_segment": true, "anchor": Vector3(40, 0, 0)})
		_check(built and net.segments.size() == 5, "%s: built, splitting both roads" % name)
		for node: RoadNetwork.RoadNode in net.nodes.values():
			if node.segment_ids.size() >= 2:
				_check(node.mesh_instance != null, "%s: node at %s has a junction surface" % [name, node.position])
			_check(not node.lane_mismatch, "%s: no lane mismatch at %s" % [name, node.position])
		# The slip road and both its junctions; not the V/H corner itself, whose
		# outer corner is cut diagonally like every two-road corner.
		var result := _surface_check(net, Rect2(-8, 8, 56, 40)) + _surface_check(net, Rect2(8, -8, 40, 16))
		_check(result.x == 0, "%s: no holes in the road surface (%d points)" % [name, result.x])
		_check(result.y == 0, "%s: junctions pave no grass (%d points)" % [name, result.y])
		# Where it leaves: V's right lane(s) go on along V and into the slip road.
		var diverge := net.find_node_near(Vector3(0, 0, 40), 0.5)
		var slip_id := -1
		for sid in net.get_node_data(diverge).segment_ids:
			if net.get_segment(sid).type == slip:
				slip_id = sid
		var lanes_in: Array = net.get_lane_ends(diverge).filter(func(e: RoadNetwork.LaneEnd) -> bool:
			return e.incoming and e.segment_id != slip_id)
		lanes_in.sort_custom(func(a: RoadNetwork.LaneEnd, b: RoadNetwork.LaneEnd) -> bool: return a.position.x > b.position.x)
		var right_outs := _outs(net, diverge, lanes_in[0].key)
		_check(right_outs.any(func(k: int) -> bool: return RoadNetwork.key_segment(k) == slip_id),
			"%s: the right lane can take the slip road" % name)
		if wide:
			var left_outs := _outs(net, diverge, lanes_in[1].key)
			_check(not left_outs.any(func(k: int) -> bool: return RoadNetwork.key_segment(k) == slip_id),
				"%s: the left lane goes straight on (got %s)" % [name, left_outs])
		# Where it joins: every slip lane merges into H.
		var merge := net.find_node_near(Vector3(40, 0, 0), 0.5)
		for e in net.get_lane_ends(merge):
			if e.incoming and e.segment_id == slip_id:
				_check(_outs(net, merge, e.key).size() == 1, "%s: each slip lane merges into one lane of H" % name)
		net.free()


## Vector2i(road points no mesh covers, junction points off every road), on a
## 0.25 m grid around the origin.
func _surface_check(net: RoadNetwork, area := Rect2(-10, -30, 30, 40)) -> Vector2i:
	var polys: Array[PackedVector2Array] = []
	for node: RoadNetwork.RoadNode in net.nodes.values():
		if node.segment_ids.size() >= 2:
			polys.append(net._junction_shape(node).poly)
	var holes := 0
	var grass := 0
	for ix in range(int(area.position.x * 4.0), int(area.end.x * 4.0) + 1):
		for iz in range(int(area.position.y * 4.0), int(area.end.y * 4.0) + 1):
			var p := Vector3(ix * 0.25, 0, iz * 0.25)
			var road := false
			var near_road := false
			var covered := false
			for seg: RoadNetwork.RoadSegment in net.segments.values():
				var t := seg.curve.closest_t(p)
				var q := seg.curve.point(t)
				var lat := Vector2(p.x - q.x, p.z - q.z).length()
				var half := seg.type.width * 0.5
				near_road = near_road or lat < half + 0.3
				if t <= 0.001 or t >= 0.999:
					continue
				var d := seg.curve.distance_at_t(t)
				road = road or lat < half - 0.15
				if lat < half + 0.05 and d >= seg.trim_start - 0.1 and d <= seg.curve.get_length() - seg.trim_end + 0.1:
					covered = true
			var in_poly := false
			for poly in polys:
				in_poly = in_poly or Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), poly)
			if in_poly and not near_road:
				grass += 1
			if road and not covered and not in_poly:
				holes += 1
	return Vector2i(holes, grass)


# ---------------------------------------------------------------- node controller

## A 4-way crossing of two-way roads at the origin; returns [net, center node].
func _new_crossing() -> Array:
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3(50, 0, 0)), _two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -50), Vector3(0, 0, 50)), _two)
	return [net, net.find_node_near(Vector3.ZERO, 0.5)]


## Segment at `node_id` whose road leaves the node roughly along `dir`.
func _end_toward(net: RoadNetwork, node_id: int, dir: Vector3) -> int:
	for sid in net.get_node_data(node_id).segment_ids:
		if net.outward_direction(node_id, sid).dot(dir) > 0.9:
			return sid
	return -1


func _trim(net: RoadNetwork, node_id: int, sid: int) -> float:
	var seg := net.get_segment(sid)
	return seg.trim_start if seg.start_id == node_id else seg.trim_end


func _info(net: RoadNetwork, node_id: int, sid: int) -> Dictionary:
	for info in net.node_end_info(node_id):
		if info.segment_id == sid:
			return info
	return {}


func _lane_ends_of(net: RoadNetwork, node_id: int, sid: int) -> Array[RoadNetwork.LaneEnd]:
	var result: Array[RoadNetwork.LaneEnd] = []
	for e in net.get_lane_ends(node_id):
		if e.segment_id == sid:
			result.append(e)
	return result


func _lane_zs(net: RoadNetwork, node_id: int, sid: int) -> Array[float]:
	var zs: Array[float] = []
	for e in _lane_ends_of(net, node_id, sid):
		zs.append(e.position.z)
	zs.sort()
	return zs


func _test_node_offset_rotate_shift() -> void:
	var setup := _new_crossing()
	var net: RoadNetwork = setup[0]
	var c: int = setup[1]
	var east := _end_toward(net, c, Vector3.RIGHT)
	var north := _end_toward(net, c, Vector3.FORWARD)
	var auto_trim := _trim(net, c, east)
	_check(net.node_end_info(c).size() == 4, "node controller: 4 road ends listed")
	_check(not net.has_node_settings(c), "fresh junction has no settings")

	# Offset pulls the road end back; the lanes end there too.
	var s := net.get_end_settings(c, east)
	s.offset = 5.0
	net.set_end_settings(c, east, s)
	_check(is_equal_approx(_trim(net, c, east), auto_trim + 5.0), "offset adds to the trim (got %.2f)" % _trim(net, c, east))
	_check(is_equal_approx(_trim(net, c, north), auto_trim), "other ends keep their trim")
	for e in _lane_ends_of(net, c, east):
		_check(absf(e.position.x - (auto_trim + 5.0)) < 0.05, "lane ends follow the offset (x = %.2f)" % e.position.x)
	_check(net.has_node_settings(c), "edited junction reports settings")

	# Rotate slants the end edge: the right corner (+z for a road heading east) moves back.
	s.rotate = 20.0
	net.set_end_settings(c, east, s)
	var info := _info(net, c, east)
	var spread := (info.right as Vector3).x - (info.left as Vector3).x
	_check(absf(spread - 2.0 * 3.0 * tan(deg_to_rad(20.0))) < 0.05, "rotated end: corners differ by 2 half tan(angle) (got %.2f)" % spread)
	var ends := _lane_ends_of(net, c, east)
	_check(ends.size() == 2 and absf(ends[0].position.x - ends[1].position.x) > 0.5, "lanes end along the slanted edge")

	# Shift moves the road end sideways.
	s.rotate = 0.0
	s.shift = 1.5
	net.set_end_settings(c, east, s)
	var seg := net.get_segment(east)
	_check(seg.offset_at(c).distance_to(Vector3(0, 0, 1.5)) < 0.01, "shift moves the end to the right (offset %s)" % seg.offset_at(c))
	# The road bends toward its shifted end, so near the junction it's shifted by a bit less.
	var zs := _lane_zs(net, c, east)
	_check(zs.size() == 2 and (zs[0] + zs[1]) * 0.5 > 1.2 and absf((zs[1] - zs[0]) - 3.0) < 0.1, "shifted lanes move sideways (z = %s)" % [zs])

	# Stretch widens the end; lanes spread with it.
	s.shift = 0.0
	s.stretch = 0.5
	net.set_end_settings(c, east, s)
	zs = _lane_zs(net, c, east)
	_check(zs.size() == 2 and absf((zs[1] - zs[0]) - 4.5) < 0.1, "stretched end: lanes 1.5x apart (got %.2f)" % (zs[1] - zs[0]))
	_check(net.get_segment(east).offset_at(c).length() < 0.01, "shift back to 0 restores the attachment")

	net.reset_node(c)
	_check(not net.has_node_settings(c), "reset clears all settings")
	_check(is_equal_approx(_trim(net, c, east), auto_trim), "reset restores the automatic trim")
	net.free()


func _test_curb_radius() -> void:
	var setup := _new_crossing()
	var net: RoadNetwork = setup[0]
	var c: int = setup[1]
	var area_before := absf(RoadNetwork._polygon_area(net._junction_shape(net.get_node_data(c)).poly))
	# Every corner gets a 10 m curb: at 90 degrees the curb needs 10 m along each
	# edge beyond where the edges meet (3 m out), so every road end moves to 13 m.
	for info in net.node_end_info(c):
		var s: RoadNetwork.EndSettings = info.settings
		s.radius = 10.0
		net.set_end_settings(c, info.segment_id, s)
	for sid in net.get_node_data(c).segment_ids:
		_check(absf(_trim(net, c, sid) - 13.0) < 0.05, "10 m curb pushes the road end to 13 m (got %.2f)" % _trim(net, c, sid))
	var area_after := absf(RoadNetwork._polygon_area(net._junction_shape(net.get_node_data(c)).poly))
	_check(area_after > area_before * 3.0, "bigger curbs make a bigger junction (%.0f -> %.0f m2)" % [area_before, area_after])
	for info in net.node_end_info(c):
		var curb: Dictionary = info.curb
		_check(not curb.is_empty(), "each corner has a curb")
		if not curb.is_empty():
			# The curb's middle is radius * (1/sin 45 - 1) from the corner.
			var d := (curb.mid as Vector3).distance_to(curb.x)
			_check(absf(d - 10.0 * (sqrt(2.0) - 1.0)) < 0.1, "curb is a 10 m arc (middle %.2f m from corner)" % d)
	var east := _end_toward(net, c, Vector3.RIGHT)
	var in_key := _incoming_key(net, c, east)
	_check(in_key >= 0 and _outs(net, c, in_key).size() == 3, "connections still exist with custom curbs")
	net.free()


func _test_align_corner() -> void:
	var setup := _new_crossing()
	var net: RoadNetwork = setup[0]
	var c: int = setup[1]
	var east := _end_toward(net, c, Vector3.RIGHT)
	var north := _end_toward(net, c, Vector3.FORWARD)
	# Move the east end's right corner 3 m further out and 1 m to the right.
	var before := _info(net, c, east)
	var target: Vector3 = (before.right as Vector3) + Vector3(3, 0, 1)
	var left_x: float = (before.left as Vector3).x
	net.align_corner(c, east, 1, target)
	var after := _info(net, c, east)
	var miss := (after.right as Vector3).distance_to(target)
	_check(miss < 0.05, "aligned corner reaches the target (off by %.3f)" % miss)
	_check(absf((after.left as Vector3).x - left_x) < 0.05, "the other corner keeps its distance")
	_check((after.settings as RoadNetwork.EndSettings).shift > 0.5, "align shifted the end sideways")

	# Corner to corner: close the curb between the north road (heading -z) and the
	# east road by moving north's right corner (+x side) onto east's left corner (-z side).
	net.reset_node(c)
	var east_left: Vector3 = _info(net, c, east).left
	net.align_corner(c, north, 1, east_left, east, -1)
	miss = (_info(net, c, north).right as Vector3).distance_to(_info(net, c, east).left)
	_check(miss < 0.05, "corners meet after aligning (off by %.3f)" % miss)
	var drift := (_info(net, c, east).left as Vector3).distance_to(east_left)
	_check(drift < 0.05, "the target corner stays where it was (moved %.3f)" % drift)
	net.free()


func _test_node_modes() -> void:
	# A bend: two roads meeting at (0, 0) at 30 degrees.
	var net := _new_net()
	net.build_road(RoadCurve.straight(Vector3(-50, 0, 0), Vector3.ZERO), _two)
	var b := net.find_node_near(Vector3.ZERO, 0.1)
	net.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(43.3, 0, 25)), _two, {"node": b})
	_check(net.get_node_data(b).segment_ids.size() == 2, "bend node joins two roads")
	net.set_node_mode(b, RoadNetwork.NodeMode.MIDDLE)
	for sid in net.get_node_data(b).segment_ids:
		_check(_trim(net, b, sid) == 0.0, "middle node: roads meet without trimming")
	_check(net.get_node_data(b).mesh_instance == null, "middle node has no junction surface")
	net.set_node_mode(b, RoadNetwork.NodeMode.STRETCH)
	for sid in net.get_node_data(b).segment_ids:
		_check(_trim(net, b, sid) >= RoadNetwork.STRETCH_NODE_LENGTH - 0.01, "stretch node: long transition (%.1f m)" % _trim(net, b, sid))
	# A third road turns MIDDLE back into a normal junction.
	net.set_node_mode(b, RoadNetwork.NodeMode.MIDDLE)
	net.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(0, 0, -40)), _two, {"node": b})
	_check(net.effective_mode(b) == RoadNetwork.NodeMode.AUTO, "middle needs exactly two roads")
	_check(net.get_node_data(b).mesh_instance != null, "3 roads: junction surface is back")
	net.free()

	# U-turn mode: every incoming lane may also turn back.
	var setup := _new_crossing()
	var x: RoadNetwork = setup[0]
	var c: int = setup[1]
	x.set_node_mode(c, RoadNetwork.NodeMode.UTURN)
	var conns := x.get_connections(c)
	for k: int in conns:
		_check((conns[k] as Array).size() == 4, "u-turn node: 4 exits per incoming lane")
	x.free()


func _test_node_settings_survive_edits() -> void:
	var setup := _new_crossing()
	var net: RoadNetwork = setup[0]
	var c: int = setup[1]
	var east := _end_toward(net, c, Vector3.RIGHT)
	var s := net.get_end_settings(c, east)
	s.offset = 4.0
	s.radius = 8.0
	net.set_end_settings(c, east, s)
	# The far end of the east road (dead end at x = 50) gets a shift too.
	var far := net.find_node_near(Vector3(50, 0, 0), 0.5)
	var fs := net.get_end_settings(far, east)
	fs.shift = 0.5
	net.set_end_settings(far, east, fs)
	far = net.find_node_near(Vector3(50, 0, 0), 0.5)

	# Split the east road with a crossing street at x = 25.
	net.build_road(RoadCurve.straight(Vector3(25, 0, -30), Vector3(25, 0, 30)), _two)
	var near_east := _end_toward(net, c, Vector3.RIGHT)
	var kept := net.get_end_settings(c, near_east)
	_check(kept.offset == 4.0 and kept.radius == 8.0, "split keeps the settings at the junction")
	var far_seg: int = net.get_node_data(far).segment_ids[0]
	_check(net.get_end_settings(far, far_seg).shift == 0.5, "split keeps the settings at the far end")
	var mid := net.find_node_near(Vector3(25, 0, 0), 0.5)
	_check(mid >= 0 and not net.has_node_settings(mid), "the new junction starts automatic")

	# Adding a road keeps the existing ends' settings.
	net.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(-30, 0, -30)), _two, {"node": c})
	_check(net.get_end_settings(c, _end_toward(net, c, Vector3.RIGHT)).offset == 4.0, "adding a road keeps settings")

	# Changing the type keeps them; reversing a one-way keeps them at the same node.
	net.set_segment_type(near_east, _one)
	_check(net.get_end_settings(c, near_east).offset == 4.0, "type change keeps settings")
	net.reverse_segment(near_east)
	_check(net.get_end_settings(c, near_east).offset == 4.0, "reverse keeps settings at the same node")
	var shifted := net.get_end_settings(c, near_east)
	shifted.shift = 1.0
	net.set_end_settings(c, near_east, shifted)
	net.set_segment_type(near_east, _two)
	var expected := net.outward_direction(c, near_east).cross(Vector3.UP).normalized()
	_check(net.get_segment(near_east).offset_at(c).distance_to(expected) < 0.01, "upgrade to two-way keeps the shift")

	# Copy / paste onto another junction, matched by order around the node.
	var copied := net.copy_node_settings(c)
	net.paste_node_settings(mid, copied)
	var count := 0
	for sid in net.get_node_data(mid).segment_ids:
		if net.get_end_settings(mid, sid).offset == 4.0:
			count += 1
	_check(count == 1, "paste applies the edited end's settings (%d ends)" % count)

	# Removing the edited road drops its settings with it; the junction keeps working.
	net.remove_segment(near_east)
	_check(net.get_node_data(c).segment_ids.size() == 4, "road removed")
	_check(net.get_node_data(c).mesh_instance != null, "junction still has a surface")
	net.free()


func _seg_at(net: RoadNetwork, pos: Vector3) -> int:
	return net.find_segment_near(pos, 1.0).get("segment_id", -1)
