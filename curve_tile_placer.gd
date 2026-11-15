@tool
class_name CurveTilePlacer
extends Node2D
## LEVEL GENERATOR. Fits a TileMapLayer to Polygon2D outlines using the sloped
## collision tiles of the TileSet, fills the ground with a TileSet terrain, and
## stitches the result onto terrain that already exists outside the builder range.
##
## HOW TO USE
##  * Draw the ground as one or more Polygon2D (solid inside). Don't overlap them.
##  * Optional: add a ReferenceRect and assign it to `builder_range`. Only cells
##    inside it are written/erased, polygons are clipped to it, and the surface
##    is connected to the tiles already placed just outside it. Generate a level
##    chunk by chunk by moving the rect; neighbouring chunks line up.
##
## ALGORITHM
##  1. LIBRARY   Every TileSet tile with exactly one non-border collision edge run
##               becomes a Piece: a surface line from point A to point B on the
##               tile border, solid on the right-hand side of travel. Flips and
##               rotations are found automatically. Plain full tiles give flat
##               pieces (floor / wall / ceiling along a cell border).##  2. REGIONS   The polygon is clipped to the builder range. Edges that lie on the
##               range border are SEAMS (terrain continues outside). What remains
##               is either a closed loop or open chains running seam to seam.
##  2b. SMOOTH   `polygon_roughness` controls cleanup of the input outline before fitting.
##  2c. GEOMETRY `geometry_roughness` trades outline accuracy for fewer fitted surface tiles
##               and smoother collision traversal by preferring longer tile pieces.
##  3. FLATS     Edges within `cardinal_snap_degrees` of 0/90/180/270 are flattened
##               (and put on the tile grid), so near-flat ground becomes flat tiles.
##  4. CONNECT   An open chain starts/ends on a node of the range border. If tiles
##               exist just outside, it starts/ends exactly at their surface end
##               (the outline is blended towards it); otherwise it ends on a border
##               node so the next chunk can connect to it later.
##  5. SEARCH    Dijkstra over a graph where a node is a point on a cell border and
##               a tile is an edge A -> B, so a chain is ALWAYS continuous. Cost =
##               how far the tile is from the outline. Tiles must move FORWARD.
##  6. WRITE     Slope tiles are written as they are. Cells near slopes use `fill_tile`;
##               the rest is filled via set_cells_terrain_connect, which also joins it
##               to terrain outside the range. End caps are flushed after terrain-connect
##               so they cannot be overwritten by terrain variants.

const KIND_TILE := 0
const KIND_FULL := 1        # virtual piece: full cell, surface along its border
const KEY_SCALE := 4.0      # node keys are points rounded to 1/4 px
## Allowed distance between tile surface and outline, in tiles. Tried in order;
## the first value that yields a result wins (tight = most faithful).
const DEVIATION_PASSES := [0.25, 0.4, 0.6, 0.9, 1.4]
const ANCHOR_SPAN := 4      # cells searched along the range border for existing terrain
## FULL piece side index -> direction of the neighbour cell that must be air.
const SIDE_DIRS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

## Polygon roughness tuning. Values reached at polygon_roughness 0.
const SIMPLIFY_MAX_TILES := 0.5      # wobble smaller than this (in tiles) is flattened out
const SMOOTH_MAX_RADIUS_TILES := 6.0 # corner radius (in tiles), limited by the length of the adjacent lines
const MAX_ROUND_TURN := 2.6          # corners sharper than this (radians, ~150 deg) stay sharp
const ARC_STEP_DEGREES := 12.0       # angular step used to sample rounded corners
const ANGLE_WEIGHT := 0.3            # strength of the "tile slope must match the line" cost
const GEOMETRY_TILE_PENALTY := 0.22  # tile-area cost per extra fitted surface piece at geometry_roughness 0
const GEOMETRY_MAX_DEVIATION_SCALE := 1.75 # lower geometry roughness allows less exact fits
## A tile whose direction differs from the outline direction by more than this (radians,
## 75 deg) is never used: that is what produced dents / perpendicular slopes.
const MAX_TILE_TURN := 1.309

class Piece:
	var kind := KIND_TILE
	var coords := Vector2i(-1, -1)
	var profile := PackedVector2Array()  # relative to tile centre, A -> B
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var first_edge := 0                  # FULL pieces: 0 top, 1 right, 2 bottom, 3 left

@export var polygon_node: Polygon2D
## More ground polygons generated in the same pass.
@export var extra_polygons: Array[Polygon2D] = []
@export var tile_layer: TileMapLayer
@export var atlas_source_id := 0
@export var physics_layer := 0
## Erase old tiles inside the builder range before placing.
@export var clean_area := true

@export_group("Builder range")
## Any Control (use a ReferenceRect). Empty = the area around the polygons.
@export var builder_range: Control
## Connect the surface to tiles that already exist just outside the range.
@export var connect_to_outside := true
## Over how many tiles the outline is blended towards the existing terrain.
@export_range(1, 12) var blend_tiles := 3

@export_group("Flat ground")
## Outline edges this close to 0/90/180/270 degrees become perfectly flat/vertical.
@export_range(0.0, 15.0) var cardinal_snap_degrees := 5.0
## Put flattened runs on the tile grid so they match flat tiles exactly.
@export var snap_flats_to_grid := true

@export_group("Filling")
## Plain interior tile. Used next to slope tiles (and everywhere if no terrain).
@export var fill_tile := Vector2i(8, 3)
## Terrain used for the ground and flat surfaces. -1 = use fill_tile everywhere.
@export var terrain_set := 0
@export var terrain_id := 0
## Interior cells within this many cells of a slope tile use fill_tile, not terrain.
@export_range(0, 6) var slope_fill_radius := 2

@export_group("Fitting")
## Also allow the quarter-circle corner tiles (off = only straight slopes).
@export var use_curved_corner_tiles := false
## A tile must advance along the outline by at least this fraction of its length.
## Higher = stricter against wrong-direction tiles.
@export_range(0.1, 0.95) var min_forward_ratio := 0.5
## How many start points are tried when closing the loop / starting a chain.
@export_range(1, 64) var start_candidates := 24

