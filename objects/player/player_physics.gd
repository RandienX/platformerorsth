class_name Player
extends CharacterBody2D
## All speeds and accelerations are in "pixels/frame @ 60 Hz"
## so keep Physics Ticks/s at 60.

signal jumped
signal landed
signal crouch_boost_released
signal state_changed(new_state: State)
signal finished_level(goal: Node2D)
signal player_death
signal player_hit                 ## took damage and survived (the killing blow is a death, not a hit)

enum State { GROUND, SLIDE, AIR, JUMP, crouch_boost, ATTACK, STOMP}

# --- Ground physics ---------------------------------------------------------
@export_category("Physics")
@export_group("Ground")
@export var acceleration_speed := 0.25
@export var deceleration_speed := 0.6
@export var friction_speed := 0.3
@export var top_speed := 18.0
@export var max_ground_speed := 20.0
@export var slope_factor := 0.2
@export var roll_friction := 0.15
@export var roll_deceleration := 0.06
@export var roll_slope_up := -0.02
@export var roll_slope_down := 0.3
@export var slide_min_speed := 2.0
@export var fall_threshold := 4.5        ## below this speed steep slopes make you slip/fall at slip_min_angle (2x at 180 degrees)
@export var slip_min_angle := 45.0       ## degrees
@export var control_lock_frames := 30
@export var hitbox_lock_frames := 90
@export var attack_lock_frames := 45
@export var dive_lock_frames := 10     ## frames; amount of time after landing when player can't attack 
@export var allow_slow_climb := false
@export var slide_start_angle := 30    ## degrees; holding down on a slope steeper than this starts a slide

@export_group("Walls Drag")
@export var steep_drag_start_angle := 45.0       ## degrees; drag begins past this angle
@export var steep_uphill_drag_min := 0.05        ## speed lost per frame at start angle
@export var steep_uphill_drag_max := 0.15         ## speed lost per frame at 90 degrees
@export var steep_friction := 0.05              ## mild friction on steep surfaces
# --- Air physics ------------------------------------------------------------
@export_group("Air")
@export var air_acceleration := 0.15
@export var gravity := 0.4
@export var jump_force := 16.0
@export var jump_release_speed := 8.0
@export var max_fall_speed := 45.0

# --- Slide/Attack --------------------------------------------------------------
@export_group("Boosts")
@export var crouch_boost_base_speed := 20.0
@export var crouch_boost_increment := 25.0    ## percent added to crouch boost speedup from value from crouch_boost_speed to max_charge per charge
@export var crouch_boost_max_charge := 62.5
@export var attack_boost := 0.75              ## percent of max_ground_speed - gsp added to gsp
@export var min_atk_boost := 6.0            ## minimal atk boost in gsp
@export var mini_attack_boost := 0.05         ## percent of max_ground_speed added to gsp over the limit
@export var max_dive_boost := 5.0
@export var stomp_fall_speed := 60.0

# --- Collision --------------------------------------------------------------
@export_group("Collision")
@export var stand_height_radius := 64.0
@export var ball_height_radius := 32.0
@export var width_radius := 16.0
@export var push_radius := 20.0
@export var step_size := 8.0                   ## max pixels moved per sub-step (anti-tunnelling)
@export var max_sensor_angle_diff := 35.0      ## deg: max gap between line angle and the closest surface normal
@export var max_angle_change := 45.0           ## deg: larger jumps count as "no floor"
@export var wall_climb_angle := 45.0           ## surfaces up to this angle are run onto, not treated as walls

@export_group("Moving Platforms")
@export var platform_momentum_keep := 1.0      ## fraction of the platform's motion you keep when you jump / run off it (1.0 = fully physical)
@export var max_platform_momentum := 30.0

@export_group("Squish")
@export var squish_enabled := true
@export var squish_tolerance := 0.75           ## fraction of the body that must still fit between two solids; below this you are crushed (lower = more forgiving, keep < 1)
@export var squish_grace_frames := 6           ## frames you must stay pinched before dying (filters one-frame blips)
@export var squish_from_static := false        ## false: only moving platforms / nodes in group "crusher" can squish you. true: ANY pinch kills (also kills you if you get stuck in the level)
@export var squish_escape_distance := 48.0     ## px: if a free spot exists this close you are shoved there instead of crushed (edge clipping)
@export var squish_escape_step := 3.0          ## px between escape tests (smaller = more precise, more queries)

@export_group("One-Way Platforms")
@export var one_way_enabled := true
@export_range(1, 32) var one_way_layer := 4    ## physics layer of the one-way tilemap. Don't use a layer MaskSetter swaps.
@export var one_way_drop_action := &"null"     ## optional input action to fall through a platform
@export var one_way_drop_frames := 8           ## frames one-way platforms are ignored after dropping through
@export var one_way_snap_pixels := 24.0        ## snap pixels to one way platform

@export_group("Debug")
@export var debug_draw := false
@export var debug_log := false                 ## prints WHY you stopped / left the ground / slipped

# --- Runtime state --------------------
var gsp := 0.0                  ## ground speed
var vel := Vector2.ZERO         ## air velocity
var ground_angle := 0.0         ## radians; 0 = flat, +ve = surface descends to the right
## What we are standing on. Setting it also chooses who carries us (see "Moving Platforms").
var floor_collider: Node2D = null:
	set(value):
		floor_collider = value
		_set_carrier(value)
## Motion the carrier gave us this tick, in px/frame (same units as vel and gsp).
var platform_velocity := Vector2.ZERO
var _carrier: Node2D = null
var _carrier_xform := Transform2D.IDENTITY
var grounded := false
var sliding := false
var attacking := false
var diving := false
var stomping := false
var jumping := false
var crouch_boosting := false
var crouching := false
var looking_up := false
var mid_hoot_shot := false
var facing := 1
var control_lock := 0
var hitbox_lock := 0
var attack_lock := 0
var crouch_boost_charge := 0.0
var state: State = State.AIR
var dead := false               ## true from the moment of death until respawn
var squished := false           ## crushed: physics frozen until die() respawns us
var _squish_frames := 0
var _squish_shape := RectangleShape2D.new()
var squish_base_scale := Vector2.ONE
var on_one_way := false         ## true while standing on a one-way platform
var _one_way_ignore := 0        ## frames left in which one-way platforms are ignored (drop-through)

