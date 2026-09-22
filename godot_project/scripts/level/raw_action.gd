## The entities whose behaviour is the RECORD's own bytes and nothing
## else — no mesh to move, no shape to stand in (docs/trigger_graph_plan.md
## §4, migration step 5d):
##
##   0x01-0x12  the map LIGHTS a chain switches, on a variant-2 record:
##              toggle (0x137700), flicker (0x137713), strobe (0x13773b)
##              and the fades (0x137747/0x137772)
##   0x2C       the countdown RELAY (v1.01 0x138038), which watches the
##              objective counter instead of the player
##   0xd6-0xda  the WATER movers (0x121160): the map's surface glides to
##              a new height, and two of the five swap themselves for
##              their partner so the next firing goes the other way
##   0xF3       the SPAWN sprites (0x129642): the robot SpawnEnemiesInit
##              built hidden here steps out
##
## …and, still inert, every act id the port has not decoded, plus the
## act-less relays a chain merely passes through (act 0, a link to the
## next entity). Those keep their data and their place in the chain so
## nothing is lost and nothing is invented.
##
## Until step 5d the four classes above were four arrays swept from one
## long loop (gone since step 5h). The node is the sweep now, and
## what it holds is what one of these records remembers between ticks:
## whether its robot is out, whether its flicker is showing the lamp or
## hiding it, whether its handler has announced itself already. What it
## does NOT hold is the record's state — the enable bit, the act byte and
## the light's two words belong to the level's trigger runtime
## (scripts/triggers/trigger_runtime.gd) and are written only there.

extends Node3D

const Rules := preload("res://scripts/triggers/rules_skynet.gd")

@export var id: int = 0
## DOS handler id; 0 = a relay.
@export var act: int = 0
## MAP entity variant: 1 = mesh, 2 = light, 3 = sprite.
@export var variant: int = 0
@export var mesh_name: String = ""
@export var sprite_index: int = -1
## The u16 at sub+2 (variant 3) or the light intensity (variant 2).
@export var param: int = 0
@export var hp: int = 0
## DOS state byte, as read.
@export var state: int = 0
@export var targets: Array[NodePath] = []

## The Behaviour branch this hangs under (scripts/level/behaviour.gd):
## where the trigger runtime, the level's lamps and the event bus are
## reached. Null for a branch nobody plays — the editor opening a baked
## scene — and then the baked bytes above are all there is.
var branch: Node = null

## An 0xF3 sprite's robot, built hidden by the level loader
## (SpawnEnemiesInit — at most 50 a map) and handed over at registration,
## and whether it has been let out.
var enemy: Node = null
var spawned: bool = false

## A flickering or strobing lamp: whether the effect is running at all
## and, while it is, whether this tick shows the lamp or hides it. The
## flip that takes the bit away ends the effect and leaves the lamp ON.
var fx_showing: bool = false
var fx_on: bool = true
## This light handler has announced itself. Flicker and strobe run every
## tick their bit is up (0x137713 / 0x13773b), so the event bus hears
## them once, on the EDGE, instead of a hundred times a second.
var fx_announced: bool = false

# ---------------------------------------------------------------------
# The live bytes (the runtime's)
# ---------------------------------------------------------------------
func _rt() -> RefCounted:
	return branch.runtime if branch != null else null

func act_now() -> int:
	var rt := _rt()
	return int(rt.act(id)) if rt != null else act

func enabled() -> bool:
	var rt := _rt()
	return rt.enabled(id) if rt != null else (state & 1) != 0

## `state &= 0xFE` — what a one-shot handler does to itself when it has
## fired. The runtime is the only thing that writes a state byte (5a).
func _clear_enable() -> void:
	var rt := _rt()
	if rt != null:
		rt.clear_enable(id)

# ---------------------------------------------------------------------
# Which class this record is on
# ---------------------------------------------------------------------
## "light", "relay" or "water" for a record one of the sweeps below runs
## for, and any other kind name for the ids that stay inert. Read off the
## act byte and the variant the MAP was AUTHORED with — the lists
## the long loop used to build once at load — so a water valve that
## swaps its own act byte (0xd9 ↔ 0xda) stays water either way.
##
## The rules module answers it, which keeps the running game and the
## generated graph drawing the line in exactly one place: a light act on
## a record that is NOT a variant-2 light is not a light at all
## (Rules.NOT_A_LIGHT — six meshes of the shipped maps carry act 0x01 and
## the game has never lit one, because those bytes are the mesh's Euler
## angles, not an intensity and an enable word).
##
## The spawn sprites are not here: a map may carry an 0xF3 the loader
## built no robot for (the DOS cap is 50 a map, and a type with no frames
## gets none), and those have never fired. They come in at registration
## instead, with the robot — as they always did.
func sweep_class() -> String:
	return String(Rules.rule_for_record(act, variant)["kind"])

# ---------------------------------------------------------------------
# The countdown relay (0x2C)
# ---------------------------------------------------------------------
## v1.01 handler 0x138038: while the relay is enabled, the tick the
## objective counter stands above zero and equal to the slot's word, it
## flips the chain from itself and switches off. MAP.232's 232MAIN waits
## for the ninth console — the counter is then 1 — and sets off the
## robots, the stuck door and the voice line.
func relay_watch(objectives_left: int) -> void:
	if not enabled():
		return
	if objectives_left <= 0 or objectives_left != Rules.RELAY_AT:
		return
	print("[action] relay @%05x fires (%d objective left)" % [id, objectives_left])
	branch.say(id, "relay", "relay", {"at": Rules.RELAY_AT, "left": objectives_left})
	branch.flip_chain(id)
	_clear_enable()

