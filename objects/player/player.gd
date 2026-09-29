extends CharacterBody2D
class_name PlayerPhysics

@export var animation: AnimatedSprite2D
@export var collision: CollisionShape2D
@export var floor_ray_cast: RayCast2D

#region SpeedVars
@export var max_speed: float = 1200.0
var max_speed_mult: float = 1.0
var speed: float = 0.0
#endregion

#region AccelVars
@export var accel: float = 800.0
var accel_mult: float = 1.0
@export var decel: float = 600.0
@export var air_decel: float = 100.0
var decel_mult: float = 1.0
@export var fastDecel: float = 900.0
var fastDecel_mult: float = 1.0
#endregion

@export var MultDecay: float = 1.0
@export var fastMultDecay: float = 2.0

var is_running: bool = false
var is_crouch: bool = false
var crouch_boost_level: int = 0
var is_sliding: bool = false
var can_jump: bool = true
var can_move: bool = true
var is_idle: bool = true
var facing_right: bool = true

var gravity = 1500

const JUMP_VELOCITY = -900.0
enum camStates {
	UP,
	NEUTRAL,
	DOWN
}

func _ready() -> void:
	floor_snap_length = 1200

func _physics_process(delta: float) -> void:
	var direction := Input.get_axis("left", "right")
	var full_speed := max_speed * max_speed_mult * direction
	var accel_step := accel * accel_mult * delta
	var decel_step := decel * decel_mult * delta
	var fastDecel_step := fastDecel * fastDecel_mult * delta
	
	if velocity.x < max_speed * 0.1 and Input.is_action_pressed("down"):
		crouch()
	elif velocity.x > max_speed * 0.1 and Input.is_action_pressed("down"):
		speed_boost(full_speed, accel_step, 2)
		slide(delta)
	else:
		is_sliding = false
		is_crouch = false
		can_move = true
		collision.shape.size.y = 164
		if crouch_boost_level > 0:
			speed_boost(full_speed, accel_step, crouch_boost_level)
	
	if direction and sign(direction) == sign(speed) and can_move:
		speed = move_toward(speed, full_speed, accel_step)
	elif direction and sign(direction) != sign(speed) and can_move:
		speed = move_toward(speed, full_speed, fastDecel_step)
		multiplier_decay(fastMultDecay, full_speed, delta)
	else:
		speed = move_toward(speed, 0, decel_step)
		multiplier_decay(MultDecay, full_speed, delta)
	
	if is_on_floor():
		floor_snap_length = 800
	
		var floorNormal = get_floor_normal()
		var floorTarget = floorNormal.angle() + PI/2
		
		collision.rotation = lerp(collision.rotation, floorTarget, 0.5)
		
		var floorTangent = Vector2(-floorNormal.y, floorNormal.x).normalized()
		var gravityDir = Vector2(0, gravity)
		var slopeSpeed = gravityDir.dot(floorTangent)
			
		speed += slopeSpeed * delta
		velocity.x = speed * floorTangent.x
		velocity.y = speed * floorTangent.y
		
		if Input.is_action_just_pressed("jump") and !is_crouch:
			velocity.y += JUMP_VELOCITY * floorTangent.y
			velocity.x *= floorTangent.x
			print(velocity)
			
	else:
		velocity.y += gravity * delta
	
	if direction != 0:
		facing_right = true if direction == 1 else facing_right
		facing_right = false if direction == -1 else facing_right
	
	animation.scale.x = 1 if facing_right else -1
	move_and_slide()

func crouch():
	is_crouch = true
	can_move = false
	lower_hitbox()
	if Input.is_action_just_pressed("jump") and crouch_boost_level <= 8:
		crouch_boost_level += 1
		max_speed_mult = Global.LOG(crouch_boost_level, 2) + 2
		accel_mult = Global.LOG(crouch_boost_level, 2) + 2
	
func slide(delta: float):
	if is_on_floor():
		is_sliding = true
		decel_mult = 0.5
		lower_hitbox()
		speed_boost(1000, 100, delta)
		floor_snap_length = 800
		if Input.is_action_just_pressed("jump") and !is_crouch:
			velocity.y = JUMP_VELOCITY
	
		var floorNormal = get_floor_normal()
		var floorTarget = floorNormal.angle() + PI/2
		
		collision.rotation = lerp(collision.rotation, floorTarget, 1.0)
		
		var floorTangent = Vector2(-floorNormal.y, floorNormal.x).normalized()
		var gravityDir = Vector2(0, gravity)
		var slopeSpeed = gravityDir.dot(floorTangent)
		speed += slopeSpeed * delta
		velocity.x = speed * floorTangent.x
		velocity.y = speed * floorTangent.y

func speed_boost(full_speed, accel_step, level):
	var boost = Global.LOG(level, 2) + 2
	var boost_dir = 1 if facing_right else -1
	velocity.x = move_toward(max_speed*boost*0.3*boost_dir, full_speed, accel_step * boost * 5)
	crouch_boost_level = 0

func multiplier_decay(strength: float, full_speed: float, delta: float):
	if velocity.x != 0:
		var decay = (strength * decel * decel_mult * delta) / (accel * accel_mult)
		max_speed_mult = move_toward(max_speed_mult, 1.0, decay)
		accel_mult = move_toward(max_speed_mult, 1.0, decay)
	else:
		max_speed_mult = 1.0
		accel_mult = 1.0
		
func lower_hitbox():
	collision.shape.size.y = 64
