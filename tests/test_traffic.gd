extends SceneTree
## Headless traffic simulation tests. Run from the project folder:
##   godot --headless --path . -s res://tests/test_traffic.gd
## Uses a 400 m map (half size 200) so trips are short.

const DT := 1.0 / 30.0
const HALF := 200.0
## A car whose front is this far past the stop line is inside the junction.
const CAR_INSIDE := 5.0

var _failures := 0
var _two: RoadType
var _one: RoadType


func _initialize() -> void:
	_two = RoadType.get_type(&"two_way")
	_one = RoadType.get_type(&"one_way")
	_test_straight_road()
	_test_crossing()
	_test_edited_crossing()
	_test_multi_lane()
	_test_lane_changes()
	_test_overtaking()
	_test_traffic_lights()
	_test_bend_slows_cars()
	_test_one_way()
	_test_network_change_while_driving()
	print("TRAFFIC TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		print("FAIL: " + msg)


func _setup(rate: float) -> Array:
	var net := RoadNetwork.new()
	root.add_child(net)
	var traffic := TrafficManager.new()
	traffic.network = net
	traffic.map_half_size = HALF
	traffic.spawn_rate = rate
	traffic.rng.seed = 12345
	root.add_child(traffic)
	return [net, traffic]


## Runs the simulation, tracking limits and checking for overlapping cars.
func _run(traffic: TrafficManager, seconds: float, stats: Dictionary = {}) -> Dictionary:
	for key in ["max_speed", "max_accel", "min_accel", "overlaps", "max_cars", "inside_waits"]:
		if not stats.has(key):
			stats[key] = 0.0
	for i in int(seconds / DT):
		traffic.step(DT)
		stats.max_cars = maxf(stats.max_cars, traffic.cars.size())
		for car in traffic.cars:
			stats.max_speed = maxf(stats.max_speed, car.v)
			stats.max_accel = maxf(stats.max_accel, car.accel)
			stats.min_accel = minf(stats.min_accel, car.accel)
			# Stopped well inside a junction, waiting for crossing traffic.
			if car.v < 0.3 and car.s > CAR_INSIDE and traffic.graph.pieces[car.route[car.index]].is_connection:
				stats.inside_waits += 1
		if i % 3 == 0:
			stats.overlaps += _count_overlaps(traffic)
	return stats


func _count_overlaps(traffic: TrafficManager) -> int:
	var poses: Array[Transform3D] = []
	for car in traffic.cars:
		poses.append(traffic.car_pose(car))
	var count := 0
	for i in poses.size():
		for j in range(i + 1, poses.size()):
			if _obb_overlap(poses[i], poses[j]):
				count += 1
	return count


## Separating-axis test on the cars' footprints (shrunk by 5 cm per side).
static func _obb_overlap(a: Transform3D, b: Transform3D) -> bool:
	var ca := Vector2(a.origin.x, a.origin.z)
	var cb := Vector2(b.origin.x, b.origin.z)
	if ca.distance_to(cb) > 6.0:
		return false
	var half := Vector2(TrafficManager.CAR_WIDTH * 0.5 - 0.05, TrafficManager.CAR_LENGTH * 0.5 - 0.05)
	var fa := Vector2(a.basis.z.x, a.basis.z.z).normalized()
	var fb := Vector2(b.basis.z.x, b.basis.z.z).normalized()
	var axes := [fa, Vector2(-fa.y, fa.x), fb, Vector2(-fb.y, fb.x)]
	for axis: Vector2 in axes:
		var ra := absf(fa.dot(axis)) * half.y + absf(Vector2(-fa.y, fa.x).dot(axis)) * half.x
		var rb := absf(fb.dot(axis)) * half.y + absf(Vector2(-fb.y, fb.x).dot(axis)) * half.x
		if absf((cb - ca).dot(axis)) > ra + rb:
			return false
	return true


func _check_limits(stats: Dictionary, name: String) -> void:
	_check(stats.overlaps == 0, "%s: no cars overlap (got %d)" % [name, stats.overlaps])
	_check(stats.max_speed <= TrafficManager.MAX_SPEED + 0.01, "%s: speed limit respected (max %.1f m/s)" % [name, stats.max_speed])
	_check(stats.max_accel <= TrafficManager.MAX_ACCEL + 0.01, "%s: acceleration within limits (max %.1f)" % [name, stats.max_accel])
	_check(stats.min_accel >= -10.0, "%s: no emergency braking (min %.1f m/s²)" % [name, stats.min_accel])


func _test_straight_road() -> void:
	var setup := _setup(20.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _two)
	var stats := _run(traffic, 120.0)
	_check(traffic.graph.outside_nodes.size() == 2, "straight: 2 outside connections")
	_check(traffic.completed_trips >= 20, "straight: cars complete trips (got %d)" % traffic.completed_trips)
	_check(stats.max_speed > TrafficManager.MAX_SPEED - 1.0, "straight: cars reach ~70 km/h (max %.1f m/s)" % stats.max_speed)
	_check_limits(stats, "straight")
	net.free()
	traffic.free()


func _test_crossing() -> void:
	# 4 entries × 5 cars/min = 20 cars/min, within what an unsignalized 4-way carries.
	var setup := _setup(5.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	var stats := _run(traffic, 300.0)
	_check(traffic.graph.outside_nodes.size() == 4, "crossing: 4 outside connections")
	var conflicted := 0
	for p in traffic.graph.pieces:
		if p.is_connection and not p.conflicts.is_empty():
			conflicted += 1
	_check(conflicted == 12, "crossing: all 12 junction paths have conflicts (got %d)" % conflicted)
	_check(traffic.completed_trips >= 70, "crossing: traffic flows through the junction (%d trips)" % traffic.completed_trips)
	_check(traffic.cars.size() < 40, "crossing: queues stay short (%d cars left)" % traffic.cars.size())
	_check_limits(stats, "crossing")
	net.free()
	traffic.free()


## A crossing shaped with the Node Controller: wide curbs, one slanted and one
## shifted road end. Cars must still flow, follow the new lane ends and not collide.
func _test_edited_crossing() -> void:
	var setup := _setup(5.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	var c := net.find_node_near(Vector3.ZERO, 0.5)
	var turn_lengths := {}
	traffic.step(DT)
	for p in traffic.graph.pieces:
		if p.is_connection and p.node_id == c:
			turn_lengths[[p.in_key, p.out_key]] = p.length
	for info in net.node_end_info(c):
		var s: RoadNetwork.EndSettings = info.settings
		s.radius = 12.0
		if (info.out as Vector3).x > 0.9:
			s.rotate = 15.0
		elif (info.out as Vector3).z > 0.9:
			s.shift = 1.0
		net.set_end_settings(c, info.segment_id, s)
	var stats := _run(traffic, 200.0)
	var longer := 0
	var total := 0
	for p in traffic.graph.pieces:
		if p.is_connection and p.node_id == c and turn_lengths.has([p.in_key, p.out_key]):
			total += 1
			if p.length > turn_lengths[[p.in_key, p.out_key]] + 1.0:
				longer += 1
	_check(total == 12 and longer == 12, "edited crossing: wider curbs lengthen all 12 paths (%d of %d)" % [longer, total])
	_check(traffic.completed_trips >= 40, "edited crossing: traffic flows (%d trips)" % traffic.completed_trips)
	_check(stats.inside_waits > 0, "edited crossing: cars pull into the junction to wait for crossing traffic")
	_check_limits(stats, "edited crossing")
	net.free()
	traffic.free()


## A four-lane road crossing a two-way road; its east piece gets a third
## eastbound lane.
func _test_multi_lane() -> void:
	var setup := _setup(5.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), RoadType.get_type(&"four_lane"))
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	var east: int = net.find_segment_near(Vector3(100, 0, 0), 1.0).segment_id
	net.edit_lanes(east, RoadNetwork.LaneEdit.ADD_RIGHT)
	var stats := _run(traffic, 200.0)
	_check(traffic.completed_trips >= 60, "multi-lane: traffic flows (%d trips)" % traffic.completed_trips)
	var used_lanes := {}
	for p in traffic.graph.pieces:
		if not p.is_connection and RoadNetwork.key_segment(p.lane_key) == east:
			used_lanes[p.lane_key] = true
	_check(used_lanes.size() == 5, "multi-lane: the widened piece has 5 lanes in the traffic graph")
	_check_limits(stats, "multi-lane")
	net.free()
	traffic.free()


## A four-lane road (2 + 2) crossing a two-way road. The right lane of each
## approach can't turn left and the left lane can't turn right, so cars that
## spawn in the wrong lane for their destination must change lanes first.
func _test_lane_changes() -> void:
	var setup := _setup(6.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), RoadType.get_type(&"four_lane"))
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	traffic.step(DT)
	var g := traffic.graph
	# Destinations each entry lane reaches without changing lanes.
	var direct := {}
	var multi_entries := 0
	for node_id in g.outside_nodes:
		for entry: int in g.entry_pieces[node_id]:
			if not g.pieces[entry].beside.is_empty():
				multi_entries += 1
			var seen := {entry: true}
			var todo: Array[int] = [entry]
			var dests := {}
			while not todo.is_empty():
				var p := g.pieces[todo.pop_back()]
				if not p.is_connection and g.exit_pieces.has(p.node_id):
					dests[p.node_id] = true
				for nx in p.next:
					if not seen.has(nx):
						seen[nx] = true
						todo.append(nx)
			direct[entry] = dests
	_check(multi_entries == 4, "lane changes: 4 entry lanes have a lane beside them (got %d)" % multi_entries)
	var unreachable := 0
	for entry: int in direct:
		unreachable += g.outside_nodes.size() - 1 - (direct[entry] as Dictionary).size()
	_check(unreachable > 0, "lane changes: some destinations need a lane change")
	# Follow every car from its spawn lane to where it leaves the map.
	var trips := {}  # car id -> [spawn piece, dest node]
	var needed_change := 0
	var stats := {}
	for i in int(240.0 / DT):
		var present := {}
		for car in traffic.cars:
			present[car.id] = true
			if not trips.has(car.id):
				trips[car.id] = [car.route[0], car.dest_node]
			trips[car.id][1] = car.dest_node
		_run(traffic, DT, stats)
		var still := {}
		for car in traffic.cars:
			still[car.id] = true
		for id: int in present:
			if not still.has(id):
				var t: Array = trips[id]
				if not (direct[t[0]] as Dictionary).has(t[1]):
					needed_change += 1
	_check(traffic.lane_changes > 0, "lane changes: cars change lanes (%d)" % traffic.lane_changes)
	_check(needed_change >= 10, "lane changes: cars reach destinations their spawn lane doesn't lead to (%d trips)" % needed_change)
	_check(traffic.completed_trips >= 60, "lane changes: traffic flows (%d trips)" % traffic.completed_trips)
	_check(traffic.cars.size() < 40, "lane changes: queues stay short (%d cars left)" % traffic.cars.size())
	_check_limits(stats, "lane changes")
	net.free()
	traffic.free()


## Cars have different preferred speeds; on a long two-lane one-way road the
## faster ones pass the slower ones.
func _test_overtaking() -> void:
	var setup := _setup(15.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), RoadType.get_type(&"one_way_2"))
	var stats := _run(traffic, 180.0)
	_check(traffic.overtakes > 0, "overtaking: faster cars pass slower ones (%d overtakes)" % traffic.overtakes)
	_check(traffic.completed_trips >= 40, "overtaking: cars complete trips (got %d)" % traffic.completed_trips)
	_check_limits(stats, "overtaking")
	net.free()
	traffic.free()


