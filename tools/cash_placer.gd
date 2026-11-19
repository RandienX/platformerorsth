@tool
class_name CashPlacer
extends Path2D
## CASH SCENE PLACER. Spreads cash scenes along a Path2D in a pattern (line, zigzag,
## wave, double row). The path points are only a guide: every corner is turned into a
## smooth curve first, using the same roughness idea as LevelBuilder, and the cash is
## placed on that smoothed curve.
##
## HOW TO USE
##  * Add this node, draw the path with the Path2D tools (only the POINTS are used,
##    bezier handles are ignored; roughness does the curving).
##  * Put one or more cash scenes into `cash_scenes` (root must be a Node2D).
##  * Press "Place cash". Items go into `container` (a "CashItems" child is created
##    if empty). Only items made by this tool are removed on the next run, anything
##    you placed by hand in the container stays.
##  * The yellow preview line and dots in the editor show exactly what will be placed.
##
## SMOOTHING (applied in this order)
##  1. ROUGHNESS   Each corner becomes a circular arc. Radius = (1 - roughness of that
##                 point) * max_curve_radius. 0 = fully round, 1 = sharp as drawn.
##                 `roughness` is the default, `point_roughness` overrides it per point.
##  2. RELAX       Optional extra passes that pull points towards their neighbours. How
##                 much a point moves is scaled by its own smoothness (1 - roughness),
##                 so sharp points stay sharp. Path ends never move.

const ARC_STEP_DEGREES_MIN := 2.0
const MAX_ROUND_TURN := 2.6        # corners sharper than this (radians, ~150 deg) stay sharp
const META_KEY := &"_cash_placer"

enum Pattern { LINE, ZIGZAG, WAVE, DOUBLE_ROW }
enum SceneOrder { CYCLE, RANDOM }

## Polyline with a "softness" value per point (0 = pinned, 1 = fully smoothable).
class Trace:
	var pts := PackedVector2Array()
	var soft := PackedFloat32Array()
	var closed := false

	func push(p: Vector2, s: float) -> void:
		var last := pts.size() - 1
		if last >= 0 and pts[last].distance_to(p) <= 0.001:
			soft[last] = minf(soft[last], s)
			return
		pts.append(p)
		soft.append(s)

	func finish() -> void:
		if not closed:
			return
		while pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.001:
			soft[0] = minf(soft[0], soft[soft.size() - 1])
			pts.remove_at(pts.size() - 1)
			soft.remove_at(soft.size() - 1)

## Scenes to place. Their root must be a Node2D.
@export var cash_scenes: Array[PackedScene] = []
## Where the items are added. Empty = a "CashItems" child of this node (made for you).
@export var container: Node2D
## Treat the path as a loop (needs at least 3 points). The last point connects to the first.
@export var closed_loop := false

@export_group("Pattern")
@export var pattern := Pattern.LINE
## Distance between items along the path, in pixels.
@export_range(4.0, 1000.0, 1.0, "or_greater") var spacing := 48.0
## Stretch the spacing a little so the items fit the path exactly (first and last item
## sit on the path ends, or the loop closes evenly).
@export var even_fit := true
## Distance from the path start to the first item (on a loop: shifts the whole pattern).
@export var start_offset := 0.0
## Distance kept free at the path end (ignored on a loop).
@export var end_offset := 0.0
## Sideways distance for zigzag / wave / double row, in pixels.
@export_range(0.0, 500.0, 1.0, "or_greater") var amplitude := 24.0
## Length of one full wave, in pixels (wave pattern).
@export_range(8.0, 2000.0, 1.0, "or_greater") var wave_length := 240.0
## Turn each item to follow the path direction.
@export var rotate_to_path := false
@export_range(-180.0, 180.0, 1.0) var rotation_offset_degrees := 0.0
@export var scene_order := SceneOrder.CYCLE
## Seed for RANDOM scene order (same seed = same result).
@export var random_seed := 1

