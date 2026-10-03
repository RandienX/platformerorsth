class_name Player
extends CharacterBody2D
## All speeds and accelerations are in "pixels per frame @ 60 Hz", so keep
## Project Settings > Physics > Common > Physics Ticks Per Second at 60.

signal jumped
signal landed
signal crouch_boost_released
signal state_changed(new_state: State)

enum State { GROUND, SLIDE, AIR, JUMP, crouch_boost, ATTACK }

# --- Ground physics ---------------------------------------------------------
@export_category("Physics")
@export_group("Ground")
@export var acceleration_speed := 0.15
@export var deceleration_speed := 0.6
@export var friction_speed := 0.25
@export var top_speed := 18.0
@export var max_ground_speed := 25.0
@export var slope_factor := 0.15
@export var roll_friction := 0.07
@export var roll_deceleration := 0.125
@export var roll_slope_up := 0.1
@export var roll_slope_down := 0.35
@export var slide_min_speed := 2.0
@export var fall_threshold := 3.5        ## below this speed steep slopes make you slip/fall
@export var slip_min_angle := 35.0       ## degrees
@export var control_lock_frames := 30
@export var hitbox_lock_frames := 150
@export var attack_lock_frames := 45
@export var dive_lock_frames := 10     ## frames; amount of time after landing when player can't attack 
@export var allow_slow_climb := false
@export var slide_start_angle := 30    ## degrees; holding down on a slope steeper than this starts a slide

@export_group("Walls Drag")
@export var steep_drag_start_angle := 45.0       ## degrees; drag begins past this angle
@export var steep_uphill_drag_min := 0.02        ## speed lost per frame at start angle
@export var steep_uphill_drag_max := 0.15         ## speed lost per frame at 90 degrees
@export var steep_friction := 0.005              ## mild friction on steep surfaces
# --- Air physics ------------------------------------------------------------
@export_group("Air")
@export var air_acceleration := 0.08
@export var gravity := 0.4
@export var jump_force := 16.0
@export var jump_release_speed := 8.0
@export var max_fall_speed := 30.0

# --- Slide/Attack --------------------------------------------------------------
@export_group("Boosts")
@export var crouch_boost_base_speed := 20.0
@export var crouch_boost_increment := 25.0    ## percent added to crouch boost speedup from value from crouch_boost_speed to max_charge per charge
@export var crouch_boost_max_charge := 45.0
@export var attack_boost := 15.0
@export var mini_attack_boost := 0.5

# --- Collision --------------------------------------------------------------
@export_group("BallCollision")
@export var stand_height_radius := 64.0
@export var ball_height_radius := 32.0
@export var width_radius := 16.0
@export var push_radius := 20.0
@export var step_size := 8.0                   ## max pixels moved per sub-step (anti-tunnelling)
@export var max_sensor_angle_diff := 30.0      ## deg: max gap between line angle and the closest surface normal
@export var max_angle_change := 75.0           ## deg: larger jumps count as "no floor"
@export var wall_climb_angle := 75.0           ## surfaces up to this angle are run onto, not treated as walls

@export_group("Debug")
@export var debug_draw := false
@export var debug_log := false                 ## prints WHY you stopped / left the ground / slipped

# --- Runtime state --------------------
var gsp := 0.0                  ## ground speed
var vel := Vector2.ZERO         ## air velocity
var ground_angle := 0.0         ## radians; 0 = flat, +ve = surface descends to the right
var floor_collider: Node2D = null
var platform_velocity := Vector2.ZERO
var grounded := false
var sliding := false
var attacking := false
var diving := false
var jumping := false
var crouch_boosting := false
var crouching := false
var looking_up := false
var facing := 1
var control_lock := 0
var hitbox_lock := 0
var attack_lock := 0
var crouch_boost_charge := 0.0
var state: State = State.AIR

var height_radius: float = 64.0
var direction := 0.0
var INPUT_DOWN := false
var INPUT_UP := false
var INPUT_ATTACK := false
var start_pos: Vector2

