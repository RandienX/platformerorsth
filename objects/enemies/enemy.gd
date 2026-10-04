class_name Enemy
extends CharacterBody2D
## Base class for every enemy and breakable object.
##
## Combat is area based and does not depend on the player's state:
##   * the enemy is HIT when an ACTIVE attack area of the player (the Area2D that owns
##     Player.hurtbox_attack / Player.hurtbox_slide, while that shape is enabled)
##     overlaps `hurt_area`
##   * the player is HURT when the player's Hitbox area overlaps `contact_area`
##     (falls back to `hurt_area`), unless an attack is hitting us at the same time
##
## Make `hurt_area` bigger than `contact_area` and the player's attack can land before
## the enemy's touch damage does.
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

@export_group("Nodes")
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
	_enemy_ready()

func _physics_process(delta: float) -> void:
	if dead:
		return
	if _hit_cooldown > 0:
		_hit_cooldown -= 1
	_enemy_tick(delta)
	if not dead:
		_check_player_contact()

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
# PLAYER CONTACT
# =============================================================================
func _check_player_contact() -> void:
	var p := Global.player as Player
	if p == null or p.health <= 0 or hurt_area == null or not hurt_area.monitoring:
		return
	_sync_detection_masks(p)

	# 1) The player's attack wins over touching us (even while we're in hit cooldown).
	if vulnerable and _attack_hits_us(p):
		if _hit_cooldown <= 0:
			_hit_by_player(p)
		return

	# 2) Otherwise touching us hurts the player.
	if contact_damage and _player_touching_us(p):
		if hurt_player(p, global_position, knockback_away, knockback_speed, hurt_score_penalty) and _hit_cooldown <= 0:
			_on_player_hurt(p)

func _attack_hits_us(p: Player) -> bool:
	var has_attack_shapes := not attack_shapes(p).is_empty()
	for area in hurt_area.get_overlapping_areas():
		if player_from_area(area) != p:
			continue
		if has_attack_shapes:
			if is_attack_area(p, area):
				return true
	return false

func _player_touching_us(p: Player) -> bool:
	var area := contact_area if contact_area != null else hurt_area
	if not area.monitoring:
		return false
	for a in area.get_overlapping_areas():
		if player_from_area(a) == p and not is_attack_area(p, a):
			return true
	return false

func _hit_by_player(p: Player) -> void:
	_hit_cooldown = hit_cooldown_frames
	if bounce_player:
		_bounce_player(p)
	take_damage(1, p)

func _bounce_player(p: Player) -> void:
	if p.grounded:
		return
	if p.vel.y < 0.0:
		p.vel.y += 1.0
	else:
		p.vel.y = -clampf(p.vel.y, bounce_min, bounce_max)

## Adds the layers of the player's areas to our masks so no manual layer setup is needed.
func _sync_detection_masks(p: Player) -> void:
	if _masks_synced:
		return
	_masks_synced = true
	var contact := contact_area if contact_area != null else hurt_area
	var hear_body := contact == hurt_area or attack_shapes(p).is_empty()
	sync_mask(hurt_area, p, true, hear_body)
	if contact != hurt_area:
		sync_mask(contact, p, false, true)

# --- helpers shared with projectiles ------------------------------------------
## The player's attack shapes (Player.hurtbox_attack / Player.hurtbox_slide).
static func attack_shapes(p: Player) -> Array[CollisionShape2D]:
	var out: Array[CollisionShape2D] = []
	if p.hurtbox_attack != null:
		out.append(p.hurtbox_attack)
	if p.hurtbox_slide != null:
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
static func is_attack_area(p: Player, area: Area2D) -> bool:
	for s in attack_shapes(p):
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

## Makes `mine` able to detect the player's attack areas and/or Hitbox area.
static func sync_mask(mine: Area2D, p: Player, attacks := true, body := true) -> void:
	if mine == null or p == null:
		return
	if attacks:
		for s in attack_shapes(p):
			_listen_to(mine, owner_area(s))
	if body:
		_listen_to(mine, owner_area(p.hitbox))

static func _listen_to(mine: Area2D, theirs: Area2D) -> void:
	if theirs == null:
		return
	if theirs.collision_layer == 0:
		push_warning("Enemies can't detect '%s': its collision layer is empty. Give it a layer." % theirs.get_path())
		return
	if not theirs.monitorable:
		push_warning("Enemies can't detect '%s': Monitorable is off." % theirs.get_path())
	mine.collision_mask |= theirs.collision_layer

## Hurts the player unless they're invulnerable/dead. Returns true if they were hurt.
static func hurt_player(p: Player, from: Vector2, knock_away := true, knock_speed := 15.0, score_penalty := 250) -> bool:
	if p == null or p.health <= 0 or p.hitbox_lock > 0:
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
	if health <= 0:
		die(source)
	else:
		damaged.emit(self)
		_flash()
		_on_damaged()

func die(source: Node = null) -> void:
	if dead:
		return
	dead = true
	health = 0
	if source is Player:
		(source as Player).score += score_value
	_on_died()
	died.emit(self)
	_set_active(false)
	if _fx_tween:
		_fx_tween.kill()
	_fx_tween = create_tween()
	_fx_tween.tween_property(self, "modulate:a", 0.0, death_fade_time)
	_fx_tween.tween_callback(_hide_if_dead)

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