@export_group("Curve")
## Smoothness of every path point that has no value of its own.
## 0 = corner rounded into a circular arc as large as the neighbouring lines allow,
## 1 = sharp corner exactly as drawn.
@export_range(0.0, 1.0, 0.01) var roughness := 0.3
## Per-point roughness, in the order of the path points. A value below 0 (or a missing
## entry) means "use `roughness`". Use "Reload curve points" to size it to the path.
@export var point_roughness := PackedFloat32Array()
## Largest corner radius (pixels) used at roughness 0.
@export_range(1.0, 2000.0, 1.0, "or_greater") var max_curve_radius := 160.0
## Smoothness of the sampled arcs: angle between two arc samples.
@export_range(2.0, 45.0, 1.0) var arc_step_degrees := 10.0
## Extra relax passes after rounding (pull points towards their neighbours). 0 = off.
@export_range(0, 20) var relax_passes := 0
## How hard each relax pass pulls. Sharp points (roughness 1) are not affected.
@export_range(0.0, 1.0, 0.01) var relax_strength := 0.5

@export_group("Editor")
@export var show_preview := true
@export_range(1.0, 32.0, 0.5) var preview_dot_radius := 5.0
@export var live_update := false
@export var debounce := 0.3

@export_category("Tool Buttons")
@warning_ignore("unused_private_class_variable")
@export_tool_button("Place cash", "Node2D") var _generate_btn = generate
@warning_ignore("unused_private_class_variable")
@export_tool_button("Clear cash", "Clear") var _clear_btn = clear_cash
@warning_ignore("unused_private_class_variable")
@export_tool_button("Reload curve points", "Reload") var _reset_pr_btn = reset_point_roughness

var _seen_hash := 0
var _dirty := false
var _idle := 0.0


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var h := _watch_hash()
	if h != _seen_hash:
		_seen_hash = h
		_dirty = true
		_idle = 0.0
		queue_redraw()
		return
	if _dirty and live_update:
		_idle += delta
		if _idle >= debounce:
			_dirty = false
			generate()


func _watch_hash() -> int:
	var pts := []
	if curve != null:
		for i in curve.point_count:
			pts.append(curve.get_point_position(i))
	return hash([pts, closed_loop, pattern, spacing, even_fit, start_offset, end_offset,
		amplitude, wave_length, roughness, point_roughness, max_curve_radius,
		arc_step_degrees, relax_passes, relax_strength, show_preview, preview_dot_radius])


func _draw() -> void:
	if not Engine.is_editor_hint() or not show_preview:
		return
	var tr := _build_line()
	if tr.pts.size() < 2:
		return
	var poly := tr.pts.duplicate()
	if tr.closed:
		poly.append(poly[0])
	var col := Color(1.0, 0.85, 0.2)
	draw_polyline(poly, Color(col, 0.7), 2.0, true)
	for s: Dictionary in _slots_for(tr):
		draw_circle(s["pos"], preview_dot_radius, Color(col, 0.9))


# ================================================================= public API

func generate() -> void:
	var scenes: Array[PackedScene] = []
	for s in cash_scenes:
		if s != null:
			scenes.append(s)
	if scenes.is_empty():
		push_warning("CashPlacer: add at least one scene to cash_scenes.")
		return
	if curve == null or curve.point_count < 2:
		push_warning("CashPlacer: the path needs at least 2 points.")
		return
	var slots := _slots_for(_build_line())
	if slots.is_empty():
		push_warning("CashPlacer: nothing to place (path too short for the offsets?).")
		return

	var holder := _holder(true)
	_clear_generated(holder)
	var root := _owner_root()
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var to_holder := holder.global_transform.affine_inverse() * global_transform
	var placed := 0
	for k in slots.size():
		var slot: Dictionary = slots[k]
		var scene: PackedScene
		if scene_order == SceneOrder.RANDOM:
			scene = scenes[rng.randi() % scenes.size()]
		else:
			scene = scenes[placed % scenes.size()]
		var node := scene.instantiate()
		var item := node as Node2D
		if item == null:
			push_warning("CashPlacer: '%s' does not have a Node2D root." % scene.resource_path)
			node.free()
			continue
		item.name = "Cash%d" % placed
		item.position = to_holder * (slot["pos"] as Vector2)
		if rotate_to_path:
			item.rotation = to_holder.basis_xform(slot["dir"] as Vector2).angle() \
					+ deg_to_rad(rotation_offset_degrees)
		item.set_meta(META_KEY, true)
		holder.add_child(item, true)
		if root != null:
			item.owner = root
		placed += 1
	print("CashPlacer: placed %d items" % placed)