@export_category("Node References")
@export var sprite: AnimatedSprite2D
@export var camera: Camera2D
@export var collision: CollisionShape2D
@export var hitbox: CollisionShape2D
@export var hurtbox_slide: CollisionShape2D 
@export var hurtbox_attack: CollisionShape2D

@export_category("Other")
var cash: int = 0
var score: int = 0
@export var max_health: int = 3 
@export var camera_max_distance: float = 120.0
var health: int = 3

func _ready() -> void:
	height_radius = stand_height_radius
	start_pos = global_position
	Global.player = self

func _physics_process(delta: float) -> void:
	direction = signf(Input.get_axis("left", "right"))
	INPUT_DOWN = Input.is_action_pressed("down")
	INPUT_UP = Input.is_action_pressed("up")
	INPUT_ATTACK = Input.is_action_just_pressed("attack")
	var jump_pressed := Input.is_action_just_pressed("jump")
	
	platform_velocity = Vector2.ZERO
	if floor_collider:
		var parent = floor_collider.get_parent()
		if parent and parent.get_parent() is Path2D:
			var moving_platform = parent.get_parent() as Path2D
			if moving_platform.has_method("get_current_velocity"):
				platform_velocity = moving_platform.get_current_velocity()
				global_position += platform_velocity * delta
	
	if grounded:
		_ground_tick(jump_pressed)
	else:
		_air_tick()
	
	_update_camera(delta)
	_update_state()
	_update_visuals()
	if debug_draw:
		queue_redraw()

# =============================================================================
# GROUND
# =============================================================================
func _ground_tick(jump_pressed: bool) -> void:
	var locked := control_lock > 0
	if locked:
		control_lock -= 1
	var hitbox_disabled := hitbox_lock > 0
	if hitbox_disabled:
		hitbox_lock -= 1
	elif hitbox_lock == 0:
		hitbox.disabled = false
	var attack_disabled := attack_lock > 0
	if attack_disabled:
		attack_lock -= 1
	else:
		attacking = false
	if diving:
		diving = false
	
	var dir := 0.0 if locked else direction
	var angle_deg := absf(rad_to_deg(ground_angle))
	var steep_hold := INPUT_DOWN and angle_deg > slide_start_angle
	
	# CrouchBoost charging
	if crouch_boosting and not sliding:
		_crouch_boost_tick(jump_pressed)
		_move_on_ground()
		return
		
	crouching = INPUT_DOWN and absf(gsp) < 0.1 and not sliding
	looking_up = INPUT_UP and absf(gsp) < 0.1 and not sliding and not INPUT_DOWN
	
	# CrouchBoost start/jump
	if jump_pressed:
		if crouching:
			crouch_boosting = true
			crouching = false
			crouch_boost_charge = 0.0
			return
		elif not crouch_boosting and not crouching:
			_do_jump()
			return
	
	var sin_a := sin(ground_angle)
	var going_uphill := gsp != 0.0 and signf(gsp) != signf(sin_a)
	
	if not attacking and not crouching and not crouch_boosting and INPUT_ATTACK:
		attacking = true
		sliding = false
		print(sin_a)
		if sin_a != 0:
			if gsp < max_ground_speed:
				if going_uphill:
					gsp = clamp(gsp + (attack_boost * dir * ((1 - sin_a) if sin_a > 0 else (1 + (-1 - sin_a)))), -max_ground_speed, max_ground_speed)
				else:
					gsp = clamp(gsp + (attack_boost * dir * ((1 + sin_a) if sin_a > 0 else (1 + (-1 - sin_a)))), -max_ground_speed*1.5, max_ground_speed*1.5)
			else:
				if going_uphill:
					gsp += mini_attack_boost * dir * ((1 - sin_a) if sin_a < 0 else (1 - (-1 - sin_a)))
				else:
					gsp += mini_attack_boost * dir * ((1 + sin_a) if sin_a < 0 else (1 + (-1 - sin_a)))
		else:
			if gsp < max_ground_speed:
				gsp = clamp(gsp + (attack_boost * dir), -max_ground_speed, max_ground_speed)
			else:
				gsp += mini_attack_boost * dir
		attack_lock = attack_lock_frames
	if not attacking and not sliding and not crouching and not crouch_boosting and INPUT_DOWN and (absf(gsp) >= slide_min_speed or steep_hold):
		sliding = true
	
	# Slope factor
	if sliding:
		gsp += ((roll_slope_up if going_uphill else roll_slope_down) * sin_a + 0.01) * 1.5
	else:
		gsp += slope_factor * sin_a + 0.005
	
	var slipping := locked and angle_deg >= slip_min_angle
	
	# Input, deceleration, friction
	if not crouching and not crouch_boosting:
		if not sliding and not attacking:
			if dir != 0.0:
				facing = int(dir)
				if signf(gsp) == -dir:
					# Skidding
					gsp += dir * deceleration_speed
					if signf(gsp) != -dir:
						gsp = dir * 0.5
				elif dir * gsp < top_speed:
					gsp += dir * acceleration_speed
					if dir * gsp > top_speed:
						gsp = lerp(gsp, dir * top_speed, (gsp-top_speed) / 10)
					if dir * gsp > top_speed * 2:
						gsp = dir*top_speed
			elif not slipping:
				gsp -= minf(absf(gsp), friction_speed) * signf(gsp)
		else:
			if dir != 0.0 and signf(gsp) == -dir:
				gsp += dir * roll_deceleration
				if signf(gsp) != -dir:
					gsp = 0.0
			gsp -= minf(absf(gsp), roll_friction) * signf(gsp)
			if absf(gsp) < 0.5 and not steep_hold:
				sliding = false
	
	if not sliding:
		_apply_steep_drag(angle_deg, sin_a)
	
	if not locked and absf(gsp) < fall_threshold and angle_deg >= slip_min_angle:
		var steep_drag := _steep_uphill_drag_at_angle(angle_deg)
		var can_climb := (
			allow_slow_climb
			and dir * sin_a < 0.0
			and acceleration_speed > slope_factor * absf(sin_a) + steep_drag
		)
	
		if not can_climb:
			control_lock = control_lock_frames
			_dbg("slip: control locked %d frames (gsp %.2f, slope %.0f°)" % [control_lock_frames, gsp, angle_deg])
			if angle_deg >= 90.0:
				_leave_ground()
				return
	
	if not crouching and not crouch_boosting:
		_move_on_ground()
	
	_refresh_hitbox()