@export_group("Roughness")
## Controls the existing outline cleanup before tile fitting.
## 1 = preserve the level-builder Polygon2D outline; towards 0, remove small wobble,
## simplify line segments, and round corners. This changes the polygon being fitted.
@export_range(0.0, 1.0, 0.01) var polygon_roughness := 1.0
## Controls how closely the fitted tile-collision surface follows the (possibly smoothed)
## outline. 1 = highest fidelity, preserving the previous tile-selection behaviour.
## Towards 0, the search tolerates more deviation and penalizes each extra surface piece,
## preferring longer/curved tile profiles where available. This aims to use fewer fitted
## surface collision tiles for smoother player movement, at the cost of accuracy.
## This is a tile-selection heuristic; available TileSet profiles limit the reduction.
@export_range(0.0, 1.0, 0.01) var geometry_roughness := 1.0

@export_group("End caps (fallback)")
## Used for a flat run right next to a slope when the atlas has no matching tile.
@export var cap_top := Vector2i(8, 0)
@export var cap_right := Vector2i(10, 14)
@export var cap_bottom := Vector2i(8, 11)
@export var cap_left := Vector2i(7, 14)

@export_group("Slope transition end caps")
## Optional atlas coordinates for caps placed INSIDE the ground where two differently
## angled, non-flat slope tiles meet. Set a coordinate to (-1, -1) to use automatic
## atlas-neighbour detection, then fall back to cap_top/right/bottom/left.
## Direction means the side of the cap cell facing the slope junction.
@export var cap_slope_transition_top := Vector2i(-1, -1)
@export var cap_slope_transition_right := Vector2i(-1, -1)
@export var cap_slope_transition_bottom := Vector2i(-1, -1)
@export var cap_slope_transition_left := Vector2i(-1, -1)
## Ignore very small changes in angle; larger turns between two diagonal slopes get a cap.
@export_range(1.0, 90.0, 1.0) var slope_transition_min_angle_degrees := 15.0

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
var _zone := Rect2i()              # cells this call may write (the builder range)
var _zone_px := Rect2()            # the same in layer pixels
var _use_range := false            # true when builder_range is set (polygons get clipped)
var _use_terrain := false
var _terrain_cells := {}           # cell -> true, filled with terrain at the very end
var _pending_caps := {}             # cell -> {"coords": Vector2i, "force": bool}; written after terrain
var _surface_slope_cells := {}      # cells occupied by actual slope tiles, protects transition caps
var _outline := PackedVector2Array()
var _closed := true
var _cum := PackedFloat64Array()   # arc length at the start of each outline edge
var _length := 0.0
var _lib: Array = []               # Array of Piece
var _entry_index := {}             # relative entry key -> PackedInt32Array of lib indices
var _pure_full := {}               # atlas coords of plain full tiles (end caps)
var _solid := {}                   # atlas coords of every full solid tile (incl. fill_tile)
var _by_coords := {}               # atlas coords -> Array of Piece (slope tiles)
var _edge_piece: Array = [null, null, null, null]   # single-edge FULL piece per side
var _info := {}                    # point key -> Vector2(distance to outline, arc length)
var _edges := {}                   # node key -> Array of edge dictionaries
var _max_dev := 16.0
var _guard_angle := true           # reject tiles pointing across the outline

func _process(delta: float) -> void:
	if not live_update or polygon_node == null or tile_layer == null:
		return
	var h := _watch_hash()
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

func _watch_hash() -> int:
	var parts: Array = [tile_layer.global_transform, polygon_roughness, geometry_roughness]
	for p in _all_polygons():
		parts.append([p.polygon, p.global_transform, p.offset])
	if builder_range != null:
		parts.append([builder_range.global_position, builder_range.size])
	return hash(parts)

# ================================================================= public API

func generate() -> void:
	if _busy:
		return
	if _all_polygons().is_empty() or tile_layer == null or tile_layer.tile_set == null:
		push_warning("CurveTilePlacer: assign polygon_node and a tile_layer that has a TileSet.")
		return
	_busy = true
	var t0 := Time.get_ticks_msec()
	_ts = Vector2(tile_layer.tile_set.tile_size)

	var rings := _rings()
	if rings.is_empty():
		_busy = false
		return
	_setup_zone(rings)

	_build_library()
	if _lib.is_empty():
		push_warning("CurveTilePlacer: no usable slope tiles found in the TileSet source.")
		_busy = false
		return

	_use_terrain = _terrain_valid()
	_terrain_cells.clear()
	_pending_caps.clear()
	_surface_slope_cells.clear()
	if clean_area:
		_erase_zone()

	var total := 0
	for ring: PackedVector2Array in rings:
		for region: PackedVector2Array in _clip_to_zone(ring):
			total += _build_region(region)
	_apply_terrain()
	_apply_end_caps()
	print("CurveTilePlacer: %d surface tiles, %d terrain cells, %d ms"
			% [total, _terrain_cells.size(), Time.get_ticks_msec() - t0])
	_busy = false


func clear_tiles() -> void:
	if tile_layer == null or tile_layer.tile_set == null:
		return
	_ts = Vector2(tile_layer.tile_set.tile_size)
	var rings := _rings()
	if rings.is_empty() and builder_range == null:
		return
	_setup_zone(rings)
	_erase_zone()


# ============================================================== 1. setup

func _all_polygons() -> Array[Polygon2D]:
	var out: Array[Polygon2D] = []
	if polygon_node != null:
		out.append(polygon_node)
	for p in extra_polygons:
		if p != null and not out.has(p):
			out.append(p)
	return out


## Every polygon in TileMapLayer space, oriented so the inside is on the right-hand
## side of travel (positive shoelace area with y pointing down).
func _rings() -> Array:
	var out: Array = []
	for poly in _all_polygons():
		var xf := tile_layer.get_global_transform().affine_inverse() * poly.get_global_transform()
		var pts := PackedVector2Array()
		for p in poly.polygon:
			pts.append(xf * (p + poly.offset))
		pts = _dedupe(pts)
		if pts.size() < 3:
			continue
		if _area(pts) < 0.0:
			pts.reverse()
		out.append(pts)
	return out


func _setup_zone(rings: Array) -> void:
	_use_range = builder_range != null
	_zone = _zone_from_node() if _use_range else _derive_zone(rings)
	_zone_px = Rect2(Vector2(_zone.position) * _ts, Vector2(_zone.size) * _ts)


## Builder range control -> whole cells (so seams lie exactly on grid lines).
func _zone_from_node() -> Rect2i:
	var xf := tile_layer.get_global_transform().affine_inverse() * builder_range.get_global_transform()
	var r := Rect2(Vector2.ZERO, builder_range.size)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var q: Vector2 = xf * corner
		lo = lo.min(q)
		hi = hi.max(q)
	var c0 := Vector2i((lo / _ts).floor())
	var c1 := Vector2i((hi / _ts).ceil())
	return Rect2i(c0, Vector2i(maxi(c1.x - c0.x, 1), maxi(c1.y - c0.y, 1)))


