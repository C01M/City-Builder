class_name RoadOverlay
extends MeshInstance3D
## Debug view: lane center lines with direction arrows, and the lane
## connections through every junction.

const LANE_COLOR := Color(1.0, 0.85, 0.2, 0.9)
const CONNECTION_COLOR := Color(0.3, 0.85, 1.0, 0.7)

@export var network: RoadNetwork

var _material := TriBatch.make_material(true)


func _ready() -> void:
	mesh = ImmediateMesh.new()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if network:
		network.changed.connect(_rebuild)
	visibility_changed.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	var im := mesh as ImmediateMesh
	im.clear_surfaces()
	if not visible or network == null:
		return
	var batch := TriBatch.new()
	for seg: RoadNetwork.RoadSegment in network.segments.values():
		for i in seg.type.lanes.size():
			var pts := network.lane_points(seg.id, i)
			batch.ribbon(pts, 0.15, LANE_COLOR)
			batch.arrows_along(pts, 8.0, 0.8, LANE_COLOR)
	for node_id: int in network.nodes:
		var by_key := {}
		for e in network.get_lane_ends(node_id):
			by_key[e.key] = e
		var conns := network.get_connections(node_id)
		for in_key: int in conns:
			for out_key: int in conns[in_key]:
				var curve := RoadNetwork.connection_curve(by_key[in_key], by_key[out_key])
				batch.ribbon(curve.sample_points(10, RoadNetwork.ROAD_Y), 0.1, CONNECTION_COLOR)
	batch.commit(im, _material)