func _move_on_ground() -> void:
	var steps := maxi(1, ceili(absf(gsp) / step_size))
	var blocked := false
	for i in steps:
		if gsp != 0.0:
			var tangent := Vector2.RIGHT.rotated(ground_angle)
			global_position += tangent * (gsp / steps)
			if _wall_blocked(tangent * signf(gsp)):
				gsp = 0.0
				blocked = true
		if not _snap_to_floor():
			_leave_ground()
			return
		if blocked:
			break

func _crouch_boost_tick(jump_pressed: bool) -> void:
	gsp = 0.0
	crouch_boost_charge -= floorf(crouch_boost_charge / 0.125) / 256.0
	if jump_pressed:
		crouch_boost_charge = minf(crouch_boost_charge + (crouch_boost_max_charge - crouch_boost_charge) * crouch_boost_increment, crouch_boost_max_charge)
	if not INPUT_DOWN:
		crouch_boosting = false
		sliding = true
		gsp = (crouch_boost_base_speed + floorf(crouch_boost_charge) / 2.0) * facing
		crouch_boost_charge = 0.0
		_refresh_hitbox()
		crouch_boost_released.emit()

func _do_jump() -> void:
	vel = Vector2.RIGHT.rotated(ground_angle) * gsp + Vector2.UP.rotated(ground_angle) * jump_force
	vel += platform_velocity/100 #converting real velocity to my vel cuz i messed up a few days ago: 3.10.2026
	floor_collider = null
	grounded = false
	ground_angle = 0.0
	jumping = true
	crouching = false
	crouch_boosting = false
	sliding = false
	looking_up = false
	_refresh_hitbox()
	jumped.emit()

func _leave_ground() -> void:
	vel = Vector2.RIGHT.rotated(ground_angle) * gsp
	print(vel)
	vel += platform_velocity/100 #converting real velocity to my vel cuz i messed up a few days ago: 3.10.2026
	print(vel)
	floor_collider = null
	grounded = false
	ground_angle = 0.0
	crouching = false
	looking_up = false
	_refresh_hitbox()