func clear_cash() -> void:
	var holder := _holder(false)
	if holder != null:
		_clear_generated(holder)


## Sizes `point_roughness` to the path (new points use -1 = global roughness).
func reset_point_roughness() -> void:
	var count := curve.point_count if curve != null else 0
	var out := PackedFloat32Array()
	for i in count:
		out.append(point_roughness[i] if i < point_roughness.size() else -1.0)
	point_roughness = out


# ============================================================== container

func _holder(create: bool) -> Node2D:
	if container != null:
		return container
	var found := get_node_or_null("CashItems") as Node2D
	if found != null:
		container = found
		return found
	if not create:
		return null
	var n := Node2D.new()
	n.name = "CashItems"
	add_child(n)
	var root := _owner_root()
	if root != null:
		n.owner = root
	container = n
	return n


func _owner_root() -> Node:
	if Engine.is_editor_hint() and is_inside_tree():
		var r := get_tree().edited_scene_root
		if r != null:
			return r
	return owner


func _clear_generated(holder: Node) -> void:
	for c in holder.get_children():
		if c.has_meta(META_KEY):
			holder.remove_child(c)
			c.queue_free()


# ================================================================ 1. curve

## Guide points + roughness -> rounded -> relaxed.
func _build_line() -> Trace:
	var pts := PackedVector2Array()
	var rough := PackedFloat32Array()
	if curve != null:
		for i in curve.point_count:
			var p := curve.get_point_position(i)
			if not pts.is_empty() and pts[pts.size() - 1].distance_to(p) <= 0.001:
				continue
			pts.append(p)
			rough.append(point_roughness[i] if i < point_roughness.size() and point_roughness[i] >= 0.0
					else roughness)
	var closed := closed_loop
	if closed and pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.001:
		pts.remove_at(pts.size() - 1)
		rough.remove_at(rough.size() - 1)
	closed = closed and pts.size() >= 3
	if pts.size() < 2:
		return Trace.new()
	var tr := _round_corners(pts, rough, closed)
	_relax(tr)
	return tr


## Replaces every corner by a circular arc (see header). Neighbouring arcs share the
## length of the line between them, so lines stay straight in between.
func _round_corners(pts: PackedVector2Array, rough: PackedFloat32Array, closed: bool) -> Trace:
	var n := pts.size()
	var m := n if closed else n - 1          # number of edges
	var dirs := PackedVector2Array()
	var lens := PackedFloat32Array()
	for e in m:
		var v := pts[(e + 1) % n] - pts[e]
		var l := v.length()
		lens.append(l)
		dirs.append(v / maxf(l, 0.0001))

	var turn := PackedFloat32Array()
	var want := PackedFloat32Array()         # tangent length wanted at each corner
	turn.resize(n)
	want.resize(n)
	for i in n:
		if not closed and (i == 0 or i == n - 1):
			continue
		var ang := acos(clampf(dirs[(i - 1 + n) % n].dot(dirs[i]), -1.0, 1.0))
		var radius := (1.0 - clampf(rough[i], 0.0, 1.0)) * max_curve_radius
		turn[i] = ang
		if radius > 0.5 and ang >= 0.03 and ang <= MAX_ROUND_TURN:
			want[i] = radius * tan(ang * 0.5)

	var edge_scale := PackedFloat32Array()
	edge_scale.resize(m)
	for e in m:
		var total := want[e] + want[(e + 1) % n]
		edge_scale[e] = 1.0 if total <= lens[e] * 0.98 else lens[e] * 0.98 / total

	var out := Trace.new()
	out.closed = closed
	var step := deg_to_rad(maxf(arc_step_degrees, ARC_STEP_DEGREES_MIN))
	for i in n:
		if not closed and (i == 0 or i == n - 1):
			out.push(pts[i], 0.0)            # path ends never move
			continue
		var smooth := 1.0 - clampf(rough[i], 0.0, 1.0)
		var prev_e := (i - 1 + n) % n
		var t: float = want[i] * minf(edge_scale[prev_e], edge_scale[i])
		if t < 0.01:
			out.push(pts[i], 0.0 if turn[i] > MAX_ROUND_TURN else smooth)
			continue
		var d1 := dirs[prev_e]
		var r := t / tan(turn[i] * 0.5)
		var sgn := signf(d1.cross(dirs[i]))
		var start := pts[i] - d1 * t
		var centre := start + d1.rotated(sgn * PI * 0.5) * r
		var radial := start - centre
		var steps := maxi(1, ceili(turn[i] / step))
		for k in steps + 1:
			out.push(centre + radial.rotated(sgn * turn[i] * float(k) / float(steps)), smooth)
	out.finish()
	return out


