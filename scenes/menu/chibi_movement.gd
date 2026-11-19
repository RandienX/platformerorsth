extends PathFollow2D

@export var speed := 200.0

var target := 0.0

func _process(delta: float) -> void:
	var curve: Curve2D = get_parent().curve
	var dir := int(Input.is_action_just_pressed("right")) - int(Input.is_action_just_pressed("left"))
	
	if dir != 0:
		var best := -1.0
		for i in curve.point_count:
			var o := curve.get_closest_offset(curve.get_point_position(i))
			if dir > 0 and o > progress + 0.1 and (best < 0 or o < best):
				best = o
			elif dir < 0 and o < progress - 0.1 and o > best:
				best = o
		if best >= 0:
			target = best
	
	progress = move_toward(progress, target, speed * delta)
