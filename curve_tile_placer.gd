@tool
class_name CurveTilePlacer
extends Node2D
## Fits a TileMapLayer to a Polygon2D outline using the sloped collision tiles of
## the TileSet (1x1, 1x2, 1x3, 1x4, 1x6, 1x8 in every flip/rotation + flats).
##
## ALGORITHM (read this first, it is short)
##  1. LIBRARY   Every TileSet tile with exactly one non-border collision edge run
##               becomes a Piece: a surface line from point A to point B on the
##               tile border, solid on the right-hand side of travel.
##               Nothing is hard-coded, so flips/rotations are found automatically.
##  2. GRAPH     A "node" is a point on a cell border (a place where two tiles
##               touch). A tile is an edge: it connects its entry node A to its
##               exit node B. A chain of tiles is therefore ALWAYS continuous.
##  3. COST      A tile's cost = how far its surface is from the polygon outline
##               (integral of distance along the tile). A tile must also move
##               FORWARD along the outline, which rejects reversed slopes.
##  4. SEARCH    Dijkstra finds the cheapest closed loop of tiles around the
##               outline. The loop picks its own cells; it is not forced through
##               the cells the ideal curve touches.
##  5. WRITE     Surface tiles are placed, cells inside get `fill_tile`.
##               Where the surface runs flat along a cell border, the atlas tile
##               next to the slope (the "end cap") is used.

const KIND_TILE := 0
const KIND_FULL := 1        # virtual piece: full cell, surface along its border
const KEY_SCALE := 4.0      # node keys are points rounded to 1/4 px
## Allowed distance between tile surface and outline, in tiles. Tried in order;
## the first value that yields a closed loop wins (tight = most faithful).
const DEVIATION_PASSES := [0.25, 0.4, 0.6, 0.9, 1.4]

class Piece:
	var kind := KIND_TILE
	var coords := Vector2i(-1, -1)
	var profile := PackedVector2Array()  # relative to tile centre, A -> B
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var first_edge := 0                  # FULL pieces: 0 top, 1 right, 2 bottom, 3 left

@export var polygon_node: Polygon2D
@export var tile_layer: TileMapLayer
@export var atlas_source_id := 0
## Tile used for everything inside the polygon.
@export var fill_tile := Vector2i(8, 3)
@export var physics_layer := 0
## Erase old tiles around the polygon before placing.
@export var clean_area := true

@export_group("Fitting")
## Also allow the quarter-circle corner tiles (off = only straight slopes).
@export var use_curved_corner_tiles := false
## A tile must advance along the outline by at least this fraction of its length.
## Higher = stricter against wrong-direction tiles.
@export_range(0.1, 0.95) var min_forward_ratio := 0.5
## How many start points are tried when closing the loop.
@export_range(1, 64) var start_candidates := 24

@export_group("End caps (fallback)")
## Used when a flat run is not next to a slope tile in the atlas.
@export var cap_top := Vector2i(8, 0)
@export var cap_right := Vector2i(10, 14)
@export var cap_bottom := Vector2i(8, 11)
@export var cap_left := Vector2i(7, 14)

@export_group("Editor")
@export var live_update := false
@export var debounce := 0.3
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate tiles", "TileMapLayer") var _generate_btn = generate
@warning_ignore("unused_private_class_variable")
@export_tool_button("Clear tiles", "Clear") var _clear_btn = clear_tiles

var _busy := false
var _seen_hash := 0
var _dirty := false
var _idle := 0.0

# working data for one generate() call
var _ts := Vector2(64, 64)
var _outline := PackedVector2Array()
var _cum := PackedFloat64Array()   # arc length at each outline vertex
var _length := 0.0
var _lib: Array = []               # Array of Piece
var _entry_index := {}             # relative entry key -> PackedInt32Array of lib indices
var _pure_full := {}               # atlas coords of plain full tiles (end caps)
var _info := {}                    # point key -> Vector2(distance to outline, arc length)
var _edges := {}                   # node key -> Array of edge dictionaries
var _max_dev := 16.0


