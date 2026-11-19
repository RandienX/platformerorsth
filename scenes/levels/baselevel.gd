extends Node2D
class_name Level

enum Rank {F, D, C, B, A, S, P}
const RANK_NAMES: Array[String] = ["F", "D", "C", "B", "A", "S", "P"]

@export_group("Rank targets")
@export var perfect_time: int ## set this in seconds pls
@export var perfect_score: int
@export var secrets: int

@export_group("Rank cutoffs")
@export var rank_cutoffs := [1.0, 0.86, 0.6, 0.33, 0.2]

@export_group("Other")
@export var no_damage_cash := 300
@export var secret_bonus := 50
@export_multiline var challenge_description := ""   ## leave empty if the level has no challenge

var start_timer: bool = false
var time: float
var level_finish: bool = false
var hits_taken := 0
var challenge_complete := false
var secrets_found := 0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	await get_tree().create_timer(1.0).timeout
	start_timer = true
	Global.player.connect("player_hit", hit_counter)
	Global.player.connect("finished_level", finish_lvl)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if !level_finish:
		time += delta
		Global.level_time = time

func hit_counter():
	hits_taken += 1

func complete_challenge() -> void:
	challenge_complete = true

func finish_lvl(goal: Area2D):
	if level_finish == true:
		return
	level_finish = true
	_results()
	
	await get_tree().create_timer(2.0).timeout
	var finish_ui = preload("uid://cuq8ynn8bd0em").instantiate()
	Global.player.get_node("CanvasLayer").add_child(finish_ui)
	
	#goal level unlock code here
	goal.level_unlock = ""

# =============================================================================
# RANKING
# =============================================================================
var result_time := 0.0
var result_score := 0
var result_hits := 0
var time_rank := Rank.D
var score_rank := Rank.D
var hits_rank := Rank.D
var final_rank := Rank.D
var cash_bonus := 0
var rank_avg: float

func _results() -> void:
	var player = Global.player
	result_time = time
	result_score = player.score
	result_hits = hits_taken
	
	# Faster than perfect_time = ratio above 1.
	var time_ratio := float(perfect_time) / result_time if (perfect_time > 0 and result_time > 0.0) else 1.0
	var score_ratio := float(result_score) / float(perfect_score) if perfect_score > 0 else 1.0
	
	time_rank = _rank_from_ratio(time_ratio)
	score_rank = _rank_from_ratio(score_ratio)
	hits_rank = clampi(Rank.P - result_hits, Rank.D, Rank.S) as Rank
	if result_hits < 12 and hits_rank <= Rank.D:
		hits_rank = Rank.D
	rank_avg = round((time_rank + score_rank + hits_rank) / 3.0)
	if rank_avg == Rank.S:
		final_rank = Rank.P
	elif rank_avg > Rank.A + 0.3:
		final_rank = Rank.S
	else:
		final_rank = floori(rank_avg) as Rank
	
	if result_hits == 0:
		cash_bonus += no_damage_cash
	cash_bonus += secrets_found * secret_bonus 
	player.cash += cash_bonus

func _rank_from_ratio(ratio: float) -> Rank:
	if ratio >= rank_cutoffs[0]:
		return Rank.S
	if ratio >= rank_cutoffs[1]:
		return Rank.A
	if ratio >= rank_cutoffs[2]:
		return Rank.B
	if ratio >= rank_cutoffs[3]:
		return Rank.C
	if ratio >= rank_cutoffs[4]:
		return Rank.D
	return Rank.F
