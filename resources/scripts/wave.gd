@tool
extends Resource
class_name Wave

@export var enemies: Array[PackedScene]:
	set(value):
		enemies = value
		enemy_positions.resize(len(enemies))
@export var enemy_positions: Array[Vector3i] ## Z is rotation
@export var break_time: float
