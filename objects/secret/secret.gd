extends Area2D

@onready var level = get_tree().current_scene

func _on_body_entered(body: Node2D) -> void:
	if body == Global.player:
		level.secrets_found += 1
		queue_free()
