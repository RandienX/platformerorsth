extends Area2D

@export var level: PackedScene
var selected = false

func _on_area_entered(area: Area2D) -> void:
	if area.name == "Chibi":
		selected = true

func _on_area_exited(area: Area2D) -> void:
	if area.name == "Chibi":
		selected = false

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("jump") and selected:
		get_tree().change_scene_to_packed(level)
