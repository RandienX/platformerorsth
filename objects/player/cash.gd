extends HSplitContainer

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	$Cash2.text = "%03d" % [$"../../../../..".cash]
