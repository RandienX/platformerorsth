extends ColorRect

func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/ranch_idle.tscn")

func _on_button2_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/test_area.tscn")

func _on_button_2_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/tutorial.tscn")
	
