## Where SKYNET.EXE stands a new robot: FUN_0012a52c, which FUN_0012a4f0
## runs for every robot it builds — start markers, path machines and 0xF3
## spawn sprites alike (SKYNET.EXE v1.01).
##
## With a stand height h (the enemy type record's last dword, +0x18:
## AIData "stand") and the surface FUN_00138d00 finds no more than WINDOW
## above or below the robot, the origin goes h + 2·sign h above that
## surface (DOS: Y = s − h − 2·sign h, Y down). A positive h is how far the
## model reaches below its origin (guntwr1 72, guntwr3 160, hvytrrt 36,
## the walkers 44-108, hvytnk 20): the level author marked the turret's
## base, which would otherwise stay in the floor. A negative h (smltrrt
## −8, hvytrrt types 22-24 −36, hvytrrt2 type 21 −28) puts the origin
## |h| + 2 UNDER the same surface: the query has no ceiling case, so a
## hung gun goes up under the top of the slab it hangs from. Unchanged
## with h = 0 or no surface in the window.
##
## The surface is computed from the MAP data, not from the physics space:
## a Godot ray hands back a normal facing the ray, which turns a ceiling's
## underside into a floor (the C# port's first try stood 47 robots on
## ceilings). Coordinates are the level's own (Godot axes, zone-local).
extends RefCounted

const MapFile    := preload("res://scripts/loaders/map_file.gd")
const WldTerrain := preload("res://scripts/loaders/wld_terrain.gd")
const AIData     := preload("res://scripts/enemy_ai_data.gd")

## Half the vertical segment FUN_00138d00 is asked about, and how far the
## surface may be from the robot for FUN_0012a52c to use it.
const WINDOW: float = 0x50
## Indoors with nothing crossed DOS returns Y 0xE10 (Y down): far out of
## the window.
const NO_SURFACE: float = -0xE10
## The sign of a face's (b − a) × (c − a) Y for a face whose visible side
## points up, in the order Mesh.get_faces() hands the triangles out. Godot
## draws clockwise front faces, so seen from above an upward face turns
## clockwise and its cross product points down.
const UP_CROSS_SIGN: float = -1.0

var _map
var _wld
var _mesh_for: Callable
## Vector2i map cell → Array of [Vector3 a, Vector3 b, Vector3 c] upward
## faces in level space, built on the first robot that asks for the cell.
var _cells: Dictionary = {}
var _by_cell: Dictionary = {}

## `mesh_for(name: String) -> Mesh` hands out a map mesh by its name (or
## null); `wld` is the outdoor heightmap, null indoors.
func _init(map, wld, mesh_for: Callable) -> void:
	_map = map
	_wld = wld
	_mesh_for = mesh_for
	for e in map.entities:
		# Variant-1 meshes without the actor bit, linked in their map cell.
		if (e.flags & 3) != 1 or (e.flags & 0x40) != 0:
			continue
		var k := Vector2i(e.cell_x, e.cell_z)
		if not _by_cell.has(k):
			_by_cell[k] = []
		_by_cell[k].append(e)

## The stand height of enemy type `type` (record +0x18); 0 = none.
static func stand_height(type: int) -> int:
	if type < 0 or type >= AIData.TYPES.size():
		return 0
	return int(AIData.TYPES[type].get("stand", 0))

## Where a new robot of `type` built at `pos` stands.
func stand(type: int, pos: Vector3) -> Vector3:
	var h: int = stand_height(type)
	if h == 0:
		return pos
	var s: float = surface(pos)
	if absf(s - pos.y) > WINDOW:
		return pos
	return Vector3(pos.x, s + float(h) + 2.0 * signf(float(h)), pos.z)

## The surface FUN_00138d00 returns for a vertical segment from WINDOW
## above `pos` to as far below it: the highest face the segment crosses
## whose normal points up (0x138ebf: hit +0x14 < 0, Y down), of the
## variant-1 meshes without the 0x40 bit linked in the four map cells
## (1024 u) round (x − 512, z − 512) (0x136cb7 per cell). Outdoors the WLD
## ground straight under or over the point wins when it is higher or when
## nothing was crossed (0x14575d, not limited to the segment); indoors
## with nothing crossed it is NO_SURFACE.
func surface(pos: Vector3) -> float:
	var x: int = roundi(pos.x)
	var z: int = roundi(-pos.z)                  # DOS Z
	var cx0: int = maxi(x - 0x200, 0) >> 10
	var cz0: int = maxi(z - 0x200, 0) >> 10
	var top: float = pos.y + WINDOW
	var bottom: float = pos.y - WINDOW
	var mesh_y: float = -INF
	for dz in 2:
		for dx in 2:
			for f in _faces(Vector2i(cx0 + dx, cz0 + dz)):
				var y: float = _cross_y(f, pos.x, pos.z)
				if is_nan(y) or y < bottom or y > top or y <= mesh_y:
					continue
				mesh_y = y
	var floor_y: float = NO_SURFACE
	if _wld != null:
		floor_y = WldTerrain.height_at_world(_wld, pos.x, -pos.z)
	if mesh_y == -INF or floor_y > mesh_y:
		return floor_y
	return mesh_y

## Y where the vertical line at (x, z) crosses face `f`, NAN when it misses.
static func _cross_y(f: Array, x: float, z: float) -> float:
	var a: Vector3 = f[0]
	var b: Vector3 = f[1]
	var c: Vector3 = f[2]
	var d: float = (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
	if absf(d) < 1e-6:
		return NAN
	var u: float = ((x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)) / d
	var v: float = ((b.x - a.x) * (z - a.z) - (x - a.x) * (b.z - a.z)) / d
	if u < 0.0 or v < 0.0 or u + v > 1.0:
		return NAN
	return a.y + u * (b.y - a.y) + v * (c.y - a.y)

## The upward faces of the meshes linked in map cell `k`, in level space.
func _faces(k: Vector2i) -> Array:
	if _cells.has(k):
		return _cells[k]
	var out: Array = []
	for e in _by_cell.get(k, []):
		var nm: String = MapFile.entity_name(_map, e)
		if nm.is_empty():
			continue
		var m = _mesh_for.call(nm)
		if not (m is Mesh):
			continue
		var xf: Transform3D = entity_transform(e)
		var tri: PackedVector3Array = (m as Mesh).get_faces()
		for i in range(0, tri.size() - 2, 3):
			var a: Vector3 = xf * tri[i]
			var b: Vector3 = xf * tri[i + 1]
			var c: Vector3 = xf * tri[i + 2]
			if (b - a).cross(c - a).y * UP_CROSS_SIGN > 0.0:
				out.append([a, b, c])
	_cells[k] = out
	return out

## A variant-1 record's transform, as the level loader places its mesh:
## X/Y/Z verbatim, R = Rz(−roll)·Rx(pitch)·Ry(yaw) (11-bit angles).
static func entity_transform(e) -> Transform3D:
	var b := Basis()
	b = b.rotated(Vector3.UP, (e.off_y & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.RIGHT, (e.off_x & 0x7FF) * TAU / 2048.0)
	b = b.rotated(Vector3.BACK, -(e.off_z & 0x7FF) * TAU / 2048.0)
	return Transform3D(b, Vector3(float(e.x), -float(e.y), -float(e.z)))