## A crossing whose traffic lights are switched on while cars drive. Nobody
## enters on red (unless the light changed too late to stop), and cars waiting
## at red stop at the stop line rather than pulling into the junction.
func _test_traffic_lights() -> void:
	var setup := _setup(3.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	var c := net.find_node_near(Vector3.ZERO, 0.5)
	var stats := _run(traffic, 30.0)
	net.set_traffic_lights(c, true)
	traffic.step(DT)
	_check(traffic.graph.lights.has(c) and traffic.graph.lights[c].phases == 4, "lights: the crossing has 4 phases")
	var red_runs := 0
	var late_goes := 0
	var entered := 0
	var stop_min := INF
	var stop_max := 0.0
	var last_index := {}
	var trips := traffic.completed_trips
	for i in int(240.0 / DT):
		_run(traffic, DT, stats)
		for car in traffic.cars:
			var p := traffic.graph.pieces[car.route[car.index]]
			if p.is_connection and p.light_node >= 0 and last_index.get(car.id, -1) != car.index:
				entered += 1
				if traffic.light_state(p.light_node, p.light_phase) != TrafficManager.Light.GREEN:
					if car.light_k == car.index and car.light_go:
						late_goes += 1
					else:
						red_runs += 1
			last_index[car.id] = car.index
			# First car stopped at a red light: where is it?
			if not p.is_connection and p.light_node >= 0 and car.v < 0.05 \
					and traffic.light_state(p.light_node, p.light_phase) == TrafficManager.Light.RED:
				var first := true
				for other: TrafficManager.Car in traffic._piece_cars.get(p.id, []):
					if other.s > car.s:
						first = false
				if first:
					stop_min = minf(stop_min, p.length - car.s)
					stop_max = maxf(stop_max, p.length - car.s)
	_check(entered >= 30, "lights: cars drive through (%d)" % entered)
	_check(red_runs == 0, "lights: nobody enters on red without having to (%d did)" % red_runs)
	_check(late_goes <= entered / 10, "lights: few cars go through on yellow/red (%d of %d)" % [late_goes, entered])
	_check(stop_max > 0.0 and stop_min >= 1.3 and stop_max <= 1.7,
		"lights: cars stop at the stop line (%.1f-%.1f m before the junction)" % [stop_min, stop_max])
	_check(traffic.completed_trips - trips >= 30, "lights: traffic flows (%d trips)" % (traffic.completed_trips - trips))
	_check(traffic.cars.size() < 50, "lights: queues stay bounded (%d cars left)" % traffic.cars.size())
	_check_limits(stats, "lights")
	# A plain bend can't have lights.
	net.build_road(RoadCurve.straight(Vector3(50, 0, 50), Vector3(100, 0, 50)), _two)
	net.build_road(RoadCurve.straight(Vector3(100, 0, 50), Vector3(100, 0, 100)), _two)
	var b := net.find_node_near(Vector3(100, 0, 50), 0.5)
	net.set_traffic_lights(b, true)
	_check(not net.has_traffic_lights(b), "lights: a node with 2 roads has no lights")
	net.free()
	traffic.free()


func _test_bend_slows_cars() -> void:
	var setup := _setup(10.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3.ZERO), _two)
	net.build_road(RoadCurve.straight(Vector3.ZERO, Vector3(0, 0, HALF)), _two)
	var corner_max := 0.0
	var corner_seen := false
	for i in int(120.0 / DT):
		traffic.step(DT)
		for car in traffic.cars:
			if Vector2(car.front_pos.x, car.front_pos.z).length() < 2.0:
				corner_seen = true
				corner_max = maxf(corner_max, car.v)
	_check(corner_seen, "bend: cars drive through the corner")
	_check(corner_max < 9.0, "bend: cars slow down for a 90° turn (max %.1f m/s at the corner)" % corner_max)
	_check(traffic.completed_trips >= 10, "bend: cars complete trips (got %d)" % traffic.completed_trips)
	net.free()
	traffic.free()


