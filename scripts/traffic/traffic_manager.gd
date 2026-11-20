class_name TrafficManager
extends Node3D
## Spawns cars at outside connections (road ends on the map border) and drives
## them along the lane graph to another outside connection.
##
## Car following uses the Intelligent Driver Model (IDM): smooth acceleration,
## comfortable braking, and a safe time gap to the car ahead. Cars slow down for
## curves. At junctions a car must reserve its path before entering: conflicting
## paths are first come, first served, and nobody enters if their exit is blocked.
## On multi-lane roads cars change into the lane their route needs before the
## junction, and overtake slower cars when another lane leads the same way.

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
## Until a car has reserved its way through a junction with crossing traffic,
## it approaches where it may have to stop no faster than this (m/s, ~35 km/h)...
const JUNCTION_APPROACH_SPEED := 9.7
## ...and asks for the junction once it is this close (m).
const JUNCTION_REQUEST_DISTANCE := 35.0
const SPAWN_SPEED := 12.0
const SPAWN_CLEARANCE := 20.0
## Lane changes: seconds for the sideways move. The car keeps its old lane
## occupied (with a stand-in "ghost" car) until it's done.
const LANE_CHANGE_TIME := 2.5
## A lane change may not make the car itself or its new follower brake harder than this (m/s²).
const LANE_CHANGE_SAFE_DECEL := 3.0
## Extra room the route leaves before the junction request point for each further lane change (m).
const LANE_CHANGE_SPACING := 30.0
## A car that still has to change lanes waits this far before the last point it may start.
const LANE_CHANGE_STOP_MARGIN := 6.0
## After waiting this long for a gap, a car drops its lane change and takes another way.
const LANE_CHANGE_GIVE_UP := 10.0
## Overtaking (MOBIL): change lanes if it gains this much acceleration (m/s²)...
const OVERTAKE_GAIN := 0.6
## ...counting the new follower's loss at this weight.
const POLITENESS := 0.3
const OVERTAKE_CHECK_INTERVAL := 0.5
## Traffic lights: each road in turn gets green, then yellow, then everyone has
## red for a moment so the junction clears (seconds).
const LIGHT_GREEN := 15.0
const LIGHT_YELLOW := 3.0
const LIGHT_ALL_RED := 2.0
## At a red light, cars stop with their front this far before the junction (m).
const RED_STOP_DISTANCE := 1.5
const STOP_LINE_WIDTH := 0.4
const STOP_LINE_COLOR := Color(0.95, 0.95, 0.95, 0.9)
const LIGHT_COLORS: Array[Color] = [Color(0.1, 1.0, 0.25), Color(1.0, 0.75, 0.05), Color(1.0, 0.1, 0.05)]

enum Light { GREEN, YELLOW, RED }
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
	## Speed the driver likes to go (up to MAX_SPEED); faster drivers overtake slower ones.
	var max_speed: float = MAX_SPEED
	var dest_node: int = -1
	var color: Color
	## Junction path (route index) whose conflict zones the car is queued for, and since when.
	var request_k: int = -1
	var request_time: float = 0.0
	## Zones queued for: zone id -> side.
	var pending: Dictionary = {}
	## Zones reserved: {zone, side, k (route index of the junction path), end (zone end along it)}.
	var held: Array[Dictionary] = []
	## Junction paths the car may enter because their exit lane had room: route index -> piece id.
	var committed: Dictionary = {}
	var front_pos := Vector3.ZERO
	var heading := Vector3.FORWARD
	## What limited the car most this step: "free", "curve", "leader", "junction", "lane" (for debugging).
	var limit := "free"
	## Lane change in progress: a stand-in car keeping the old lane piece occupied,
	## its offset along that piece (s there = s here + ghost_ds), and the lane piece changed into.
	var ghost: Car = null
	var ghost_piece: int = -1
	var ghost_ds: float = 0.0
	var change_piece: int = -1
	## Sideways offset (m, + = right) from the new lane when the change started, and time since then.
	var change_lat: float = 0.0
	var change_time: float = INF
	## How long the car has been stopped waiting to change lanes.
	var change_wait: float = 0.0
	var next_overtake_check: float = 0.0
	## Traffic light decision for the junction path at route index `light_k`
	## (made when the light turned yellow or red): go through, or stop at the line.
	var light_k: int = -1
	var light_go: bool = false
	## Set while the car's next junction stop is a red light.
	var at_red: bool = false


