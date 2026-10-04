extends HSplitContainer

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	$Lives2.text = "%03d" % [Global.lives]
