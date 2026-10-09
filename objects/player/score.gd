extends HSplitContainer

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	$Score2.text = "%07d" % [$"../../../../..".score]