@export var network: RoadNetwork
@export var map_half_size: float = 1000.0
## Cars per minute spawned on each lane entering the map.
@export_range(0.0, 60.0) var spawn_rate: float = 10.0

var graph: TrafficGraph
var cars: Array[Car] = []
var completed_trips: int = 0
## Lane changes done so far, and how many of them were overtakes.
var lane_changes: int = 0
var overtakes: int = 0
## Lane changes dropped because no gap came up (the car took another way).
var lane_change_give_ups: int = 0
var rng := RandomNumberGenerator.new()

var _time := 0.0
var _next_car_id := 1
var _dirty := true
var _spawn_due: Dictionary = {}  # entry piece id -> time of next spawn
## Per conflict zone id: [cars holding side 0, cars holding side 1].
var _zone_holders: Array = []
## Per conflict zone id: [cars queued for side 0, cars queued for side 1].
var _zone_pending: Array = []
var _entering: Dictionary = {}  # connection piece id -> Array of Car committed to it
var _piece_cars: Dictionary = {}  # piece id -> Array of Car, sorted by s
var _multimesh: MultiMesh
var _markers: MeshInstance3D
var _light_parts: MultiMesh
var _lamps: MultiMesh
## Per lamp instance: [node id, phase, Light it shows].
var _lamp_info: Array[Array] = []


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
	# Traffic lights: poles and housings (unit boxes scaled per instance), and lamps.
	_light_parts = MultiMesh.new()
	_light_parts.transform_format = MultiMesh.TRANSFORM_3D
	_light_parts.use_colors = true
	var part := BoxMesh.new()
	part.size = Vector3.ONE
	part.material = mat
	_light_parts.mesh = part
	var parts_mmi := MultiMeshInstance3D.new()
	parts_mmi.multimesh = _light_parts
	add_child(parts_mmi)
	_lamps = MultiMesh.new()
	_lamps.transform_format = MultiMesh.TRANSFORM_3D
	_lamps.use_colors = true
	var lamp := SphereMesh.new()
	lamp.radius = 0.13
	lamp.height = 0.26
	lamp.radial_segments = 12
	lamp.rings = 6
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp_mat.vertex_color_use_as_albedo = true
	lamp.material = lamp_mat
	_lamps.mesh = lamp
	var lamps_mmi := MultiMeshInstance3D.new()
	lamps_mmi.multimesh = _lamps
	lamps_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lamps_mmi)
	if graph != null:  # simulated before entering the tree
		_draw_markers()


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
	for car in cars:
		_update_lane_change(car, delta)


func _on_network_changed() -> void:
	_dirty = true


# ---------------------------------------------------------------- graph changes

