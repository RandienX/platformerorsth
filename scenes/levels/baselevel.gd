extends Node2D

var start_timer: bool = false
var time: float
var level_finish: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	await get_tree().create_timer(1.0).timeout
	start_timer = true

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if !level_finish:
		time += delta
		Global.level_time = time

func finish_lvl():
	level_finish = true

func _on_goal_body_entered(body: Node2D) -> void:
	if body is Player:
		finish_lvl()
