extends SceneTree
## Opens the main scene with border-to-border roads and traffic already flowing
## (simulated for a while before the first frame). For screenshots:
##   godot --path . -s res://tests/demo_traffic.gd --write-movie <dir>/f.png --quit-after 30


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var net: RoadNetwork = main.get_node("RoadNetwork")
	var traffic: TrafficManager = main.get_node("TrafficManager")
	var two := RoadType.get_type(&"two_way")
	var one := RoadType.get_type(&"one_way")
	var edge := traffic.map_half_size
	net.build_road(RoadCurve.straight(Vector3(-edge, 0, 0), Vector3(edge, 0, 0)), two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -edge), Vector3(0, 0, edge)), two)
	net.build_road(RoadCurve.straight(Vector3(40, 0, -edge), Vector3(40, 0, 0)), one, {}, {"on_segment": true})
	traffic.spawn_rate = 8.0
	traffic.rng.seed = 7
	for i in 150 * 30:  # 150 s of traffic, so cars have reached the center
		traffic.step(1.0 / 30.0)
	# Fixed view for screenshots, applied once the rig is ready; ignore mouse input.
	var rig: Node3D = main.get_node("CameraRig")
	process_frame.connect(func() -> void:
		rig.set_process_unhandled_input(false)
		rig.position = Vector3(15, 0, 5)
		rig.set("_distance", 75.0)
		rig.set("_pitch", deg_to_rad(-55.0))
		rig.call("_update_camera"), CONNECT_ONE_SHOT)
