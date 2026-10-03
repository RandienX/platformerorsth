extends HSplitContainer

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	var miliseconds: String = str(Global.level_time)
	miliseconds = miliseconds.get_slice(".", 1)
	miliseconds = miliseconds.substr(0, 3)
	$Time2.text = "%02d:%02d:%s" % [floor(Global.level_time / 60), int(Global.level_time) % 60, miliseconds]