func _process(delta: float) -> void:
	if not live_update or polygon_node == null or tile_layer == null:
		return
	var h := hash([polygon_node.polygon, polygon_node.global_transform,
			polygon_node.offset, tile_layer.global_transform])
	if h != _seen_hash:
		_seen_hash = h
		_dirty = true
		_idle = 0.0
		return
	if _dirty:
		_idle += delta
		if _idle >= debounce:
			_dirty = false
			generate()


# ================================================================= public API

func generate() -> void:
	if _busy:
		return
	if polygon_node == null or tile_layer == null or tile_layer.tile_set == null:
		push_warning("CurveTilePlacer: assign polygon_node and a tile_layer that has a TileSet.")
		return
	_busy = true
	var t0 := Time.get_ticks_msec()
	_ts = Vector2(tile_layer.tile_set.tile_size)
	_outline = _outline_in_layer_space()
	if _outline.size() < 3:
		_busy = false
		return
	_prepare_outline()
	_build_library()
	if _lib.is_empty():
		push_warning("CurveTilePlacer: no usable slope tiles found in the TileSet source.")
		_busy = false
		return

	var steps := _find_tile_loop()
	if steps.is_empty():
		push_warning("CurveTilePlacer: could not close a tile loop around the polygon. "
				+ "Check that the TileSet has collision on physics layer %d." % physics_layer)
		_busy = false
		return

	_write_tiles(steps)
	print("CurveTilePlacer: %d surface tiles, max deviation %.0f px, %d ms"
			% [steps.size(), _max_dev, Time.get_ticks_msec() - t0])
	_busy = false


func clear_tiles() -> void:
	if polygon_node == null or tile_layer == null or tile_layer.tile_set == null:
		return
	_ts = Vector2(tile_layer.tile_set.tile_size)
	_outline = _outline_in_layer_space()
	var rect := _cell_rect()
	for x in range(rect.position.x, rect.end.x):
		for y in range(rect.position.y, rect.end.y):
			tile_layer.erase_cell(Vector2i(x, y))


# ============================================================ 1. outline setup

## Polygon in TileMapLayer space, oriented so the inside is on the right-hand
## side of travel (positive shoelace area with y pointing down).
func _outline_in_layer_space() -> PackedVector2Array:
	var xf := tile_layer.get_global_transform().affine_inverse() * polygon_node.get_global_transform()
	var pts := PackedVector2Array()
	for p in polygon_node.polygon:
		pts.append(xf * (p + polygon_node.offset))
	pts = _dedupe(pts)
	if _area(pts) < 0.0:
		pts.reverse()
	return pts


func _prepare_outline() -> void:
	_cum = PackedFloat64Array()
	_length = 0.0
	for i in _outline.size():
		_cum.append(_length)
		_length += _outline[i].distance_to(_outline[(i + 1) % _outline.size()])
	_info.clear()


## Cells around the polygon's bounding box (with margin).
func _cell_rect() -> Rect2i:
	var lo := Vector2i(2147483647, 2147483647)
	var hi := Vector2i(-2147483647, -2147483647)
	for p in _outline:
		var c := Vector2i(floori(p.x / _ts.x), floori(p.y / _ts.y))
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return Rect2i(lo - Vector2i(2, 2), hi - lo + Vector2i(5, 5))


# ================================================================ 2. library