var static_camera: bool = false
var static_camera_position: Vector2 = Vector2.ZERO
var static_camera_scale: Vector2 = Vector2(0.66, 0.66)
var cam_time: float = 0.0

var height_radius: float = 64.0
var direction := 0.0
var INPUT_DOWN := false
var INPUT_UP := false
var INPUT_ATTACK := false
var INPUT_JUMP := false
var start_pos: Vector2

@export_category("Node References")
@export var sprite: AnimatedSprite2D
@export var camera: Camera2D
@export var collision: CollisionShape2D
@export var hitbox: CollisionShape2D
@export var hurtbox_slide: CollisionShape2D 
@export var hurtbox_attack: CollisionShape2D
@export var hook_shot_detection_range: Area2D
@export var hook_shot_hurtbox: CollisionShape2D
@export var hook_line: Line2D
@export var hook_head: Sprite2D
@export var hook_head_area: Area2D

enum HookPhase { NONE, WAIT, SHOOT, PULL, IMPACT }
const HOOK_PULL_TIMEOUT := 75    ## frames before a pull that can't reach its target gives up

var hook_phase := HookPhase.NONE
var hook_target: Node2D = null
var hook_chain := false          ## true after a hook until we land: chained hooks skip the stop-and-wait
var hook_timer := 0.0
var hook_frames := 0             ## PULL: frames spent pulling. IMPACT: frames left
var hook_tip := Vector2.ZERO     ## world position of the hook head
var hook_pull_vel := Vector2.ZERO
var hook_miss_active := false
var hook_miss_dir := Vector2.RIGHT
var hook_miss_dist := 0.0
var hook_miss_returning := false

@export_category("Abilities")
@export_group("Hookshot")
@export var hook_shot_active: bool = true
@export var hook_shot_wait_timer: float = 0.2     ## wait time in seconds before hook shot
@export var hook_shot_impact_frame_timer: int = 20 ## await frames upon impact
@export var hook_shot_speed := 64.0               ## px/frame the hook tip travels
@export var hook_shot_pull_speed := 32.0          ## px/frame the player is pulled toward the target
@export var hook_shot_miss_length := 400.0        ## px a target-less hook flies out before retracting
@export var hook_shot_momentum_keep := 1.2        
@export var hook_shot_bounce_factor := 0.5        ## bounce speed as a fraction of pull speed
@export var hook_shot_bounce_up := 6.0            ## small hop when bouncing
@export var hook_shot_chain_texture: Texture2D    ## tiled along the line
@export var hook_shot_head_texture: Texture2D     ## drawn at the tip
@export_flags_2d_physics var hook_shot_head_layer := 128   ## layer of the tip's Area2D
@export_flags_2d_physics var hook_target_layer := 256      ## hook targetts layer
@export_flags_2d_physics var hook_shot_los_mask := 3

@export_group("Camera")
@export var camera_max_distance: float = 180.0   ## px: max look-ahead at full speed
@export var camera_max_scale: float = 0.6        ## zoom at full speed (smaller = more zoomed out)
@export var camera_base_zoom: float = 0.6       ## zoom when standing still
@export var camera_lookahead_start_speed := 10.0  ## px/frame: below this the camera stays centred on the player
@export var camera_full_speed := 40.0            ## px/frame: look-ahead and zoom-out reach their maximum here
@export var camera_vertical_factor := 0.6        ## vertical look-ahead relative to horizontal
@export var camera_velocity_smoothing := 14.0     ## how fast the camera's idea of your velocity follows the real one (higher = snappier)
@export var camera_offset_smoothing := 6.0       ## how fast the camera slides to the look-ahead position
@export var camera_zoom_smoothing := 1.0         ## how fast the camera zooms in/out
@export var camera_static_min_time := 1.0        ## seconds: shortest allowed cam_trigger transition (so a trigger with cam_move_time 0 still glides)
@export var camera_teleport_threshold := 600.0   ## px moved in one tick that counts as a teleport (not speed)
 
var _measured_vel := Vector2.ZERO   ## real movement of the last physics tick, px/frame
var _prev_physics_pos := Vector2.ZERO
var _cam_vel := Vector2.ZERO        ## smoothed velocity the camera reacts to
var _cam_offset := Vector2.ZERO     ## smoothed look-ahead, world px
var _cam_zoom := 0.66               ## smoothed dynamic zoom
var _cam_center := Vector2.ZERO     ## where the camera is looking this frame (world)
var _cam_start := Vector2.ZERO      ## where the camera was when the last transition began
var _cam_start_zoom := Vector2.ONE
var _cam_t := 1.0                   ## linear transition progress, 0..1 (1 = arrived)
var _interpolated := false          ## project has physics interpolation on

@export_category("Other")
var cash: int = 0
var score: int = 0
var defeats: int = 0

var level_finish = false
var was_damaged = false

@export var max_health: int = 3 
var health: int = 3

func _ready() -> void:
	height_radius = stand_height_radius
	start_pos = global_position
	Global.player = self
	
	_prev_physics_pos = global_position
	_cam_zoom = camera_base_zoom
	if camera:
		# The camera is driven only through offset/zoom (neither is part of the node's
		# transform, so physics interpolation keeps working), and smoothed by us
		# instead of Camera2D's built-in smoothing, which would double up and add lag.
		camera.position = Vector2.ZERO
		camera.position_smoothing_enabled = false
		camera.offset = Vector2.ZERO
		camera.zoom = Vector2(_cam_zoom, _cam_zoom)
	
	if hook_shot_detection_range:
		hook_shot_detection_range.monitoring = true
		hook_shot_detection_range.collision_mask |= hook_target_layer

