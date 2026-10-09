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

@export_group("Nodes")
@export var hurt_area: Area2D              ## where the player's attacks hit us. Defaults to child "HurtArea"
@export var contact_area: Area2D           ## optional: where we hurt the player. Defaults to child "ContactArea", else hurt_area
var velocity := Vector2.ZERO

var _age := 0.0

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

	if _player_touching_us(Global.player):
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
			
func _player_touching_us(p: Player) -> bool:
	var area := contact_area if contact_area != null else hurt_area
	if not area:
		return false
	if not area.monitoring:
		return false
	var player_hitbox := Enemy.owner_area(p.hitbox)
	if player_hitbox == null or Enemy.is_attack_area(p, player_hitbox):
		return false
	return area.overlaps_area(player_hitbox)
	
func _on_body_entered(body: Node2D) -> void:
	if body is Player:
		return
	if body is Enemy or body.is_in_group("enemies"):
		return
	if destroy_on_world:
		queue_free()
