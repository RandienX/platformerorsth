extends StaticBody2D

## Lock the door until reset, so it won't open after arena ends.
@export var force_lock: bool
## NOT IMPLEMENTED
@export var unlock_wave: int

func close_door():
	var tween = create_tween().set_ease(Tween.EASE_IN)
	tween.tween_property(self, "position", Vector2(position.x, position.y+$CollisionShape2D.shape.size.y), 0.16)
	
func open_door():
	if force_lock:
		return
	var tween = create_tween().set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position", Vector2(position.x, position.y-$CollisionShape2D.shape.size.y), 0.16)
	
