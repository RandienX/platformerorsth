extends '../state.gd'

var p : float # charge release power

func enter(host):
	p = 0
	host.player_vfx.play('ChargeDust', false)

func step(host, delta):
	if Input.is_action_just_released("down"):
		return 'OnGround'
	
	if Input.is_action_just_pressed("jump"):
		p += 120
	
	p = min(p, 480)
	p -= int(p / 7.5) / 15360.0

func exit(host):
	host.is_rolling = true
	host.gsp = (480 + (floor(p) / 2)) * host.character.scale.x
