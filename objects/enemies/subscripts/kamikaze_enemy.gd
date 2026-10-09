extends FlyerEnemy

@export_category("Kamikaze Enemy")
@export_group("Explosion")
@export var kaboom_timer_seconds: float = 5.0
@export var kaboom_timer_fade: float = 1.0
@export var explosion_radius: int = 80
@export var one_shot: bool = false

@export_subgroup("Nodes")
@export var explosion_sprite: Sprite2D
@export var explosion_area: CollisionShape2D
var kaboom_time := 0.0

func on_enemy_ready():
	if explosion_area.shape is CircleShape2D:
		explosion_area.shape.radius = explosion_radius
	else: push_warning("WARNING: Enemy - ", name, " explosion area is not CircleShape2D")
	
	if !one_shot: explosion_area.add_to_group("danger") 
	else: explosion_area.add_to_group("death")
	
	explosion_area.disabled = true
	explosion_sprite.visible = false

func on_enemy_tick_start(delta: float):
	match mode:
		Mode.CHASE:
			if !dead:
				kaboom_time -= delta
		_:
			kaboom_time = kaboom_timer_seconds
	
	if kaboom_time < 0:
		explode()
		
func explode():
	explosion_area.disabled = false
	explosion_sprite.visible = true
	death_fade_time = kaboom_timer_fade
	die(self)
	await get_tree().create_timer(death_fade_time).timeout
	explosion_area.disabled = true
