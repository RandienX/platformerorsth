extends Path2D
@export var movement_array: Array[Instruction]
@export var beginning_wait_time: float
@export var loops: bool = true

@onready var path: PathFollow2D = get_child(0)
var current_instruction: int = 0

var active_tween: Tween

## px/s, kept for other scripts (the player does not use it any more).
var current_velocity: Vector2 = Vector2.ZERO
var last_path_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	add_to_group("moving_platform")
	last_path_pos = path.global_position
	await _wait(beginning_wait_time)
	_run_instructions()

## Timer that counts physics ticks instead of idle frames.
func _wait(seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds, true, true).timeout

func _run_instructions() -> void:
	if movement_array.is_empty():
		return
	while true:
		if current_instruction >= movement_array.size():
			if loops:
				current_instruction = 0
			else:
				break
				
		var instruction = movement_array[current_instruction]
		match instruction.instruction_type:
			Instruction.InstructionTypes.MOVE:
				await _move_platform(instruction, path)
			Instruction.InstructionTypes.WAIT:
				await _wait(instruction.wait_time)
		
		current_instruction += 1

func _move_platform(instruction: Instruction, platform_path: PathFollow2D) -> void:
	if active_tween and active_tween.is_valid():
		active_tween.kill()
	
	active_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS).set_trans(instruction.move_tween_type)
	if !instruction.no_ease_type:
		active_tween.set_ease(instruction.move_ease_type)
	
	var start_ratio := platform_path.progress_ratio
	var target_ratio := start_ratio + instruction.move_progress
	
	if !loops:
		target_ratio = clampf(target_ratio, 0.0, 1.0)
		active_tween.tween_method(func(value): platform_path.progress_ratio = value, start_ratio, target_ratio, instruction.move_time)
	else:
		active_tween.tween_method(func(value): platform_path.progress_ratio = fposmod(value, 1.0), start_ratio, target_ratio, instruction.move_time)
	
	await active_tween.finished

func _physics_process(delta: float) -> void:
	current_velocity = (path.global_position - last_path_pos) / delta
	last_path_pos = path.global_position

func get_current_velocity() -> Vector2:
	return current_velocity
