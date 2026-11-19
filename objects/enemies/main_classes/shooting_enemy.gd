class_name ShooterEnemy
extends Enemy
## Enemy 3: stands still (with gravity so it settles on the ground), turns to face
## the player and fires projectiles when the player is in range and visible.
##
## Animations used if present: idle, windup. Optional child Marker2D "Muzzle"
## (assign it to `muzzle`) marks where projectiles spawn.

@export_group("Shooter")
@export var projectile_scene: PackedScene  ## scene whose root has enemy_projectile.gd
@export var muzzle: Marker2D
@export var detect_radius := 600.0
@export var fire_interval := 2.0           ## seconds between bursts
@export var windup_time := 0.35            ## telegraph before the first shot
@export var burst_count := 1
@export var burst_interval := 0.2
@export var projectile_speed := 360.0      ## px / second
@export var aim_at_player := true          ## false = shoots straight ahead in the facing direction
@export var require_line_of_sight := true  ## terrain between you and it blocks shots
@export var turn_to_player := true
@export var start_facing := -1
@export var sprite_faces_right := true

@export_group("Physics")
@export var use_gravity := true
@export var gravity := 1500.0

var facing := -1

var _cooldown := 1.0
var _firing := false
var _token := 0                            ## invalidates a running fire sequence on death/respawn

func _enemy_ready() -> void:
	facing = start_facing
	if muzzle == null:
		muzzle = get_node_or_null("Muzzle") as Marker2D
	_face_sprite(facing, sprite_faces_right)
	_play("idle")

func _enemy_tick(delta: float) -> void:
	if use_gravity:
		if not is_on_floor():
			velocity.y += gravity * delta
		velocity.x = 0.0
		move_and_slide()

	_cooldown -= delta

	var p := Global.player as Player
	if p == null or p.health <= 0:
		return

	var to_player := p.global_position - global_position
	if turn_to_player and absf(to_player.x) > 1.0:
		facing = int(signf(to_player.x))
		_face_sprite(facing, sprite_faces_right)

	if _firing or _cooldown > 0.0:
		return
	if to_player.length() > detect_radius:
		return
	if require_line_of_sight and not _has_line_of_sight(p):
		return
	_fire_sequence()

func _fire_sequence() -> void:
	_firing = true
	var token := _token
	_play("windup")
	await get_tree().create_timer(windup_time).timeout
	for i in burst_count:
		if token != _token or dead:
			return
		_shoot()
		if i < burst_count - 1:
			await get_tree().create_timer(burst_interval).timeout
	if token != _token or dead:
		return
	_play("idle")
	_cooldown = fire_interval
	_firing = false

func _shoot() -> void:
	if projectile_scene == null or get_parent() == null:
		return
	var origin := _muzzle_position()
	var dir := Vector2(facing, 0.0)
	var p := Global.player as Player
	if aim_at_player and p != null:
		dir = (Vector2(p.global_position.x, p.global_position.y - 32) - origin).normalized()

	var proj := projectile_scene.instantiate() as Node2D
	get_parent().add_child(proj)
	proj.global_position = origin
	if proj.has_method("launch"):
		proj.call("launch", dir, projectile_speed)

func _muzzle_position() -> Vector2:
	return muzzle.global_position if muzzle != null else global_position

func _has_line_of_sight(p: Player) -> bool:
	var q := PhysicsRayQueryParameters2D.create(_muzzle_position(), p.global_position, collision_mask)
	q.exclude = [get_rid(), p.get_rid()]
	return get_world_2d().direct_space_state.intersect_ray(q).is_empty()

func _on_died() -> void:
	_token += 1
	_firing = false

func _on_respawn() -> void:
	_token += 1
	_firing = false
	_cooldown = 1.0
	facing = start_facing
	_face_sprite(facing, sprite_faces_right)
	_play("idle")