func _snap_to_floor() -> bool:
	var reach := height_radius + minf(absf(gsp) + 4.0, 14.0)
	var f := _sense_floor(ground_angle, reach)
	if f.is_empty():
		floor_collider = null 
		return false
	
	floor_collider = f.get("collider") 
	var new_angle: float = f["angle"]
	var change := absf(rad_to_deg(angle_difference(ground_angle, new_angle)))
	if change > max_angle_change:
		return false
	ground_angle = new_angle
	_place_on(f)
	return true

# =============================================================================
# AIR
# =============================================================================
func _air_tick() -> void:
	if direction != 0.0:
		facing = int(direction)
		if direction < 0.0 and vel.x > -top_speed:
			vel.x = maxf(vel.x - air_acceleration, -top_speed)
		elif direction > 0.0 and vel.x < top_speed:
			vel.x = minf(vel.x + air_acceleration, top_speed)
	
	if jumping and vel.y < -jump_release_speed and not Input.is_action_pressed("jump"):
		vel.y = -jump_release_speed
	
	if vel.y < 0.0 and vel.y > -4.0 and absf(vel.x) >= 0.125:
		vel.x *= 0.96875
	
	if diving:
		sprite.rotation = clamp(vel.angle(), -PI/4, PI/4) #clamp to 45 degrees
	
	if INPUT_ATTACK and !grounded and !diving:
		diving = true
		if vel.y > 1:
			vel.x += (vel.y - 1 * 2) * direction
			vel.y = 3
		attack_lock = dive_lock_frames
	
	var steps := maxi(1, ceili(maxf(absf(vel.x), absf(vel.y)) / step_size))
	for i in steps:
		global_position += vel / steps
		
		if vel.x != 0.0 and _wall_blocked(Vector2(signf(vel.x), 0.0)):
			vel.x = 0.0
		
		if vel.y < 0.0 and _handle_ceiling():
			return
		
		var f := _sense_floor(0.0, height_radius)
		if not f.is_empty() and _should_land(f):
			_land(f)
			return
	
	vel.y = minf(vel.y + gravity, max_fall_speed)

## Land if falling, or if rising but moving INTO the surface we just touched.
func _should_land(f: Dictionary) -> bool:
	if vel.y >= 0.0:
		return true
	var a: float = f["angle"]
	return vel.dot(Vector2.UP.rotated(a)) < 0.0

func _land(f: Dictionary) -> void:
	floor_collider = f.get("collider")
	grounded = true
	jumping = false
	_refresh_hitbox()
	
	ground_angle = f["angle"]
	var deg := absf(rad_to_deg(ground_angle))
	var slope_sign := signf(sin(ground_angle))
	if vel.y < 0.0:
		gsp = vel.dot(Vector2.RIGHT.rotated(ground_angle))
	elif deg < 23.0:
		gsp = vel.x
	elif deg < 45.0:
		gsp = vel.x if absf(vel.x) > vel.y else vel.y * 0.5 * slope_sign
	else:
		gsp = vel.x if absf(vel.x) > vel.y else vel.y * slope_sign
	vel = Vector2.ZERO
	_place_on(f)
	landed.emit()

func _handle_ceiling() -> bool:
	var o := global_position
	var left := o + Vector2(-width_radius, 0.0)
	var right := o + Vector2(width_radius, 0.0)
	var ha := _ray(left, left + Vector2.UP * height_radius)
	var hb := _ray(right, right + Vector2.UP * height_radius)
	if ha.is_empty() and hb.is_empty():
		return false
	
	var da := INF
	var db := INF
	if not ha.is_empty():
		var pa: Vector2 = ha["position"]
		da = o.y - pa.y
	if not hb.is_empty():
		var pb: Vector2 = hb["position"]
		db = o.y - pb.y
	var n: Vector2 = ha["normal"] if da <= db else hb["normal"]
	
	global_position.y += height_radius - minf(da, db)
	
	if absf(n.x) > 0.7071 and n.y > 0.1:
		ground_angle = _angle_from_normal(n)
		gsp = vel.dot(Vector2.RIGHT.rotated(ground_angle))
		vel = Vector2.ZERO
		grounded = true
		jumping = false
		_refresh_hitbox()
		landed.emit()
		return true
	
	vel.y = 0.0
	return false