func _rebuild_graph() -> void:
	_dirty = false
	graph = TrafficGraph.build(network, map_half_size, MAX_SPEED)
	_zone_holders.clear()
	_zone_pending.clear()
	for i in graph.zone_count:
		_zone_holders.append([[], []])
		_zone_pending.append([[], []])
	_entering.clear()
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
	car.held.clear()
	car.pending.clear()
	car.committed.clear()
	car.request_k = -1
	car.ghost = null
	car.change_time = INF
	car.change_wait = 0.0
	car.light_k = -1
	var piece := graph.pieces[best_piece]
	if piece.is_connection:
		# Already inside the junction: it takes the zones it still has to pass.
		car.committed[0] = piece.id
		_entering_list(piece.id).append(car)
		for z: Dictionary in piece.zones:
			if car.s - CAR_LENGTH <= z.end:
				_take(car, z, 0)
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
			car.max_speed = MAX_SPEED * rng.randf_range(0.8, 1.0)
			car.v = minf(_safe_spawn_speed(entry, car.s), car.max_speed)
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
	var v0 := car.max_speed
	var approach := INF
	var need := 0.0  # braking needed to slow for curves ahead
	var approach_need := 0.0  # braking needed to slow for the junction ahead
	var accel := INF
	car.limit = "free"
	var speed_lookahead := v * v / (2.0 * COMFORT_DECEL) + 20.0
	var to_piece := -car.s  # distance from the car's front to the start of piece k
	var leader_found := false
	var junction_checked := false
	## Where the car has to stop for a junction (distance from its front).
	var stop := INF
	## Cars beyond this don't matter yet: the car waits at its stop point first.
	## While the junction is still far off, its stop line isn't a real stop yet,
	## so cars waiting inside it count (otherwise they'd appear suddenly).
	var horizon := INF
	## Where the car has to come to rest for a red light (distance from its front).
	var red_stop := INF
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
		# Junction (the one we're in, then the next): drive up to the first
		# conflict zone we can't reserve yet and wait there.
		# At a red light the car stops at the stop line instead.
		if p.is_connection and (not p.zones.is_empty() or p.light_node >= 0) and stop == INF and not junction_checked:
			junction_checked = k > car.index
			car.at_red = false
			stop = _junction_stop(car, p, k, to_piece)
			if k == car.index or to_piece - STOP_LINE_MARGIN < JUNCTION_REQUEST_DISTANCE or car.at_red:
				horizon = stop
			if stop < INF:
				var va := 0.0 if car.at_red else JUNCTION_APPROACH_SPEED
				approach = minf(approach, sqrt(va * va + 2.0 * COMFORT_DECEL * stop))
				approach_need = (v * v - va * va) / (2.0 * maxf(stop, 0.5))
				if car.at_red:
					red_stop = stop
				elif stop < JUNCTION_REQUEST_DISTANCE:
					# A stop point needs no time gap, just room to stop.
					var term := _idm_interaction(v, stop, v, 0.0)
					if term < accel:
						accel = term
						car.limit = "junction"
		# Car ahead (cars beyond where we have to stop don't matter yet).
		if not leader_found:
			for other: Car in _piece_cars.get(p.id, []):
				if other == car or (k == car.index and other.s <= car.s):
					continue
				var gap := to_piece + other.s - CAR_LENGTH
				if gap <= horizon:
					var term := _idm_interaction(v, gap, v - other.v, TIME_HEADWAY)
					if term < accel:
						accel = term
						car.limit = "leader"
				leader_found = true
				break
			# A car that just turned off this lane onto another path through the
			# junction may still have its tail in the lane (e.g. waiting inside).
			if not leader_found and not p.is_connection:
				var next_on_route := car.route[k + 1] if k + 1 < car.route.size() else -1
				for nid in p.next:
					var list: Array = _piece_cars.get(nid, [])
					if nid == next_on_route or list.is_empty():
						continue
					var other: Car = list[0]
					if other.s < CAR_LENGTH:
						var gap := to_piece + p.length + other.s - CAR_LENGTH
						if gap <= horizon:
							var term := _idm_interaction(v, gap, v - other.v, TIME_HEADWAY)
							if term < accel:
								accel = term
								car.limit = "leader"
						leader_found = true
			if to_piece + p.length > horizon:
				leader_found = true
		# A lane change ahead: the car can't go on along this lane, so it waits at
		# the last point to start the change if it hasn't found a gap by then.
		if k + 1 < car.route.size() and graph.is_lane_change(p.id, car.route[k + 1]):
			var stop_s := clampf(_change_deadline(car.route, k) - LANE_CHANGE_STOP_MARGIN, CAR_LENGTH + 2.0, p.length - 1.0)
			if k == car.index and car.s > stop_s:
				stop_s = p.length - 1.0
			var term := _idm_interaction(v, to_piece + stop_s, v, 0.0)
			if term < accel:
				accel = term
				car.limit = "lane"
			break
		to_piece += p.length
		k += 1
	# Mid lane change the car is still partly in its old lane.
	if car.ghost != null:
		var lead := _lane_leader(graph.pieces[car.ghost_piece], car.ghost.s, car)
		if not lead.is_empty():
			var term := _idm_interaction(v, lead.gap, v - lead.v, TIME_HEADWAY)
			if term < accel:
				accel = term
				car.limit = "leader"
	if accel == INF:
		accel = 0.0
		car.limit = "curve" if v0 < car.max_speed - 0.1 else "free"
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
	if red_stop < INF:
		var stop_accel := _stop_accel(v, red_stop)
		if stop_accel < result:
			result = stop_accel
			car.limit = "light"
	return clampf(result, -MAX_DECEL, MAX_ACCEL)


## Acceleration that brings the car to rest exactly `d` m ahead: brake evenly
## (v² / 2d) once it's faster than a gentle approach allows, otherwise roll up.
func _stop_accel(v: float, d: float) -> float:
	if d <= 0.05:
		return -minf(v * 10.0, MAX_DECEL)
	var gentle := sqrt(COMFORT_DECEL * d)  # speed from which braking at half comfort stops in d
	if v > gentle:
		return -v * v / (2.0 * d)
	return minf((gentle - v) * 3.0, MAX_ACCEL)


