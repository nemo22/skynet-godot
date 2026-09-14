## Warm the combat effects before the level is played.
##
## The first shot, hit and kill of a session used to do their loading on
## the main thread in the middle of the fight: the explosion, muzzle-flash
## and smoke banks decoded pixel by pixel on first use, a projectile model
## opened two archives, and every effect's material compiled its shader on
## the frame it first appeared. main.gd calls warm() once a level is built,
## behind the load fade:
##
##   1. once per session: convert (or fetch from the asset cache) every
##      effect bank, the grenade sprite, the projectile models, the halo
##      texture and the fire/impact sounds the DOS ammo table names;
##   2. every call: put one of each effect — flash, blast, smoke, tracer,
##      bolt with halo, rocket with motor, sphere round, grenade, debris
##      chunk — in front of the camera for a few frames, not simulating,
##      then free them, so their shaders (and the light pass, with DYNAMIC
##      LIGHTS on) compile before play. The fade covers them. Skipped on
##      a headless run, where nothing is drawn.

extends RefCounted

const Explosion := preload("res://scripts/explosion.gd")
const MuzzleFlash := preload("res://scripts/muzzle_flash.gd")
const SmokePuff := preload("res://scripts/smoke_puff.gd")
const Grenade := preload("res://scripts/grenade.gd")
const Projectile := preload("res://scripts/projectile.gd")
const Tracer := preload("res://scripts/tracer.gd")
const Debris := preload("res://scripts/debris.gd")
const AIData := preload("res://scripts/enemy_ai_data.gd")

## Effect banks thrown outside the ammo table (whose impact banks — 365
## bullets, 364 bolts, 363 rockets, 356 grenades … — are read from it):
## the enemy-death fireball, the grenade blast and the player's bullet
## puff. The muzzle flash (219) and smoke (237) load through their own
## scripts.
const EXTRA_BANKS: Array = [Explosion.BANK_ENEMY_DEATH, 356, 365]
## Sounds every fight plays whatever the ammo (Enemy / Debris / Grenade).
const EXTRA_SOUNDS: Array = ["EXPLO1.RAW", "HIT2.RAW"]
## How far in front of the camera the warm-up effects stand: past
## Explosion.NEAR_SKIP and Projectile.NEAR_CLIP, close enough to be drawn.
const WARM_DISTANCE: float = 400.0
## Frames the warm-up effects stay drawn before they are freed.
const WARM_FRAMES: int = 3

static var _loaded: bool = false

## Holds the warm-up effects and frees them (and itself) after
## WARM_FRAMES drawn frames, paused or not.
class Holder extends Node3D:
	var frames_left: int = 3

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		frames_left -= 1
		if frames_left <= 0:
			queue_free()

## Warm every effect under `parent` (a Node3D in the level's tree). Cheap
## to call again: the loading happens once, the instances are a dozen
## nodes for three frames.
static func warm(parent: Node3D) -> void:
	if not _loaded:
		_loaded = true
		_load_all()
	if parent == null or not parent.is_inside_tree() \
			or DisplayServer.get_name() == "headless":
		return
	var at: Vector3 = parent.global_position
	var fwd := Vector3.FORWARD
	var cam: Camera3D = parent.get_viewport().get_camera_3d()
	if cam != null:
		fwd = -cam.global_transform.basis.z
		at = cam.global_position + fwd * WARM_DISTANCE
	var holder := Holder.new()
	holder.name = "EffectWarmup"
	holder.frames_left = WARM_FRAMES
	parent.add_child(holder)
	var side: Vector3 = fwd.cross(Vector3.UP).normalized() if absf(fwd.y) < 0.99 else Vector3.RIGHT

	var mf := MuzzleFlash.new()
	holder.add_child(mf)
	mf.setup(at, Color(1.0, 0.45, 0.22), 44.0)
	mf.set_process(false)

	var ex := Explosion.new()
	holder.add_child(ex)
	ex.setup(at + side * 60.0, 120.0, Explosion.BANK_ENEMY_DEATH)
	ex.set_process(false)

	var sm := SmokePuff.new()
	holder.add_child(sm)
	sm.setup(at - side * 60.0, 160.0)
	sm.set_process(false)

	var tr := Tracer.new()
	holder.add_child(tr)
	tr.setup(at - side * 120.0, at + side * 120.0, Color(1.0, 0.86, 0.55, 0.5), 2.0)
	tr.set_process(false)

	# A bolt (model + halo), a rocket (model + motor) and a model-less
	# round (the fallback sphere), none of them flying.
	var shots: Array = [
		{"model": "LASER3.3D", "color": Projectile.colour_for("LASER3.3D")},
		{"model": "ROCKET.3D", "color": Color(1.0, 0.75, 0.4), "trail": true},
		{"model": "", "color": Color(1.0, 0.45, 0.22)},
	]
	for i in shots.size():
		var cfg: Dictionary = shots[i]
		cfg["hits"] = "none"
		cfg["speed"] = 0.0
		var pr := Projectile.new()
		holder.add_child(pr)
		pr.setup(at + Vector3(0.0, 40.0 * float(i + 1), 0.0), fwd, 0.0, cfg, null)
		pr.set_physics_process(false)
		# A shot shows itself only once clear of the camera, from its
		# first physics tick — which this one will not have.
		for c in pr.get_children():
			if c is GeometryInstance3D:
				(c as GeometryInstance3D).visible = true

	var gr := Grenade.new()
	holder.add_child(gr)
	gr.visual_only = true
	gr.setup(at - Vector3(0.0, 40.0, 0.0), fwd, 0.0, 0.0, null)
	gr.set_physics_process(false)

	var db := Debris.new()
	holder.add_child(db)
	db.setup(at - Vector3(0.0, 80.0, 0.0), Vector3.ZERO, null)
	db.set_physics_process(false)

## Step 1: everything the effects load on first use.
static func _load_all() -> void:
	var banks: Dictionary = {}
	for b in EXTRA_BANKS:
		banks[int(b)] = true
	var models: Dictionary = {}
	var sounds: Dictionary = {}
	for s in EXTRA_SOUNDS:
		sounds[String(s)] = true
	# AIData.AMMO rows: [family, model, impact bank, damage, blast, life,
	# fire sound, impact sound].
	for a in AIData.AMMO:
		if int(a[2]) > 0:
			banks[int(a[2])] = true
		if not String(a[1]).is_empty():
			models[String(a[1])] = true
		for sid in [int(a[6]), int(a[7])]:
			var nm: String = Audio.sound_name(sid)
			if not nm.is_empty():
				sounds[nm.to_upper()] = true
	for b in banks:
		Explosion.bank_frames(int(b))
	MuzzleFlash.texture()
	SmokePuff.frames()
	Grenade.sprite_texture()
	for m in models:
		Projectile.model_mesh(String(m))
	Projectile.soft_dot()
	Tracer.unit_box()
	Debris.chunk_mesh()
	Debris.chunk_material()
	for nm in sounds:
		Audio.stream(String(nm))
