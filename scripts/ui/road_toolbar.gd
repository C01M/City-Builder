extends CanvasLayer
## Bottom toolbar: road type, tool and option toggles.

@export var tool: RoadTool
@export var overlay: RoadOverlay
@export var traffic: TrafficManager

var _hint: Label
var _traffic_stats: Label


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
	var type_buttons := {}
	for type in RoadType.all_types():
		type_buttons[type] = _add_toggle(row, type.display_name, type_group, type == tool.road_type,
			func() -> void: tool.set_road_type(type))
	# A layout picked from a road (Ctrl+click with the Lanes tool).
	var picked: Array[RoadType] = [null]
	var custom := _add_toggle(row, "", type_group, false, func() -> void:
		if picked[0]:
			tool.set_road_type(picked[0]))
	custom.visible = false
	tool.road_type_changed.connect(func() -> void:
		var t := tool.road_type
		if type_buttons.has(t):
			(type_buttons[t] as Button).set_pressed_no_signal(true)
			return
		picked[0] = t
		custom.text = t.display_name
		custom.tooltip_text = "Layout picked from a road"
		custom.visible = true
		custom.set_pressed_no_signal(true))
	row.add_child(VSeparator.new())

	var tool_group := ButtonGroup.new()
	var tools := [
		["Straight", RoadTool.Mode.STRAIGHT],
		["Curved", RoadTool.Mode.CURVED],
		["Freeform", RoadTool.Mode.FREEFORM],
		["Upgrade", RoadTool.Mode.UPGRADE],
		["Lanes", RoadTool.Mode.LAYOUT],
		["Connections", RoadTool.Mode.LANES],
		["Node", RoadTool.Mode.NODE],
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

	if traffic:
		_build_traffic_panel()

	var node_panel := NodePanel.new()
	add_child(node_panel)
	node_panel.setup(tool, tool.network)


func _process(_delta: float) -> void:
	if _traffic_stats and traffic:
		_traffic_stats.text = "%d cars driving  ·  %d trips done" % [traffic.cars.size(), traffic.completed_trips]


## Top-left panel: spawn rate slider and traffic stats.
func _build_traffic_panel() -> void:
	var panel := PanelContainer.new()
	panel.layout_direction = Control.LAYOUT_DIRECTION_LTR
	panel.position = Vector2(12, 12)
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)

	var rate_label := Label.new()
	column.add_child(rate_label)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 30
	slider.step = 1
	slider.value = traffic.spawn_rate
	slider.custom_minimum_size.x = 220
	slider.focus_mode = Control.FOCUS_NONE
	var show_rate := func(value: float) -> void:
		rate_label.text = "Traffic: %d cars/min per entry lane" % value if value > 0 else "Traffic: off"
	show_rate.call(slider.value)
	slider.value_changed.connect(func(value: float) -> void:
		traffic.set_spawn_rate(value)
		show_rate.call(value))
	column.add_child(slider)

	_traffic_stats = Label.new()
	_traffic_stats.modulate = Color(1, 1, 1, 0.75)
	column.add_child(_traffic_stats)
	var hint := Label.new()
	hint.text = "Connect roads to the map edge to bring in traffic"
	hint.modulate = Color(1, 1, 1, 0.5)
	column.add_child(hint)


func _add_toggle(parent: Control, text: String, group: ButtonGroup, pressed: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b
