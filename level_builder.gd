@tool
class_name LevelBuilder
extends Polygon2D
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
##  1. CURVE     Every polygon is turned into a smooth curve BEFORE anything else: each
##               corner becomes a circular arc whose radius depends on that point's
##               roughness (0 = fully round, 1 = sharp as drawn). The drawn polygon is
##               only a guide; the curve is independent of the builder range, so
##               neighbouring chunks get exactly the same outline.
##  2. LIBRARY   Every TileSet tile with exactly one non-border collision edge run
##               becomes a Piece: a surface line from point A to point B on the tile
##               border, solid on the right-hand side of travel. Plain full tiles give
##               flat pieces (floor / wall / ceiling along a cell border).
##  3. REGIONS   The curve is clipped to the builder range. Edges on the range border
##               are SEAMS; what remains is a closed loop or open chains seam to seam.
##  4. FLATS     Edges within `cardinal_snap_degrees` of 0/90/180/270 become flat.
##  5. CONNECT   Open chains start/end exactly at existing tiles outside the range
##               (outline blended towards them) or on a border node.
##  6. SEARCH    Dijkstra over TILES (not points): a node is a point on a cell border,
##               a tile is an edge A -> B, so the dark outline is ALWAYS continuous.
##               Cost = distance from the curve + a penalty for every bend between two
##               neighbouring tiles (squared, so bends are spread out like on a circle).
##  7. WRITE     Slope tiles are written as they are. Cells near slopes use `fill_tile`,
##               the rest is filled via set_cells_terrain_connect. Flat caps and the
##               optional slope-flag tiles are written after terrain-connect.

const KIND_TILE := 0
const KIND_FULL := 1        # virtual piece: full cell, surface along its border
const KEY_SCALE := 4.0      # node keys are points rounded to 1/4 px
## Allowed distance between tile surface and outline, in tiles. Tried in order;
## the first value that yields a result wins (tight = most faithful).
const DEVIATION_PASSES := [0.25, 0.4, 0.6, 0.9, 1.4]
const ANCHOR_SPAN := 4      # cells searched along the range border for existing terrain
## FULL piece side index -> direction of the neighbour cell that must be air.
const SIDE_DIRS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

const MAX_ROUND_TURN := 2.6          # corners sharper than this (radians, ~150 deg) stay sharp
const ARC_STEP_DEGREES := 12.0       # angular step used to sample rounded corners
const ANGLE_WEIGHT := 0.3            # strength of the "tile slope must match the curve" cost
const TURN_WEIGHT := 0.35            # cost of a 45 degree bend between two tiles, in tile areas
## A tile whose direction differs from the curve direction by more than this (radians,
## 75 deg) is never used: that is what produced dents / perpendicular slopes.
const MAX_TILE_TURN := 1.309

class Piece:
	var kind := KIND_TILE
	var coords := Vector2i(-1, -1)
	var profile := PackedVector2Array()  # relative to tile centre, A -> B
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var first_edge := 0                  # FULL pieces: 0 top, 1 right, 2 bottom, 3 left

@export var polygon_node: Polygon2D = self
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
@export var fill_tile := Vector2i(11, 4)
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

@export_group("Curve")
## Smoothness of every outline point that has no value of its own.
## 0 = the corner is rounded into a circular arc as large as the neighbouring lines allow,
## 1 = sharp corner exactly as drawn.
@export_range(0.0, 1.0, 0.01) var roughness := 0.3
## Per-point roughness for `polygon_node`, in the order of its points. A value below 0
## (or a missing entry) means "use `roughness`". Use "Reset point roughness" to size it.
@export var point_roughness := PackedFloat32Array()
## Same for `extra_polygons` (same order as that array).
@export var extra_point_roughness: Array[PackedFloat32Array] = []
## Largest corner radius (in tiles) used at roughness 0.
@export_range(1.0, 32.0) var max_curve_radius_tiles := 8.0
## How strongly neighbouring tiles must flow into each other. Every bend between two
## tiles costs extra (squared), so the search prefers gradual slope changes and long
## straight runs over one abrupt bend. 0 = only distance to the curve matters.
@export_range(0.0, 1.0, 0.01) var continuity := 0.6

