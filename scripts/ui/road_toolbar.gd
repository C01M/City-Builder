extends CanvasLayer
## Bottom toolbar: road type, tool and option toggles.

@export var tool: RoadTool
@export var overlay: RoadOverlay

var _hint: Label


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# Don't mirror the toolbar when the OS uses a right-to-left language.
	panel.layout_direction = Control.LAYOUT_DIRECTION_LTR
	add_child(panel)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -12.0
	panel.offset_bottom = -12.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.modulate = Color(1, 1, 1, 0.75)
	_hint.text = tool.get_hint()
	column.add_child(_hint)
	tool.hint_changed.connect(func(text: String) -> void: _hint.text = text)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	column.add_child(row)

	var type_group := ButtonGroup.new()
	for type in RoadType.all_types():
		_add_toggle(row, type.display_name, type_group, type == tool.road_type,
			func() -> void: tool.set_road_type(type))
	row.add_child(VSeparator.new())

	var tool_group := ButtonGroup.new()
	var tools := [
		["Straight", RoadTool.Mode.STRAIGHT],
		["Curved", RoadTool.Mode.CURVED],
		["Freeform", RoadTool.Mode.FREEFORM],
		["Upgrade", RoadTool.Mode.UPGRADE],
		["Lanes", RoadTool.Mode.LANES],
		["Bulldoze", RoadTool.Mode.BULLDOZE],
	]
	for entry: Array in tools:
		var m: RoadTool.Mode = entry[1]
		_add_toggle(row, entry[0], tool_group, m == tool.mode, func() -> void: tool.set_mode(m))
	row.add_child(VSeparator.new())

	var snap := CheckButton.new()
	snap.text = "Snapping"
	snap.button_pressed = tool.grid_snap
	snap.toggled.connect(func(on: bool) -> void: tool.grid_snap = on)
	row.add_child(snap)

	var lanes := CheckButton.new()
	lanes.text = "Lane overlay"
	lanes.button_pressed = overlay.visible
	lanes.toggled.connect(func(on: bool) -> void: overlay.visible = on)
	row.add_child(lanes)


func _add_toggle(parent: Control, text: String, group: ButtonGroup, pressed: bool, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	parent.add_child(b)