## IDM braking term for an obstacle `gap` meters ahead approached at `dv` m/s,
## keeping a time gap of `headway` seconds.
func _idm_interaction(v: float, gap: float, dv: float, headway: float) -> float:
	var desired := MIN_GAP + maxf(0.0, v * headway + v * dv / (2.0 * sqrt(MAX_ACCEL * COMFORT_DECEL)))
	var g := maxf(gap, 0.05)
	return -MAX_ACCEL * (desired / g) * (desired / g)


## Where the car must stop for junction path `p` (route index `k`, starting
## `to_piece` m ahead of its front), as a distance from its front: at the stop
## line while it's far off or its exit lane is full, otherwise just before the
## first conflict zone it can't reserve yet. INF if it may drive through.
## Zones are reserved in order along the path, first come first served by the
## time cars asked for the junction, so waiting cars never wait on each other in
## a circle.
func _junction_stop(car: Car, p: TrafficGraph.Piece, k: int, to_piece: float) -> float:
	var on_piece := k == car.index
	if not on_piece and p.light_node >= 0 and _must_stop_at_light(car, p, k, to_piece):
		car.at_red = true
		return maxf(to_piece - RED_STOP_DISTANCE, 0.0)
	if not on_piece:
		var to_line := maxf(to_piece - STOP_LINE_MARGIN, 0.0)
		if to_line >= JUNCTION_REQUEST_DISTANCE:
			return to_line
		_request(car, p, k)
		if not car.committed.has(k):
			# Don't block the junction: the exit lane needs room for everyone entering.
			if not _exit_has_room(p):
				return to_line
			car.committed[k] = p.id
			_entering_list(p.id).append(car)
	for z: Dictionary in p.zones:
		if _holds(car, z.zone, k):
			continue
		if on_piece and car.s - CAR_LENGTH > z.end:
			continue  # already past it
		if on_piece and car.s >= z.start:
			_take(car, z, k)  # already in it
			continue
		if not _can_take(car, z.zone, z.side):
			return maxf(to_piece + z.start - STOP_LINE_MARGIN, 0.0)
		_take(car, z, k)
	return INF


## Traffic lights: on green the car drives on. Once the light turns yellow (or
## red) it decides once whether it can stop comfortably at the line; if so it
## stops there (and gives up any junction reservations) until green, otherwise
## it goes through.
func _must_stop_at_light(car: Car, p: TrafficGraph.Piece, k: int, to_piece: float) -> bool:
	var state := light_state(p.light_node, p.light_phase)
	if state == Light.GREEN:
		if car.light_k == k:
			car.light_k = -1
		return false
	if car.light_k != k:
		car.light_k = k
		var room := maxf(to_piece - RED_STOP_DISTANCE, 0.1)
		car.light_go = car.v * car.v / (2.0 * room) > COMFORT_DECEL
	if car.light_go:
		return false
	_withdraw(car, k)
	return true


## Drops the car's queue place, reservations and commitment for junction path `k`.
func _withdraw(car: Car, k: int) -> void:
	if car.request_k == k:
		_cancel_request(car)
	for i in range(car.held.size() - 1, -1, -1):
		var h := car.held[i]
		if h.k == k:
			(_zone_holders[h.zone][h.side] as Array).erase(car)
			car.held.remove_at(i)
	if car.committed.has(k):
		_entering_list(car.committed[k]).erase(car)
		car.committed.erase(k)


## Light shown to traffic of `phase` at junction `node_id`.
func light_state(node_id: int, phase: int) -> Light:
	var info: Dictionary = graph.lights.get(node_id, {})
	if info.is_empty():
		return Light.GREEN
	var step := LIGHT_GREEN + LIGHT_YELLOW + LIGHT_ALL_RED
	var t := fmod(_time, step * info.phases)
	var current := int(t / step)
	var within := t - current * step
	if current != phase or within >= LIGHT_GREEN + LIGHT_YELLOW:
		return Light.RED
	return Light.GREEN if within < LIGHT_GREEN else Light.YELLOW


func _exit_has_room(p: TrafficGraph.Piece) -> bool:
	var out_cars: Array = _piece_cars.get(p.next[0], [])
	if out_cars.is_empty():
		return true
	var last: Car = out_cars[0]
	var needed := ((_entering.get(p.id, []) as Array).size() + 1) * (CAR_LENGTH + MIN_GAP)
	return last.s - CAR_LENGTH >= needed or last.v >= 2.0