func _build_library() -> void:
	_lib.clear()
	_pure_full.clear()
	_entry_index.clear()
	var h := _ts * 0.5
	var src := tile_layer.tile_set.get_source(atlas_source_id) as TileSetAtlasSource
	if src == null:
		return

	for i in src.get_tiles_count():
		var coords: Vector2i = src.get_tile_id(i)
		var td: TileData = src.get_tile_data(coords, 0)
		if td == null or td.get_collision_polygons_count(physics_layer) != 1:
			continue
		var pts := _dedupe(td.get_collision_polygon_points(physics_layer, 0))
		if pts.size() < 3:
			continue
		var area := _area(pts)
		if absf(area) < 1.0:
			continue
		if area < 0.0:           # make every tile polygon clockwise like the outline
			pts.reverse()
			area = -area

		# which polygon edges lie on the tile border?
		var count := pts.size()
		var on_border: Array[bool] = []
		for k in count:
			on_border.append(_edge_on_border(pts[k], pts[(k + 1) % count], h))

		# find the single run of non-border edges = the surface
		var run_starts := 0
		var start := -1
		for k in count:
			if not on_border[k] and on_border[(k - 1 + count) % count]:
				run_starts += 1
				start = k
		if run_starts == 0:
			if coords != fill_tile and area >= _ts.x * _ts.y * 0.98:
				_pure_full[coords] = true
			continue
		if run_starts != 1:
			continue

		var profile := PackedVector2Array([pts[start]])
		var k2 := start
		while not on_border[k2]:
			k2 = (k2 + 1) % count
			profile.append(pts[k2])
		if profile.size() > 2 and not use_curved_corner_tiles:
			continue
		_add_piece(KIND_TILE, coords, profile, 0)

	# virtual pieces: surface running along the border of a plain full cell
	var corners := [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]
	for s in 4:
		for edge_count in [1, 2]:
			var profile := PackedVector2Array()
			for k in edge_count + 1:
				profile.append(corners[(s + k) % 4])
			_add_piece(KIND_FULL, Vector2i(-1, -1), profile, s)

	# index pieces by where they start, so a node can find the tiles that enter there
	for i in _lib.size():
		var key := _key((_lib[i] as Piece).a)
		if not _entry_index.has(key):
			_entry_index[key] = PackedInt32Array()
		_entry_index[key].append(i)


func _add_piece(kind: int, coords: Vector2i, profile: PackedVector2Array, first_edge: int) -> void:
	var pc := Piece.new()
	pc.kind = kind
	pc.coords = coords
	pc.profile = profile
	pc.a = profile[0]
	pc.b = profile[profile.size() - 1]
	pc.first_edge = first_edge
	_lib.append(pc)


func _edge_on_border(p: Vector2, q: Vector2, h: Vector2) -> bool:
	const E := 0.01
	if absf(p.x - h.x) < E and absf(q.x - h.x) < E: return true
	if absf(p.x + h.x) < E and absf(q.x + h.x) < E: return true
	if absf(p.y - h.y) < E and absf(q.y - h.y) < E: return true
	if absf(p.y + h.y) < E and absf(q.y + h.y) < E: return true
	return false


# ============================================================ 3. path search

## Returns the closed loop as an Array of {"cell": Vector2i, "piece": int}.
func _find_tile_loop() -> Array:
	for factor in DEVIATION_PASSES:
		_max_dev = factor * _ts.x
		_edges.clear()
		var best_cost := INF
		var best_steps: Array = []
		for start in _start_nodes():
			var found := _shortest_loop(start, best_cost)
			if not found.is_empty():
				best_cost = found["cost"]
				best_steps = found["steps"]
		if not best_steps.is_empty():
			return best_steps
	return []


## Candidate start nodes: tile entry points close to the outline near its first vertex.
func _start_nodes() -> Array:
	var v0 := _outline[0]
	var base := Vector2i(floori(v0.x / _ts.x), floori(v0.y / _ts.y))
	var seen := {}
	var found: Array = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var centre := _cell_centre(base + Vector2i(dx, dy))
			for pc: Piece in _lib:
				var key := _key(centre + pc.a)
				if seen.has(key):
					continue
				seen[key] = true
				var d := _info_at(centre + pc.a).x
				if d <= _max_dev:
					found.append([d, key])
	found.sort_custom(func(x, y): return x[0] < y[0])
	var out: Array = []
	for i in mini(start_candidates, found.size()):
		out.append(found[i][1])
	return out