var toggle_ui := false
func _process(delta: float) -> void:
	_update_camera(delta)

func _input(_event: InputEvent) -> void:
	if Input.is_action_just_pressed("see_ui"):
		toggle_ui = !toggle_ui
		$CanvasLayer/UI/MarginContainer/VBoxContainer/Time.visible = toggle_ui
		$CanvasLayer/UI/MarginContainer/VBoxContainer/Score.visible = toggle_ui
		$CanvasLayer/UI/MarginContainer/VBoxContainer/Cash.visible = toggle_ui

func _physics_process(_delta: float) -> void:
	_track_motion()
	if squished:
		_ride_carrier()
		_update_state()
		hp_bar.value = health
		return
	
	if _one_way_ignore > 0:
		_one_way_ignore -= 1
	
	direction = signf(Input.get_axis("left", "right"))
	INPUT_DOWN = Input.is_action_pressed("down")
	INPUT_UP = Input.is_action_pressed("up")
	INPUT_ATTACK = Input.is_action_just_pressed("attack")
	INPUT_JUMP = Input.is_action_just_pressed("jump")
	
	_ride_carrier()   # move with whatever we stand on, before anything else this tick
	_resolve_walls()
	
	if level_finish:
		return
	
	if grounded:
		hook_chain = false
	
	if hook_phase != HookPhase.NONE:
		_hook_tick()
	elif grounded:
		_ground_tick(INPUT_JUMP)
	else:
		_air_tick()
	_hook_miss_tick()
	
	_check_squish()
	_update_state()
	_update_visuals()
	if debug_draw:
		queue_redraw()

# =============================================================================
# GROUND
# =============================================================================
#region Ground Movement
func _ground_tick(jump_pressed: bool) -> void:
	if on_one_way and not crouch_boosting and _drop_pressed():
		_one_way_drop()
		return
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
	if diving or stomping:
		diving = false
		if stomping and INPUT_DOWN:
			sliding = true
		stomping = false
	
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
	
	# Attack Logic
	if not attacking and not crouching and not crouch_boosting and INPUT_ATTACK:
		attacking = true
		sliding = false
		
		if direction != 0:
			var boost_type = attack_boost if gsp < max_ground_speed else mini_attack_boost
			var boost_amount = ((max_ground_speed - abs(gsp)) if boost_type == attack_boost else max_ground_speed) * boost_type
			if sin_a != 0:
				
				var bonus = max(boost_amount, min_atk_boost if boost_type == attack_boost else 0.0) * (direction + sin_a)
				print(boost_amount, "    ", bonus)
				if going_uphill:
					gsp = bonus * 1.5 + gsp if sign(direction) == sign(gsp) else max_ground_speed * attack_boost * (direction + sin_a)
				else:
					gsp = bonus * 0.86 + gsp if sign(direction) == sign(gsp) else max_ground_speed * attack_boost * (direction + sin_a)
			else:
				gsp = max(boost_amount, min_atk_boost if boost_type == attack_boost else 0.0) * direction + gsp if sign(direction) == sign(gsp) else max_ground_speed * attack_boost * direction
		attack_lock = attack_lock_frames
	
	if not attacking and not sliding and not crouching and not crouch_boosting and INPUT_DOWN and (absf(gsp) >= slide_min_speed or steep_hold):
		sliding = true
	
	# Slope factor
	if sliding:
		gsp += ((roll_slope_up if going_uphill else roll_slope_down) * sin_a + 0.01) * 1.2
	elif crouching and angle_deg < slip_min_angle: #crouch jitter fix
		gsp = 0.0
	else:
		gsp += slope_factor * sin_a + 0.005
	
	var slipping := locked and angle_deg >= slip_min_angle
	
	# Input, deceleration, friction
	if not crouching and not crouch_boosting and not attacking:
		if not sliding:
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
						gsp = lerp(gsp, dir * top_speed, (gsp/top_speed) / 10)
					elif dir * gsp > top_speed * 2:
						gsp = dir*top_speed*2
			elif not slipping:
				gsp -= minf(absf(gsp), friction_speed) * signf(gsp)
		else:
			if dir != 0.0 and signf(gsp) == -dir:
				gsp += dir * roll_deceleration
				if signf(gsp) != -dir:
					gsp = 0.0
			gsp -= minf(absf(gsp), roll_friction) * signf(gsp)
			if (absf(gsp) < 0.5 and not steep_hold) or not INPUT_DOWN:
				sliding = false
	
	if not sliding:
		_apply_steep_drag(angle_deg, sin_a)
	
	if not locked and absf(gsp) < fall_threshold and angle_deg >= slip_min_angle:
		var steep_drag := _steep_uphill_drag_at_angle(angle_deg)
		var can_climb := (allow_slow_climb and dir * sin_a < 0.0 and acceleration_speed > slope_factor * absf(sin_a) + steep_drag)
	
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
		#sliding = true
		gsp = (crouch_boost_base_speed + floorf(crouch_boost_charge) / 2.0) * facing
		crouch_boost_charge = 0.0
		_refresh_hitbox()
		crouch_boost_released.emit()

func _do_jump() -> void:
	vel = Vector2.RIGHT.rotated(ground_angle) * gsp + Vector2.UP.rotated(ground_angle) * jump_force
	vel += platform_velocity * platform_momentum_keep
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
	vel = Vector2.RIGHT.rotated(ground_angle) * gsp * 0.75
	vel += platform_velocity * platform_momentum_keep
	floor_collider = null
	grounded = false
	ground_angle = 0.0
	crouching = false
	looking_up = false
	_refresh_hitbox()

