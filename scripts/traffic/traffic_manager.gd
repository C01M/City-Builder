class_name TrafficManager
extends Node3D
## Spawns cars at outside connections (road ends on the map border) and drives
## them along the lane graph to another outside connection.
##
## Car following uses the Intelligent Driver Model (IDM): smooth acceleration,
## comfortable braking, and a safe time gap to the car ahead. Cars slow down for
## curves. At junctions a car must reserve its path before entering: conflicting
## paths are first come, first served, and nobody enters if their exit is blocked.

const MAX_SPEED := 70.0 / 3.6
## IDM parameters.
const MAX_ACCEL := 5.0
const COMFORT_DECEL := 6.0
const MAX_DECEL := 18.0
const MIN_GAP := 2.0
const TIME_HEADWAY := 1.2
const ACCEL_EXPONENT := 4.0

const CAR_LENGTH := 4.5
const CAR_WIDTH := 1.9
const CAR_HEIGHT := 1.4
const LOOKAHEAD := 150.0
const MAX_CARS := 800
const STOP_LINE_MARGIN := 0.5
## Until a car has reserved its path through a junction with crossing traffic,
## it approaches the stop line no faster than this (m/s, ~20 km/h)...
const JUNCTION_APPROACH_SPEED := 6.0
## ...and asks for the junction once it is this close (m).
const JUNCTION_REQUEST_DISTANCE := 35.0
const SPAWN_SPEED := 12.0
const SPAWN_CLEARANCE := 20.0
const CAR_COLORS: Array[Color] = [
	Color(0.85, 0.2, 0.2), Color(0.2, 0.45, 0.85), Color(0.9, 0.9, 0.9), Color(0.15, 0.15, 0.15),
	Color(0.95, 0.75, 0.2), Color(0.3, 0.65, 0.35), Color(0.6, 0.6, 0.65), Color(0.55, 0.3, 0.7),
]
const MARKER_COLOR := Color(0.35, 0.7, 1.0, 0.9)


class Car:
	var id: int
	var route := PackedInt32Array()
	## Position in `route` of the piece the car's front is on.
	var index: int = 0
	## Distance of the front bumper along the current piece.
	var s: float = 0.0
	var v: float = 0.0
	var accel: float = 0.0
	var dest_node: int = -1
	var color: Color
	## Route indices of junction connections this car has reserved.
	var granted: Dictionary = {}
	var requested_piece: int = -1
	var request_time: float = 0.0
	var front_pos := Vector3.ZERO
	var heading := Vector3.FORWARD
	## What limited the car most this step: "free", "curve", "leader", "junction" (for debugging).
	var limit := "free"


@export var network: RoadNetwork
@export var map_half_size: float = 1000.0
## Cars per minute spawned on each lane entering the map.
@export_range(0.0, 60.0) var spawn_rate: float = 10.0

var graph: TrafficGraph
var cars: Array[Car] = []
var completed_trips: int = 0
var rng := RandomNumberGenerator.new()

var _time := 0.0
var _next_car_id := 1
var _dirty := true
var _spawn_due: Dictionary = {}  # entry piece id -> time of next spawn
var _reserved: Dictionary = {}  # connection piece id -> Array of Car
var _pending: Dictionary = {}  # connection piece id -> Array of Car waiting
var _piece_cars: Dictionary = {}  # piece id -> Array of Car, sorted by s
var _multimesh: MultiMesh
var _markers: MeshInstance3D


func _init() -> void:
	rng.randomize()


func _ready() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(CAR_WIDTH, CAR_HEIGHT, CAR_LENGTH)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.6
	box.material = mat
	_multimesh.mesh = box
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _multimesh
	add_child(mmi)
	_markers = MeshInstance3D.new()
	_markers.mesh = ImmediateMesh.new()
	_markers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_markers)


func _physics_process(delta: float) -> void:
	step(delta)


func _process(_delta: float) -> void:
	_update_visuals()


func set_spawn_rate(rate: float) -> void:
	spawn_rate = rate
	_spawn_due.clear()


## Advances the simulation by `delta` seconds.
func step(delta: float) -> void:
	if network == null:
		return
	if not network.changed.is_connected(_on_network_changed):
		network.changed.connect(_on_network_changed)
	if _dirty:
		_rebuild_graph()
	_time += delta
	_spawn()
	for list: Array in _piece_cars.values():
		list.sort_custom(func(a: Car, b: Car) -> bool: return a.s < b.s)
	for car in cars:
		car.accel = _acceleration(car)
	var arrived: Array[Car] = []
	for car in cars:
		car.v = maxf(0.0, car.v + car.accel * delta)
		if not _advance(car, car.v * delta):
			arrived.append(car)
	for car in arrived:
		completed_trips += 1
		_remove_car(car)


