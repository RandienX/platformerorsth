extends Control

@onready var level: Level = get_tree().current_scene

@onready var time: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Time/Panel/HSplitContainer/Time
@onready var time_rank: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Time/Panel2/Label
@onready var score: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Score/Panel/HSplitContainer/Score
@onready var score_rank: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Score/Panel2/Label
@onready var hits: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Defeats/Panel/HSplitContainer/Defeats
@onready var hits_rank: Label = $CenterContainer/VBoxContainer/HBoxContainer3/VBoxContainer/Defeats/Panel2/Label
@onready var final_rank: Label = $CenterContainer/VBoxContainer/HBoxContainer3/FinalScore/Label

@onready var secrets_panel: Panel = $CenterContainer/VBoxContainer/Extra/Secrets
@onready var secrets_label: Label = $CenterContainer/VBoxContainer/Extra/Secrets/Label
@onready var challenge_panel: Panel = $CenterContainer/VBoxContainer/Extra/Challenge
@onready var challenge_label: Label = $CenterContainer/VBoxContainer/Extra/Challenge/Label
@onready var cash_label: Label = $CenterContainer/VBoxContainer/Cash/Cash/Label

const COUNT_SECONDS := 1.0
const NOT_EARNED := Color(1, 1, 1, 1)

var skip := false
var finished := false

func _ready() -> void:
	visible = false
	_reset_texts()
	_setup_extras()
	await get_tree().create_timer(0.2).timeout
	$AnimationPlayer.play("on_creation")
	position = Vector2.ZERO
	visible = true

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("jump") or event.is_action_pressed("attack"):
		skip = true
		$AnimationPlayer.advance(3)
		if finished:
			get_tree().change_scene_to_file("res://scenes/menu/campaign_map.tscn")
		finished = true
		
func _on_animation_player_animation_finished(anim_name: StringName) -> void:
	if anim_name == "on_creation":
		_run_count_up()

# =============================================================================
# SEQUENCE
# =============================================================================
func _run_count_up() -> void:
	await _count(_show_time, level.result_time, COUNT_SECONDS)
	_reveal_rank(time_rank, level.time_rank)
	await _wait(0.25)
	
	await _count(_show_score, level.result_score, COUNT_SECONDS)
	_reveal_rank(score_rank, level.score_rank)
	await _wait(0.25)
	
	await _count(_show_hits, level.result_hits, 0.5)
	_reveal_rank(hits_rank, level.hits_rank)
	await _wait(0.5)
	
	final_rank.text = Level.RANK_NAMES[level.final_rank]
	$AnimationPlayer.play("rank")
	await _wait(1.0)
	
	await _count(_show_cash, level.cash_bonus, 0.8)
	finished = true

## Runs setter(value) every frame, easing from 0 to `to`. Pressing skip finishes it at once.
func _count(setter: Callable, to: float, seconds: float) -> void:
	if not is_zero_approx(to):
		var t := 0.0
		while t < seconds and not skip:
			t += get_process_delta_time()
			var k := 1.0 - pow(1.0 - clampf(t / seconds, 0.0, 1.0), 3.0)   # ease out
			setter.call(to * k)
			await get_tree().process_frame
	setter.call(to)

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

# =============================================================================
# DISPLAY
# =============================================================================
func _reset_texts() -> void:
	_show_time(0.0)
	_show_score(0.0)
	_show_hits(0.0)
	_show_cash(0.0)
	time_rank.text = ""
	score_rank.text = ""
	hits_rank.text = ""
	final_rank.text = ""

func _setup_extras() -> void:
	secrets_label.text = "Found \n%d/%d\n Secrets. (+ %d Cash)" % [level.secrets_found, level.secrets, level.secret_bonus * level.secrets_found]
	secrets_panel.modulate = Color.GOLD if level.secrets_found == level.secrets else NOT_EARNED
	
	if level.challenge_description.is_empty():
		challenge_label.visible = false
	else:
		challenge_label.text = "%s" % [level.challenge_description]
		challenge_panel.modulate = Color.GOLD if level.challenge_complete else NOT_EARNED

func _show_time(t: float) -> void:
	time.text = "%02d:%02d:%03d" % [floori(t / 60.0), int(t) % 60, int(fmod(t, 1.0) * 1000.0)]

func _show_score(v: float) -> void:
	score.text = "%07d" % roundi(v)

func _show_hits(v: float) -> void:
	hits.text = str(roundi(v))

func _show_cash(v: float) -> void:
	cash_label.text = "+%d Cash" % roundi(v)

func _reveal_rank(label: Label, rank: int) -> void:
	label.text = Level.RANK_NAMES[rank]
	if skip:
		return
	label.pivot_offset = label.size / 2.0
	label.scale = Vector2(1.6, 1.6)
	create_tween().tween_property(label, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
