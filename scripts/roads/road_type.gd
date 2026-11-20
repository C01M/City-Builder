class_name RoadType
extends RefCounted
## A road's cross-section: its lanes and total width. Traffic drives on the right.

const LANE_WIDTH := 3.0


class LaneDef:
	## Offset of the lane center from the road center line,
	## positive = right of the segment direction (start -> end).
	var offset: float
	## True if the lane runs from the segment's start node to its end node.
	var forward: bool
	var width: float

	func _init(p_offset: float, p_forward: bool, p_width: float) -> void:
		offset = p_offset
		forward = p_forward
		width = p_width


var id: StringName
var display_name: String
var lanes: Array[LaneDef] = []
var width: float = 0.0

static var _registry: Dictionary = {}


func is_one_way() -> bool:
	for lane in lanes:
		if not lane.forward:
			return false
	return true


static func get_type(type_id: StringName) -> RoadType:
	_ensure_registry()
	return _registry.get(type_id) as RoadType


static func all_types() -> Array[RoadType]:
	_ensure_registry()
	var result: Array[RoadType] = []
	for t: RoadType in _registry.values():
		result.append(t)
	return result


static func _ensure_registry() -> void:
	if not _registry.is_empty():
		return
	var half := LANE_WIDTH * 0.5
	_register(&"two_way", "Two-way road", [
		LaneDef.new(-half, false, LANE_WIDTH),
		LaneDef.new(half, true, LANE_WIDTH),
	])
	_register(&"one_way", "One-way road", [
		LaneDef.new(0.0, true, LANE_WIDTH),
	])


static func _register(type_id: StringName, name: String, lane_defs: Array) -> void:
	var t := RoadType.new()
	t.id = type_id
	t.display_name = name
	for lane: LaneDef in lane_defs:
		t.lanes.append(lane)
		t.width += lane.width
	_registry[type_id] = t
