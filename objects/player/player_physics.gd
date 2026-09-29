extends CharacterBody2D

# ==============================================================================
# Classic Sonic Physics (MIT License - Inspired by marmitoTH/Godot-Sonic-Physics)
# Added Side Floor Raycasts for perfect Ground Reacquisition and zero jitter.
# ==============================================================================

@export var acc: float = 800.0
@export var dec: float = 1200.0
@export var frc: float = 400.0
@export var roll_dec: float = 100.0
@export var top_speed: float = 900.0
@export var fall_threshold: float = 50.0

@export var jump_force: float = 900.0
@export var gravity: float = 1500.0
@export var slope_transition_angle: float = 30

@export var animation: AnimatedSprite2D
@export var collision: CollisionShape2D

# === NEW: Side Floor Raycasts ===
# Place these as children of the CharacterBody2D. 
# Set their Target Position to Vector2(0, 20) (or slightly longer).
@export var left_floor_ray: RayCast2D
@export var right_floor_ray: RayCast2D

# === Core Physics ===
var gsp: float = 0.0
var is_grounded: bool = false
var ground_timer: float = 0.0 

# === Character State ===
var is_crouch: bool = false
var is_sliding: bool = false
var crouch_boost_level: int = 0
var can_move: bool = true
var facing_right: bool = true

# === Multipliers ===
var speed_mult: float = 1.0
var accel_mult: float = 1.0
var decel_mult: float = 1.0

func _ready() -> void:
	floor_snap_length = 1200.0
	floor_max_angle = deg_to_rad(slope_transition_angle)

# ==============================================================================
# GROUND REACQUISITION (The Magic of Side Raycasts)
# ==============================================================================
func get_stable_floor_normal() -> Vector2:
	var left_hit := left_floor_ray and left_floor_ray.is_colliding()
	var right_hit := right_floor_ray and right_floor_ray.is_colliding()

	if left_hit and right_hit:
		# If both hit, we are likely on a flat surface or a very gentle curve.
		# Prefer the ray in the direction of movement to look "ahead" onto the next slope.
		if gsp >= 0:
			return right_floor_ray.get_collision_normal()
		else:
			return left_floor_ray.get_collision_normal()
	elif left_hit:
		return left_floor_ray.get_collision_normal()
	elif right_hit:
		return right_floor_ray.get_collision_normal()
	else:
		# Fallback to the engine's built-in normal if rays miss (e.g., in the air)
		return get_floor_normal()