## Cells around all polygons (with margin) when no builder range is set.
func _derive_zone(rings: Array) -> Rect2i:
	var lo := Vector2i(2147483647, 2147483647)
	var hi := Vector2i(-2147483647, -2147483647)
	for ring: PackedVector2Array in rings:
		for p in ring:
			var c := Vector2i(floori(p.x / _ts.x), floori(p.y / _ts.y))
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
			hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return Rect2i(lo - Vector2i(2, 2), hi - lo + Vector2i(5, 5))


func _erase_zone() -> void:
	for x in range(_zone.position.x, _zone.end.x):
		for y in range(_zone.position.y, _zone.end.y):
			tile_layer.erase_cell(Vector2i(x, y))


func _terrain_valid() -> bool:
	if terrain_id < 0:
		return false
	var ts := tile_layer.tile_set
	if terrain_set >= ts.get_terrain_sets_count() or terrain_id >= ts.get_terrains_count(terrain_set):
		push_warning("CurveTilePlacer: terrain %d (set %d) does not exist in the TileSet; using fill_tile instead."
				% [terrain_id, terrain_set])
		return false
	return true


# ====================================================== 2. clipping to the range

func _clip_to_zone(ring: PackedVector2Array) -> Array:
	if not _use_range:
		return [ring]
	var r := _zone_px
	var rect := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
			Vector2(r.position.x, r.end.y)])
	var out: Array = []
	for piece: PackedVector2Array in Geometry2D.intersect_polygons(ring, rect):
		var p := _dedupe(piece)
		if p.size() < 3:
			continue
		if _area(p) < 0.0:
			p.reverse()
		out.append(p)
	return out


## Splits a clipped region into jobs: a closed loop (no seams) or open chains that
## run from one seam to the next along the true outline.
func _split_ring(ring: PackedVector2Array) -> Array:
	if not _use_range:
		return [{"pts": ring, "closed": true}]
	var n := ring.size()
	var seam: Array[bool] = []
	var any_seam := false
	for i in n:
		var s := _is_seam(ring[i], ring[(i + 1) % n])
		seam.append(s)
		any_seam = any_seam or s
	if not any_seam:
		return [{"pts": ring, "closed": true}]
	var jobs: Array = []
	for i in n:
		if seam[(i - 1 + n) % n] and not seam[i]:
			var pts := PackedVector2Array([ring[i]])
			var j := i
			while not seam[j]:
				j = (j + 1) % n
				pts.append(ring[j])
			pts = _dedupe(pts, false)
			if pts.size() >= 2:
				jobs.append({"pts": pts, "closed": false})
	return jobs


func _is_seam(a: Vector2, b: Vector2) -> bool:
	const E := 0.05
	var r := _zone_px
	if absf(a.x - r.position.x) < E and absf(b.x - r.position.x) < E: return true
	if absf(a.x - r.end.x) < E and absf(b.x - r.end.x) < E: return true
	if absf(a.y - r.position.y) < E and absf(b.y - r.position.y) < E: return true
	if absf(a.y - r.end.y) < E and absf(b.y - r.end.y) < E: return true
	return false


## Which border of the range a point lies on: (-1,0) left, (1,0) right, (0,-1) top,
## (0,1) bottom, (0,0) none.
func _side_of(p: Vector2) -> Vector2i:
	const E := 0.5
	if absf(p.x - _zone_px.position.x) < E: return Vector2i(-1, 0)
	if absf(p.x - _zone_px.end.x) < E: return Vector2i(1, 0)
	if absf(p.y - _zone_px.position.y) < E: return Vector2i(0, -1)
	if absf(p.y - _zone_px.end.y) < E: return Vector2i(0, 1)
	return Vector2i.ZERO


## Bit mask of the coordinate that keeps a point on its border (1 = x, 2 = y).
func _side_lock(side: Vector2i) -> int:
	if side.x != 0: return 1
	if side.y != 0: return 2
	return 0


func _on_border(n: Vector2, side: Vector2i) -> bool:
	if side.x < 0: return absf(n.x - _zone_px.position.x) < 0.01
	if side.x > 0: return absf(n.x - _zone_px.end.x) < 0.01
	if side.y < 0: return absf(n.y - _zone_px.position.y) < 0.01
	return absf(n.y - _zone_px.end.y) < 0.01


## Cells along a range border near point p: the first row inside the range
## (outside = false) or the row of cells just outside it (outside = true).
func _border_cells(p: Vector2, side: Vector2i, outside: bool) -> Array:
	var out: Array = []
	var c := Vector2i(floori(p.x / _ts.x), floori(p.y / _ts.y))
	for k in range(-ANCHOR_SPAN, ANCHOR_SPAN + 1):
		var cell: Vector2i
		var along: int
		var lo: int
		var hi: int
		if side.x != 0:
			var x: int = _zone.position.x if side.x < 0 else _zone.end.x - 1
			cell = Vector2i(x + (side.x if outside else 0), c.y + k)
			along = cell.y
			lo = _zone.position.y
			hi = _zone.end.y
		else:
			var y: int = _zone.position.y if side.y < 0 else _zone.end.y - 1
			cell = Vector2i(c.x + k, y + (side.y if outside else 0))
			along = cell.x
			lo = _zone.position.x
			hi = _zone.end.x
		if along >= lo and along < hi:
			out.append(cell)
	return out


# ============================================================ 3. build a region

## Fits every chain of one clipped region and writes it. Returns the tile count.
func _build_region(ring: PackedVector2Array) -> int:
	var chains: Array = []
	var count := 0
	var failed := false
	for job: Dictionary in _split_ring(ring):
		var pts: PackedVector2Array = job["pts"]
		var closed: bool = job["closed"]
		pts = _smooth_outline(pts, closed)
		var a_start: Variant = null
		var a_end: Variant = null
		var lock_a := 0
		var lock_b := 0
		if not closed:
			var s_side := _side_of(pts[0])
			var e_side := _side_of(pts[pts.size() - 1])
			a_start = _find_anchor(pts[0], s_side, true)
			a_end = _find_anchor(pts[pts.size() - 1], e_side, false)
			if a_start != null or a_end != null:
				pts = _blend_ends(pts, a_start, a_end)
			lock_a = 3 if a_start != null else _side_lock(s_side)
			lock_b = 3 if a_end != null else _side_lock(e_side)
		pts = _snap_cardinal(pts, closed, lock_a, lock_b)
		if pts.size() < (3 if closed else 2):
			failed = true
			continue

		_outline = pts
		_closed = closed
		_prepare_outline()
		var steps: Array = _find_tile_loop() if closed else _find_tile_path(a_start, a_end)
		if steps.is_empty():
			push_warning("CurveTilePlacer: could not fit a tile chain to part of the outline. "
					+ "Check that the TileSet has collision on physics layer %d." % physics_layer)
			failed = true
			continue
		chains.append({"steps": steps, "closed": closed})
		count += steps.size()
	if failed:
		return count      # leave this region untouched rather than fill the wrong side
	_write_region(ring, chains)
	return count


