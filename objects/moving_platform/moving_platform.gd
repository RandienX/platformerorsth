extends Path2D

@export var movement_array: Array[Instruction]
@export var beginning_wait_time: float
@export var loops: bool = true

@onready var path: PathFollow2D = $PathFollow2D
var current_instruction: int = 0

var active_tween: Tween 

func _ready() -> void:
	last_path_pos = path.global_position # Initialize position
	await get_tree().create_timer(beginning_wait_time).timeout
	_run_instructions()

func _run_instructions() -> void:
	while true:
		if current_instruction >= movement_array.size():
			if loops:
				current_instruction = 0
			else:
				break 

		var instruction = movement_array[current_instruction]
		
		match instruction.instruction_type:
			Instruction.InstructionTypes.MOVE:
				await _move_platform(instruction)
			Instruction.InstructionTypes.WAIT:
				await get_tree().create_timer(instruction.wait_time).timeout
				
		current_instruction += 1

func _move_platform(instruction: Instruction) -> void:
	if active_tween and active_tween.is_valid():
		active_tween.kill()
		
	active_tween = create_tween().set_trans(instruction.move_tween_type)
	if !instruction.no_ease_type:
		active_tween.set_ease(instruction.move_ease_type)

	var start_ratio = path.progress_ratio
	var target_ratio = start_ratio + instruction.move_progress

	if !loops:
		target_ratio = clamp(target_ratio, 0.0, 1.0)
		active_tween.tween_method(func(value): path.progress_ratio = value, start_ratio, target_ratio, instruction.move_time)
	else:
		active_tween.tween_method(func(value): path.progress_ratio = fposmod(value, 1.0), start_ratio, target_ratio, instruction.move_time)

	await active_tween.finished

var current_velocity: Vector2 = Vector2.ZERO
var last_path_pos: Vector2 = Vector2.ZERO

func _physics_process(delta: float) -> void:
	current_velocity = (path.global_position - last_path_pos) / delta
	last_path_pos = path.global_position 

func get_current_velocity() -> Vector2:
	return current_velocity
