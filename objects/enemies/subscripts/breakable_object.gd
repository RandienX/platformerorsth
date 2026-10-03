class_name BreakableObject
extends Enemy
## Enemy 4: a crate / wall / pot that breaks when the player attacks it
## (jump ball, rolling, crouch-boost slide). It never hurts the player.
##
## It can be SOLID: put its body on your world layer and the player will
## stand on / run into it until it breaks. Make HurtArea's shape the same as
## the body or a bit bigger (~20-40 px) so a fast roll breaks it before the
## wall sensor stops the player.
##
## Use `max_health` for "hits to break", `drop_scene` + `drop_count` for loot.
## Set `respawns = false` for objects that should stay broken after the
## player dies.

@export_group("BreakAnim")
@export var scene: PackedScene

func _enemy_ready() -> void:
	contact_damage = false                 # a crate never hurts you

func _on_damaged() -> void:
	_play("hit")

func _on_died() -> void:
	_play("break")
	if scene == null or get_parent() == null:
		return
	var fx := scene.instantiate() as Node2D
	if fx == null:
		return
	get_parent().add_child.call_deferred(fx)
	fx.set_deferred("global_position", global_position)
