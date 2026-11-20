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
