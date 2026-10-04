extends Node

var level_time: float = 0.000
var lives: int = 5
var player: CharacterBody2D

func LOG(value: float, base: float) -> float: 
	return log(value) / log(base)

func respawn_enemies() -> void:
	get_tree().call_group("enemies", "respawn")