func _snap_to_floor() -> bool:
	var reach := height_radius + minf(absf(gsp) + 4.0, 14.0)
	var f := _sense_floor_ow(ground_angle, reach)
	if f.is_empty():
		floor_collider = null 
		on_one_way = false
		return false
	
	on_one_way = f.get("one_way", false)
	floor_collider = f.get("collider") 
	var new_angle: float = f["angle"]
	var change := absf(rad_to_deg(angle_difference(ground_angle, new_angle)))
	if change > max_angle_change:
		return false
	ground_angle = new_angle
	_place_on(f)
	return true
#endregion
# =============================================================================
# AIR
# =============================================================================
#region Air Movement
var hook_shot_started := false
func _air_tick() -> void:
	on_one_way = false
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
		sprite.rotation = clamp(Vector2(abs(vel.x), vel.y).angle() * direction, -PI/4, PI/4) #clamp to 45 degrees
	if stomping:
		sprite.rotation = PI/2 if facing > 0 else -PI/2
	
	if INPUT_ATTACK and INPUT_DOWN and !grounded and !stomping:
		stomping = true
		vel.x = 0
		vel.y = stomp_fall_speed
	
	if INPUT_ATTACK and !grounded and !diving and !stomping and !INPUT_DOWN:
		diving = true
		if sign(direction) == sign(vel.x):
			vel.x += clampf(abs(min((vel.y + 1), -max_dive_boost/2) * 2), 0, max_dive_boost) * direction
			vel.y -= 3
		else:
			if vel.y < 1:
				vel.x = clampf(abs(min((vel.y + 1), -max_dive_boost/2) * 2), 0, max_dive_boost) * direction
			else:
				vel.x = max_dive_boost * direction
			vel.y -= 3
			
			
		attack_lock = dive_lock_frames
		
	if INPUT_JUMP and !diving and !stomping and !grounded and hook_shot_active and not dead:
		if _hook_try_start():
			return
	
	var steps := maxi(1, ceili(maxf(absf(vel.x), absf(vel.y)) / step_size))
	for i in steps:
		var prev_feet := global_position + Vector2.DOWN * height_radius
		global_position += vel / steps
		
		if vel.x != 0.0 and _wall_blocked(Vector2(signf(vel.x), 0.0)):
			vel.x = 0.0
		
		if vel.y < 0.0 and _handle_ceiling():
			return
		
		var f := _sense_floor_ow(0.0, height_radius, prev_feet)
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
	on_one_way = f.get("one_way", false)
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
		gsp = clampf(vel.dot(Vector2.RIGHT.rotated(ground_angle)), -max_ground_speed, max_ground_speed)
		vel = Vector2.ZERO
		grounded = true
		jumping = false
		_refresh_hitbox()
		landed.emit()
		return true
	
	vel.y = 0.0
	return false
#endregion
# =============================================================================
# SENSORS
# =============================================================================
#region Sensors
## `mask` < 0 means "use the player's collision_mask" (whatever MaskSetter last left it as).
func _ray(from: Vector2, to: Vector2, mask: int = -1) -> Dictionary:
	var q := PhysicsRayQueryParameters2D.create(from, to, collision_mask if mask < 0 else mask)
	q.hit_from_inside = false
	return get_world_2d().direct_space_state.intersect_ray(q)

## Two foot sensors cast "down" relative to `frame_angle`.
func _sense_floor(frame_angle: float, reach: float, mask: int = -1) -> Dictionary:
	var down := Vector2.DOWN.rotated(frame_angle)
	var side := Vector2.RIGHT.rotated(frame_angle)
	var o := global_position
	var ha := _ray(o - side * width_radius, o - side * width_radius + down * reach, mask)
	var hb := _ray(o + side * width_radius, o + side * width_radius + down * reach, mask)
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

## --- One-way platforms ------------------------------------------------------
## The one-way layer is NEVER written into collision_mask (MaskSetter owns that
## value). Instead the floor sensors do a second query against only that layer,
## and the result is used or ignored depending on the situation. Walls, ceiling,
## hook and squish sensors keep using collision_mask, so they can't see it.
func _one_way_mask() -> int:
	return 1 << (one_way_layer - 1)

## Floor sensing = solid floor (collision_mask) + one-way floor, whichever is closer.
## `prev_feet` is the foot position before this move when airborne; leave it
## as Vector2.INF when grounded. Adds "one_way": true to the result when it won.
func _sense_floor_ow(frame_angle: float, reach: float, prev_feet := Vector2.INF) -> Dictionary:
	var solid := _sense_floor(frame_angle, reach)
	if not one_way_enabled or _one_way_ignore > 0 and ground_angle == 0:
		return solid
	var ow := _sense_floor(frame_angle, reach, _one_way_mask())
	if ow.is_empty() or not _one_way_accepts(ow, prev_feet):
		return solid
	if not solid.is_empty() and float(solid["distance"]) <= float(ow["distance"]):
		return solid
	ow["one_way"] = true
	return ow

func _one_way_accepts(f: Dictionary, prev_feet: Vector2) -> bool:
	var a: float = f["angle"]
	if prev_feet != Vector2.INF:
		# Airborne
		var n := Vector2.UP.rotated(a)
		return vel.y >= 0.0 and (prev_feet - (f["point"] as Vector2)).dot(n) >= -maxf(one_way_snap_pixels, 1.0)
	# Grounded
	var tol := maxf(minf(absf(gsp) + 5.0, 14.0), one_way_snap_pixels)
	return float(f["distance"]) >= height_radius - tol

func _drop_pressed() -> bool:
	return InputMap.has_action(one_way_drop_action) and Input.is_action_just_pressed(one_way_drop_action)

func _one_way_drop() -> void:
	_one_way_ignore = one_way_drop_frames
	_leave_ground()
	vel.y = maxf(vel.y, 2.0)