## Dijkstra: cheapest chain of tiles that leaves `start` and comes back to it.
## `limit` = best loop cost found so far (anything worse is abandoned).
func _shortest_loop(start: Vector2i, limit: float) -> Dictionary:
	var dist := {start: 0.0}
	var came := {}                     # node -> {from, cell, piece}
	var heap: Array = [[0.0, start]]
	var best := limit
	var goal := {}

	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var cost: float = top[0]
		var node: Vector2i = top[1]
		if cost >= best:
			break
		if cost > dist[node]:
			continue                   # outdated heap entry
		var came_from_cell := Vector2i(-99999, -99999)
		if came.has(node):
			came_from_cell = came[node]["cell"]

		for edge: Dictionary in _edges_from(node):
			if edge["cell"] == came_from_cell:
				continue               # never use the same cell twice in a row
			var new_cost: float = cost + edge["cost"]
			if new_cost >= best:
				continue
			var to: Vector2i = edge["to"]
			if to == start:
				best = new_cost
				goal = {"from": node, "cell": edge["cell"], "piece": edge["piece"]}
			elif new_cost < dist.get(to, INF):
				dist[to] = new_cost
				came[to] = {"from": node, "cell": edge["cell"], "piece": edge["piece"]}
				_heap_push(heap, [new_cost, to])

	if goal.is_empty():
		return {}
	var steps: Array = [{"cell": goal["cell"], "piece": goal["piece"]}]
	var back: Vector2i = goal["from"]
	while back != start:
		var c: Dictionary = came[back]
		steps.push_front({"cell": c["cell"], "piece": c["piece"]})
		back = c["from"]
	return {"cost": best, "steps": steps}


## All tiles that can be placed starting at `node` (cached).
func _edges_from(node: Vector2i) -> Array:
	if _edges.has(node):
		return _edges[node]
	var list: Array = []
	var p := Vector2(node) / KEY_SCALE
	for cell: Vector2i in _cells_touching(p):
		var centre := _cell_centre(cell)
		var rel_key := _key(p - centre)
		if not _entry_index.has(rel_key):
			continue
		for pi in _entry_index[rel_key]:
			var pc: Piece = _lib[pi]
			var cost := _tile_cost(p, centre, pc)
			if cost >= 0.0:
				list.append({"to": _key(centre + pc.b), "cell": cell, "piece": pi, "cost": cost})
	_edges[node] = list
	return list


## Cost of placing `pc` in the cell at `centre`, entering at point `p`.
## Returns -1 if the tile is not acceptable here.
func _tile_cost(p: Vector2, centre: Vector2, pc: Piece) -> float:
	var pts := PackedVector2Array()
	for v in pc.profile:
		pts.append(centre + v)
	var q := pts[pts.size() - 1]

	# 1) must move forward along the outline (rejects reversed / sideways tiles)
	var chord := p.distance_to(q)
	if chord < 1.0:
		return -1.0
	var forward := _advance(p, q)
	if forward < min_forward_ratio * chord or forward > 3.0 * chord:
		return -1.0

	# 2) must stay close to the outline; cost = integral of distance along the tile
	var cost := 0.001                  # tiny constant so ties are stable
	for k in pts.size() - 1:
		var s0 := pts[k]
		var s1 := pts[k + 1]
		var d0 := _info_at(s0).x
		var dm := _info_at((s0 + s1) * 0.5).x
		var d1 := _info_at(s1).x
		if maxf(d0, maxf(dm, d1)) > _max_dev:
			return -1.0
		cost += s0.distance_to(s1) * (d0 + 2.0 * dm + d1) * 0.25
	return cost


## Cells whose border contains point p (1 to 4 cells).
func _cells_touching(p: Vector2) -> Array:
	var out: Array = []
	for x in _cell_span(p.x / _ts.x):
		for y in _cell_span(p.y / _ts.y):
			out.append(Vector2i(x, y))
	return out


func _cell_span(v: float) -> Array:
	var nearest := roundi(v)
	if absf(v - float(nearest)) < 0.002:   # exactly on a grid line: both sides
		return [nearest - 1, nearest]
	return [floori(v)]


# ---- distance / arc length of the outline, cached per point

## x = distance from point to outline, y = arc length of the nearest outline point.
func _info_at(p: Vector2) -> Vector2:
	var key := _key(p)
	if _info.has(key):
		return _info[key]
	var q := Vector2(key) / KEY_SCALE
	var best_d := INF
	var best_s := 0.0
	var n := _outline.size()
	for i in n:
		var a := _outline[i]
		var closest := Geometry2D.get_closest_point_to_segment(q, a, _outline[(i + 1) % n])
		var d := q.distance_to(closest)
		if d < best_d:
			best_d = d
			best_s = _cum[i] + a.distance_to(closest)
	var result := Vector2(best_d, best_s)
	_info[key] = result
	return result