# ---------------------------------------------------------------------
# The spawn sprites (0xF3)
# ---------------------------------------------------------------------
## The chain enables the sprite, its robot appears, the sprite's bit goes
## down.
func spawn_watch() -> void:
	if not branch.fires(id):
		return
	_clear_enable()
	spawn_reveal()

## The robot steps out. Also what a save's overlay does on the way back
## into a map (Behaviour.present_restore), where the bit is long since
## down and the robot is simply out again.
func spawn_reveal() -> void:
	spawned = true
	branch.say(id, "spawn", "spawn", {"type": param & 0xFFFF})
	if enemy != null and is_instance_valid(enemy) and enemy.has_method("spawn_in"):
		print("[action] spawn @%05x: %s appears" % [id, enemy.name])
		enemy.spawn_in()

# ---------------------------------------------------------------------
# The water movers (0xd6-0xda)
# ---------------------------------------------------------------------
## Handler 0x121160: the map's water level glides to a new target. DOS Y
## grows downward, so a NEGATIVE delta RAISES the surface and the sign is
## flipped on the way out; a delta of 0 means "go to this entity's own Y",
## which is an absolute height and so is handed over in WORLD terms (the
## records are zone-local — see branch.zone_origin). 0xd9/0xda swap
## themselves for their partner as they fire, so MAP.254's valve maze
## raises and lowers in turn.
func water_watch() -> void:
	if not branch.fires(id):
		return
	_clear_enable()
	var cfg: Array = Rules.WATER_ACTS[act_now()]
	var delta_u: int = int(cfg[0])
	var partner: int = int(cfg[1])
	if partner != 0:
		_rt().set_act(id, partner)              # next time it goes the other way
	var target: float = -float(delta_u)
	if delta_u == 0:
		target = position.y + branch.zone_origin.y
		branch.water_to(target, true)
	else:
		branch.water_to(target, false)
	print("[action] water act @%05x (DOS delta %d)" % [id, delta_u])
	branch.say(id, "water", "water",
		{"delta": delta_u, "absolute": delta_u == 0, "target": target})

# ---------------------------------------------------------------------
# The map lights (0x01-0x12, variant-2 records)
# ---------------------------------------------------------------------
## One tick of this lamp. `fx_tick` is the port's flicker clock
## (Behaviour.LIGHT_FX_TICK): the DOS flicker and strobe handlers run on
## the engine tick, which is faster than anything worth watching.
##
## Toggle and the fades clear their own bit and so run once; flicker and
## strobe run for as long as their bit is up, and the flip that takes it
## away ends them with the lamp ON.
func light_watch(fx_tick: bool) -> void:
	if branch.fires(id):
		if not fx_announced:
			fx_announced = true
			branch.say(id, "light", "light",
				{"op": Rules.light_op(act_now()),
				 "enable": _rt().light_enable(id)})
		_light_step(fx_tick)
	else:
		fx_announced = false
		if fx_showing:
			# The chain took the bit away: the flicker ends on, and the next
			# one starts from a lit lamp as the first tick of one always did.
			fx_showing = false
			fx_on = true
			light_apply()

func _light_step(fx_tick: bool) -> void:
	var rt := _rt()
	var a: int = act_now()
	if a == Rules.ACT_LIGHT_TOGGLE:
		var word: int = rt.light_enable(id)
		rt.set_light_enable(id, -word if word != 0 else 1)
		_clear_enable()
		light_apply()
	elif a == Rules.ACT_LIGHT_FLICKER or a == Rules.ACT_LIGHT_STROBE:
		if not fx_tick:
			return
		fx_showing = true
		if a == Rules.ACT_LIGHT_STROBE or randf() < 0.5:
			fx_on = not fx_on
		light_apply()
	else:
		# Fade by (act - 12)/4 of the current intensity, up or down.
		var l = _lamp()
		var f: float = float(a - 0x0C) / 4.0
		if a >= 0x10:
			f = -float(a - 0x0C) / 4.0
		if l != null:
			l.light_energy = maxf(l.light_energy * (1.0 + f), 0.0)
		rt.set_light_intensity(id,
			maxi(int(float(rt.light_intensity(id)) * (1.0 + f)), 0))
		_clear_enable()
		light_apply()

## The lamp as the map shows it: on when the enable word is positive (the
## DOS toggle flips its sign bit), and hidden for the half of a flicker
## that is dark.
func light_apply() -> void:
	var l = _lamp()
	if l == null:
		return
	var rt := _rt()
	var on: bool = rt != null and rt.light_enable(id) > 0
	if fx_showing:
		on = on and fx_on
	l.visible = on

## The OmniLight3D main.gd placed for this record (_place_map_lights), or
## null — an outdoor map gets no lamps at all, and the settings that
## rebuild them free the old ones.
func _lamp() -> OmniLight3D:
	var l = branch.lamp(id) if branch != null else null
	return l if l != null and is_instance_valid(l) else null

## Everything this node remembers about the level's own doing, forgotten
## — what the verifier clears between two checks of the same map. The
## lamp is left showing whatever it shows: putting a robot back or a light
## back is the level loader's work, not a snapshot's.
func raw_forget() -> void:
	spawned = false
	fx_showing = false
	fx_on = true
	fx_announced = false
