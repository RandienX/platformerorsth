@tool
extends Resource
class_name Instruction

enum InstructionTypes { MOVE, WAIT }

@export var instruction_type: InstructionTypes

@export var move_progress: float = 0.0
@export var move_time: float = 1.0
@export var move_tween_type: Tween.TransitionType
@export var move_ease_type: Tween.EaseType
@export var no_ease_type: bool = true
@export var wait_time: float = 1.0