## ============================================ 3b. polygon roughness (smoothing)

## roughness 1: unchanged. Lower: (1) Douglas-Peucker removes wobble so lines become
## straight, (2) every remaining corner is replaced by a circular arc tangent to both
## neighbouring lines. End points of open chains never move (range border / anchors).
func _smooth_outline(pts: PackedVector2Array, closed: bool) -> PackedVector2Array:
	var smooth := 1.0 - polygon_roughness
	if smooth <= 0.001 or pts.size() < 3:
		return pts
	var out := _simplify(pts, closed, smooth * SIMPLIFY_MAX_TILES * _ts.x)
	out = _round_corners(out, closed, smooth * SMOOTH_MAX_RADIUS_TILES * _ts.x)
	out = _dedupe(out, closed)
	return out if out.size() >= (3 if closed else 2) else pts


func _simplify(pts: PackedVector2Array, closed: bool, tol: float) -> PackedVector2Array:
	if tol <= 0.0:
		return pts
	if not closed:
		return _rdp(pts, tol)
	# closed: split at the vertex farthest from vertex 0 so both halves are open polylines
	var far := 0
	var far_d := -1.0
	for i in pts.size():
		var d := pts[0].distance_squared_to(pts[i])
		if d > far_d:
			far_d = d
			far = i
	if far == 0:
		return pts
	var half_a := pts.slice(0, far + 1)
	var half_b := pts.slice(far)
	half_b.append(pts[0])
	var a := _rdp(half_a, tol)
	var b := _rdp(half_b, tol)
	var out := a.duplicate()
	for i in range(1, b.size() - 1):
		out.append(b[i])
	return out if out.size() >= 3 else pts


