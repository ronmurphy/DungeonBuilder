extends Node3D

const PICKER_WIDTH: int = 320

var camera_position:Vector3
var camera_rotation:Vector3

var zoom:float = 30.0 # 30 = Standard zoom level, in meters

@onready var camera = $Camera

func _ready():

	camera_rotation = rotation_degrees # Initial rotation

	pass

func _is_over_picker() -> bool:
	var vp := get_viewport()
	return vp.get_mouse_position().x >= vp.get_visible_rect().size.x - PICKER_WIDTH

var block_input: bool = false  # Set by builder.gd during intermission

func _process(delta):

	if block_input:
		# During intermission — snap to targets for smooth orbit
		position = camera_position
		rotation_degrees = camera_rotation
		camera.position = Vector3(0, 0, zoom)
	else:
		# Normal play — lerp smoothly to targets
		position = position.lerp(camera_position, delta * 8)
		rotation_degrees = rotation_degrees.lerp(camera_rotation, delta * 6)
		camera.position = camera.position.lerp(Vector3(0, 0, zoom), delta * 8)
		handle_input(delta)

# Handle input

func handle_input(_delta):

	if _is_over_picker():
		return

	# Rotation

	var input := Vector3.ZERO

	input.x = Input.get_axis("camera_left", "camera_right")
	input.z = Input.get_axis("camera_forward", "camera_back")

	input = input.rotated(Vector3.UP, rotation.y).normalized()

	camera_position += input / 4

	# Zoom in/out

	if Input.is_action_just_released("zoom_in"):
		zoom = max(15, zoom - 5) # 15 = Minimum zoom level, in meters

	if Input.is_action_just_released("zoom_out"):
		zoom = min(80, zoom + 5) # 80 = Maximum zoom level, in meters

	# Back to center

	if Input.is_action_pressed("camera_center"):
		camera_position = Vector3()

func _input(event):
	if block_input:
		return

	# Rotate camera using mouse (hold 'middle' mouse button)

	if event is InputEventMouseMotion:
		if Input.is_action_pressed("camera_rotate") and not _is_over_picker():
			camera_rotation += Vector3(0, -event.relative.x / 10, 0)