## Moves with a platform in small sub-steps, running the wall sensors after each
## one, so a platform can't drag the player into or through geometry.
func _carry_with_platform(carry: Vector2) -> void:
	if carry == Vector2.ZERO:
		return
	var steps := maxi(1, ceili(carry.length() / step_size))
	var step := carry / steps
	for i in steps:
		global_position += step
		_resolve_walls()

## Checks BOTH sides every frame, not just the direction of travel. Anything that
## pushes the player (platforms, knockback) is caught even when gsp / vel.x is 0.
func _resolve_walls() -> void:
	var side := Vector2.RIGHT.rotated(ground_angle if grounded else 0.0)
	_wall_blocked(side)
	_wall_blocked(-side)

## Returns the ray hit if `dir` is blocked by something that counts as a wall
## (not a runnable slope), else {}. Adds "wall_angle" to the hit for debugging.
func _wall_hit(dir: Vector2) -> Dictionary:
	var o := global_position
	var hit := _ray(o, o + dir * push_radius)
	if hit.is_empty():
		return {}
	var n: Vector2 = hit["normal"]
	var up := Vector2.UP.rotated(ground_angle if grounded else 0.0)
	var wall_angle := absf(rad_to_deg(n.angle_to(up)))
	if wall_angle <= wall_climb_angle:
		return {}
	hit["wall_angle"] = wall_angle
	return hit

## Wall sensor. Returns true if `dir` is blocked (and pushes us out of the wall).
func _wall_blocked(dir: Vector2) -> bool:
	var hit := _wall_hit(dir)
	if hit.is_empty():
		return false
	_dbg("wall hit: surface is %.0f° from ground normal (limit %.0f°)" % [hit["wall_angle"], wall_climb_angle])
	var o := global_position
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
#endregion
# =============================================================================
# MOVING PLATFORMS
# =============================================================================
#region Moving Platforms
## "Virtual parenting": whatever we stand on (floor_collider) becomes our carrier. Each tick we
## measure how far the carrier's transform moved since the last tick and apply that same change
## to the player. It is what reparenting would do, minus the side effects of leaving the tree
## (the Hitbox area re-fires area_entered, and a rotating PathFollow2D would spin the player).
##
## Only (transform_now * transform_before.inverse()) is ever applied, so the sum of all carries
## equals the platform's real displacement no matter WHEN it moved (idle frame, physics frame,
## before or after us). No velocity estimation, so no jitter and no double/zero carry frames.

func _set_carrier(c: Node2D) -> void:
	if c == _carrier:
		return
	_carrier = c
	_carrier_xform = c.global_transform if c != null else Transform2D.IDENTITY   # re-baseline: no carry on the switch frame

func _ride_carrier() -> void:
	platform_velocity = Vector2.ZERO
	if _carrier == null:
		return
	if not is_instance_valid(_carrier) or not _carrier.is_inside_tree():
		_carrier = null
		return
	var now := _carrier.global_transform
	if now == _carrier_xform:
		return                                   # static floor or a platform that is standing still
	var moved := now * _carrier_xform.affine_inverse()
	_carrier_xform = now
	var carry := moved * global_position - global_position
	platform_velocity = carry.limit_length(max_platform_momentum)
	if squished:
		global_position += carry                 # the corpse stays pinned in whatever crushed it
		return
	if grounded:
		ground_angle = wrapf(ground_angle + moved.get_rotation(), -PI, PI)   # tilting/spinning platforms
	_carry_with_platform(carry)
#endregion
# =============================================================================
# SQUISH
# =============================================================================
#region Squish
## Crushed = "the body overlaps a solid that is allowed to squish us, and there is no free spot
## nearby to be shoved to". Runs once per tick, after all movement and wall-pushing.
##
##   1. Probe: a box shaped like the body (push_radius x height_radius, rotated with the surface,
##      shrunk to squish_tolerance) is tested against the world with a real shape query.
##   2. Overlap with a mover (moving platform / group "crusher" / anything if squish_from_static),
##      or overlap with anything while we are riding a mover into it (lift into a ceiling).
##   3. Look for the nearest free spot within squish_escape_distance. Found: shove the player
##      there (edge clipping, getting pushed aside). Not found: pinched.
##   4. Pinched for squish_grace_frames in a row = dead.

const _ESCAPE_DIRS := [
	Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0),
	Vector2(-0.7071, -0.7071), Vector2(0.7071, -0.7071), Vector2(-0.7071, 0.7071), Vector2(0.7071, 0.7071),
]

func _check_squish() -> void:
	if not squish_enabled or dead:
		_squish_frames = 0
		return
	var angle := ground_angle if grounded else 0.0
	var hits := _squish_overlaps(global_position, angle)
	if hits.is_empty():
		_squish_frames = 0
		return

	var culprit: Object = null
	for h in hits:
		if squish_from_static or _is_moving_solid(h["collider"]):
			culprit = h["collider"]
			break
	if culprit == null and is_instance_valid(_carrier) and _is_moving_solid(_carrier):
		culprit = _carrier                       # carried into something solid
	if culprit == null:
		_squish_frames = 0                       # only static geometry: not our business
		return

	var escape = _squish_find_escape(angle)      # Vector2, or null when boxed in
	if escape != null:
		global_position = escape
		_squish_frames = 0
		return

	_squish_frames += 1
	_dbg("pinched %d/%d by %s" % [_squish_frames, squish_grace_frames, culprit])
	if _squish_frames >= squish_grace_frames:
		_squish_death(culprit)

## Everything the body box overlaps at `at`.
func _squish_overlaps(at: Vector2, angle: float) -> Array[Dictionary]:
	_squish_shape.size = Vector2(push_radius, height_radius) * 2.0 * minf(squish_tolerance, 0.95)
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = _squish_shape
	q.transform = Transform2D(angle, at)
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_2d().direct_space_state.intersect_shape(q, 8)

