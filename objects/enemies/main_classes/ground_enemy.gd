class_name WalkerEnemy
extends Enemy
## Enemy 1: walks left/right and turns around when there is no floor ahead
## or a wall in front. Uses move_and_slide, so it follows slopes by itself.
##
## Body collision layer: Enemy (NOT your world layer). Body collision mask: world.
## The sensor rays copy the body's collision mask.

@export_group("Walker")
@export var speed := 250.0                  ## px / second
@export var gravity := 1500.0
@export var max_fall_speed := 900.0
@export var start_facing := -1             ## -1 = left, 1 = right
@export var turn_at_ledges := true
@export var turn_at_walls := true
@export var turn_pause := 0.25             ## seconds standing still after turning
@export var sprite_faces_right := true
@export var floor_snap := 16.0

@export_group("Sensors")
@export var sensor_origin := Vector2.ZERO  ## offset from the body origin (put it around the body's centre)
@export var ledge_ahead := 28.0            ## how far in front of the origin the floor check is
@export var ledge_depth := 48.0            ## how far below the origin it looks (a bit more than origin->feet)
@export var wall_ahead := 24.0             ## wall check length in front of the origin

var facing := -1

var _floor_ray: RayCast2D
var _wall_ray: RayCast2D
var _pause := 0.0


func _enemy_ready() -> void:
	facing = start_facing
	floor_snap_length = floor_snap
	_floor_ray = _make_ray()
	_wall_ray = _make_ray()
	_face_sprite(facing, sprite_faces_right)

func _enemy_tick(delta: float) -> void:
	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	_pause = maxf(_pause - delta, 0.0)

	_update_sensors()
	if is_on_floor() and _pause <= 0.0:
		var ledge := turn_at_ledges and not _floor_ray.is_colliding()
		var wall := turn_at_walls and (_wall_in_front() or _bumped_wall())
		if ledge or wall:
			_turn_around()

	velocity.x = 0.0 if _pause > 0.0 else facing * speed
	move_and_slide()
	_play("walk" if _pause <= 0.0 else "idle")

func _on_respawn() -> void:
	facing = start_facing
	_pause = 0.0
	_face_sprite(facing, sprite_faces_right)

func _turn_around() -> void:
	facing = -facing
	_pause = turn_pause
	_face_sprite(facing, sprite_faces_right)
	_update_sensors()

func _make_ray() -> RayCast2D:
	var r := RayCast2D.new()
	r.collision_mask = collision_mask
	r.exclude_parent = true
	r.enabled = true
	add_child(r)
	return r

func _update_sensors() -> void:
	_floor_ray.position = sensor_origin + Vector2(facing * ledge_ahead, 0.0)
	_floor_ray.target_position = Vector2(0.0, ledge_depth)
	_wall_ray.position = sensor_origin
	_wall_ray.target_position = Vector2(facing * wall_ahead, 0.0)
	_floor_ray.force_raycast_update()
	_wall_ray.force_raycast_update()

## A surface in front that is too steep to walk on (ramps don't count as walls).
func _wall_in_front() -> bool:
	if not _wall_ray.is_colliding():
		return false
	var n := _wall_ray.get_collision_normal()
	return absf(n.angle_to(up_direction)) > floor_max_angle

## Backup: move_and_slide reported a wall pushing against our walking direction.
func _bumped_wall() -> bool:
	return is_on_wall() and get_wall_normal().x * facing < 0.0


func _on_hitbox_area_entered(area: Area2D) -> void:
	print(area.name)