func _rdp(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var i0: int = seg[0]
		var i1: int = seg[1]
		var worst := -1.0
		var worst_i := -1
		for i in range(i0 + 1, i1):
			var d := pts[i].distance_to(Geometry2D.get_closest_point_to_segment(pts[i], pts[i0], pts[i1]))
			if d > worst:
				worst = d
				worst_i = i
		if worst > tol:
			keep[worst_i] = 1
			stack.append([i0, worst_i])
			stack.append([worst_i, i1])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out


## Replaces each corner by a circular arc (fillet) of at most `radius`. The arc may use
## at most half of each adjacent line, so neighbouring arcs never overlap and straight
## lines stay straight in between.
func _round_corners(pts: PackedVector2Array, closed: bool, radius: float) -> PackedVector2Array:
	var n := pts.size()
	if radius <= 0.0 or n < 3:
		return pts
	var out := PackedVector2Array()
	if not closed:
		out.append(pts[0])
	for i in n:
		if not closed and (i == 0 or i == n - 1):
			continue
		var prev := pts[(i - 1 + n) % n]
		var cur := pts[i]
		var next := pts[(i + 1) % n]
		var d1 := cur - prev
		var d2 := next - cur
		var l1 := d1.length()
		var l2 := d2.length()
		if l1 < 0.001 or l2 < 0.001:
			out.append(cur)
			continue
		d1 /= l1
		d2 /= l2
		var turn := acos(clampf(d1.dot(d2), -1.0, 1.0))
		if turn < 0.03 or turn > MAX_ROUND_TURN:
			out.append(cur)
			continue
		var half_tan := tan(turn * 0.5)
		var t := minf(radius * half_tan, 0.5 * minf(l1, l2))   # distance corner -> arc start/end
		var r := t / half_tan
		var sgn := signf(d1.cross(d2))
		var start := cur - d1 * t
		var centre := start + d1.rotated(sgn * PI * 0.5) * r
		var radial := start - centre
		var steps := maxi(1, ceili(turn / deg_to_rad(ARC_STEP_DEGREES)))
		for k in steps + 1:
			out.append(centre + radial.rotated(sgn * turn * float(k) / float(steps)))
	if not closed:
		out.append(pts[n - 1])
	return out


# ====================================================== 4. flat ground (snapping)

## Flattens runs of edges that are within `cardinal_snap_degrees` of horizontal or
## vertical. All vertices of a run get the same y (or x), optionally on the tile
## grid. `lock_a` / `lock_b` (bit 1 = x, bit 2 = y) pin coordinates of the first /
## last vertex of an open polyline (range border, anchors).
func _snap_cardinal(pts: PackedVector2Array, closed: bool, lock_a := 0, lock_b := 0) -> PackedVector2Array:
	var n := pts.size()
	var m := n if closed else n - 1
	if m < 1 or cardinal_snap_degrees <= 0.0:
		return pts
	var tol := deg_to_rad(cardinal_snap_degrees)
	var axis := PackedInt32Array()      # per edge: 0 free, 1 horizontal, 2 vertical
	axis.resize(m)
	for i in m:
		var d := pts[(i + 1) % n] - pts[i]
		var ax := absf(d.x)
		var ay := absf(d.y)
		if ax + ay < 0.001:
			axis[i] = 0
		elif atan2(ay, ax) <= tol:
			axis[i] = 1
		elif atan2(ax, ay) <= tol:
			axis[i] = 2

	var start_edge := 0
	if closed:
		# begin at an edge whose axis differs from the previous one, so no run wraps
		var found := false
		for i in m:
			if axis[i] != axis[(i - 1 + m) % m]:
				start_edge = i
				found = true
				break
		if not found:
			return pts

	var out := pts.duplicate()
	var i := 0
	while i < m:
		var kind := axis[(start_edge + i) % m]
		if kind == 0:
			i += 1
			continue
		var j := i
		while j + 1 < m and axis[(start_edge + j + 1) % m] == kind:
			j += 1
		var verts: Array[int] = []
		for k in range(i, j + 2):
			verts.append((start_edge + k) % n)
		_flatten_run(out, verts, kind, closed, lock_a, lock_b)
		i = j + 1
	return _dedupe(out, closed)


func _flatten_run(pts: PackedVector2Array, verts: Array[int], kind: int, closed: bool,
		lock_a: int, lock_b: int) -> void:
	var comp := 1 if kind == 1 else 0     # horizontal run -> equalise y, vertical -> x
	var bit := 2 if kind == 1 else 1
	var last := pts.size() - 1
	var movable: Array[int] = []
	var pinned := 0.0
	var pinned_count := 0
	var sum := 0.0
	for v in verts:
		sum += pts[v][comp]
		var locked := false
		if not closed:
			if v == 0 and (lock_a & bit) != 0: locked = true
			if v == last and (lock_b & bit) != 0: locked = true
		if locked:
			pinned += pts[v][comp]
			pinned_count += 1
		else:
			movable.append(v)
	if movable.is_empty():
		return
	var target := sum / verts.size()
	if pinned_count > 0:
		target = pinned / pinned_count
	elif snap_flats_to_grid:
		var g: float = _ts[comp]
		target = roundf(target / g) * g
	for v in movable:
		var p := pts[v]
		p[comp] = target
		pts[v] = p


# ============================================== 5. connecting to outside terrain

## The surface end of existing tiles just outside the range that this chain should
## continue (is_start) or run into (not is_start). Returns a Vector2 node or null.
func _find_anchor(p: Vector2, side: Vector2i, is_start: bool) -> Variant:
	if not connect_to_outside or side == Vector2i.ZERO:
		return null
	var best: Variant = null
	var best_d := INF
	for cell: Vector2i in _border_cells(p, side, true):
		var centre := _cell_centre(cell)
		for pc: Piece in _existing_pieces(cell):
			var node := centre + (pc.b if is_start else pc.a)
			if not _on_border(node, side):
				continue
			var d := node.distance_to(p)
			if d < best_d:
				best_d = d
				best = node
	return best


## Surface pieces of a tile that already exists in the layer (outside the range).
func _existing_pieces(cell: Vector2i) -> Array:
	if tile_layer.get_cell_source_id(cell) != atlas_source_id:
		return []
	var coords := tile_layer.get_cell_atlas_coords(cell)
	if _by_coords.has(coords):
		return _by_coords[coords]
	if not _solid.has(coords):
		return []
	var out: Array = []
	for s in 4:
		if _is_air(cell + (SIDE_DIRS[s] as Vector2i)) and _edge_piece[s] != null:
			out.append(_edge_piece[s])
	return out


## Cells inside the range are unknown (about to be rewritten), so never "air".
func _is_air(cell: Vector2i) -> bool:
	if _zone.has_point(cell):
		return false
	return tile_layer.get_cell_source_id(cell) == -1


## Pulls the ends of an open outline onto the anchors: the first/last part of the
## outline (about `blend_tiles` tiles) is replaced by a straight run to the anchor.
func _blend_ends(pts: PackedVector2Array, a_start: Variant, a_end: Variant) -> PackedVector2Array:
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	var blend := minf(float(blend_tiles) * _ts.x, total * 0.4)
	var out := pts.duplicate()
	if a_start != null:
		out = _trim_start(out, a_start as Vector2, blend)
	if a_end != null:
		out.reverse()
		out = _trim_start(out, a_end as Vector2, blend)
		out.reverse()
	return out


func _trim_start(pts: PackedVector2Array, anchor: Vector2, blend: float) -> PackedVector2Array:
	var acc := 0.0
	var k := 1
	while k < pts.size() - 1:
		acc += pts[k - 1].distance_to(pts[k])
		if acc >= blend:
			break
		k += 1
	var out := PackedVector2Array([anchor])
	out.append_array(pts.slice(k))
	return out


# ================================================================ 6. library

func _build_library() -> void:
	_lib.clear()
	_pure_full.clear()
	_solid.clear()
	_by_coords.clear()
	_entry_index.clear()
	_edge_piece = [null, null, null, null]
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
			if area >= _ts.x * _ts.y * 0.98:
				_solid[coords] = true
				if coords != fill_tile:
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
		var pc := _add_piece(KIND_TILE, coords, profile, 0)
		if not _by_coords.has(coords):
			_by_coords[coords] = []
		_by_coords[coords].append(pc)

	# virtual pieces: surface running along the border of a plain full cell
	var corners := [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]
	for s in 4:
		for edge_count in [1, 2]:
			var profile := PackedVector2Array()
			for k in edge_count + 1:
				profile.append(corners[(s + k) % 4])
			var pc := _add_piece(KIND_FULL, Vector2i(-1, -1), profile, s)
			if edge_count == 1:
				_edge_piece[s] = pc

	# index pieces by where they start, so a node can find the tiles that enter there
	for i in _lib.size():
		var key := _key((_lib[i] as Piece).a)
		if not _entry_index.has(key):
			_entry_index[key] = PackedInt32Array()
		_entry_index[key].append(i)


func _add_piece(kind: int, coords: Vector2i, profile: PackedVector2Array, first_edge: int) -> Piece:
	var pc := Piece.new()
	pc.kind = kind
	pc.coords = coords
	pc.profile = profile
	pc.a = profile[0]
	pc.b = profile[profile.size() - 1]
	pc.first_edge = first_edge
	_lib.append(pc)
	return pc


func _edge_on_border(p: Vector2, q: Vector2, h: Vector2) -> bool:
	const E := 0.01
	if absf(p.x - h.x) < E and absf(q.x - h.x) < E: return true
	if absf(p.x + h.x) < E and absf(q.x + h.x) < E: return true
	if absf(p.y - h.y) < E and absf(q.y - h.y) < E: return true
	if absf(p.y + h.y) < E and absf(q.y + h.y) < E: return true
	return false


# ============================================================ 7. path search

func _prepare_outline() -> void:
	_cum = PackedFloat64Array()
	_length = 0.0
	var n := _outline.size()
	var m := n if _closed else n - 1
	for i in m:
		_cum.append(_length)
		_length += _outline[i].distance_to(_outline[(i + 1) % n])
	_info.clear()


## Closed loop around the outline, as an Array of {"cell": Vector2i, "piece": int}.
func _find_tile_loop() -> Array:
	for guarded in [true, false]:       # second round = old behaviour, only if nothing fits
		_guard_angle = guarded
		var steps := _loop_search()
		if not steps.is_empty():
			return steps
	return []


func _loop_search() -> Array:
	for factor in DEVIATION_PASSES:
		_max_dev = factor * _ts.x * lerpf(1.0, GEOMETRY_MAX_DEVIATION_SCALE,
				1.0 - clampf(geometry_roughness, 0.0, 1.0))
		_edges.clear()
		var best_cost := INF
		var best_steps: Array = []
		for start in _start_keys(_outline[0]):
			var found := _shortest_loop(start, best_cost)
			if not found.is_empty():
				best_cost = found["cost"]
				best_steps = found["steps"]
		if not best_steps.is_empty():
			return best_steps
	return []


## Open chain from one range border to another. With an anchor the chain starts/ends
## exactly at the existing tile; otherwise on a node of the range border.
func _find_tile_path(a_start: Variant, a_end: Variant) -> Array:
	for guarded in [true, false]:
		_guard_angle = guarded
		var steps := _path_search(a_start, a_end)
		if not steps.is_empty():
			return steps
	return []


func _path_search(a_start: Variant, a_end: Variant) -> Array:
	var s_pt := _outline[0]
	var e_pt := _outline[_outline.size() - 1]
	var s_side := _side_of(s_pt)
	var e_side := _side_of(e_pt)
	for factor in DEVIATION_PASSES:
		_max_dev = factor * _ts.x * lerpf(1.0, GEOMETRY_MAX_DEVIATION_SCALE, 1.0 - clampf(geometry_roughness, 0.0, 1.0))
		_edges.clear()
		var starts: Array = []
		if a_start != null:
			starts.append([0.0, _key(a_start as Vector2)])
		else:
			starts = _free_nodes(s_pt, s_side, true)
		var goals := {}
		if a_end != null:
			goals[_key(a_end as Vector2)] = 0.0
		else:
			for g: Array in _free_nodes(e_pt, e_side, false):
				goals[g[1]] = g[0]
		if starts.is_empty() or goals.is_empty():
			continue
		var steps := _shortest_path(starts, goals)
		if not steps.is_empty():
			return steps
	return []


## Candidate nodes [distance, key] for a free chain end: tile entry (or exit) points on
## the range border near p; without a border, nodes near the outline point.
func _free_nodes(p: Vector2, side: Vector2i, entry: bool) -> Array:
	if side == Vector2i.ZERO:
		return _nodes_near(p, entry)
	var found: Array = []
	var seen := {}
	for cell: Vector2i in _border_cells(p, side, false):
		var centre := _cell_centre(cell)
		for pc: Piece in _lib:
			var node := centre + (pc.a if entry else pc.b)
			if not _on_border(node, side):
				continue
			var key := _key(node)
			if seen.has(key):
				continue
			seen[key] = true
			var d := node.distance_to(p)
			if d <= _max_dev:
				found.append([d, key])
	found.sort_custom(func(x, y): return x[0] < y[0])
	return found.slice(0, start_candidates)


func _start_keys(p: Vector2) -> Array:
	var out: Array = []
	for c: Array in _nodes_near(p, true):
		out.append(c[1])
	return out


## Tile entry (or exit) points close to the outline near p: Array of [distance, key].
func _nodes_near(p: Vector2, entry: bool) -> Array:
	var base := Vector2i(floori(p.x / _ts.x), floori(p.y / _ts.y))
	var seen := {}
	var found: Array = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell := base + Vector2i(dx, dy)
			if not _zone.has_point(cell):
				continue
			var centre := _cell_centre(cell)
			for pc: Piece in _lib:
				var node := centre + (pc.a if entry else pc.b)
				var key := _key(node)
				if seen.has(key):
					continue
				seen[key] = true
				var d := _info_at(node).x
				if d <= _max_dev:
					found.append([d, key])
	found.sort_custom(func(x, y): return x[0] < y[0])
	return found.slice(0, start_candidates)


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


## Dijkstra: cheapest chain from any start [cost, node] to any goal node
## (goals maps node -> extra cost). Needs at least one tile.
func _shortest_path(starts: Array, goals: Dictionary) -> Array:
	var dist := {}
	var came := {}
	var heap: Array = []
	for s: Array in starts:
		var first: Vector2i = s[1]
		if s[0] < dist.get(first, INF):
			dist[first] = s[0]
			_heap_push(heap, [s[0], first])

	var best_total := INF
	var best_node := Vector2i.ZERO
	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var cost: float = top[0]
		if cost >= best_total:
			break
		var node: Vector2i = top[1]
		if cost > dist[node]:
			continue
		var came_from_cell := Vector2i(-99999, -99999)
		if came.has(node):
			came_from_cell = came[node]["cell"]
			if goals.has(node) and cost + goals[node] < best_total:
				best_total = cost + goals[node]
				best_node = node

		for edge: Dictionary in _edges_from(node):
			if edge["cell"] == came_from_cell:
				continue
			var new_cost: float = cost + edge["cost"]
			var to: Vector2i = edge["to"]
			if new_cost < dist.get(to, INF):
				dist[to] = new_cost
				came[to] = {"from": node, "cell": edge["cell"], "piece": edge["piece"]}
				_heap_push(heap, [new_cost, to])

	if best_total == INF:
		return []
	var steps: Array = []
	var back := best_node
	while came.has(back):
		var c: Dictionary = came[back]
		steps.push_front({"cell": c["cell"], "piece": c["piece"]})
		back = c["from"]
	return steps


## All tiles that can be placed starting at `node` (cached). Only cells inside the
## builder range are used.
func _edges_from(node: Vector2i) -> Array:
	if _edges.has(node):
		return _edges[node]
	var list: Array = []
	var p := Vector2(node) / KEY_SCALE
	for cell: Vector2i in _cells_touching(p):
		if not _zone.has_point(cell):
			continue
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

	# 2) must run ALONG the outline, never across it (no perpendicular slopes / dents);
	#    below roughness 1 a slope that differs from the line direction also costs extra
	#    below polygon_roughness 1 a slope that differs from the line direction also costs extra
	var mis := _chord_misalignment(p, q)
	if _guard_angle and mis > MAX_TILE_TURN:
		return -1.0
	var penalty := 0.0
	if mis > 0.0 and polygon_roughness < 1.0:
		var k := mis / (PI * 0.25)
		penalty = (1.0 - clampf(polygon_roughness, 0.0, 1.0)) * ANGLE_WEIGHT * chord * _ts.x * k * k

	# 3) must stay close to the outline; cost = integral of distance along the tile+	# 3) Geometry roughness trades fidelity for fewer collision-bearing surface pieces.
	# The per-piece cost rewards longer profiles (including two-edge corner profiles),
	# while the geometry-dependent deviation bound lets those profiles fit less exactly.
	var geometry_coarsening := 1.0 - clampf(geometry_roughness, 0.0, 1.0)
	var piece_penalty := geometry_coarsening * GEOMETRY_TILE_PENALTY * _ts.x * _ts.y
	var geometry_precision := lerpf(0.35, 1.0, 1.0 - geometry_coarsening)

	# 4) measure outline deviation. Coarser geometry gives this term less weight, making
	# the search willing to trade some accuracy for a shorter chain of collision-bearing tiles.
	var cost := 0.001 + penalty + piece_penalty # tiny tie-breaker plus optional geometry cost
	for k in pts.size() - 1:
		var s0 := pts[k]
		var s1 := pts[k + 1]
		var d0 := _info_at(s0).x
		var dm := _info_at((s0 + s1) * 0.5).x
		var d1 := _info_at(s1).x
		if maxf(d0, maxf(dm, d1)) > _max_dev:
			return -1.0
		cost += geometry_precision * s0.distance_to(s1) * (d0 + 2.0 * dm + d1) * 0.25
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
	var m := n if _closed else n - 1
	for i in m:
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
	if _closed:
		if d > _length * 0.5:
			d -= _length
		elif d < -_length * 0.5:
			d += _length
	return d


## Angle (radians) between the tile chord p -> q and the outline between the points
## nearest to p and q. -1 if that part of the outline is too short to tell.
func _chord_misalignment(p: Vector2, q: Vector2) -> float:
	var s0 := _info_at(p).y
	var oc := _point_at(s0 + _advance(p, q)) - _point_at(s0)
	if oc.length() < 1.0:
		return -1.0
	return absf(oc.angle_to(q - p))


## Point on the outline at arc length s (wraps on closed outlines, clamps on open ones).
func _point_at(s: float) -> Vector2:
	var n := _outline.size()
	var m := n if _closed else n - 1
	if m < 1:
		return _outline[0]
	s = fposmod(s, _length) if _closed else clampf(s, 0.0, _length)
	var i := clampi(_cum.bsearch(s) - 1, 0, m - 1)
	var seg_len: float = (_cum[i + 1] if i + 1 < m else _length) - _cum[i]
	var a := _outline[i]
	if seg_len < 0.0001:
		return a
	return a.lerp(_outline[(i + 1) % n], clampf((s - _cum[i]) / seg_len, 0.0, 1.0))


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


# ============================================================ 8. write tiles

func _write_region(ring: PackedVector2Array, chains: Array) -> void:
	# End caps outrank partial/near-full slope tiles if they compete for one cell.
	var surface := {}   # cell -> {"prio", "slope", "terrain", "cap", "coords"}
	for ch: Dictionary in chains:
		var steps: Array = ch["steps"]
		var closed: bool = ch["closed"]
		for i in steps.size():
			var cell: Vector2i = steps[i]["cell"]
			var pc: Piece = _lib[steps[i]["piece"]]
			var entry := {"prio": 1, "slope": false, "terrain": false,
					"cap": false, "coords": Vector2i(-1, -1)}
			if pc.kind == KIND_TILE:
				entry = {"prio": 2, "slope": true, "terrain": false,
						"cap": false, "coords": pc.coords}
			elif _use_terrain and not _next_to_slope(steps, i, closed):
				entry["terrain"] = true
			else:
				entry["coords"] = _find_cap(steps, i, closed)
				entry["cap"] = true
				entry["prio"] = 3
			if not surface.has(cell) or surface[cell]["prio"] < entry["prio"]:
				surface[cell] = entry

	# Only inspect the few cells next to each actual slope-to-slope junction. This is
	# deliberately local/bounded; it does not add another scan over the whole zone.
	_queue_slope_transition_caps(ring, chains, surface)

	# Cells near slope tiles are plain fill tiles because slopes are not terrain tiles.
	var near := {}
	var r := slope_fill_radius
	for cell: Vector2i in surface:
		if surface[cell]["slope"]:
			for dx in range(-r, r + 1):
				for dy in range(-r, r + 1):
					near[cell + Vector2i(dx, dy)] = true

	# Flood-fill bounded by _zone to determine interior cells.
	var seen := {}
	for x in range(_zone.position.x, _zone.end.x):
		for y in range(_zone.position.y, _zone.end.y):
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
				if Geometry2D.is_point_in_polygon(_cell_centre(c), ring):
					votes += 1
				for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var nb: Vector2i = c + dir
					if _zone.has_point(nb) and not surface.has(nb) and not seen.has(nb):
						seen[nb] = true
						stack.append(nb)
			if votes * 2 <= region.size():
				continue
			for c: Vector2i in region:
				if _use_terrain and not near.has(c):
					_terrain_cells[c] = true
				else:
					_terrain_cells.erase(c)
					tile_layer.set_cell(c, atlas_source_id, fill_tile)

	for cell: Vector2i in surface:
		var e: Dictionary = surface[cell]
		if e["terrain"]:
			_terrain_cells[cell] = true
		else:
			_terrain_cells.erase(cell)
			if e["cap"]:
				# Write after terrain-connect so it cannot replace the intended cap.
				_queue_end_cap(cell, e["coords"], true)
			else:
				tile_layer.set_cell(cell, atlas_source_id, e["coords"])
				if e["slope"]:
					_surface_slope_cells[cell] = true


## The terrain operation runs before end caps so terrain-connect cannot overwrite them.
func _apply_terrain() -> void:
	if not _use_terrain or _terrain_cells.is_empty():
		return
	var cells: Array[Vector2i] = []
	cells.assign(_terrain_cells.keys())
	tile_layer.set_cells_terrain_connect(cells, terrain_set, terrain_id)


func _queue_end_cap(cell: Vector2i, coords: Vector2i, force: bool) -> void:
	if not _zone.has_point(cell):
		return
	if _pending_caps.has(cell):
		var old: Dictionary = _pending_caps[cell]
		# Forced boundary caps override optional interior transition caps.
		if old["force"] or not force:
			return
	_pending_caps[cell] = {"coords": coords, "force": force}


## Queue a cap just inside a corner where two differently angled diagonal slopes meet.
## Flat pieces and continuous/same-angle slope runs are intentionally ignored.
func _queue_slope_transition_caps(ring: PackedVector2Array, chains: Array, surface: Dictionary) -> void:
	if slope_transition_min_angle_degrees <= 0.0:
		return
	var min_dot := cos(deg_to_rad(slope_transition_min_angle_degrees))
	for ch: Dictionary in chains:
		var steps: Array = ch["steps"]
		var closed: bool = ch["closed"]
		if steps.size() < 2:
			continue
		var pair_count: int = steps.size() if closed else steps.size() - 1
		for i in range(pair_count):
			var j := (i + 1) % steps.size()
			var a: Dictionary = steps[i]
			var b: Dictionary = steps[j]
			var cell_a: Vector2i = a["cell"]
			var cell_b: Vector2i = b["cell"]
			if cell_a == cell_b:
				continue
			var pa: Piece = _lib[a["piece"]]
			var pb: Piece = _lib[b["piece"]]
			if pa.kind != KIND_TILE or pb.kind != KIND_TILE:
				continue
			var da := pa.b - pa.a
			var db := pb.b - pb.a
			# This is specifically a diagonal-slope transition, not a flat/vertical join.
			if absf(da.x) < 1.0 or absf(da.y) < 1.0 or absf(db.x) < 1.0 or absf(db.y) < 1.0:
				continue
			var na := da.normalized()
			var nb := db.normalized()
			if na.dot(nb) >= min_dot:
				continue

			var junction_a := _cell_centre(cell_a) + pa.b
			var junction_b := _cell_centre(cell_b) + pb.a
			var junction := (junction_a + junction_b) * 0.5
			var tangent := na + nb
			if tangent.length_squared() < 0.001:
				tangent = na
			tangent = tangent.normalized()
			# Every outline ring is oriented with its interior to the right of travel.
			var inside_normal := Vector2(-tangent.y, tangent.x).normalized()
			var target_point := junction + inside_normal * maxf(_ts.x, _ts.y) * 0.75
			var target_cell := _find_transition_cap_cell(junction, target_point, inside_normal,
					cell_a, cell_b, ring, surface)
			if target_cell == Vector2i(-99999, -99999):
				continue
			var coords := _find_transition_cap_coords(target_cell, junction, a, b)
			_queue_end_cap(target_cell, coords, false)


## Search is limited to at most 18 candidate cells per junction, preventing unbounded work.
func _find_transition_cap_cell(junction: Vector2, target_point: Vector2,
		inside_normal: Vector2, cell_a: Vector2i, cell_b: Vector2i,
		ring: PackedVector2Array, surface: Dictionary) -> Vector2i:
	var best := Vector2i(-99999, -99999)
	var best_score := INF
	var candidates := {}
	for base: Vector2i in [cell_a, cell_b]:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var c := base + Vector2i(dx, dy)
				if not _zone.has_point(c) or surface.has(c) or candidates.has(c):
					continue
				candidates[c] = true
				var centre := _cell_centre(c)
				if not Geometry2D.is_point_in_polygon(centre, ring):
					continue
				if (centre - junction).dot(inside_normal) <= 0.0:
					continue
				var score := centre.distance_to(target_point)
				if score > maxf(_ts.x, _ts.y) * 1.25:
					continue
				if score < best_score:
					best_score = score
					best = c
	return best


func _find_transition_cap_coords(target_cell: Vector2i, junction: Vector2,
		a: Dictionary, b: Dictionary) -> Vector2i:
	var toward_surface := junction - _cell_centre(target_cell)
	var configured := _configured_slope_transition_cap(toward_surface)
	if configured != Vector2i(-1, -1):
		return configured

	# Auto-detect a full tile at the same atlas offset as the nearest slope.
	var source_step: Dictionary = a
	var target_centre := _cell_centre(target_cell)
	var distance_a := target_centre.distance_squared_to(_cell_centre(a["cell"]))
	var distance_b := target_centre.distance_squared_to(_cell_centre(b["cell"]))
	if distance_a > distance_b:
		source_step = b
	var slope: Piece = _lib[source_step["piece"]]
	var delta: Vector2i = target_cell - (source_step["cell"] as Vector2i)
	var guess: Vector2i = slope.coords + delta
	if _pure_full.has(guess):
		return guess

	# No automatically matching tile exists: use the configured directional fallback.
	return _configured_slope_transition_fallback(toward_surface)


func _configured_slope_transition_cap(toward_surface: Vector2) -> Vector2i:
	if absf(toward_surface.x) >= absf(toward_surface.y):
		return cap_slope_transition_left if toward_surface.x < 0.0 else cap_slope_transition_right
	return cap_slope_transition_top if toward_surface.y < 0.0 else cap_slope_transition_bottom


func _configured_slope_transition_fallback(toward_surface: Vector2) -> Vector2i:
	if absf(toward_surface.x) >= absf(toward_surface.y):
		return cap_left if toward_surface.x < 0.0 else cap_right
	return cap_top if toward_surface.y < 0.0 else cap_bottom


func _apply_end_caps() -> void:
	for cell: Vector2i in _pending_caps:
		var cap: Dictionary = _pending_caps[cell]
		if not cap["force"] and _surface_slope_cells.has(cell):
			continue
		_terrain_cells.erase(cell)
		tile_layer.set_cell(cell, atlas_source_id, cap["coords"])
	_pending_caps.clear()


func _step_index(steps: Array, i: int, offset: int, closed: bool) -> int:
	var idx := i + offset
	var n := steps.size()
	if closed:
		return (idx % n + n) % n
	return idx if idx >= 0 and idx < n else -1


func _next_to_slope(steps: Array, i: int, closed: bool) -> bool:
	for offset in [1, -1]:
		var idx := _step_index(steps, i, offset, closed)
		if idx >= 0 and (_lib[steps[idx]["piece"]] as Piece).kind == KIND_TILE:
			return true
	return false


## End cap for a flat run: the atlas tile that sits beside the neighbouring slope
## tile (same offset as in the map), e.g. the tile after the last 1x8 piece.
func _find_cap(steps: Array, i: int, closed: bool) -> Vector2i:
	for offset in [1, -1]:
		var idx := _step_index(steps, i, offset, closed)
		if idx < 0:
			continue
		var other: Dictionary = steps[idx]
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

func _dedupe(p: PackedVector2Array, closed := true) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in p:
		if out.is_empty() or out[out.size() - 1].distance_to(v) > 0.001:
			out.append(v)
	if closed:
		while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= 0.001:
			out.remove_at(out.size() - 1)
	return out