# =============================================================================
# SENSORS
# =============================================================================
func _ray(from: Vector2, to: Vector2) -> Dictionary:
	var q := PhysicsRayQueryParameters2D.create(from, to, collision_mask)
	q.hit_from_inside = false
	return get_world_2d().direct_space_state.intersect_ray(q)

## Two foot sensors cast "down" relative to `frame_angle`.
func _sense_floor(frame_angle: float, reach: float) -> Dictionary:
	var down := Vector2.DOWN.rotated(frame_angle)
	var side := Vector2.RIGHT.rotated(frame_angle)
	var o := global_position
	var ha := _ray(o - side * width_radius, o - side * width_radius + down * reach)
	var hb := _ray(o + side * width_radius, o + side * width_radius + down * reach)
	if ha.is_empty() and hb.is_empty():
		return {}
	var da := INF
	var db := INF
	var pa := Vector2.ZERO
	var pb := Vector2.ZERO
	if not ha.is_empty():
		pa = ha["position"]
		da = (pa - o).dot(down)
	if not hb.is_empty():
		pb = hb["position"]
		db = (pb - o).dot(down)
	var closest_point: Vector2 = pa if da <= db else pb
	var closest_normal: Vector2 = ha["normal"] if da <= db else hb["normal"]
	
	var closest_collider: Node2D = ha["collider"] if da <= db else hb["collider"]
	
	var angle := _angle_from_normal(closest_normal)
	if da < INF and db < INF:
		var line_angle := (pb - pa).angle()
		if absf(rad_to_deg(angle_difference(line_angle, angle))) <= max_sensor_angle_diff:
			angle = line_angle
			
	return {"point": closest_point, "angle": angle, "distance": minf(da, db), "collider": closest_collider}

## Wall sensor. Returns true if `dir` is blocked (and pushes us out of the wall).
func _wall_blocked(dir: Vector2) -> bool:
	var o := global_position
	var hit := _ray(o, o + dir * push_radius)
	if hit.is_empty():
		return false
	var n: Vector2 = hit["normal"]
	var up := Vector2.UP.rotated(ground_angle)
	
	var wall_angle := absf(rad_to_deg(n.angle_to(up)))
	if wall_angle <= wall_climb_angle:
		return false
	_dbg("wall hit: surface is %.0f° from ground normal (limit %.0f°)" % [wall_angle, wall_climb_angle])
	var p: Vector2 = hit["position"]
	global_position += dir * ((p - o).dot(dir) - push_radius)
	return true

## Move along the surface normal so the feet sit exactly on the floor.
func _place_on(f: Dictionary) -> void:
	var p: Vector2 = f["point"]
	var n := Vector2.UP.rotated(ground_angle)
	var dn := (global_position - p).dot(n)
	global_position += n * (height_radius - dn)

static func _angle_from_normal(n: Vector2) -> float:
	return atan2(n.x, -n.y)

# =============================================================================
# HELPERS
# =============================================================================
func _dbg(msg: String) -> void:
	if debug_log:
		print("[Player] ", msg)

func _steep_blend(angle_deg: float) -> float:
	if angle_deg <= steep_drag_start_angle:
		return 0.0
	
	var span := maxf(90.0 - steep_drag_start_angle, 0.001)
	return clampf((angle_deg - steep_drag_start_angle) / span, 0.0, 1.0)

func _steep_uphill_drag_at_angle(angle_deg: float) -> float:
	var t := _steep_blend(angle_deg)
	if t <= 0.0:
		return 0.0
	
	return steep_uphill_drag_min + (steep_uphill_drag_max - steep_uphill_drag_min) * t

