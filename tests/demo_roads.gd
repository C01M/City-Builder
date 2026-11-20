extends SceneTree
## Opens the main scene with a sample road network and the lane overlay on.
## Useful for screenshots: add --write-movie <dir>/f.png --quit-after 30
##   godot --path . -s res://tests/demo_roads.gd


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var net: RoadNetwork = main.get_node("RoadNetwork")
	var two := RoadType.get_type(&"two_way")
	var one := RoadType.get_type(&"one_way")
	net.build_road(RoadCurve.straight(Vector3(-70, 0, 0), Vector3(70, 0, 0)), two)
	net.build_road(RoadCurve.straight(Vector3(0, 0, -50), Vector3(0, 0, 50)), two)
	net.build_road(RoadCurve.straight(Vector3(40, 0, -45), Vector3(40, 0, 0)), one, -1, -1, false, true)
	net.build_road(RoadCurve.quadratic(Vector3(-60, 0, 40), Vector3(-45, 0, -10), Vector3(-20, 0, -40)), one)
	net.build_road(RoadCurve.quadratic(Vector3(10, 0, 40), Vector3(45, 0, 40), Vector3(55, 0, 0)), two, -1, -1, false, true)
	(main.get_node("RoadOverlay") as Node3D).visible = true
	# Show the lane connector on the center junction with one lane selected and edited.
	var tool: RoadTool = main.get_node("RoadTool")
	var center := net.find_node_near(Vector3.ZERO, 1.0)
	tool.mode = RoadTool.Mode.LANES
	tool.set("_lane_node", center)
	for e in net.get_lane_ends(center):
		if e.incoming and e.direction.x > 0.5:  # eastbound lane arriving from the west
			tool.set("_lane_selected", e.key)
			var outs: Array = net.get_connections(center)[e.key]
			net.set_connection(center, e.key, outs[0], false)
	var rig: Node3D = main.get_node("CameraRig")
	rig.set("_distance", 120.0)
	rig.set("_pitch", deg_to_rad(-70.0))  # applied by the rig's _ready
