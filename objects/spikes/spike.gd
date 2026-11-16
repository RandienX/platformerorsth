extends TextureRect

@export var base_width: float = 128.0 

func _ready() -> void:
	stretch_mode = TextureRect.STRETCH_TILE
	var parent_scale_x = get_parent().scale.x if get_parent() is Node2D else 1.0
	scale.x = 1 / parent_scale_x 
	size.x = base_width * parent_scale_x
	position.x = -size.x / (parent_scale_x*2)
	var term = 8.0
	$"../Area2D/CollisionShape2D2".shape.size.x = 96.0
	for i in range(int(parent_scale_x)):
		$"../Area2D/CollisionShape2D2".shape.size.x += term
		term *= 0.5