func _apply_steep_drag(angle_deg: float, sin_a: float) -> void:
	var t := _steep_blend(angle_deg)
	if t <= 0.0 or gsp == 0.0:
		return
	
	var uphill := sin_a != 0.0 and signf(gsp) != signf(sin_a)
	
	if uphill:
		var drag := _steep_uphill_drag_at_angle(angle_deg)
		var before := gsp
		gsp = move_toward(gsp, 0.0, drag)
		
		if debug_log and absf(before) > absf(gsp):
			_dbg("steep drag: %.2f -> %.2f (%.0f°)" % [before, gsp, angle_deg])
	
	if steep_friction > 0.0:
		gsp = move_toward(gsp, 0.0, steep_friction * t)

func _refresh_hitbox() -> void:
	var crouch := sliding or crouch_boosting
	collision.shape.radius = ball_height_radius if crouch else stand_height_radius
	$Hitbox/CollisionShape2D.shape.radius = collision.shape.radius

func _update_state() -> void:
	var s: State
	if crouch_boosting:
		s = State.crouch_boost
	elif grounded:
		s = State.SLIDE if sliding else State.GROUND
		s = State.ATTACK if attacking else State.GROUND
	else:
		s = State.JUMP if (jumping or sliding) else State.AIR
	if s != state:
		state = s
		state_changed.emit(s)
		
	hurtbox_slide.disabled = false if sliding or diving else true
	hurtbox_attack.disabled = false if s == State.ATTACK else true
	
@onready var hp_bar := $CanvasLayer/UI/MarginContainer/VBoxContainer/HP
func _update_visuals() -> void:
	if sprite == null:
		return
	if "flip_h" in sprite:
		sprite.scale.x = -1 if facing < 0 else 1
	var target := ground_angle if (grounded and not crouch_boosting) else 0.0
	sprite.rotation = lerp_angle(sprite.rotation, target, 0.3)
	
	if (hp_bar.value - health) > 0.1:
		hp_bar.value = lerpf(hp_bar.value, health, (hp_bar.value-health) / 4)
	elif hp_bar.value != health:
		hp_bar.value = health
	
	if attacking and grounded:
		sprite.play("idle")
	elif diving and !grounded:
		sprite.play("crouch")
	elif sliding:
		sprite.play("slide")
	elif crouching or crouch_boosting:
		sprite.play("crouch")
	elif abs(gsp) > 0.1:
		sprite.play("run")
	elif vel.y > 0:
		sprite.play("jump")
	elif vel.y < 0:
		sprite.play("fall")
	else:
		sprite.play("idle")

func _update_camera(delta):
	if abs(vel) > Vector2.ZERO:
		var velocity_ratio = vel / max_ground_speed
		camera.position = camera.position.lerp(velocity_ratio * camera_max_distance, 5.0 * delta)

func _draw() -> void:
	if not debug_draw:
		return
	var side := Vector2.RIGHT.rotated(ground_angle)
	var down := Vector2.DOWN.rotated(ground_angle)
	for s: float in [-1.0, 1.0]:
		var a: Vector2 = side * s * width_radius
		draw_line(a, a + down * height_radius, Color.GREEN, 1.0)
	draw_line(Vector2.ZERO, side * float(facing) * push_radius, Color.RED, 1.0)
	draw_circle(Vector2.ZERO, 2.0, Color.YELLOW)

func _on_area_2d_area_entered(area: Area2D) -> void:
	if area.is_in_group("cash"):
		cash += 1
		score += 50
		area.queue_free()
	elif area.is_in_group("danger"):
		score -= 250
		player_hurt()
	elif area.is_in_group("checkpoint") and area.global_position != start_pos:
		score += 500
		health = max_health
		start_pos = area.global_position
		
func player_hurt():
	health -= 1
	grounded = false
	vel.x = min(vel.x/3, -15.0) if direction > 0 else max(vel.x/3, 15.0)
	vel.y = -5.0
	control_lock = 30
	hitbox_lock = hitbox_lock_frames
	hitbox.set_deferred("disabled", true)
	if health == 0:
		die()
	
func die():
	hitbox_lock = 180
	control_lock = 180
	await get_tree().create_timer(3).timeout
	Global.lives -= 1
	Global.respawn_enemies()
	health = max_health
	global_position = start_pos
