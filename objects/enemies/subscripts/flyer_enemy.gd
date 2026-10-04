class_name FlyerEnemy
extends Enemy
## Enemy 2: hovers at its home position, chases the player once they come close,
## gives up (and flies home) when the player gets too far away.
## After hurting the player it recoils for a moment so it doesn't camp on top of them.

enum Mode { IDLE, CHASE, RETURN, RECOIL }

@export_group("Flyer")
@export var detect_radius := 500.0
@export var lose_radius := 800.0
@export var max_speed := 220.0             ## px / second
@export var acceleration := 600.0          ## px / second^2 (lower = floatier)
@export var target_offset := Vector2.ZERO  ## aim at player + this offset
@export var return_home := true
@export var recoil_time := 0.6
@export var collide_with_walls := true     ## false = flies through terrain
@export var sprite_faces_right := true

@export_group("Bobbing")
@export var bob_amplitude := 6.0
@export var bob_speed := 3.0

var mode: Mode = Mode.IDLE

var _home := Vector2.ZERO
var _recoil_timer := 0.0
var _recoil_dir := Vector2.ZERO
var _time := 0.0
var _sprite_y := 0.0

func _enemy_ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	_home = global_position
	if sprite != null:
		_sprite_y = sprite.position.y

func _enemy_tick(delta: float) -> void:
	var p := Global.player as Player
	var alive := p != null and p.health > 0
	var dist := INF
	if alive:
		dist = global_position.distance_to(p.global_position)

	var desired := Vector2.ZERO
	match mode:
		Mode.IDLE:
			if alive and dist <= detect_radius:
				mode = Mode.CHASE
		Mode.CHASE:
			if not alive or dist > lose_radius:
				mode = Mode.RETURN if return_home else Mode.IDLE
			else:
				desired = (p.global_position + target_offset - global_position).normalized() * max_speed
		Mode.RETURN:
			var to_home := _home - global_position
			if alive and dist <= detect_radius:
				mode = Mode.CHASE
			elif to_home.length() < 10.0:
				mode = Mode.IDLE
			else:
				desired = to_home.normalized() * minf(max_speed * 0.6, to_home.length() * 4.0)
		Mode.RECOIL:
			_recoil_timer -= delta
			desired = _recoil_dir * max_speed * 0.8
			if _recoil_timer <= 0.0:
				mode = Mode.CHASE if alive else Mode.RETURN

	velocity = velocity.move_toward(desired, acceleration * delta)
	if collide_with_walls:
		move_and_slide()
	else:
		global_position += velocity * delta

	if absf(velocity.x) > 10.0:
		_face_sprite(int(signf(velocity.x)), sprite_faces_right)

	_time += delta
	if sprite != null:
		sprite.position.y = _sprite_y + sin(_time * bob_speed) * bob_amplitude

func _on_player_hurt(p: Player) -> void:
	mode = Mode.RECOIL
	_recoil_timer = recoil_time
	_recoil_dir = (global_position - p.global_position).normalized()
	if _recoil_dir == Vector2.ZERO:
		_recoil_dir = Vector2.UP

func _on_respawn() -> void:
	mode = Mode.IDLE
	_recoil_timer = 0.0
