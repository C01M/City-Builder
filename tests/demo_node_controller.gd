extends SceneTree
## Opens the main scene with junctions shaped by the Node Controller and the
## Node tool active on one of them. For screenshots: add --write-movie <dir>/f.png --quit-after 30
##   godot --path . -s res://tests/demo_node_controller.gd


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var net: RoadNetwork = main.get_node("RoadNetwork")
	var two := RoadType.get_type(&"two_way")
	var one := RoadType.get_type(&"one_way")
	# Left: an untouched crossing for comparison.
	net.build_road(RoadCurve.straight(Vector3(-90, 0, 0), Vector3(90, 0, 0)), two)
	net.build_road(RoadCurve.straight(Vector3(-40, 0, -45), Vector3(-40, 0, 45)), two)
	# Right: a crossing with wide curbs, one slanted end and one shifted end.
	net.build_road(RoadCurve.straight(Vector3(40, 0, -45), Vector3(40, 0, 45)), two)
	var right := net.find_node_near(Vector3(40, 0, 0), 0.5)
	for info in net.node_end_info(right):
		var s: RoadNetwork.EndSettings = info.settings
		s.radius = 10.0
		var out: Vector3 = info.out
		if out.z > 0.9:
			s.rotate = 20.0  # south road: slanted end
		elif out.z < -0.9:
			s.shift = 1.5  # north road: moved sideways
			s.stretch = 0.3
		net.set_end_settings(right, info.segment_id, s)
	# Middle: a one-way meeting the main road at a narrow angle.
	net.build_road(RoadCurve.straight(Vector3(0, 0, 0), Vector3(-25, 0, 40)), one, {"on_segment": true})

	var tool: RoadTool = main.get_node("RoadTool")
	tool.set_mode(RoadTool.Mode.NODE)
	tool.select_node(right)
	var close := OS.get_cmdline_user_args().has("close")
	if close:
		(main.get_node("RoadOverlay") as Node3D).visible = true
	var rig: Node3D = main.get_node("CameraRig")
	rig.position = Vector3(45, 0, 0) if close else Vector3(5, 0, 0)
	rig.set("_distance", 50.0 if close else 120.0)
	rig.set("_pitch", deg_to_rad(-80.0))  # applied by the rig's _ready