func _test_one_way() -> void:
	var setup := _setup(20.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _one)
	var wrong_way := 0
	for i in int(60.0 / DT):
		traffic.step(DT)
		for car in traffic.cars:
			if car.heading.x < 0.9:
				wrong_way += 1
	_check(traffic.completed_trips >= 5, "one-way: cars drive it (got %d trips)" % traffic.completed_trips)
	_check(wrong_way == 0, "one-way: every car drives in the road's direction")
	net.free()
	traffic.free()


func _test_network_change_while_driving() -> void:
	var setup := _setup(20.0)
	var net: RoadNetwork = setup[0]
	var traffic: TrafficManager = setup[1]
	net.build_road(RoadCurve.straight(Vector3(-HALF, 0, 0), Vector3(HALF, 0, 0)), _two)
	var stats := _run(traffic, 30.0)
	var before := traffic.cars.size()
	# Cut the road with a crossing street while cars are on it.
	net.build_road(RoadCurve.straight(Vector3(0, 0, -HALF), Vector3(0, 0, HALF)), _two)
	traffic.step(DT)
	_check(before > 0 and traffic.cars.size() >= before - 2,
		"change: cars stay on the road when it is split (%d -> %d)" % [before, traffic.cars.size()])
	var trips := traffic.completed_trips
	_run(traffic, 90.0, stats)
	_check(traffic.completed_trips > trips + 20, "change: traffic keeps flowing afterwards")
	_check_limits(stats, "change")
	# Deleting a road removes the cars on it.
	for sid: int in net.segments.keys():
		net.remove_segment(sid)
	traffic.step(DT)
	_check(traffic.cars.is_empty(), "change: cars vanish with their road")
	net.free()
	traffic.free()