## Queues the car for every conflict zone of junction path `p`.
func _request(car: Car, p: TrafficGraph.Piece, k: int) -> void:
	if car.request_k == k:
		return
	_cancel_request(car)
	car.request_k = k
	car.request_time = _time
	for z: Dictionary in p.zones:
		if not _holds(car, z.zone, k):
			(_zone_pending[z.zone][z.side] as Array).append(car)
			car.pending[z.zone] = z.side


func _cancel_request(car: Car) -> void:
	for zone: int in car.pending:
		(_zone_pending[zone][car.pending[zone]] as Array).erase(car)
	car.pending.clear()
	car.request_k = -1


## A zone side is free if nobody holds the other side and nobody who asked
## earlier is queued for it.
func _can_take(car: Car, zone: int, side: int) -> bool:
	if not (_zone_holders[zone][1 - side] as Array).is_empty():
		return false
	for other: Car in _zone_pending[zone][1 - side]:
		if other.request_time < car.request_time or (other.request_time == car.request_time and other.id < car.id):
			return false
	return true


func _take(car: Car, z: Dictionary, k: int) -> void:
	(_zone_holders[z.zone][z.side] as Array).append(car)
	if car.pending.has(z.zone):
		(_zone_pending[z.zone][car.pending[z.zone]] as Array).erase(car)
		car.pending.erase(z.zone)
	car.held.append({"zone": z.zone, "side": z.side, "k": k, "end": z.end})


func _holds(car: Car, zone: int, k: int) -> bool:
	for h in car.held:
		if h.zone == zone and h.k == k:
			return true
	return false


## How far the car's tail is past the start of route piece `k` (negative before it).
func _tail_past(car: Car, k: int) -> float:
	if k > car.index:
		return -INF
	var d := car.s - CAR_LENGTH
	for j in range(k, car.index):
		d += graph.pieces[car.route[j]].length
	return d


## Moves the car `ds` meters along its route. Returns false when it arrives.
func _advance(car: Car, ds: float) -> bool:
	car.s += ds
	var piece := graph.pieces[car.route[car.index]]
	while car.s >= piece.length:
		if car.index + 1 >= car.route.size():
			return false
		if graph.is_lane_change(piece.id, car.route[car.index + 1]):
			car.s = piece.length - 0.01  # has to change lanes first
			break
		car.s -= piece.length
		_piece_list(piece.id).erase(car)
		car.index += 1
		piece = graph.pieces[car.route[car.index]]
		_piece_list(piece.id).push_front(car)
	# Couldn't stop in time: claim the zone anyway so others wait.
	if piece.is_connection:
		for z: Dictionary in piece.zones:
			if car.s >= z.start and car.s - CAR_LENGTH <= z.end and not _holds(car, z.zone, car.index):
				_take(car, z, car.index)
	# Release zones once the whole car has left them, and forget junctions behind.
	for i in range(car.held.size() - 1, -1, -1):
		var h := car.held[i]
		if _tail_past(car, h.k) > h.end:
			(_zone_holders[h.zone][h.side] as Array).erase(car)
			car.held.remove_at(i)
	for k: int in car.committed.keys():
		if car.index > k:
			_entering_list(car.committed[k]).erase(car)
			car.committed.erase(k)
	if car.request_k >= 0 and car.index > car.request_k:
		_cancel_request(car)
	car.front_pos = piece.position_at(car.s)
	car.heading = piece.direction_at(car.s)
	return true


# ---------------------------------------------------------------- lane changes

## Starts a lane change the route needs, or an overtake; animates one in progress.
func _update_lane_change(car: Car, delta: float) -> void:
	if car.change_time < LANE_CHANGE_TIME:
		car.change_time += delta
	if car.ghost != null:
		if car.change_time >= LANE_CHANGE_TIME or car.route[car.index] != car.change_piece:
			_end_ghost(car)
		else:
			var old := graph.pieces[car.ghost_piece]
			car.ghost.s = clampf(car.s + car.ghost_ds, 0.0, old.length)
			car.ghost.v = car.v
		return
	var i := car.index
	if i + 1 < car.route.size() and graph.is_lane_change(car.route[i], car.route[i + 1]):
		if _try_change(car, car.route[i + 1], false):
			car.change_wait = 0.0
		elif car.v < 0.5:
			car.change_wait += delta
			if car.change_wait > LANE_CHANGE_GIVE_UP:
				_give_up_change(car)
		return
	if _time >= car.next_overtake_check:
		car.next_overtake_check = _time + OVERTAKE_CHECK_INTERVAL
		_try_overtake(car)


