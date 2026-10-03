class_name EnemyProjectile
extends Area2D
## Bullet fired by ShooterEnemy. Root must be an Area2D with a CollisionShape2D.

@export var speed := 360.0                 ## px / second (ShooterEnemy overrides this)
@export var lifetime := 4.0                ## seconds
@export var shot_gravity := 0.0                 ## px / second^2, > 0 for lobbed shots
@export var destroy_on_world := true
@export var rotate_to_direction := true
@export var destroyed_by_attack := true    ## the player's attack hurtbox destroys it
@export var knockback_away := true
@export var knockback_speed := 15.0
@export var hurt_score_penalty := 250

var velocity := Vector2.ZERO

var _age := 0.0
var _synced := false

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func launch(direction: Vector2, speed_override := -1.0) -> void:
	if speed_override > 0.0:
		speed = speed_override
	velocity = direction.normalized() * speed
	if rotate_to_direction:
		rotation = velocity.angle()

func _physics_process(delta: float) -> void:
	velocity.y += shot_gravity * delta
	global_position += velocity * delta
	if rotate_to_direction and velocity != Vector2.ZERO:
		rotation = velocity.angle()

	_age += delta
	if _age >= lifetime:
		queue_free()
		return

	var player := Global.player as Player
	if not _synced and player != null:
		_synced = true
		Enemy.sync_mask(self, player, destroyed_by_attack, true)

	for area in get_overlapping_areas():
		var p := Enemy.player_from_area(area)
		if p == null:
			continue
		if Enemy.is_attack_area(p, area):
			if destroyed_by_attack:
				queue_free()
				return
			continue
		if Enemy.hurt_player(p, global_position, knockback_away, knockback_speed, hurt_score_penalty):
			queue_free()
			return

func _on_body_entered(body: Node2D) -> void:
	if body is Player:
		return
	if body is Enemy or body.is_in_group("enemies"):
		return
	if destroy_on_world:
		queue_free()
