extends Area2D

@export var exit_static: bool
@export var cam_scale: Vector2 = Vector2(0.66, 0.66)
@export var cam_position: Vector2
@export var cam_move_time: float

func _on_body_entered(body: Node2D) -> void:
	if body is Player:
		body.static_camera = !exit_static
		body.static_camera_position = cam_position
		body.static_camera_scale = cam_scale
		body.cam_time = cam_move_time