## Closest position (smallest shove first) where the body box overlaps nothing, or null.
func _squish_find_escape(angle: float):
	var step := maxf(squish_escape_step, 0.5)
	var d := step
	while d <= squish_escape_distance:
		for dir in _ESCAPE_DIRS:
			var p: Vector2 = global_position + dir * d
			if _squish_overlaps(p, angle).is_empty():
				return p
		d += step
	return null

## Moving platform (group "moving_platform", set by moving_platform.gd) or anything in group
## "crusher". The group may be on the collider itself or on one of its parents.
func _is_moving_solid(collider: Object) -> bool:
	var node := collider as Node
	for i in 4:
		if node == null or not is_instance_valid(node):
			return false
		if node.is_in_group("crusher") or node.is_in_group("moving_platform"):
			return true
		node = node.get_parent()
	return false

## Free distance from the body centre along `dir` (0 when the centre is already inside a solid).
func _squish_room(dir: Vector2, limit: float) -> float:
	var q := PhysicsRayQueryParameters2D.create(global_position, global_position + dir * limit, collision_mask)
	q.hit_from_inside = true
	q.exclude = [get_rid()]
	var hit := get_world_2d().direct_space_state.intersect_ray(q)
	return limit if hit.is_empty() else global_position.distance_to(hit["position"])

## Which way did the squeeze come from? Compare the remaining room on each axis with the body size.
func _squish_is_horizontal() -> bool:
	var a := ground_angle if grounded else 0.0
	var side := Vector2.RIGHT.rotated(a)
	var up := Vector2.UP.rotated(a)
	var gap_h := _squish_room(-side, 256.0) + _squish_room(side, 256.0)
	var gap_v := _squish_room(up, 256.0) + _squish_room(-up, 256.0)
	return gap_h / (2.0 * push_radius) < gap_v / (2.0 * height_radius)

func _squish_death(culprit: Object) -> void:
	if dead:
		return
	var horizontal := _squish_is_horizontal()
	_dbg("squished (%s) by %s" % ["from the sides" if horizontal else "top/bottom", culprit])
	_squish_frames = 0
	_hook_cancel()
	health = 0
	Global.lives -= 1
	squished = true
	gsp = 0.0
	vel = Vector2.ZERO
	grounded = false
	floor_collider = null
	platform_velocity = Vector2.ZERO
	sliding = false
	attacking = false
	diving = false
	stomping = false
	jumping = false
	crouching = false
	crouch_boosting = false
	looking_up = false
	hitbox.set_deferred("disabled", true)
	if culprit is Node2D and is_instance_valid(culprit):
		_set_carrier(culprit as Node2D)          # the flattened body rides along with what crushed it

	# Flatten the sprite along the squeeze axis.
	if sprite:
		squish_base_scale = sprite.scale
		var flat := Vector2(0.2, 1.25) if horizontal else Vector2(1.25, 0.2)
		create_tween().tween_property(sprite, "scale", squish_base_scale * flat, 0.08)
	die()
#endregion
# =============================================================================
# HOOK SHOT (homing_attack)
# =============================================================================
#region Hoot Shot
## Closest hookable inside the detection range with a clear line of sight.
func _hook_find_closest_target() -> Node2D:
	if hook_shot_detection_range == null:
		return null
	
	var best: Node2D = null
	var best_d := INF
	
	for area in hook_shot_detection_range.get_overlapping_areas():
		if not area.is_in_group("hookable"):
			continue
		
		if area.is_queued_for_deletion():
			continue
		
		var d := global_position.distance_squared_to(area.global_position)
		
		if d >= best_d:
			continue
		
		var clear := _hook_has_clear_path(area)
		if not clear:
			continue
		
		best = area
		best_d = d
	
	return best

func _hook_has_clear_path(target: Node2D) -> bool:
	var q := PhysicsRayQueryParameters2D.create(
		global_position,
		target.global_position,
		hook_shot_los_mask
	)
	
	q.hit_from_inside = false
	q.exclude = [get_rid()]
	
	var target_root := target.get_parent()
	if target_root is CollisionObject2D:
		q.exclude.append(target_root.get_rid())
	
	var hit := get_world_2d().direct_space_state.intersect_ray(q)
	
	if hit.is_empty():
		return true
	
	return false


func _hook_target_ok() -> bool:
	return is_instance_valid(hook_target) and hook_target.is_in_group("hookable") \
			and not hook_target.is_queued_for_deletion()

## Called from _air_tick on a jump press. Returns true if a TARGETED hook began
## (the caller then skips the rest of the air tick). With no target it fires a
## visual-only hook along the movement direction and the player keeps flying.
func _hook_try_start() -> bool:
	var target := _hook_find_closest_target()
	if target == null:
		_hook_start_miss()
		return false
	hook_miss_active = false
	_hook_show(false)
	hook_target = target
	jumping = false
	hitbox.set_deferred("disabled", true)
	var to_target := target.global_position - global_position
	if absf(to_target.x) > 1.0:
		facing = int(signf(to_target.x))
	if hook_chain:
		_hook_begin_shoot()
	else:
		hook_phase = HookPhase.WAIT
		hook_timer = hook_shot_wait_timer
		vel = Vector2.ZERO
	return true

func _hook_begin_shoot() -> void:
	hook_phase = HookPhase.SHOOT
	hook_tip = global_position
	_hook_show(true)
	_hook_draw()

