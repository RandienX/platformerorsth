class_name Enemy
extends CharacterBody2D
## Base class for every enemy and breakable object.
##
## Make `hurt_area` bigger than `contact_area` and the player's attack can land before
## the enemy's touch damage does.
##
## Hook shot: with `hookable` on, `hurt_area` joins group "hookable" (removed on death,
## re-added on respawn), is put on `hook_layer`, and the player's hook detection range
## gets that layer in its mask. Nothing to set up by hand.
##
## Collision masks are synced automatically: at runtime the enemy adds the layers of the
## player's areas to its own masks. The player's areas only need a layer (not 0) and
## must be Monitorable.
##
## Subclasses override the virtual hooks (never _ready / _physics_process):
##   _enemy_ready()   _enemy_tick(delta)   _on_damaged()   _on_died()
##   _on_respawn()    _on_player_hurt(player)

signal damaged(enemy: Enemy)
signal died(enemy: Enemy)

@export_group("Combat")
@export var max_health := 1
@export var vulnerable := true             ## false = cannot be destroyed (spikes-like enemy)
@export var contact_damage := true         ## hurts the player on touch
@export var score_value := 100
@export var hit_cooldown_frames := 30      ## ignore further hits for a moment (multi-hit enemies)
@export var respawns := true               ## comes back when respawn() is called
@export var death_fade_time := 0.2

@export_group("Player Interaction")
@export var bounce_player := true          ## bounce the player when they hit us while airborne (dive attack)
@export var bounce_min := 6.0
@export var bounce_max := 14.0
@export var knockback_away := true         ## knock the player away from us instead of using their input direction
@export var knockback_speed := 15.0
@export var hurt_score_penalty := 250      ## same penalty your "danger" group applies
@export var hookable := true               ## the player's hook shot can target us
@export var damaged_by_hook_shot := false        ## the player's hook can kill us
@export_flags_2d_physics var hook_layer := 256   ## extra layer hurt_area sits on so the hook detection can see it

@export_group("Nodes")
@export var collision: CollisionShape2D
@export var hurt_area: Area2D              ## where the player's attacks hit us. Defaults to child "HurtArea"
@export var contact_area: Area2D           ## optional: where we hurt the player. Defaults to child "ContactArea", else hurt_area
@export var sprite: AnimatedSprite2D       ## defaults to child "AnimatedSprite2D"

var health := 1
var dead := false

var _spawn_position := Vector2.ZERO
var _hit_cooldown := 0
var _body_layer := 0
var _body_mask := 0
var _base_modulate := Color.WHITE
var _fx_tween: Tween
var _masks_synced := false

func _ready() -> void:
	add_to_group("enemies")
	health = max_health
	_spawn_position = global_position
	_body_layer = collision_layer
	_body_mask = collision_mask
	_base_modulate = modulate
	if hurt_area == null:
		hurt_area = get_node_or_null("HurtArea") as Area2D
	if contact_area == null:
		contact_area = get_node_or_null("ContactArea") as Area2D
	if sprite == null:
		sprite = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		
	if hurt_area != null:
		hurt_area.area_entered.connect(check_player_contact)
	_setup_hookable()
	_enemy_ready()

func _physics_process(delta: float) -> void:
	if dead:
		collision.disabled = true
		return
	if _hit_cooldown > 0:
		_hit_cooldown -= 1
	_enemy_tick(delta)

# =============================================================================
# VIRTUAL HOOKS
# =============================================================================
func _enemy_ready() -> void:
	pass

func _enemy_tick(_delta: float) -> void:
	pass

func _on_damaged() -> void:
	pass

func _on_died() -> void:
	pass

func _on_respawn() -> void:
	pass

func _on_player_hurt(_player: Player) -> void:
	pass

# =============================================================================
# HOOK SHOT TARGET
# =============================================================================
func _setup_hookable() -> void:
	if not hookable or hurt_area == null:
		return
	# The hook detection can only see areas that are monitorable AND on a non-zero layer.
	hurt_area.collision_layer |= hook_layer
	hurt_area.set_deferred("monitorable", true)
	_set_hookable(true)

## The player treats "still in group hookable" as "still there", so leaving the group
## on death is what lets a killed target not block the hook.
func _set_hookable(on: bool) -> void:
	if hurt_area == null or not hookable:
		return
	if on and not hurt_area.is_in_group("hookable"):
		hurt_area.add_to_group("hookable")
	elif not on and hurt_area.is_in_group("hookable"):
		hurt_area.remove_from_group("hookable")

# =============================================================================
# PLAYER CONTACT
# =============================================================================
func check_player_contact(area: Area2D) -> void:
	var p := Global.player as Player
	if p == null or p.health <= 0 or hurt_area == null or not hurt_area.monitoring and not dead:
		return
	
	# 1) The player's attack wins over touching us (even while we're in hit cooldown).
	if vulnerable and is_attack_area(p, area, damaged_by_hook_shot):
		if _hit_cooldown <= 0:
			var vel = p.vel
			_hit_by_player(p)
			p.set_deferred("vel", vel)
		return

	# 2) Otherwise touching us hurts the player.
	if contact_damage and _player_touching_us(p):
		if hurt_player(p, global_position, knockback_away, knockback_speed, hurt_score_penalty) and _hit_cooldown <= 0:
			_on_player_hurt(p)
	
