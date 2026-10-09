@tool
extends Area2D

@export_range(1, 32) var left_layer := 1:
	set(value):
		left_layer = value
		queue_redraw()
@export_range(1, 32) var right_layer := 2:
	set(value):
		right_layer = value
		queue_redraw()
@export var max_travel_per_frame := 256.0
@export var optional_layer_removal: Array[int] = []:
	set(value):
		optional_layer_removal = value
		queue_redraw()
@export var required_vel: Vector2 = Vector2(0,0)

var _prev := Vector2.ZERO
var _has_prev := false
var _shape_node: CollisionShape2D

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(true)
		return
	set_process(false)
	_shape_node = _find_shape()
	if _shape_node == null:
		push_warning("%s: needs a CollisionShape2D child with a RectangleShape2D." % get_path())
	monitoring = false
	monitorable = false
	process_physics_priority = -100

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _shape_node == null:
		return
	var player := Global.player as Node2D
	if player == null or not is_instance_valid(player):
		_has_prev = false
		return
	
	var now := player.global_position
	if _has_prev and _prev.distance_to(now) <= max_travel_per_frame:
		var xf := _shape_node.global_transform
		var half := (_shape_node.shape as RectangleShape2D).size.y * 0.5
		var top := xf * Vector2(0.0, -half)
		var bottom := xf * Vector2(0.0, half)
		
		var has_req_vel = true
		
		if required_vel.x != 0.0:
			has_req_vel = (absf(player.vel.x) >= absf(required_vel.x) and signf(player.vel.x) == signf(required_vel.x))
		if has_req_vel and required_vel.y != 0.0:
			has_req_vel = (absf(player.vel.y) >= absf(required_vel.y)and signf(player.vel.y) == signf(required_vel.y))
		
		if Geometry2D.segment_intersects_segment(_prev, now, top, bottom) != null and has_req_vel:
			var local_x := (xf.affine_inverse() * now).x
			_apply(player, left_layer if local_x < 0.0 else right_layer)
	_prev = now
	_has_prev = true

func _apply(body: CharacterBody2D, layer: int) -> void:
	var other := right_layer if layer == left_layer else left_layer
	body.set_collision_mask_value(other, false)
	body.set_collision_mask_value(layer, true)
	if optional_layer_removal.size() > 0:
		for mask in optional_layer_removal:
			body.set_collision_mask_value(mask, false)

# =============================================================================
# EDITOR HELPERS
# =============================================================================
func _find_shape() -> CollisionShape2D:
	for c in get_children():
		if c is CollisionShape2D and c.shape is RectangleShape2D:
			return c
	return null

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		queue_redraw()

func _layer_color(layer: int) -> Color:
	match layer:
		1: return Color(0.3, 0.6, 1.0)
		2: return Color(1.0, 0.6, 0.2)
		_: return Color(0.7, 0.5, 1.0)

func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var shape_node := _find_shape()
	if shape_node == null:
		return
	var half := (shape_node.shape as RectangleShape2D).size.y * 0.5
	var xf := shape_node.transform
	var top := xf * Vector2(0.0, -half)
	var bottom := xf * Vector2(0.0, half)
	var mid := (top + bottom) * 0.5
	draw_line(top, bottom, Color.WHITE, 3.0)
	
	var font := ThemeDB.fallback_font
	var sides := [[Vector2.LEFT, left_layer, "L"], [Vector2.RIGHT, right_layer, "R"]]
	for s in sides:
		var dir := xf.basis_xform(s[0] as Vector2).normalized()
		var perp := dir.orthogonal()
		var col := _layer_color(s[1] as int)
		var tip := mid + dir * 56.0
		draw_line(mid, tip, col, 4.0)
		draw_line(tip, tip - dir * 14.0 + perp * 9.0, col, 4.0)
		draw_line(tip, tip - dir * 14.0 - perp * 9.0, col, 4.0)
		draw_string(font, tip + dir * 8.0, "%s: %d" % [s[2], s[1]], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
	if optional_layer_removal.size() > 0:
		draw_string(font, mid - Vector2(0, -64), "OFF: %s" % [optional_layer_removal], HORIZONTAL_ALIGNMENT_CENTER, 128, 12)