func _hook_tick() -> void:
	match hook_phase:
		HookPhase.WAIT:
			vel = Vector2.ZERO
			hook_timer -= get_physics_process_delta_time()
			if hook_timer <= 0.0:
				hook_target = _hook_find_closest_target()
				if hook_target == null:
					_hook_cancel()
					_hook_start_miss()
				else:
					_hook_begin_shoot()
		
		HookPhase.SHOOT:
			if not _hook_target_ok():
				_hook_lost_target()
				return
			if hook_chain and not _hook_move(vel):
				vel = Vector2.ZERO
				_hook_end()
				return
			var goal := hook_target.global_position
			var new_tip := hook_tip.move_toward(goal, hook_shot_speed)
			if not _ray(hook_tip, new_tip).is_empty():
				_hook_end()
				return
			hook_tip = new_tip
			if hook_tip.is_equal_approx(goal):
				hook_phase = HookPhase.PULL
				hook_frames = 0
				hurtbox_attack.set_deferred("disabled", false)
			_hook_draw()
		
		HookPhase.PULL:
			if not _hook_target_ok():
				_hook_lost_target()
				return
			var to_target := hook_target.global_position - global_position
			var dist := to_target.length()
			var dir := to_target / dist if dist > 0.001 else Vector2(facing, 0)
			hook_pull_vel = dir * hook_shot_pull_speed
			vel = hook_pull_vel
			if absf(dir.x) > 0.05:
				facing = int(signf(dir.x))
			hook_frames += 1
			if not _hook_move(dir * minf(hook_shot_pull_speed, dist)):
				vel = Vector2.ZERO
				_hook_end()
				return
			hook_tip = hook_target.global_position 
			_hook_draw()
		
		HookPhase.IMPACT:
			vel = Vector2.ZERO
			hook_frames -= 1
			if hook_frames <= 0:
				_hook_resolve_impact()

func _hook_begin_impact() -> void:
	hook_phase = HookPhase.IMPACT
	hook_frames = hook_shot_impact_frame_timer
	vel = Vector2.ZERO
	_hook_show(false)
	if hook_target.has_method("hook_hit"):
		hook_target.hook_hit(self)

## After the impact frames: 
## target still there = we collided (bounce back),
## target gone = nothing in the way (keep momentum).
func _hook_resolve_impact() -> void:
	if _hook_target_ok():
		var away := -signf(hook_pull_vel.x) if absf(hook_pull_vel.x) > 0.01 else -float(facing)
		vel = Vector2(away * hook_pull_vel.length() * hook_shot_bounce_factor, -hook_shot_bounce_up)
	else:
		vel = hook_pull_vel * hook_shot_momentum_keep
	_hook_end()

func _hook_lost_target() -> void:
	if hook_phase == HookPhase.PULL:
		vel = hook_pull_vel * hook_shot_momentum_keep
	_hook_end()

## Terrain-aware movement for the pull. Returns false (and stops) if terrain is ahead.
func _hook_move(motion: Vector2) -> bool:
	var steps := maxi(1, ceili(motion.length() / step_size))
	var step := motion / steps
	for i in steps:
		if not _ray(global_position, global_position + step + step.normalized() * push_radius).is_empty():
			return false
		global_position += step
		_resolve_walls()
	return true

func _hook_end() -> void:
	_hook_cancel()
	hook_chain = true

func _hook_cancel() -> void:
	hook_phase = HookPhase.NONE
	hook_target = null
	hook_miss_active = false
	_hook_show(false)
	hurtbox_attack.set_deferred("disabled", true)
	
	if hitbox_lock <= 0 and not dead:
		hitbox.set_deferred("disabled", false)

func _hook_start_miss() -> void:
	hook_miss_dir = vel.normalized() if vel.length() > 0.5 else Vector2(facing, 0)
	hook_miss_active = true
	hook_miss_returning = false
	hook_miss_dist = 0.0
	hook_tip = global_position
	_hook_show(true)
	_hook_draw()

func _hook_miss_tick() -> void:
	if not hook_miss_active:
		return
	if hook_miss_returning:
		hook_miss_dist -= hook_shot_speed
		if hook_miss_dist <= 0.0:
			hook_miss_active = false
			_hook_show(false)
			return
	else:
		var next := hook_miss_dist + hook_shot_speed
		var hit := _ray(global_position, global_position + hook_miss_dir * next)
		if not hit.is_empty():
			hook_miss_dist = global_position.distance_to(hit["position"])
			hook_miss_returning = true
		else:
			hook_miss_dist = next
			hook_miss_returning = next >= hook_shot_miss_length
	hook_tip = global_position + hook_miss_dir * hook_miss_dist
	_hook_draw()

# --- visuals ----------------------------------------------------------------
func _hook_show(on: bool) -> void:
	hook_line.visible = on
	hook_head.visible = on
	hook_head_area.set_deferred("monitorable", on)

func _hook_draw() -> void:
	hook_line.points = PackedVector2Array([global_position, hook_tip])
	hook_head.global_position = hook_tip
	hook_head.rotation = (hook_tip - global_position).angle()
#endregion
# =============================================================================
# HELPERS
# =============================================================================
#region Helpers:
func _dbg(msg: String) -> void:
	if debug_log:
		print("[Player] ", msg)

func _steep_blend(angle_deg: float) -> float:
	if angle_deg <= steep_drag_start_angle:
		return 0.0
	
	var span := maxf(90.0 - steep_drag_start_angle, 0.001)
	return clampf((angle_deg - steep_drag_start_angle) / span, 0.0, 2.0)

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
		if attacking:
			s = State.ATTACK
	else:
		s = State.JUMP if (jumping or sliding) else State.AIR
		if stomping:
			s = State.STOMP
	if s != state:
		state = s
		state_changed.emit(s)
		
	hurtbox_slide.disabled = false if sliding or diving or stomping else true
	hurtbox_attack.disabled = false if s == State.ATTACK or hook_phase != HookPhase.NONE else true
#endregion
	
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
		
	if hook_phase != HookPhase.NONE:
		sprite.play("slide" if hook_phase >= HookPhase.PULL else "idle")
		return
	elif crouching or crouch_boosting:
		sprite.play("crouch")
	elif stomping and !grounded:
		sprite.play("slide")
	elif attacking and grounded:
		sprite.play("idle")
	elif diving and !grounded:
		sprite.play("crouch")
	elif sliding:
		sprite.play("slide")
	elif abs(gsp) > 0.1:
		sprite.play("run")
	elif vel.y > 0:
		sprite.play("jump")
	elif vel.y < 0:
		sprite.play("fall")
	else:
		sprite.play("idle")

