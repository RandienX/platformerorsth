extends CanvasLayer

var INPUT_MENU := false
var paused := false

signal button_changed
var button_index := 0
@onready var button_container: VBoxContainer = $VBoxContainer
var button_container_start_pos

func _ready() -> void:
	button_container.position.y += 250
	button_container_start_pos = button_container.position
	button_changed.connect(button_move)

func _unhandled_input(_event: InputEvent) -> void:
	if Global.player.level_finish:
		return
	
	INPUT_MENU = true if Input.is_action_just_pressed("menu") else false
	
	if INPUT_MENU:
		paused = !paused
		button_container.visible = !button_container.visible
		
	if paused:
		if Input.is_action_just_pressed("down"):
			button_index = clampi(button_index + 1, 0, 4)
			button_changed.emit()
		elif Input.is_action_just_pressed("up"):
			button_index = clampi(button_index - 1, 0, 4)
			button_changed.emit()
		elif Input.is_action_just_pressed("jump"):
			button_container.get_children()[button_index].pressed.emit()
	
func _physics_process(_delta: float) -> void:
	get_tree().paused = paused
	
	if paused:
		for c: Button in button_container.get_children():
			c.global_position.x = button_container.global_position.x - (c.global_position.y * 0.335) + 160

func button_move():
	var tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var tween2 = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(button_container, "position", button_container_start_pos - Vector2(0, button_index * 160), 0.5)
	tween2.tween_property(button_container.get_children()[button_index], "scale", Vector2(1.1, 1.1), 0.33)
	
	await tween2.finished
	for c in button_container.get_children():
		if c != button_container.get_children()[button_index]:
			var tween3 = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tween3.tween_property(c, "scale", Vector2(1.0, 1.0), 0.3)

func _on_restart_pressed() -> void:
	paused = false
	get_tree().reload_current_scene()
	
func _on_exit_pressed() -> void:
	paused = false
	await get_tree().create_timer(0.1).timeout
	get_tree().change_scene_to_file("res://scenes/menu/start_menu.tscn")

func _on_resume_pressed() -> void:
	paused = false
	button_container.visible = false
