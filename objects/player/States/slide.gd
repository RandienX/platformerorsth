extends '../state.gd'

@export var DASH_SPEED: float = 720
@export var CHARGE_TIME: float = 1

var charge_timer : float

func enter(host: PlayerPhysics):
	charge_timer = CHARGE_TIME

func step(host: PlayerPhysics, delta):
	charge_timer -= delta
	
	if Input.is_action_just_released("up"):
		return 'OnGround'

func exit(host: PlayerPhysics):
	if charge_timer <= 0:
		host.gsp = DASH_SPEED * host.character.scale.x
