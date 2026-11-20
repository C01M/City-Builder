class_name NodePanel
extends PanelContainer
## Node Controller side panel: the selected junction's mode and, per road end,
## sliders for offset, shift, rotate, stretch and curb radius. Built in code.

const MODE_NAMES := ["Auto", "Middle", "Stretch", "U-turn"]

var tool: RoadTool
var network: RoadNetwork

var _node_id := -1
var _segments: Array[int] = []
var _title: Label
var _mode: OptionButton
var _lights: CheckBox
var _align: Button
var _paste: Button
var _ends_box: VBoxContainer
## segment id -> {field name -> Range control}, plus "auto" -> CheckBox.
var _controls: Dictionary = {}


func setup(road_tool: RoadTool, road_network: RoadNetwork) -> void:
	tool = road_tool
	network = road_network
	layout_direction = Control.LAYOUT_DIRECTION_LTR
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -332.0
	offset_right = -12.0
	offset_top = 12.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	_title = Label.new()
	column.add_child(_title)

	var mode_row := HBoxContainer.new()
	column.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Mode"
	mode_label.custom_minimum_size.x = 90
	mode_row.add_child(mode_label)
	_mode = OptionButton.new()
	_mode.focus_mode = Control.FOCUS_NONE
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in MODE_NAMES.size():
		_mode.add_item(MODE_NAMES[i], i)
	_mode.item_selected.connect(func(index: int) -> void:
		network.set_node_mode(_node_id, index as RoadNetwork.NodeMode))
	mode_row.add_child(_mode)

	_lights = CheckBox.new()
	_lights.text = "Traffic lights (T)"
	_lights.focus_mode = Control.FOCUS_NONE
	_lights.toggled.connect(func(on: bool) -> void: network.set_traffic_lights(_node_id, on))
	column.add_child(_lights)

	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	_align = _add_button(buttons, "Align", func() -> void: tool.set_aligning(not tool.aligning))
	_align.toggle_mode = true
	_add_button(buttons, "Copy", func() -> void: tool.copy_node())
	_paste = _add_button(buttons, "Paste", func() -> void: tool.paste_node())
	_add_button(buttons, "Reset", func() -> void: tool.reset_node())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 420
	column.add_child(scroll)
	_ends_box = VBoxContainer.new()
	_ends_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ends_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_ends_box)

	tool.node_tool_changed.connect(_refresh)
	tool.hint_changed.connect(func(_text: String) -> void: _refresh())
	network.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var node := network.get_node_data(tool.selected_node)
	visible = tool.mode == RoadTool.Mode.NODE and node != null and node.segment_ids.size() >= 2
	if not visible:
		_node_id = -1
		return
	var infos := network.node_end_info(node.id)
	var segs: Array[int] = []
	for info in infos:
		segs.append(info.segment_id)
	if node.id != _node_id or segs != _segments:
		_node_id = node.id
		_segments = segs
		_build_ends(infos)
	_title.text = "Junction %d  ·  %d roads" % [node.id, segs.size()]
	_mode.select(node.mode)
	for i in [RoadNetwork.NodeMode.MIDDLE, RoadNetwork.NodeMode.STRETCH]:
		_mode.set_item_disabled(i, segs.size() != 2)
	_lights.set_pressed_no_signal(node.traffic_lights)
	_lights.disabled = segs.size() < RoadNetwork.MIN_LIGHT_ROADS
	_lights.tooltip_text = "Each road in turn gets green" if not _lights.disabled else "Needs a junction of 3 or more roads"
	_align.set_pressed_no_signal(tool.aligning)
	_paste.disabled = not tool.has_clipboard()
	for info in infos:
		var s: RoadNetwork.EndSettings = info.settings
		var c: Dictionary = _controls[info.segment_id]
		_set_slider(c.offset, s.offset)
		_set_slider(c.shift, s.shift)
		_set_slider(c.rotate, s.rotate)
		_set_slider(c.stretch, s.stretch * 100.0)
		var auto := s.radius < 0.0
		(c.auto as CheckBox).set_pressed_no_signal(auto)
		(c.radius as Range).editable = not auto
		_set_slider(c.radius, 0.0 if auto else s.radius)
		(c.curb_row as Control).visible = not (info.curb as Dictionary).is_empty() or not auto


func _build_ends(infos: Array[Dictionary]) -> void:
	for child in _ends_box.get_children():
		child.queue_free()
	_controls.clear()
	for i in infos.size():
		var info := infos[i]
		var sid: int = info.segment_id
		var c := {}
		_controls[sid] = c
		var header := Label.new()
		header.text = "Road %d  ·  %s" % [i + 1, info.type_name]
		header.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
		_ends_box.add_child(header)
		c.offset = _add_slider("Offset (m)", -10.0, 30.0, 0.1, sid, func(s: RoadNetwork.EndSettings, v: float) -> void: s.offset = v)
		c.shift = _add_slider("Shift (m)", -6.0, 6.0, 0.05, sid, func(s: RoadNetwork.EndSettings, v: float) -> void: s.shift = v)
		c.rotate = _add_slider("Rotate (°)", -RoadNetwork.MAX_ROTATE, RoadNetwork.MAX_ROTATE, 0.5, sid,
			func(s: RoadNetwork.EndSettings, v: float) -> void: s.rotate = v)
		c.stretch = _add_slider("Stretch (%)", -50.0, 100.0, 1.0, sid, func(s: RoadNetwork.EndSettings, v: float) -> void: s.stretch = v / 100.0)
		var curb_row := HBoxContainer.new()
		_ends_box.add_child(curb_row)
		c.curb_row = curb_row
		var auto := CheckBox.new()
		auto.text = "Auto curb"
		auto.focus_mode = Control.FOCUS_NONE
		auto.toggled.connect(func(on: bool) -> void:
			var s := network.get_end_settings(_node_id, sid)
			s.radius = -1.0 if on else 6.0
			network.set_end_settings(_node_id, sid, s))
		curb_row.add_child(auto)
		c.auto = auto
		c.radius = _add_slider_to(curb_row, "", 0.0, 40.0, 0.25, sid, func(s: RoadNetwork.EndSettings, v: float) -> void: s.radius = v)
		_ends_box.add_child(HSeparator.new())


func _add_slider(text: String, min_v: float, max_v: float, step: float, sid: int, apply: Callable) -> HSlider:
	var row := HBoxContainer.new()
	_ends_box.add_child(row)
	return _add_slider_to(row, text, min_v, max_v, step, sid, apply)


## Slider plus value readout; dragging it updates that road end's settings.
func _add_slider_to(row: HBoxContainer, text: String, min_v: float, max_v: float, step: float, sid: int, apply: Callable) -> HSlider:
	if text != "":
		var label := Label.new()
		label.text = text
		label.custom_minimum_size.x = 90
		row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var value := Label.new()
	value.custom_minimum_size.x = 48
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	var show := func(v: float) -> void: value.text = ("%.0f" if step >= 1.0 else "%.1f" if step >= 0.1 else "%.2f") % v
	slider.set_meta("show", show)
	slider.value_changed.connect(func(v: float) -> void:
		show.call(v)
		var s := network.get_end_settings(_node_id, sid)
		apply.call(s, v)
		network.set_end_settings(_node_id, sid, s))
	show.call(slider.value)
	return slider


## Sets a slider and its readout without applying the value to the network.
static func _set_slider(slider: Range, v: float) -> void:
	slider.set_value_no_signal(v)
	(slider.get_meta("show") as Callable).call(slider.value)


func _add_button(parent: Control, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b