## Distance along route piece `k` by which the lane change(s) starting there
## should be done: before the next junction's request point, leaving room for
## each further change. On a short lane: anywhere before its end.
func _change_deadline(route: PackedInt32Array, k: int) -> float:
	var n := 1
	while k + n < route.size() - 1 and graph.is_lane_change(route[k + n], route[k + n + 1]):
		n += 1
	var length := graph.pieces[route[k]].length
	var d := length - JUNCTION_REQUEST_DISTANCE - LANE_CHANGE_SPACING * (n - 1)
	if d < CAR_LENGTH + 20.0:
		d = length - 2.0 - 10.0 * (n - 1)
	return d


## Moves the car into lane piece `to` beside its own if there is a safe gap and
## it can still finish before the deadline. With `overtake`, `new_route` replaces
## the rest of the route.
func _try_change(car: Car, to: int, overtake: bool, new_route := PackedInt32Array()) -> bool:
	var a := graph.pieces[car.route[car.index]]
	var b := graph.pieces[to]
	if car.s < CAR_LENGTH + 1.0:
		return false  # tail still in the junction behind
	if car.v >= 1.0 and car.s + (car.v + 1.0) * LANE_CHANGE_TIME > _change_deadline(car.route, car.index):
		return false
	var s_b := b.project(a.position_at(car.s)).x
	if s_b < CAR_LENGTH + 1.0 or s_b > b.length - 1.0:
		return false
	if not _change_safe(car, b, s_b):
		return false
	# Junction state for pieces after this one refers to route indices that change.
	_cancel_request(car)
	for j in range(car.held.size() - 1, -1, -1):
		var h := car.held[j]
		if h.k >= car.index:
			(_zone_holders[h.zone][h.side] as Array).erase(car)
			car.held.remove_at(j)
	for k: int in car.committed.keys():
		if k >= car.index:
			_entering_list(car.committed[k]).erase(car)
			car.committed.erase(k)
	if overtake:
		var r := car.route.slice(0, car.index)
		r.append_array(new_route)
		car.route = r
		overtakes += 1
	else:
		var r := car.route.duplicate()  # routes are shared with the route cache
		r.remove_at(car.index)
		car.route = r
	lane_changes += 1
	# The car moves to the new lane now; a ghost holds its place in the old one.
	var ghost := Car.new()
	ghost.id = -car.id
	ghost.s = car.s
	ghost.v = car.v
	_piece_list(a.id).erase(car)
	_insert_sorted(_piece_list(a.id), ghost)
	car.ghost = ghost
	car.ghost_piece = a.id
	car.ghost_ds = car.s - s_b
	car.change_piece = b.id
	var old_pos := a.position_at(car.s)
	car.s = s_b
	_insert_sorted(_piece_list(b.id), car)
	car.front_pos = b.position_at(s_b)
	car.heading = b.direction_at(s_b)
	car.change_lat = (old_pos - car.front_pos).dot(_right(car.heading))
	car.change_time = 0.0
	return true


## A lane change is safe if neither the car nor its new follower would have to
## brake harder than LANE_CHANGE_SAFE_DECEL.
func _change_safe(car: Car, b: TrafficGraph.Piece, s_b: float) -> bool:
	var lead := _lane_leader(b, s_b, car)
	if not lead.is_empty():
		if lead.gap < MIN_GAP + 0.5 or _idm_interaction(car.v, lead.gap, car.v - lead.v, TIME_HEADWAY) < -LANE_CHANGE_SAFE_DECEL:
			return false
	var follow := _lane_follower(b, s_b, car)
	if not follow.is_empty():
		if follow.gap < MIN_GAP + 0.5 or _idm_interaction(follow.v, follow.gap, follow.v - car.v, TIME_HEADWAY) < -LANE_CHANGE_SAFE_DECEL:
			return false
	return true


