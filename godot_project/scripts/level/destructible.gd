## A destructible object — a car that wrecks in stages, a wall a ram
## punches through, a sign (docs/map_format_plan.md §2).
##
## DOS: acts 0x18/0x19 (v1.01 handler 0x120833; the 0x120433 in the older
## notes is v1.00) step the mesh through the damage stages TRANSFRM.PRS
## lists for its name. The handler is passed NO damage value at all — it
## adds 16 to the object's own counter and shows stage counter >> 4 — so
## one qualifying hit is exactly ONE stage, whatever the blow was worth,
## and what decides how many blows a thing takes is its hit points. (The
## port used to step damage / 16 stages at once, and a single 50-point
## pipe swing shattered a car: playtest 2026-09-16.)
##
## The handler's first move is to look the object's mesh up in the
## transform table (0x120879 `call 0x12078a`, which sets the carry flag
## when the name has no template) and RETURN on `jb` when there is none.
## A car placed already wrecked — the map is full of CARHIP*C, which are
## other cars' last stage — therefore does nothing at all when shot, and
## neither does this. Past the last stage the object is a spent wreck; an
## object whose name has no template at all vanishes instead when its hit
## points run out, which is the ordinary destruction path and not this.
##
## A chain can break one outright: on MAP.248 a START BOX runs a sound
## node into the IBEM64 girder and on into 248WALL — the ram that punches
## the hole the player walks through, one stage per press of the box.
##
##   Destructible (this)   StaticBody3D at the DOS position and rotation
##   +- Mesh               stage 0 — the intact object
##   +- Shape              the shared trimesh of the intact mesh
##
## Since step 5g of docs/trigger_graph_plan.md this node is the record's
## damage stages: what it holds is the whole of what one of these
## remembers between ticks — which stage it is showing and how far its
## counter has come — and it is the only thing that moves either. What it
## does NOT hold is state: the hit points, the spent flag and every enable
## bit belong to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd) and are written only there. The
## mesh it swaps is the one the level loader built, handed over at
## registration exactly as a mover is handed its own
## (Behaviour.register_destructible).

extends StaticBody3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

@export var id: int = 0
@export var act: int = 0
@export var mesh_name: String = ""
@export var hp: int = 0
## DOS state byte: bit 1 = act on every hit, bit 2 = act when the HP
## runs out (ObjHit, v1.01 0x139019).
@export var state: int = 0
## The TRANSFRM.PRS damage stages, [0] = intact. Empty when the name
## has no template: the object then vanishes on destruction.
@export var stages: Array[Mesh] = []
## Link-record destruction data (Skynet.exe 0x423d6 table): the effect
## sprites, the drop and the sound of the final blast.
@export var destroy_type: int = 0
@export var destroy_param: int = 0
@export var targets: Array[NodePath] = []

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime, the MAP records, the blast and the event bus
## are reached. Null for a branch nobody plays, and then nothing here runs.
var branch: Node = null
## The mesh the level loader built and placed for this record — the thing
## the stage swap swaps and the blast goes off at. Null until the loader
## hands it over, and for a record whose .3D the archives do not hold.
var body: Node3D = null
## The stage meshes the loader read out of TRANSFRM.PRS for this name,
## [0] = the intact object. EMPTY means the name has no template, which is
## the case the DOS handler returns on.
var meshes: Array = []

## The memory, and the whole of it: which stage is showing, and the damage
## counter in DOS units (16 to a stage, so the constant still means what
## its name says).
var stage: int = 0
var accum: float = 0.0

## The level loader has built this record's mesh and read its damage
## stages: from here on they are this node's.
func adopt(node: Node3D, stage_meshes: Array) -> void:
	body = node
	meshes = stage_meshes

## Has this record a TRANSFRM.PRS template at all? Membership is the
## loader's registration, which makes the same test the DOS lookup does —
## by the object's own mesh name (cars carry bit 1 and hit points but act
## 0x00 in the MAP data, and are staged all the same).
func has_stages() -> bool:
	return not meshes.is_empty()

## One qualifying hit: the counter goes up by one stage's worth and the
## mesh follows it. Returns false for a wreck that has nothing left to
## give — the final stage, or a thing already gone.
func advance() -> bool:
	var last: int = meshes.size() - 1
	if stage >= last and (meshes.size() > 1 or _spent()):
		return false                          # final wreck / already gone
	accum += Rules.DESTRUCT_DAMAGE_PER_STAGE
	var want: int = int(accum / Rules.DESTRUCT_DAMAGE_PER_STAGE)
	var alive: bool = body != null and is_instance_valid(body)
	if meshes.size() > 1:
		var new_stage: int = mini(want, last)
		if new_stage != stage:
			stage = new_stage
			# One announcement per stage that actually happens, wherever the
			# damage came from — gunfire as well as a chain (M3 step 3).
			branch.say(id, "destructible", "destruct",
				{"stage": stage, "stages": meshes.size()})
			if alive and body is MeshInstance3D and meshes[stage] != null:
				(body as MeshInstance3D).mesh = meshes[stage]
				branch.blast(id, body, stage == last)
			if stage == last:
				branch.runtime.set_spent(id)
	elif want >= 1:
		# No stage meshes — vanish (rubble piles etc.).
		branch.runtime.set_spent(id)
		branch.say(id, "destructible", "destruct", {"stage": 1, "stages": 1})
		if alive:
			branch.blast(id, body, true)
			body.visible = false
			branch.disable_collision(body)
	return true

## A CHAIN switched this on (0x18/0x19): a machine breaks it for you.
## MAP.248's girder has to ram 248WALL several times before it gives (the
## DOS run, 2026-09-11) — each press of the START BOX swings the girder
## and enables the wall once, and one enable is one stage, exactly as one
## hit is. Until 2026-09-16 the port ran every stage at the first enable
## and the wall fell at the first touch.
func break_down() -> void:
	if not has_stages():
		return
	print("[action] destructible @%05x struck by a chain" % id)
	var was_spent: bool = _spent()
	# (The stage itself is announced by advance(), which every way of
	# damaging the thing goes through — one stage a call.)
	advance()
	if was_spent or not _spent():
		return                                   # still standing, or long gone
	branch.runtime.set_hp(id, 0.0)
	branch.destroy(id)
	if body != null and is_instance_valid(body):
		branch.disable_collision(body)

func _spent() -> bool:
	return branch != null and bool(branch.runtime.spent(id))

# ---------------------------------------------------------------------
# The map's state overlay
# ---------------------------------------------------------------------
## How far this wreck has come — the branch asks for it on the way into
## a snapshot (Behaviour.present_snapshot). The shape is the one the
## save has always had, so an older save still reads.
func snapshot() -> Array:
	return [stage, accum]

## …and the way back, mesh and all. A wreck with no stage meshes that the
## overlay says is spent left the world instead.
func restore(snap: Array) -> void:
	if snap.size() < 2:
		return
	stage = int(snap[0])
	accum = float(snap[1])
	if body == null or not is_instance_valid(body):
		return
	if meshes.size() > 1:
		if body is MeshInstance3D and stage < meshes.size() and meshes[stage] != null:
			(body as MeshInstance3D).mesh = meshes[stage]
	elif _spent():
		body.visible = false
		branch.disable_collision(body)
