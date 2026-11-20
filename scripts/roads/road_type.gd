class_name RoadType
extends RefCounted
## A road's cross-section: its lanes and total width. Traffic drives on the right.
## There is one RoadType per lane layout (`from_layout`), so types compare with ==.

const LANE_WIDTH := 3.0
const MAX_LANES := 8


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
## Lanes from left to right, looking along the segment direction.
var lanes: Array[LaneDef] = []
var width: float = 0.0

## Presets shown in the toolbar.
static var _registry: Dictionary = {}
## Every layout used so far, by signature: the presets and custom layouts.
static var _layouts: Dictionary = {}


func is_one_way() -> bool:
	for lane in lanes:
		if not lane.forward:
			return false
	return true


func is_preset() -> bool:
	_ensure_registry()
	return _registry.has(id)


## Lane directions from left to right (true = runs start -> end).
func layout() -> Array[bool]:
	var result: Array[bool] = []
	for lane in lanes:
		result.append(lane.forward)
	return result


## True if reversing a road of this type changes it (false for a symmetric two-way road).
func is_reversible() -> bool:
	return layout() != reversed_layout(layout())


## Index of the lane `lateral` m right of the center line (clamped to the road).
func lane_at(lateral: float) -> int:
	return clampi(floori((lateral + width * 0.5) / LANE_WIDTH), 0, lanes.size() - 1)


static func get_type(type_id: StringName) -> RoadType:
	_ensure_registry()
	return _registry.get(type_id) as RoadType


static func all_types() -> Array[RoadType]:
	_ensure_registry()
	var result: Array[RoadType] = []
	for t: RoadType in _registry.values():
		result.append(t)
	return result


## The road type with these lane directions (left to right, true = forward).
static func from_layout(forwards: Array[bool]) -> RoadType:
	_ensure_registry()
	if forwards.is_empty():
		return null
	var sig := _signature(forwards)
	if _layouts.has(sig):
		return _layouts[sig]
	return _make(StringName("custom_" + sig), _describe(forwards), forwards)


## The same road seen from its other end: lanes in reverse order, directions flipped.
static func reversed_layout(forwards: Array[bool]) -> Array[bool]:
	var result: Array[bool] = []
	for i in range(forwards.size() - 1, -1, -1):
		result.append(not forwards[i])
	return result


static func _ensure_registry() -> void:
	if not _registry.is_empty():
		return
	_register(&"two_way", "Two-way road", [false, true])
	_register(&"one_way", "One-way road", [true])
	_register(&"four_lane", "Four-lane road", [false, false, true, true])
	_register(&"one_way_2", "Two-lane one-way", [true, true])


static func _register(type_id: StringName, name: String, forwards: Array[bool]) -> void:
	_registry[type_id] = _make(type_id, name, forwards)


static func _make(type_id: StringName, name: String, forwards: Array[bool]) -> RoadType:
	var t := RoadType.new()
	t.id = type_id
	t.display_name = name
	t.width = LANE_WIDTH * forwards.size()
	for i in forwards.size():
		t.lanes.append(LaneDef.new(-t.width * 0.5 + (i + 0.5) * LANE_WIDTH, forwards[i], LANE_WIDTH))
	_layouts[_signature(forwards)] = t
	return t


static func _signature(forwards: Array[bool]) -> String:
	var s := ""
	for f in forwards:
		s += "F" if f else "B"
	return s


static func _describe(forwards: Array[bool]) -> String:
	var fwd := forwards.count(true)
	var back := forwards.size() - fwd
	if back == 0 or fwd == 0:
		return "%d-lane one-way" % forwards.size()
	return "%d-lane road (%d + %d)" % [forwards.size(), fwd, back]