func _on_network_changed() -> void:
	_dirty = true


# ---------------------------------------------------------------- graph changes

func _rebuild_graph() -> void:
	_dirty = false
	graph = TrafficGraph.build(network, map_half_size, MAX_SPEED)
	_reserved.clear()
	_pending.clear()
	_piece_cars.clear()
	_spawn_due.clear()
	var kept: Array[Car] = []
	for car in cars:
		if _relocate(car):
			kept.append(car)
	cars = kept
	_draw_markers()


## Puts a car back on the rebuilt graph where it currently is, and re-routes it.
func _relocate(car: Car) -> bool:
	var best_piece := -1
	var best_s := 0.0
	var best_d := 1.5
	var p2 := Vector2(car.front_pos.x, car.front_pos.z)
	for piece in graph.pieces:
		if not piece.bounds.grow(2.0).has_point(p2):
			continue
		var proj := piece.project(car.front_pos)
		if proj.y < best_d and piece.direction_at(proj.x).dot(car.heading) > 0.7:
			best_d = proj.y
			best_piece = piece.id
			best_s = proj.x
	if best_piece < 0:
		return false
	var route := graph.route(best_piece, car.dest_node)
	if route.is_empty():
		return false
	car.route = route
	car.index = 0
	car.s = best_s
	car.granted.clear()
	car.requested_piece = -1
	var piece := graph.pieces[best_piece]
	if piece.is_connection:
		_grant(car, piece, 0)
	_piece_list(best_piece).append(car)
	return true


# ---------------------------------------------------------------- spawning

func _spawn() -> void:
	if spawn_rate <= 0.0 or graph.outside_nodes.size() < 2:
		return
	for node_id in graph.outside_nodes:
		for entry: int in graph.entry_pieces[node_id]:
			if not _spawn_due.has(entry):
				_spawn_due[entry] = _time + _spawn_interval()
			if _time < _spawn_due[entry] or cars.size() >= MAX_CARS or not _entry_clear(entry):
				continue
			_spawn_due[entry] = _time + _spawn_interval()
			var route := _random_route(entry, node_id)
			if route.is_empty():
				continue
			var car := Car.new()
			car.id = _next_car_id
			_next_car_id += 1
			car.route = route
			car.dest_node = graph.pieces[route[route.size() - 1]].node_id
			car.s = minf(CAR_LENGTH, graph.pieces[entry].length)
			car.v = _safe_spawn_speed(entry, car.s)
			car.color = CAR_COLORS[rng.randi() % CAR_COLORS.size()]
			car.front_pos = graph.pieces[entry].position_at(car.s)
			car.heading = graph.pieces[entry].direction_at(car.s)
			cars.append(car)
			_piece_list(entry).push_front(car)


func _spawn_interval() -> float:
	var mean := 60.0 / maxf(spawn_rate, 0.001)
	return -log(1.0 - rng.randf() * 0.999) * mean


func _entry_clear(entry: int) -> bool:
	var list: Array = _piece_cars.get(entry, [])
	for car: Car in list:
		if car.s - CAR_LENGTH < CAR_LENGTH + SPAWN_CLEARANCE:
			return false
	return true


## Fastest spawn speed (up to SPAWN_SPEED) that needs only comfortable braking
## for the car already on the entry lane.
func _safe_spawn_speed(entry: int, s: float) -> float:
	var list: Array = _piece_cars.get(entry, [])
	if list.is_empty():
		return SPAWN_SPEED
	var leader: Car = list[0]
	var gap := leader.s - CAR_LENGTH - s
	var v := SPAWN_SPEED
	while v > 0.0 and _idm_interaction(v, gap, v - leader.v, TIME_HEADWAY) < -COMFORT_DECEL:
		v -= 1.0
	return maxf(v, 0.0)


func _random_route(entry: int, from_node: int) -> PackedInt32Array:
	var dests := graph.outside_nodes.duplicate()
	dests.erase(from_node)
	while not dests.is_empty():
		var dest: int = dests.pop_at(rng.randi() % dests.size())
		var route := graph.route(entry, dest)
		if not route.is_empty():
			return route
	return PackedInt32Array()


# ---------------------------------------------------------------- driving