## MOBIL: move to a lane beside if that lets the car go noticeably faster, net
## of what it costs the new follower, and the lane leads the same way.
func _try_overtake(car: Car) -> void:
	var a := graph.pieces[car.route[car.index]]
	if car.limit != "leader" or a.is_connection or a.beside.is_empty() or car.s < CAR_LENGTH + 1.0:
		return
	# Far enough from the junction to settle in (and its route won't need changes back).
	if car.s + (car.v + 1.0) * LANE_CHANGE_TIME > a.length - JUNCTION_REQUEST_DISTANCE - LANE_CHANGE_SPACING:
		return
	var current := _lane_leader(a, car.s, car)
	if current.is_empty():
		return
	var gain_now := _free_accel(car.v, car.max_speed) + _idm_interaction(car.v, current.gap, car.v - current.v, TIME_HEADWAY)
	var next_road := -1
	if car.index + 1 < car.route.size():
		next_road = RoadNetwork.key_segment(graph.pieces[car.route[car.index + 1]].out_key)
	for c_id in a.beside:
		var c := graph.pieces[c_id]
		var s_c := c.project(a.position_at(car.s)).x
		var lead := _lane_leader(c, s_c, car)
		var gain := _free_accel(car.v, car.max_speed)
		if not lead.is_empty():
			gain += _idm_interaction(car.v, lead.gap, car.v - lead.v, TIME_HEADWAY)
		var follow := _lane_follower(c, s_c, car)
		if not follow.is_empty():
			gain += POLITENESS * _idm_interaction(follow.v, follow.gap, follow.v - car.v, TIME_HEADWAY)
		if gain - gain_now < OVERTAKE_GAIN:
			continue
		# The other lane must take the car onto the same road without changing back.
		var r := graph.route(c_id, car.dest_node)
		if r.is_empty():
			continue
		if next_road < 0:
			if r.size() != 1:
				continue
		elif r.size() < 2 or graph.is_lane_change(r[0], r[1]) or RoadNetwork.key_segment(graph.pieces[r[1]].out_key) != next_road:
			continue
		if _try_change(car, c_id, true, r):
			return


## The car couldn't get into the lane it needs: it takes another way from its
## current lane (to its destination if possible, else to any outside connection).
func _give_up_change(car: Car) -> void:
	car.change_wait = 0.0
	lane_change_give_ups += 1
	var a := graph.pieces[car.route[car.index]]
	var dests: Array[int] = [car.dest_node]
	for n in graph.outside_nodes:
		if n != car.dest_node and n != a.from_node:
			dests.append(n)
	for dest in dests:
		for nx in a.next:
			var r := graph.route(nx, dest)
			if r.is_empty():
				continue
			_cancel_request(car)
			var head := car.route.slice(0, car.index + 1)
			head.append_array(r)
			car.route = head
			car.dest_node = dest
			return


func _end_ghost(car: Car) -> void:
	if car.ghost == null:
		return
	_piece_list(car.ghost_piece).erase(car.ghost)
	car.ghost = null


## The car (or ghost) right ahead of distance `s` on lane piece `p`, or the tail
## of one that just left it: {gap, v}. Empty if none.
func _lane_leader(p: TrafficGraph.Piece, s: float, me: Car) -> Dictionary:
	var best: Car = null
	for other: Car in _piece_cars.get(p.id, []):
		if other == me or other == me.ghost or other.s <= s:
			continue
		if best == null or other.s < best.s:
			best = other
	if best != null:
		return {"gap": best.s - CAR_LENGTH - s, "v": best.v}
	var result := {}
	for nid in p.next:
		for other: Car in _piece_cars.get(nid, []):
			if other != me and other.s < CAR_LENGTH:
				var gap := p.length - s + other.s - CAR_LENGTH
				if result.is_empty() or gap < result.gap:
					result = {"gap": gap, "v": other.v}
	return result


## The car (or ghost) right behind distance `s` on lane piece `p`, or the
## nearest one about to enter it: {gap, v}. Empty if none.
func _lane_follower(p: TrafficGraph.Piece, s: float, me: Car) -> Dictionary:
	var best: Car = null
	for other: Car in _piece_cars.get(p.id, []):
		if other == me or other == me.ghost or other.s > s:
			continue
		if best == null or other.s > best.s:
			best = other
	if best != null:
		return {"gap": s - CAR_LENGTH - best.s, "v": best.v}
	var result := {}
	for pid in p.prev:
		var prev := graph.pieces[pid]
		for other: Car in _piece_cars.get(pid, []):
			if other == me:
				continue
			var gap := s - CAR_LENGTH + prev.length - other.s
			if result.is_empty() or gap < result.gap:
				result = {"gap": gap, "v": other.v}
	return result