#region other
func _track_motion() -> void:
	var d := global_position - _prev_physics_pos
	_prev_physics_pos = global_position
	_measured_vel = Vector2.ZERO if d.length() > camera_teleport_threshold else d
 
## Frame-rate independent smoothing factor: lerp(a, b, _damp(rate, delta)).
static func _damp(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)
 
## Where the player is actually drawn this frame (same maths Godot uses to interpolate the sprite).
func _visual_position() -> Vector2:
	if _interpolated:
		return _prev_physics_pos.lerp(global_position, Engine.get_physics_interpolation_fraction())
	return global_position
 
## Starts a linear camera transition from wherever the camera is right now.
func _camera_retarget() -> void:
	_cam_start = _cam_center
	_cam_start_zoom = camera.zoom
	_cam_t = 0.0
 
## Call after teleporting the player (respawn, warp) so the camera doesn't swoosh across the level.
func _camera_snap() -> void:
	_measured_vel = Vector2.ZERO
	_cam_vel = Vector2.ZERO
	_cam_offset = Vector2.ZERO
	_prev_physics_pos = global_position
	_cam_center = global_position
	_cam_t = 1.0
	reset_physics_interpolation()
 
func _update_camera(delta: float) -> void:
	if camera == null:
		return
	
	# Look-ahead + zoom from speed and direction of travel.
	_cam_vel = _cam_vel.lerp(_measured_vel, _damp(camera_velocity_smoothing, delta))
	var t := smoothstep(camera_lookahead_start_speed, camera_full_speed, _cam_vel.length())
	var look := _cam_vel.normalized() * camera_max_distance * t
	look.y *= camera_vertical_factor
	_cam_offset = _cam_offset.lerp(look, _damp(camera_offset_smoothing, delta))
	_cam_zoom = lerpf(_cam_zoom, lerpf(camera_base_zoom, camera_max_scale, t), _damp(camera_zoom_smoothing, delta))
	
	# Where the camera wants to be: on the static view, or following the player.
	var player_pos := _visual_position()
	var target_center := static_camera_position if static_camera else player_pos + _cam_offset
	var target_zoom := static_camera_scale if static_camera else Vector2(_cam_zoom, _cam_zoom)
	
	# One straight, constant-speed move from where the camera was when the trigger was touched.
	_cam_t = minf(_cam_t + delta / maxf(cam_time, camera_static_min_time), 1.0)
	_cam_center = _cam_start.lerp(target_center, _cam_t)
	camera.offset = _cam_center - player_pos
	camera.zoom = _cam_start_zoom.lerp(target_zoom, _cam_t)

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

var booster_latch = false
func _on_area_2d_area_entered(area: Area2D) -> void: #detector
	if area.is_in_group("cash"):
		cash += 1
		score += 50
		area.queue_free()
	elif area.is_in_group("checkpoint") and area.global_position != start_pos:
		score += 500
		health = max_health
		start_pos = area.global_position
	elif area.is_in_group("goal"):
		finished_level.emit(area)
		hide_score_ui()
		await get_tree().create_timer(3.0).timeout
		finish_level()
	elif area.is_in_group("booster"):
		if area.vel_boost.y == 0:
			if !(grounded or sliding):
				await landed
			gsp += area.vel_boost.x
		if abs(area.vel_boost.y) > 0 and !booster_latch:
			booster_latch = true
			if !(grounded or sliding):
				await landed
			position.y -= 10
			state = State.AIR
			vel = Vector2(vel.x + area.vel_boost.x, -area.vel_boost.y)
			grounded = false
			stomping = false
			diving = false
			booster_latch = false
	elif area.is_in_group("death"):
		health = 0
		die()
	elif area.is_in_group("cam_trigger"):
		static_camera = false if area.exit_static else true
		static_camera_position = area.cam_position
		static_camera_scale = area.cam_scale
		cam_time = area.cam_move_time
		
func _on_hitbox_damage(area: Area2D) -> void:
	if area.is_in_group("danger"):
		score -= 250
		player_hurt()
		
func player_hurt():
	if dead:
		return
	health -= 1
	was_damaged = true
	floor_collider = null
	platform_velocity = Vector2.ZERO
	ground_angle = 0.0
	grounded = false
	sliding = false
	attacking = false
	diving = false
	crouching = false
	crouch_boosting = false
	crouch_boost_charge = 0.0
	looking_up = false
	_refresh_hitbox()
	vel.x = min(vel.x/3, -8.0) if direction > 0 else max(vel.x/3, 8.0)
	vel.y = -5.0
	control_lock = 30
	hitbox_lock = hitbox_lock_frames
	hitbox.set_deferred("disabled", true)
	player_hit.emit()
	if health == 0:
		die()
	
func die():
	if dead:
		return
	dead = true
	player_death.emit()
	_hook_cancel()
	hitbox_lock = 180
	control_lock = 180
	await get_tree().create_timer(3).timeout
	Global.lives -= 1
	Global.respawn_enemies()
	health = max_health
	global_position = start_pos
	_camera_snap()
	_set_carrier(null)
	set_collision_mask_value(1 ,true)
	set_collision_mask_value(2 ,false)
	if squished:
		squished = false
		if sprite:
			sprite.scale = squish_base_scale
			sprite.rotation = 0.0
		ground_angle = 0.0
	dead = false
	
func hide_score_ui():
	$CanvasLayer/UI/MarginContainer/VBoxContainer/Time.visible = false
	$CanvasLayer/UI/MarginContainer/VBoxContainer/Score.visible = false
	$CanvasLayer/UI/MarginContainer/VBoxContainer/Cash.visible = false
	
func finish_level():
	control_lock = 9999
	hitbox_lock = 9999
	level_finish = true
	# add sum animation
	
#endregion