## IDM acceleration toward the speed allowed by curves ahead, limited by the
## car ahead and by a stop line at a junction the car may not enter yet.
func _acceleration(car: Car) -> float:
	var v := car.v
	var v0 := MAX_SPEED
	var approach := INF
	var need := 0.0  # braking needed to slow for curves ahead
	var approach_need := 0.0  # braking needed to slow for the junction ahead
	var accel := INF
	car.limit = "free"
	var speed_lookahead := v * v / (2.0 * COMFORT_DECEL) + 20.0
	var to_piece := -car.s  # distance from the car's front to the start of piece k
	var leader_found := false
	var junction_checked := false
	var k := car.index
	while k < car.route.size() and to_piece < LOOKAHEAD:
		var p := graph.pieces[car.route[k]]
		# Curves ahead: the fastest speed from which we can still slow down in time.
		if to_piece < speed_lookahead:
			for i in range(p.index_at(car.s) if k == car.index else 0, p.points.size()):
				var d := to_piece + p.dist[i]
				if d > speed_lookahead:
					break
				if d >= 0.0:
					var vl := p.speed_limit[i]
					v0 = minf(v0, sqrt(vl * vl + 2.0 * COMFORT_DECEL * d))
					need = maxf(need, (v * v - vl * vl) / (2.0 * maxf(d, 0.5)))
		# Next junction: stop at the line unless our path through it is reserved.
		if p.is_connection and k > car.index and not junction_checked:
			junction_checked = true
			if not p.conflicts.is_empty() and not car.granted.has(k):
				var to_line := maxf(to_piece - STOP_LINE_MARGIN, 0.0)
				if to_line >= JUNCTION_REQUEST_DISTANCE or not _try_reserve(car, p, k):
					# We stop at the line, so cars beyond it don't matter yet.
					leader_found = true
					var va := JUNCTION_APPROACH_SPEED
					approach = minf(approach, sqrt(va * va + 2.0 * COMFORT_DECEL * to_line))
					approach_need = (v * v - va * va) / (2.0 * maxf(to_line, 0.5))
					if to_line < JUNCTION_REQUEST_DISTANCE:
						# A stop line needs no time gap, just room to stop.
						var term := _idm_interaction(v, to_line, v, 0.0)
						if term < accel:
							accel = term
							car.limit = "junction"
		# Car ahead.
		if not leader_found:
			for other: Car in _piece_cars.get(p.id, []):
				if other == car or (k == car.index and other.s <= car.s):
					continue
				var term := _idm_interaction(v, to_piece + other.s - CAR_LENGTH, v - other.v, TIME_HEADWAY)
				if term < accel:
					accel = term
					car.limit = "leader"
				leader_found = true
				break
		to_piece += p.length
		k += 1
	if accel == INF:
		accel = 0.0
		car.limit = "curve" if v0 < MAX_SPEED - 0.1 else "free"
	if approach < v0:
		v0 = approach
		if car.limit != "leader":
			car.limit = "junction"
	# Free-road term; above the allowed speed, brake firmly but not in a panic.
	var free := maxf(MAX_ACCEL * (1.0 - pow(v / maxf(v0, 0.1), ACCEL_EXPONENT)), -2.0 * COMFORT_DECEL)
	var result := free + accel
	# Anticipation: if a slower point ahead (curve or junction approach) needs about
	# comfortable braking or more to reach in time, brake exactly that hard now.
	var brake := maxf(need, approach_need)
	if brake > 0.8 * COMFORT_DECEL and -brake < result:
		result = -brake
		if car.limit == "free":
			car.limit = "junction" if approach_need >= need else "curve"
	return clampf(result, -MAX_DECEL, MAX_ACCEL)


## IDM braking term for an obstacle `gap` meters ahead approached at `dv` m/s,
## keeping a time gap of `headway` seconds.
func _idm_interaction(v: float, gap: float, dv: float, headway: float) -> float:
	var desired := MIN_GAP + maxf(0.0, v * headway + v * dv / (2.0 * sqrt(MAX_ACCEL * COMFORT_DECEL)))
	var g := maxf(gap, 0.05)
	return -MAX_ACCEL * (desired / g) * (desired / g)


## Tries to reserve junction path `p` (route index `k`). First come, first served
## among conflicting paths, and only if the exit lane has room.
func _try_reserve(car: Car, p: TrafficGraph.Piece, k: int) -> bool:
	if car.requested_piece != p.id:
		_cancel_request(car)
		car.requested_piece = p.id
		car.request_time = _time
		_pending_list(p.id).append(car)
	for cid in p.conflicts:
		if not (_reserved.get(cid, []) as Array).is_empty():
			return false
		for other: Car in _pending.get(cid, []):
			if other.request_time < car.request_time or (other.request_time == car.request_time and other.id < car.id):
				return false
	# Don't block the junction: the exit lane needs room for everyone entering.
	var out_cars: Array = _piece_cars.get(p.next[0], [])
	if not out_cars.is_empty():
		var last: Car = out_cars[0]
		var needed := ((_reserved.get(p.id, []) as Array).size() + 1) * (CAR_LENGTH + MIN_GAP)
		if last.s - CAR_LENGTH < needed and last.v < 2.0:
			return false
	_grant(car, p, k)
	return true