## Laplacian smoothing. A point moves by relax_strength * its own smoothness, so points
## with roughness 1 (and the path ends) stay exactly where they are.
func _relax(tr: Trace) -> void:
	var n := tr.pts.size()
	if n < 3 or relax_passes <= 0 or relax_strength <= 0.0:
		return
	for _k in relax_passes:
		var src := tr.pts.duplicate()
		for i in n:
			if tr.soft[i] <= 0.0:
				continue
			var a := src[(i - 1 + n) % n]
			var b := src[(i + 1) % n]
			tr.pts[i] = src[i].lerp((a + b) * 0.5, relax_strength * tr.soft[i])


# ============================================================== 2. pattern

## Positions + travel directions of every item, in this node's local space.
func _slots_for(tr: Trace) -> Array:
	var out: Array = []
	var pts := tr.pts
	var n := pts.size()
	if n < 2:
		return out
	var m := n if tr.closed else n - 1
	var cum := PackedFloat32Array()
	cum.resize(m + 1)
	for e in m:
		cum[e + 1] = cum[e] + pts[e].distance_to(pts[(e + 1) % n])
	var total := cum[m]
	if total < 0.01:
		return out

	var gap := maxf(spacing, 1.0)
	var dists: Array[float] = []
	if tr.closed:
		var count := maxi(1, roundi(total / gap)) if even_fit else maxi(1, floori(total / gap))
		var step := total / float(count) if even_fit else gap
		for i in count:
			dists.append(start_offset + step * float(i))
	else:
		var usable := total - start_offset - end_offset
		if usable < 0.0:
			return out
		if usable < 0.01:
			dists.append(start_offset)
		elif even_fit:
			var intervals := maxi(1, roundi(usable / gap))
			var step := usable / float(intervals)
			for i in intervals + 1:
				dists.append(start_offset + step * float(i))
		else:
			var d := start_offset
			while d <= start_offset + usable + 0.001:
				dists.append(d)
				d += gap

	for i in dists.size():
		var d := dists[i]
		var s := _sample(pts, cum, m, tr.closed, d)
		var p: Vector2 = s[0]
		var dir: Vector2 = s[1]
		var nrm := dir.orthogonal()
		match pattern:
			Pattern.ZIGZAG:
				var side := 1.0 if i % 2 == 0 else -1.0
				out.append({"pos": p + nrm * amplitude * side, "dir": dir})
			Pattern.WAVE:
				var off := sin(d / maxf(wave_length, 1.0) * TAU) * amplitude
				out.append({"pos": p + nrm * off, "dir": dir})
			Pattern.DOUBLE_ROW:
				out.append({"pos": p + nrm * amplitude, "dir": dir})
				out.append({"pos": p - nrm * amplitude, "dir": dir})
			_:
				out.append({"pos": p, "dir": dir})
	return out


## Point and direction at arc length `d` along the polyline. Returns [pos, dir].
func _sample(pts: PackedVector2Array, cum: PackedFloat32Array, m: int, closed: bool,
		d: float) -> Array:
	var total := cum[m]
	d = fposmod(d, total) if closed else clampf(d, 0.0, total)
	var e := clampi(cum.bsearch(d) - 1, 0, m - 1)
	var a := pts[e]
	var b := pts[(e + 1) % pts.size()]
	var seg := cum[e + 1] - cum[e]
	var t := (d - cum[e]) / seg if seg > 0.0001 else 0.0
	var dir := (b - a).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	return [a.lerp(b, t), dir]