@export_group("End caps (fallback)")
## Used for a flat run right next to a slope when the atlas has no matching tile.
@export var cap_top := Vector2i(11, 3)
@export var cap_right := Vector2i(12, 4)
@export var cap_bottom := Vector2i(11, 5)
@export var cap_left := Vector2i(10, 4)

@export_group("Slope flag tiles")
## Uses the TileSet custom data below to force "set" tiles onto fill cells next to slope
## tiles: beyond the END of a slope (left / right) and behind the BEGIN of a slope (up / down).
@export var force_flag_tiles := false
## Custom data layer names in the TileSet (bool, bool, Vector2i).
@export var custom_data_slope_begin := "is_slope_begin"
@export var custom_data_slope_end := "is_slope_end"
## (x, y) = tiles from the begin tile to the end tile, negative = left / up, e.g. (4, -1).
@export var custom_data_slope_type := "slope_type"
## When no explicit entry exists, use the tile next to the slope tile in the ATLAS
## (right / left of an end tile, below / above a begin tile).
@export var flag_use_atlas_neighbour := true
## Explicit tiles, slope_type (Vector2i) -> atlas coords (Vector2i). They win over the
## atlas neighbour. Left / right apply to slope END tiles, up / down to slope BEGIN tiles.
@export var end_left_tiles := {
	Vector2i(-1, 1): Vector2i(16,6),
	Vector2i(-1, -1): Vector2i(16,5),
	Vector2i(-2, 1): Vector2i(16,6),
	Vector2i(-2, -1): Vector2i(16,5),
	Vector2i(-3, 1): Vector2i(16,6),
	Vector2i(-3, -1): Vector2i(16,5),
	Vector2i(-4, 1): Vector2i(16,6),
	Vector2i(-4, -1): Vector2i(16,5),
	Vector2i(-6, 1): Vector2i(16,6),
	Vector2i(-6, -1): Vector2i(16,5),
	Vector2i(-8, 1): Vector2i(16,6),
	Vector2i(-8, -1): Vector2i(16,5),
}
@export var end_right_tiles := {
	Vector2i(1, 1): Vector2i(1,6),
	Vector2i(1, -1): Vector2i(1,5),
	Vector2i(2, 1): Vector2i(1,6),
	Vector2i(2, -1): Vector2i(1,5),
	Vector2i(3, 1): Vector2i(1,6),
	Vector2i(3, -1): Vector2i(1,5),
	Vector2i(4, 1): Vector2i(1,6),
	Vector2i(4, -1): Vector2i(1,5),
	Vector2i(6, 1): Vector2i(1,6),
	Vector2i(6, -1): Vector2i(1,5),
	Vector2i(8, 1): Vector2i(1,6),
	Vector2i(8, -1): Vector2i(1,5),
	
}
@export var begin_up_tiles := {
	
}
@export var begin_down_tiles := {
	Vector2i(1, 1): Vector2i(1,5)
	
}

@export_group("Editor")
@export var live_update := false
@export var debounce := 0.3