## Signed distance travelled along the outline when moving from point a to point b.
func _advance(a: Vector2, b: Vector2) -> float:
	var d := _info_at(b).y - _info_at(a).y
	if d > _length * 0.5:
		d -= _length
	elif d < -_length * 0.5:
		d += _length
	return d


# ---- minimal binary min-heap of [priority, item]

func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if heap[parent][0] <= heap[i][0]:
			break
		var tmp = heap[parent]
		heap[parent] = heap[i]
		heap[i] = tmp
		i = parent


func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var m := i
			if l < n and heap[l][0] < heap[m][0]:
				m = l
			if r < n and heap[r][0] < heap[m][0]:
				m = r
			if m == i:
				break
			var tmp = heap[m]
			heap[m] = heap[i]
			heap[i] = tmp
			i = m
	return top


# ============================================================ 4. write tiles

func _write_tiles(steps: Array) -> void:
	# surface tiles (a real slope tile beats a flat end cap if a cell is used twice)
	var surface := {}   # cell -> {"prio": int, "coords": Vector2i}
	for i in steps.size():
		var cell: Vector2i = steps[i]["cell"]
		var pc: Piece = _lib[steps[i]["piece"]]
		var entry := {"prio": 2, "coords": pc.coords}
		if pc.kind == KIND_FULL:
			entry = {"prio": 1, "coords": _find_cap(steps, i)}
		if not surface.has(cell) or surface[cell]["prio"] < entry["prio"]:
			surface[cell] = entry

	# the surface loop separates inside from outside; flood-fill every other region
	# (4-connected) and decide inside/outside by majority vote of its cell centres
	var rect := _cell_rect()
	var seen := {}
	for x in range(rect.position.x, rect.end.x):
		for y in range(rect.position.y, rect.end.y):
			var first := Vector2i(x, y)
			if surface.has(first) or seen.has(first):
				continue
			var region: Array = []
			var stack: Array = [first]
			var votes := 0
			seen[first] = true
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				region.append(c)
				if Geometry2D.is_point_in_polygon(_cell_centre(c), _outline):
					votes += 1
				for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var nb: Vector2i = c + dir
					if rect.has_point(nb) and not surface.has(nb) and not seen.has(nb):
						seen[nb] = true
						stack.append(nb)
			var inside := votes * 2 > region.size()
			for c: Vector2i in region:
				if inside:
					tile_layer.set_cell(c, atlas_source_id, fill_tile)
				elif clean_area:
					tile_layer.erase_cell(c)

	for cell: Vector2i in surface:
		tile_layer.set_cell(cell, atlas_source_id, surface[cell]["coords"])


## End cap for a flat run: the atlas tile that sits beside the neighbouring slope
## tile (same offset as in the map), e.g. the tile after the last 1x8 piece.
func _find_cap(steps: Array, i: int) -> Vector2i:
	var n := steps.size()
	for offset in [1, -1]:
		var other: Dictionary = steps[((i + offset) % n + n) % n]
		var nb: Piece = _lib[other["piece"]]
		if nb.kind != KIND_TILE:
			continue
		var delta: Vector2i = (steps[i]["cell"] as Vector2i) - (other["cell"] as Vector2i)
		var guess: Vector2i = nb.coords + delta
		if _pure_full.has(guess):
			return guess
	match (_lib[steps[i]["piece"]] as Piece).first_edge:
		0: return cap_top
		1: return cap_right
		2: return cap_bottom
		_: return cap_left


# ================================================================== helpers

func _cell_centre(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * _ts

func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * KEY_SCALE), roundi(p.y * KEY_SCALE))

func _area(p: PackedVector2Array) -> float:
	var s := 0.0
	var m := p.size()
	for i in m:
		var q := p[(i + 1) % m]
		s += p[i].x * q.y - q.x * p[i].y
	return s * 0.5

func _dedupe(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in p:
		if out.is_empty() or out[out.size() - 1].distance_to(v) > 0.001:
			out.append(v)
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= 0.001:
		out.remove_at(out.size() - 1)
	return out