func _grant(car: Car, p: TrafficGraph.Piece, k: int) -> void:
	_cancel_request(car)
	_reserved_list(p.id).append(car)
	car.granted[k] = p.id


func _cancel_request(car: Car) -> void:
	if car.requested_piece >= 0:
		_pending_list(car.requested_piece).erase(car)
		car.requested_piece = -1


## Moves the car `ds` meters along its route. Returns false when it arrives.
func _advance(car: Car, ds: float) -> bool:
	car.s += ds
	var piece := graph.pieces[car.route[car.index]]
	while car.s >= piece.length:
		if car.index + 1 >= car.route.size():
			return false
		car.s -= piece.length
		_piece_list(piece.id).erase(car)
		car.index += 1
		piece = graph.pieces[car.route[car.index]]
		_piece_list(piece.id).push_front(car)
		# Couldn't stop in time: claim the junction anyway so others wait.
		if piece.is_connection and not piece.conflicts.is_empty() and not car.granted.has(car.index):
			_grant(car, piece, car.index)
	# Release junctions once the whole car has left them.
	for k: int in car.granted.keys():
		if car.index > k + 1 or (car.index == k + 1 and car.s >= CAR_LENGTH):
			_reserved_list(car.granted[k]).erase(car)
			car.granted.erase(k)
	car.front_pos = piece.position_at(car.s)
	car.heading = piece.direction_at(car.s)
	return true


func _remove_car(car: Car) -> void:
	_cancel_request(car)
	for k: int in car.granted:
		_reserved_list(car.granted[k]).erase(car)
	_piece_list(car.route[car.index]).erase(car)
	cars.erase(car)


func _piece_list(id: int) -> Array:
	if not _piece_cars.has(id):
		_piece_cars[id] = []
	return _piece_cars[id]


func _reserved_list(id: int) -> Array:
	if not _reserved.has(id):
		_reserved[id] = []
	return _reserved[id]


func _pending_list(id: int) -> Array:
	if not _pending.has(id):
		_pending[id] = []
	return _pending[id]


# ---------------------------------------------------------------- queries / visuals

## Point `back` meters behind the car's front along its route.
func route_position(car: Car, back: float) -> Vector3:
	var k := car.index
	var s := car.s - back
	while s < 0.0 and k > 0:
		k -= 1
		s += graph.pieces[car.route[k]].length
	var piece := graph.pieces[car.route[k]]
	if s < 0.0:
		return piece.position_at(0.0) + piece.direction_at(0.0) * s
	return piece.position_at(s)


## Car body center and forward direction (front minus rear along the path).
func car_pose(car: Car) -> Transform3D:
	var front := route_position(car, 0.0)
	var rear := route_position(car, CAR_LENGTH)
	var dir := front - rear
	dir.y = 0.0
	if dir.length_squared() < 1e-6:
		dir = car.heading
	var center := (front + rear) * 0.5
	center.y = RoadNetwork.ROAD_Y + CAR_HEIGHT * 0.5
	return Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), center)


func _update_visuals() -> void:
	if _multimesh == null or graph == null:
		return
	if _multimesh.instance_count < cars.size():
		_multimesh.instance_count = maxi(64, cars.size() * 2)
	_multimesh.visible_instance_count = cars.size()
	for i in cars.size():
		_multimesh.set_instance_transform(i, car_pose(cars[i]))
		_multimesh.set_instance_color(i, cars[i].color)


func _draw_markers() -> void:
	if _markers == null:
		return
	var im := _markers.mesh as ImmediateMesh
	im.clear_surfaces()
	var batch := TriBatch.new()
	for node_id in graph.outside_nodes:
		var pos := network.get_node_data(node_id).position + Vector3.UP * 0.12
		batch.ring(pos, 5.0, 0.5, MARKER_COLOR)
		var out := -network.continue_direction(node_id)  # points into the map
		batch.arrow(pos + out * 2.0, out, 1.6, MARKER_COLOR)
		batch.arrow(pos - out * 2.0, -out, 1.6, MARKER_COLOR)
	batch.commit(im, TriBatch.make_material(true))