@export_category("Tool Buttons")
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate tiles", "TileMapLayer") var _generate_btn = generate
@warning_ignore("unused_private_class_variable")
@export_tool_button("Clear tiles", "Clear") var _clear_btn = clear_tiles
@warning_ignore("unused_private_class_variable")
@export_tool_button("Reload polygon points", "Reload") var _reset_pr_btn = reset_point_roughness

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
var _pending_caps := {}            # cell -> atlas coords, flat end caps written after terrain
var _pending_forced := {}          # cell -> atlas coords, slope-flag tiles written last
var _flag_cache := {}              # atlas coords -> {"begin", "end", "type"} custom data
var _edge_seq := 0                 # unique id of every cached edge (search state)
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
	var parts: Array = [tile_layer.global_transform, roughness, continuity, max_curve_radius_tiles,
		point_roughness, extra_point_roughness]
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
		push_warning("LevelBuilder: assign polygon_node and a tile_layer that has a TileSet.")
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
		push_warning("LevelBuilder: no usable slope tiles found in the TileSet source.")
		_busy = false
		return

	_use_terrain = _terrain_valid()
	_terrain_cells.clear()
	_pending_caps.clear()
	_pending_forced.clear()
	_flag_cache.clear()
	if clean_area:
		_erase_zone()

	var total := 0
	for ring: PackedVector2Array in rings:
		for region: PackedVector2Array in _clip_to_zone(ring):
			total += _build_region(region)
	_apply_terrain()
	_apply_pending()
	print("LevelBuilder: %d surface tiles, %d terrain cells, %d ms"
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


## Every polygon as a smooth curve in TileMapLayer space, oriented so the inside is on the
## right-hand side of travel (positive shoelace area with y pointing down).
func _rings() -> Array:
	var out: Array = []
	for poly in _all_polygons():
		var xf := tile_layer.get_global_transform().affine_inverse() * poly.get_global_transform()
		var own := _point_roughness_of(poly)
		var pts := PackedVector2Array()
		var rough := PackedFloat32Array()
		for i in poly.polygon.size():
			pts.append(xf * (poly.polygon[i] + poly.offset))
			rough.append(own[i] if i < own.size() and own[i] >= 0.0 else roughness)
		var clean := _dedupe_aligned(pts, rough)
		pts = clean[0]
		rough = clean[1]
		if pts.size() < 3:
			continue
		if _area(pts) < 0.0:
			pts.reverse()
			rough.reverse()
		out.append(_smooth_ring(pts, rough))
	return out


func _point_roughness_of(poly: Polygon2D) -> PackedFloat32Array:
	if poly == polygon_node:
		return point_roughness
	var k := extra_polygons.find(poly)
	if k >= 0 and k < extra_point_roughness.size():
		return extra_point_roughness[k]
	return PackedFloat32Array()


## Sizes the per-point arrays to the polygons (new points use -1 = global roughness).
func reset_point_roughness() -> void:
	if polygon_node != null:
		point_roughness = _filled(polygon_node.polygon.size(), point_roughness)
	for i in extra_polygons.size():
		if extra_polygons[i] == null:
			continue
		while extra_point_roughness.size() <= i:
			extra_point_roughness.append(PackedFloat32Array())
		extra_point_roughness[i] = _filled(extra_polygons[i].polygon.size(), extra_point_roughness[i])


func _filled(count: int, old: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in count:
		out.append(old[i] if i < old.size() else -1.0)
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
		push_warning("LevelBuilder: terrain %d (set %d) does not exist in the TileSet; using fill_tile instead."
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
			push_warning("LevelBuilder: could not fit a tile chain to part of the outline. "
					+ "Check that the TileSet has collision on physics layer %d." % physics_layer)
			failed = true
			continue
		chains.append({"steps": steps, "closed": closed})
		count += steps.size()
	if failed:
		return count      # leave this region untouched rather than fill the wrong side
	_write_region(ring, chains)
	return count


# ============================================ 1b. curve (per-point smoothing)

## Replaces every corner of a closed ring by a circular arc. The radius of a corner is
## (1 - roughness of that point) * max_curve_radius_tiles; roughness 1 keeps it sharp.
## Neighbouring arcs share the length of the line between them, so lines stay straight
## in between and the curve has no kinks except at sharp points.
func _smooth_ring(pts: PackedVector2Array, rough: PackedFloat32Array) -> PackedVector2Array:
	var n := pts.size()
	var max_r := max_curve_radius_tiles * _ts.x
	var dirs := PackedVector2Array()
	var lens := PackedFloat32Array()
	for i in n:
		var edge := pts[(i + 1) % n] - pts[i]
		var edge_len := edge.length()
		lens.append(edge_len)
		dirs.append(edge / maxf(edge_len, 0.0001))
	var turn := PackedFloat32Array()
	var want := PackedFloat32Array()
	turn.resize(n)
	want.resize(n)
	var found_any := false
	for i in n:
		var incoming := dirs[(i - 1 + n) % n]
		var ang := acos(clampf(incoming.dot(dirs[i]), -1.0, 1.0))
		var radius := (1.0 - clampf(rough[i], 0.0, 1.0)) * max_r
		turn[i] = ang
		if radius > 0.5 and ang >= 0.03 and ang <= MAX_ROUND_TURN:
			want[i] = radius * tan(ang * 0.5)
			found_any = true
	if not found_any:
		return pts
	var edge_scale := PackedFloat32Array()
	edge_scale.resize(n)
	for e in n:
		var total := want[e] + want[(e + 1) % n]
		edge_scale[e] = 1.0 if total <= lens[e] * 0.98 else lens[e] * 0.98 / total
	var out := PackedVector2Array()
	for i in n:
		var t: float = want[i] * minf(edge_scale[(i - 1 + n) % n], edge_scale[i])
		if t < 0.01:
			out.append(pts[i])
			continue
		var d1 := dirs[(i - 1 + n) % n]
		var r := t / tan(turn[i] * 0.5)
		var sgn := signf(d1.cross(dirs[i]))
		var start := pts[i] - d1 * t
		var centre := start + d1.rotated(sgn * PI * 0.5) * r
		var radial := start - centre
		var steps := maxi(1, ceili(turn[i] / deg_to_rad(ARC_STEP_DEGREES)))
		for k in steps + 1:
			out.append(centre + radial.rotated(sgn * turn[i] * float(k) / float(steps)))
	return _dedupe(out)


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
	for guarded in [true, false]:       # second round = no direction guard, only if nothing fits
		_guard_angle = guarded
		var steps := _loop_search()
		if not steps.is_empty():
			return steps
	return []


func _loop_search() -> Array:
	for factor in DEVIATION_PASSES:
		_max_dev = factor * _ts.x
		_edges.clear()
		var best_cost := INF
		var best_steps: Array = []
		for start in _start_keys(_outline[0]):
			var found := _dijkstra([[0.0, start]], {start: 0.0}, best_cost)
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
		_max_dev = factor * _ts.x
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
		var found := _dijkstra(starts, goals, INF)
		if not found.is_empty():
			return found["steps"]
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


## Dijkstra over TILES: the state is the last tile placed, so the cost of the next tile can
## depend on how sharply the chain bends between the two. starts = [[cost, node], ...],
## goals = node -> extra cost (a loop uses its own start node as the goal). `limit` =
## best cost found so far, anything worse is abandoned. Needs at least one tile.
## Returns {"cost", "steps"} or {}.
func _dijkstra(starts: Array, goals: Dictionary, limit: float) -> Dictionary:
	var dist := {}      # edge id -> cost of the cheapest chain ending with that tile
	var came := {}      # edge id -> previous edge id (-1 = first tile)
	var by_id := {}     # edge id -> edge
	var heap: Array = []
	for s: Array in starts:
		for first: Dictionary in _edges_from(s[1]):
			var c0: float = s[0] + first["cost"]
			if c0 < limit and c0 < dist.get(first["id"], INF):
				dist[first["id"]] = c0
				came[first["id"]] = -1
				by_id[first["id"]] = first
				_heap_push(heap, [c0, first["id"]])

	var best := limit
	var best_id := -1
	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var cost: float = top[0]
		if cost >= best:
			break
		var id: int = top[1]
		if cost > dist[id]:
			continue                   # outdated heap entry
		var cur: Dictionary = by_id[id]
		if goals.has(cur["to"]):
			var total: float = cost + goals[cur["to"]]
			if total < best:
				best = total
				best_id = id
		for nxt: Dictionary in _edges_from(cur["to"]):
			if nxt["cell"] == cur["cell"]:
				continue               # never use the same cell twice in a row
			var c1: float = cost + nxt["cost"] + _turn_cost(cur["ang"], nxt["ang"])
			if c1 >= best:
				continue
			var nid: int = nxt["id"]
			if c1 < dist.get(nid, INF):
				dist[nid] = c1
				came[nid] = id
				by_id[nid] = nxt
				_heap_push(heap, [c1, nid])

	if best_id == -1:
		return {}
	var steps: Array = []
	var back := best_id
	while back != -1:
		var e: Dictionary = by_id[back]
		steps.push_front({"cell": e["cell"], "piece": e["piece"]})
		back = came[back]
	return {"cost": best, "steps": steps}


## Extra cost of a bend of `b - a` radians between two neighbouring tiles. Squared, so
## spreading a turn over several small bends is much cheaper than one big bend.
func _turn_cost(a: float, b: float) -> float:
	if continuity <= 0.0:
		return 0.0
	var k := absf(angle_difference(a, b)) / (PI * 0.25)
	return continuity * TURN_WEIGHT * _ts.x * _ts.y * k * k


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
				var q := centre + pc.b
				_edge_seq += 1
				list.append({"id": _edge_seq, "to": _key(q), "cell": cell, "piece": pi,
						"cost": cost, "ang": (q - p).angle()})
	_edges[node] = list
	return list


## Cost of placing `pc` in the cell at `centre`, entering at point `p`.
## Returns -1 if the tile is not acceptable here.
func _tile_cost(p: Vector2, centre: Vector2, pc: Piece) -> float:
	var pts := PackedVector2Array()
	for v in pc.profile:
		pts.append(centre + v)
	var q := pts[pts.size() - 1]

	# 1) must move forward along the curve (rejects reversed / sideways tiles)
	var chord := p.distance_to(q)
	if chord < 1.0:
		return -1.0
	var forward := _advance(p, q)
	if forward < min_forward_ratio * chord or forward > 3.0 * chord:
		return -1.0

	# 2) must run ALONG the curve, never across it (no perpendicular slopes / dents);
	#    a slope that differs from the curve direction also costs extra
	var mis := _chord_misalignment(p, q)
	if _guard_angle and mis > MAX_TILE_TURN:
		return -1.0
	var cost := 0.001                  # tiny constant so ties are stable
	if mis > 0.0 and continuity > 0.0:
		var k := mis / (PI * 0.25)
		cost += continuity * ANGLE_WEIGHT * chord * _ts.x * k * k

	# 3) must stay close to the curve; cost = integral of distance along the tile
	for i in pts.size() - 1:
		var s0 := pts[i]
		var s1 := pts[i + 1]
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

	# Cells near slope tiles are plain fill tiles because slopes are not terrain tiles.
	var near := {}
	var r := slope_fill_radius
	for cell: Vector2i in surface:
		if surface[cell]["slope"]:
			for dx in range(-r, r + 1):
				for dy in range(-r, r + 1):
					near[cell + Vector2i(dx, dy)] = true

	# Flood-fill bounded by _zone to determine interior cells.
	var interior := {}
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
				interior[c] = true
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
				_queue_end_cap(cell, e["coords"])    # after terrain-connect, so it stays
			else:
				tile_layer.set_cell(cell, atlas_source_id, e["coords"])

	if force_flag_tiles:
		_queue_flag_tiles(chains, surface, interior)


func _apply_terrain() -> void:
	if not _use_terrain or _terrain_cells.is_empty():
		return
	var cells: Array[Vector2i] = []
	cells.assign(_terrain_cells.keys())
	tile_layer.set_cells_terrain_connect(cells, terrain_set, terrain_id)


func _queue_end_cap(cell: Vector2i, coords: Vector2i) -> void:
	if _zone.has_point(cell):
		_pending_caps[cell] = coords


## Terrain-connect may rewrite neighbouring cells, so caps and flag tiles go in afterwards.
func _apply_pending() -> void:
	for cell: Vector2i in _pending_caps:
		_terrain_cells.erase(cell)
		tile_layer.set_cell(cell, atlas_source_id, _pending_caps[cell])
	for cell: Vector2i in _pending_forced:
		tile_layer.set_cell(cell, atlas_source_id, _pending_forced[cell])
	_pending_caps.clear()
	_pending_forced.clear()


# ================================================= slope flag tiles (custom data)

## TileSet custom data of a slope tile: {"begin": bool, "end": bool, "type": Vector2i},
## or {} when the TileSet has none of the layers.
func _slope_flags(coords: Vector2i) -> Dictionary:
	if _flag_cache.has(coords):
		return _flag_cache[coords]
	var out := {}
	var ts := tile_layer.tile_set
	var lb := ts.get_custom_data_layer_by_name(custom_data_slope_begin)
	var le := ts.get_custom_data_layer_by_name(custom_data_slope_end)
	var lt := ts.get_custom_data_layer_by_name(custom_data_slope_type)
	var src := ts.get_source(atlas_source_id) as TileSetAtlasSource
	if src != null and src.has_tile(coords) and (lb >= 0 or le >= 0):
		var td := src.get_tile_data(coords, 0)
		out = {
			"begin": lb >= 0 and bool(td.get_custom_data_by_layer_id(lb)),
			"end": le >= 0 and bool(td.get_custom_data_by_layer_id(le)),
			"type": Vector2i(td.get_custom_data_by_layer_id(lt)) if lt >= 0 else Vector2i.ZERO,
		}
	_flag_cache[coords] = out
	return out


## slope_type = tiles from the BEGIN to the END tile (negative = left / up), so:
##  END tile:   the fill cell beyond the end, to its left / right (sign of x).
##  BEGIN tile: the fill cell behind the start, above / below it (opposite sign of y).
func _queue_flag_tiles(chains: Array, surface: Dictionary, interior: Dictionary) -> void:
	for ch: Dictionary in chains:
		var steps: Array = ch["steps"]
		for i in steps.size():
			var pc: Piece = _lib[steps[i]["piece"]]
			if pc.kind != KIND_TILE:
				continue
			var fl := _slope_flags(pc.coords)
			if fl.is_empty():
				continue
			var cell: Vector2i = steps[i]["cell"]
			var type: Vector2i = fl["type"]
			if fl["end"] and type.x != 0:
				var dir_h := Vector2i(signi(type.x), 0)
				_queue_flag_tile(cell + dir_h, pc.coords, dir_h, type,
						end_left_tiles if dir_h.x < 0 else end_right_tiles, surface, interior)
			if fl["begin"]:
				var dir_v := Vector2i(0, -signi(type.y))
				if type.y == 0:      # no vertical info: use the solid side of the tile
					dir_v = Vector2i(0, 1 if (pc.b - pc.a).rotated(PI * 0.5).y > 0.0 else -1)
				_queue_flag_tile(cell + dir_v, pc.coords, dir_v, type,
						begin_up_tiles if dir_v.y < 0 else begin_down_tiles, surface, interior)


func _queue_flag_tile(target: Vector2i, base: Vector2i, dir: Vector2i, type: Vector2i,
		table: Dictionary, surface: Dictionary, interior: Dictionary) -> void:
	if not interior.has(target) or surface.has(target):
		return                                  # only fill cells inside the ground
	var coords := Vector2i(-1, -1)
	if table.has(type) and table[type] is Vector2i:
		coords = table[type]
	elif flag_use_atlas_neighbour:
		coords = base + dir
	var src := tile_layer.tile_set.get_source(atlas_source_id) as TileSetAtlasSource
	if coords.x < 0 or src == null or not src.has_tile(coords) or _by_coords.has(coords):
		return                                  # missing, or it is itself a slope tile
	_pending_forced[target] = coords


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

## Like _dedupe for a closed ring, keeping the per-point values `r` aligned. Returns [points, values].
func _dedupe_aligned(p: PackedVector2Array, r: PackedFloat32Array) -> Array:
	var op := PackedVector2Array()
	var orr := PackedFloat32Array()
	for i in p.size():
		if op.is_empty() or op[op.size() - 1].distance_to(p[i]) > 0.001:
			op.append(p[i])
			orr.append(r[i])
	while op.size() > 1 and op[0].distance_to(op[op.size() - 1]) <= 0.001:
		op.remove_at(op.size() - 1)
		orr.remove_at(orr.size() - 1)
	return [op, orr]

func _dedupe(p: PackedVector2Array, closed := true) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in p:
		if out.is_empty() or out[out.size() - 1].distance_to(v) > 0.001:
			out.append(v)
	if closed:
		while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= 0.001:
			out.remove_at(out.size() - 1)
	return out
