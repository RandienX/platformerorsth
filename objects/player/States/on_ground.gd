extends '../state.gd'

var slope : float
var is_braking : bool
var brake_sign : int

func step(host, delta):
	host.is_looking_down = false
	host.is_looking_up = false
	host.is_pushing = false
	
	if !host.is_ray_colliding or host.fall_from_ground():
		host.is_grounded = false
		return 'OnAir'
	
	if Input.is_action_pressed("down"):
		if abs(host.gsp) > 61.875:
			host.is_sliding = true
		elif host.ground_mode == 0:
			host.is_sliding = false
			if Input.is_action_just_pressed("jump"):
				return 'Crouch'
			host.is_looking_down = true
	elif Input.is_action_pressed('up'):
		if abs(host.gsp) < .1 and host.ground_mode == 0:
			if Input.is_action_just_pressed("jump"):
				return 'Slide'
			host.is_looking_up = true
	
	if host.is_sliding and abs(host.gsp) < 30.0:
		host.is_sliding = false
	
	if !host.is_sliding:
		slope = host.SLP
	else:
		if sign(host.gsp) == sign(sin(host.ground_angle())):
			slope = host.SLPROLLUP
		else:
			slope = host.SLPROLLDOWN
	
	host.gsp -= slope * sin(host.ground_angle())
	
	if Input.is_action_pressed("left") and !host.control_locked:
		if host.gsp > 0:
			host.gsp -= host.DEC if !host.is_rolling else host.ROLLDEC
			
			if host.gsp > 270 and !host.is_rolling and host.ground_mode == 0:
				if !is_braking:
					brake_sign = sign(host.gsp)
				is_braking = true
		elif host.gsp > -host.TOP and !host.is_rolling:
			host.gsp -= host.ACC
		
		if host.is_wall_left and host.gsp < 0:
			host.is_pushing = true
	elif Input.is_action_pressed("right") and !host.control_locked:
		if host.gsp < 0 :
			host.gsp += host.DEC if !host.is_rolling else host.ROLLDEC
			
			if host.gsp < -270 and !host.is_rolling and host.ground_mode == 0:
				if !is_braking:
					brake_sign = sign(host.gsp)
				is_braking = true
		elif host.gsp < host.TOP and !host.is_rolling:
			host.gsp += host.ACC
		
		if host.is_wall_right and host.gsp > 0:
			host.is_pushing = true
	elif !host.is_rolling:
		host.gsp -= min(abs(host.gsp), host.FRC) * sign(host.gsp)
	
	if sign(host.gsp) != brake_sign or abs(host.gsp) <= 0.01:
		is_braking = false
	
	host.is_braking = is_braking
	
	if host.is_rolling:
		host.gsp -= min(abs(host.gsp), host.FRC / 2.0) * sign(host.gsp)
		host.gsp = clamp(host.gsp, -host.TOPROLL, host.TOPROLL)
	elif host.is_looking_down:
		host.gsp = .0
	
	host.gsp = .0 if host.is_wall_left and host.gsp < 0 else host.gsp
	host.gsp = .0 if host.is_wall_right and host.gsp > 0 else host.gsp
	host.velocity.x = host.gsp * cos(host.ground_angle())
	host.velocity.y = host.gsp * -sin(host.ground_angle())
	
	if Input.is_action_just_pressed("ui_accept"):
			host.velocity.x -= host.JMP * sin(host.ground_angle())
			host.velocity.y -= host.JMP * cos(host.ground_angle())
			host.rotation_degrees = 0
			host.is_grounded = false
			host.has_jumped = true
			host.audio_player.play('jump')
			return 'OnAir'
	
	if !host.can_fall:
		host.snap_to_ground()

func exit(host):
	is_braking = false
	host.is_braking = false
