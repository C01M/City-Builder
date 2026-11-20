extends SceneTree
## Main scene with edited lane layouts (extra lanes, a reversed lane), the lane
## overlay and the Lanes tool on. For screenshots: add --write-movie <dir>/f.png --quit-after 30
##   godot --path . -s res://tests/demo_lanes.gd


func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var net: RoadNetwork = main.get_node("RoadNetwork")
	# A four-lane road crossing a two-way road.
	net.build_road(RoadCurve.straight(Vector3(-70, 0, 0), Vector3(70, 0, 0)), RoadType.get_type(&"four_lane"))
	net.build_road(RoadCurve.straight(Vector3(0, 0, -50), Vector3(0, 0, 50)), RoadType.get_type(&"two_way"))
	# East: an extra eastbound lane. South: widened to 2 + 1 lanes.
	var east: int = net.find_segment_near(Vector3(40, 0, 0), 1.0).segment_id
	net.edit_lanes(east, RoadNetwork.LaneEdit.ADD_RIGHT)
	var south: int = net.find_segment_near(Vector3(0, 0, 30), 1.0).segment_id
	net.edit_lanes(south, RoadNetwork.LaneEdit.ADD_LEFT)
	# West: an irregular layout, lane 2 reversed.
	var west: int = net.find_segment_near(Vector3(-40, 0, 0), 1.0).segment_id
	net.edit_lanes(west, RoadNetwork.LaneEdit.REVERSE, 1)
	(main.get_node("RoadOverlay") as Node3D).visible = true
	var tool: RoadTool = main.get_node("RoadTool")
	tool.set_mode(RoadTool.Mode.LAYOUT)
	var rig: Node3D = main.get_node("CameraRig")
	rig.position = Vector3(0, 0, 0)
	rig.set("_distance", 70.0)
	rig.set("_pitch", deg_to_rad(-80.0))