func _player_touching_us(p: Player) -> bool:
	var area := contact_area if contact_area != null else hurt_area
	if not area.monitoring:
		return false
	var player_hitbox := owner_area(p.hitbox)
	if player_hitbox == null or is_attack_area(p, player_hitbox, damaged_by_hook_shot) or (player_hitbox == p.hook_shot_hurtbox and damaged_by_hook_shot):
		return false
	return area.overlaps_area(player_hitbox)

func _hit_by_player(p: Player) -> void:
	_hit_cooldown = hit_cooldown_frames
	if bounce_player:
		_bounce_player(p)
	take_damage(1, p)

func _bounce_player(p: Player) -> void:
	# The hook shot handles its own bounce / momentum after impact.
	if p.grounded or p.hook_phase != Player.HookPhase.NONE:
		return
	p.vel.y = -clampf(p.vel.y, bounce_min, bounce_max)

# --- helpers shared with projectiles ------------------------------------------
## The player's attack shapes (hurtbox_attack, hurtbox_slide, hook_shot_hurtbox).
static func attack_shapes(p: Player, dmg_by_hook_shot: bool = false) -> Array[CollisionShape2D]:
	var out: Array[CollisionShape2D] = []
	if p.hurtbox_attack != null:
		out.append(p.hurtbox_attack)
	if p.hurtbox_slide != null:
		out.append(p.hurtbox_slide)
	if p.hook_shot_hurtbox != null and dmg_by_hook_shot:
		out.append(p.hurtbox_slide)
	return out

## First Area2D at or above `node`.
static func owner_area(node: Node) -> Area2D:
	var n := node
	while n != null:
		if n is Area2D:
			return n as Area2D
		n = n.get_parent()
	return null

## True if `area` owns an attack shape that is currently enabled.
static func is_attack_area(p: Player, area: Area2D, dmg_by_hook: bool = false) -> bool:
	for s in attack_shapes(p, dmg_by_hook):
		if not s.disabled and owner_area(s) == area:
			return true
	return false

static func player_from_area(area: Node) -> Player:
	var n: Node = area
	for i in 3:
		if n == null:
			return null
		if n is Player:
			return n as Player
		n = n.get_parent()
	return null

## Hurts the player unless they're invulnerable/dead. Returns true if they were hurt.
static func hurt_player(p: Player, from: Vector2, knock_away := true, knock_speed := 15.0, score_penalty := 250) -> bool:
	if p == null or p.health <= 0 or p.hitbox_lock > 0:
		return false
	# Invulnerable for the whole hook shot (the hitbox disable is deferred a frame).
	if p.hook_phase != Player.HookPhase.NONE:
		return false
	p.score -= score_penalty
	p.player_hurt()
	if knock_away and p.health > 0:
		var side := signf(p.global_position.x - from.x)
		if side == 0.0:
			side = float(-p.facing)
		p.vel.x = side * knock_speed
	return true

# =============================================================================
# DAMAGE / DEATH / RESPAWN
# =============================================================================
func take_damage(amount := 1, source: Node = null) -> void:
	if dead:
		return
	health -= amount
	Global.player.hook_phase = Player.HookPhase.IMPACT
	if health <= 0:
		die(source)
	else:
		damaged.emit(self)
		_flash()
		_on_damaged()

func die(source: Node = null, fade: bool = true) -> void:
	if dead:
		return
	dead = true
	health = 0
	if source is Player:
		(source as Player).score += score_value
	_on_died()
	died.emit(self)
	_set_active(false)
	if fade:
		if _fx_tween:
			_fx_tween.kill()
		_fx_tween = create_tween()
		_fx_tween.tween_property(self, "modulate:a", 0.0, death_fade_time)
		_fx_tween.tween_callback(_hide_if_dead)
	return

func respawn() -> void:
	if dead and not respawns:
		return
	if _fx_tween:
		_fx_tween.kill()
	global_position = _spawn_position
	velocity = Vector2.ZERO
	health = max_health
	dead = false
	_hit_cooldown = 0
	_set_active(true)
	_on_respawn()

func _set_active(active: bool) -> void:
	collision_layer = _body_layer if active else 0
	collision_mask = _body_mask if active else 0
	for area in [hurt_area, contact_area]:
		if area != null:
			area.set_deferred("monitoring", active)
			area.set_deferred("monitorable", active)
	_set_hookable(active)
	if active:
		visible = true
		modulate = _base_modulate

func _hide_if_dead() -> void:
	if dead:
		visible = false

func _flash() -> void:
	if sprite == null:
		return
	sprite.modulate = Color(3.0, 3.0, 3.0)
	create_tween().tween_property(sprite, "modulate", Color.WHITE, 0.15)

# =============================================================================
# ANIM_SPRITE HELPERS
# =============================================================================
func _play(anim: StringName) -> void:
	if sprite != null and sprite.sprite_frames != null and sprite.sprite_frames.has_animation(anim) and sprite.animation != anim:
		sprite.play(anim)

func _face_sprite(dir: int, sprite_faces_right := true) -> void:
	if sprite != null and dir != 0:
		sprite.flip_h = (dir < 0) == sprite_faces_right