func _free_accel(v: float, v0: float) -> float:
	return MAX_ACCEL * (1.0 - pow(v / v0, ACCEL_EXPONENT))


func _insert_sorted(list: Array, car: Car) -> void:
	var i := 0
	while i < list.size() and (list[i] as Car).s < car.s:
		i += 1
	list.insert(i, car)


static func _right(dir: Vector3) -> Vector3:
	return Vector3(-dir.z, 0.0, dir.x).normalized()


func _remove_car(car: Car) -> void:
	_cancel_request(car)
	for h in car.held:
		(_zone_holders[h.zone][h.side] as Array).erase(car)
	car.held.clear()
	for k: int in car.committed:
		_entering_list(car.committed[k]).erase(car)
	car.committed.clear()
	_end_ghost(car)
	_piece_list(car.route[car.index]).erase(car)
	cars.erase(car)


func _piece_list(id: int) -> Array:
	if not _piece_cars.has(id):
		_piece_cars[id] = []
	return _piece_cars[id]


func _entering_list(id: int) -> Array:
	if not _entering.has(id):
		_entering[id] = []
	return _entering[id]


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
	if car.change_time < LANE_CHANGE_TIME:
		# Sliding over from the old lane; the rear follows a little later, so
		# the car turns slightly into the new lane.
		var t := car.change_time / LANE_CHANGE_TIME
		var side := _right(dir) * car.change_lat
		front += side * (1.0 - smoothstep(0.0, 0.85, t))
		rear += side * (1.0 - smoothstep(0.15, 1.0, t))
		dir = front - rear
		dir.y = 0.0
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
	for i in _lamp_info.size():
		var info := _lamp_info[i]
		var shows: Light = info[2]
		var lit := light_state(info[0], info[1]) == shows
		var color := LIGHT_COLORS[shows]
		_lamps.set_instance_color(i, color if lit else color.darkened(0.85))


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
	# Stop lines where cars wait at red lights.
	var lines := TriBatch.new()
	for p in graph.pieces:
		if p.is_connection or p.light_node < 0 or not graph.lights.has(p.light_node):
			continue
		var dir := p.direction_at(p.length)
		var across := dir.cross(Vector3.UP) * RoadType.LANE_WIDTH * 0.47
		var mid := p.position_at(p.length) - dir * (RED_STOP_DISTANCE - STOP_LINE_WIDTH * 0.5 - 0.1)
		mid.y = RoadNetwork.ROAD_Y + 0.02
		var half := dir * STOP_LINE_WIDTH * 0.5
		lines.tri(mid - across - half, mid + across - half, mid + across + half, STOP_LINE_COLOR)
		lines.tri(mid - across - half, mid + across + half, mid - across + half, STOP_LINE_COLOR)
	lines.commit(im, TriBatch.make_material(false))
	_build_lights()


## Poles, housings and lamps for every road with a traffic light, at the curb
## on the right of the incoming traffic, facing it.
func _build_lights() -> void:
	if _lamps == null:
		return
	_lamp_info.clear()
	var parts: Array[Transform3D] = []
	var lamps: Array[Transform3D] = []
	for node_id: int in graph.lights:
		var ends: Array = graph.lights[node_id].ends
		for phase in ends.size():
			var e: Dictionary = ends[phase]
			var out: Vector3 = e.out
			var side: Vector3 = e.side  # right of `out`
			var base: Vector3 = e.left + out * 1.2 - side * 0.9
			base.y = 0.0
			var facing := Basis.looking_at(out, Vector3.UP)  # front (-Z) toward approaching cars
			parts.append(Transform3D(facing.scaled(Vector3(0.16, 4.2, 0.16)), base + Vector3.UP * 2.1))
			var head := base + Vector3.UP * 3.7
			parts.append(Transform3D(facing.scaled(Vector3(0.45, 1.25, 0.32)), head))
			for light: Light in [Light.RED, Light.YELLOW, Light.GREEN]:
				var y := 0.38 * (light - 1)  # red on top, green at the bottom
				lamps.append(Transform3D(Basis(), head + out * 0.15 + Vector3.UP * y))
				_lamp_info.append([node_id, phase, light])
	_light_parts.instance_count = parts.size()
	for i in parts.size():
		_light_parts.set_instance_transform(i, parts[i])
		_light_parts.set_instance_color(i, Color(0.18, 0.19, 0.2))
	_lamps.instance_count = lamps.size()
	for i in lamps.size():
		_lamps.set_instance_transform(i, lamps[i])
