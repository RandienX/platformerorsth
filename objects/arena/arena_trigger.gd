@tool
extends Area2D

@export var waves: Array[Wave]
@export var enemy_position_helper: Polygon2D
@export var arena_door_node: Node2D
@warning_ignore("unused_private_class_variable")
@export_tool_button("Print Positions", "PreviewEnvironment") var _print_pos_btn = print_pos

var activated: bool = false
var enemies_left: int = 0
signal wave_ended()

func _on_body_entered(body: Node2D) -> void:
	if body == Global.player and !activated:
		activate()
		
func activate():
	activated = true
	print(name, ": Arena Activated")
	
	for c in arena_door_node.get_children():
		c.close_door()
	
	activate_wave(0)
	
func activate_wave(wave_idx: int) -> void:
	if wave_idx >= waves.size():
		end_fight()
		return
	
	var wave = waves[wave_idx]
	for s in range(len(wave.enemies)):
		var enemy = wave.enemies[s].instantiate()
		enemy.position = wave.enemy_positions[s]
		enemy.connect("died", self.lower_enemy_count)
		enemies_left += 1
		call_deferred("add_child", enemy)
		
	await wave_ended
	await get_tree().create_timer(wave.break_time).timeout
	activate_wave(wave_idx + 1)

func lower_enemy_count(_enemy):
	enemies_left -= 1
	if enemies_left <= 0:
		wave_ended.emit()

func end_fight():
	for c in arena_door_node.get_children():
		c.open_door()
	
func print_pos() -> void:
	if enemy_position_helper == null:
		print("ArenaTrigger: EnemyPositionHelper not set!")
		return
	for i in enemy_position_helper.polygon.size():
		print(i, ": ", enemy_position_helper.polygon[i])