func _physics_process(delta: float) -> void:
	var direction := Input.get_axis("left", "right")
	var is_jumping := Input.is_action_just_pressed("jump")
	var is_down := Input.is_action_pressed("down")
	var touching_floor := is_on_floor()

	# ==================================================================
	# GROUND TIMER (Prevents 1-frame physics flickers)
	# ==================================================================
	if touching_floor:
		ground_timer = 0.1 
	else:
		ground_timer = max(0.0, ground_timer - delta)
	
	var is_visually_grounded := ground_timer > 0.0

	# ==================================================================
	# DYNAMIC FLOOR MAX ANGLE
	# ==================================================================
	# Use the stable normal from the raycasts to calculate the slope angle
	var current_normal := get_stable_floor_normal()
	var slope_deg := rad_to_deg(acos(clamp(current_normal.dot(Vector2.UP), -1.0, 1.0)))
	
	if touching_floor:
		floor_max_angle = deg_to_rad(slope_deg + slope_transition_angle)
	else:
		floor_max_angle = deg_to_rad(slope_transition_angle)

	# ==================================================================
	# STATE TRANSITIONS
	# ==================================================================
	if is_grounded:
		if touching_floor:
			if abs(current_normal.x) > 0.707 and abs(gsp) < fall_threshold:
				is_grounded = false
				is_sliding = true
				can_move = false
				lower_hitbox()
				var tangent := Vector2(-current_normal.y, current_normal.x)
				velocity.x = tangent.x * gsp
				velocity.y = tangent.y * gsp
		else:
			is_grounded = false
	else:
		if touching_floor and velocity.y >= 0:
			is_grounded = true
			var tangent := Vector2(-current_normal.y, current_normal.x)
			gsp = velocity.dot(tangent)

	# ==================================================================
	# GROUND MOVEMENT
	# ==================================================================
	if is_grounded:
		var floor_normal := get_stable_floor_normal() # USE STABLE NORMAL HERE
		var tangent := Vector2(-floor_normal.y, floor_normal.x)

		# --- Input & Acceleration ---
		if can_move and not is_sliding:
			if direction != 0:
				if sign(direction) == sign(gsp) or gsp == 0:
					gsp = move_toward(gsp, top_speed * speed_mult * direction, acc * accel_mult * delta)
				else:
					gsp = move_toward(gsp, top_speed * speed_mult * direction, dec * decel_mult * delta)
					speed_mult = move_toward(speed_mult, 1.0, 2.0 * delta)
					accel_mult = move_toward(accel_mult, 1.0, 2.0 * delta)
			else:
				gsp = move_toward(gsp, 0.0, frc * decel_mult * delta)
				speed_mult = move_toward(speed_mult, 1.0, 1.0 * delta)
				accel_mult = move_toward(accel_mult, 1.0, 1.0 * delta)
		elif is_sliding:
			gsp = move_toward(gsp, 0.0, roll_dec * delta)

		# --- Slope Gravity ---
		var slope_pull := Vector2(0.0, gravity).dot(tangent)
		gsp += slope_pull * delta

		# --- Crouch / Slide State ---
		if is_down and not is_sliding:
			if abs(gsp) > top_speed * 0.1:
				is_sliding = true
				is_crouch = false
				can_move = false
				lower_hitbox()
				var slide_dir: float = sign(gsp) if gsp != 0 else (1.0 if facing_right else -1.0)
				gsp += 300.0 * slide_dir
			else:
				if not is_crouch:
					is_crouch = true
					can_move = false
					lower_hitbox()
					if is_jumping and crouch_boost_level <= 8:
						crouch_boost_level += 1
						var boost := log(crouch_boost_level) / log(2.0) + 2.0
						speed_mult = boost
						accel_mult = boost
		else:
			if is_sliding or is_crouch:
				is_sliding = false
				is_crouch = false
				can_move = true
				restore_hitbox()
				if crouch_boost_level > 0:
					var boost_dir: float = sign(gsp) if gsp != 0 else (1.0 if facing_right else -1.0)
					var boost := log(crouch_boost_level) / log(2.0) + 2.0
					gsp = top_speed * boost * 0.3 * boost_dir
					crouch_boost_level = 0

		# --- Apply GSP to Velocity ---
		velocity.x = tangent.x * gsp
		velocity.y = tangent.y * gsp
		velocity.y += 15.0  # Downward bias for reliable floor snapping

		# --- Jump --- := 
		if is_jumping and not is_crouch:
			velocity += floor_normal * jump_force
			is_grounded = false

		# --- SMOOTHED COLLISION ROTATION ---
		if collision:
			if is_visually_grounded:
				var target_rot := floor_normal.angle() + PI / 2.0
				# Because floor_normal is now perfectly stable thanks to the raycasts,
				# this lerp will be incredibly smooth with zero hiccups.
				collision.rotation = lerp_angle(collision.rotation, target_rot, min(1.0, 25.0 * delta))
			else:
				collision.rotation = lerp_angle(collision.rotation, 0.0, min(1.0, 15.0 * delta))

	# ==================================================================
	# AIR MOVEMENT
	# ==================================================================
	else:
		if can_move and direction != 0:
			velocity.x = move_toward(velocity.x, top_speed * 0.5 * direction, (acc * 0.5) * delta)
		if direction == 0:
			velocity.x = move_toward(velocity.x, 0.0, frc * 0.5 * delta)
		velocity.y += gravity * delta

	# ==================================================================
	# FINALIZATION
	# ==================================================================
	if direction != 0:
		facing_right = direction > 0
	if animation:
		animation.scale.x = 1.0 if facing_right else -1.0

	move_and_slide()

# ==============================================================================
# Helpers
# ==============================================================================
func lower_hitbox() -> void:
	if collision and collision.shape:
		collision.shape.size.y = 64

func restore_hitbox() -> void:
	if collision and collision.shape:
		collision.shape.size.y = 164
