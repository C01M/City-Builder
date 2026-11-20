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
