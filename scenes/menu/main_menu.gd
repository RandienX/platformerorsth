extends Control

func _on_campaign_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/test_area.tscn")
	

func _on_exit_pressed() -> void:
	get_tree().quit()
