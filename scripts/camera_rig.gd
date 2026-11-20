extends Node3D
## City-builder style camera: WASD/arrows to pan, mouse wheel to zoom,
## hold middle mouse to rotate and tilt. Stays inside the map bounds.

@export var pan_speed: float = 60.0
@export var rotate_speed: float = 0.005
@export var zoom_step: float = 0.1
@export var min_distance: float = 10.0
@export var max_distance: float = 800.0
## Half the map size in meters (map is 2000 x 2000).
@export var bounds: float = 1000.0

@onready var camera: Camera3D = $Camera3D

var _distance: float = 120.0
var _pitch: float = deg_to_rad(-50.0)
var _rotating: bool = false


func _ready() -> void:
	_update_camera()


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		dir.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		dir.z += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if dir == Vector3.ZERO:
		return
	# Pan faster when zoomed out.
	var speed := pan_speed * (_distance / 100.0)
	position += basis * dir.normalized() * speed * delta
	position.x = clampf(position.x, -bounds, bounds)
	position.z = clampf(position.z, -bounds, bounds)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_distance = maxf(min_distance, _distance * (1.0 - zoom_step))
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_distance = minf(max_distance, _distance * (1.0 + zoom_step))
			MOUSE_BUTTON_MIDDLE:
				_rotating = mb.pressed
		_update_camera()
	elif event is InputEventMouseMotion and _rotating:
		var mm := event as InputEventMouseMotion
		rotation.y -= mm.relative.x * rotate_speed
		_pitch = clampf(_pitch - mm.relative.y * rotate_speed, deg_to_rad(-85.0), deg_to_rad(-10.0))
		_update_camera()


func _update_camera() -> void:
	# Orbit the rig's origin at _distance, tilted down by _pitch.
	camera.position = Vector3(0.0, -sin(_pitch), cos(_pitch)) * _distance
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
