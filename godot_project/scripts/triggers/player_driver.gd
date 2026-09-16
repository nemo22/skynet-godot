## The PLAYER DRIVER — one way for automation to play the game
## (docs plan §5 layer (c), M3 step 4).
##
## Everything that has driven the player until now did it from the
## inside: the solver called ActionSystem.on_player_activate with an
## entity offset it had already picked, the console's `use` skipped the
## crosshair ray, the tests called tick() by hand. Each of those proves
## that the ACTION SYSTEM does something; none of them proves that a
## player can make it happen, because none of them goes through the
## input path the game actually has.
##
## This does. The movement, activate and fire keys are sent as real
## InputEvents through Input.parse_input_event, so they travel exactly
## the way a key press from the keyboard does —
##
##   Input.parse_input_event → (flush) → Viewport → fly_camera
##   _unhandled_input → _act_on / Controls.matches → _try_activate
##   (crosshair ray → ActionTarget.activate, or use_pressed →
##   main._on_use_pressed → press_use / activate_teleport / use_nearby)
##   and _shoot for the trigger
##
## — with the bindings the player has (scripts/controls.gd), the pauses,
## the capture state and the weapon cool-down all in the way, as they
## are in play. Held movement keys are the same: Controls.is_pressed
## reads Input's own key state, which a parsed event sets.
##
## Godot buffers parsed events until the main loop flushes them
## (use_accumulated_input), which would put a key press one frame after
## the call that made it; every send below flushes at once, so a press
## has landed by the time the call returns and the physics frame that
## follows it is the one that sees it.
##
## WHERE the player stands is not input — a player walks there, and for
## a check that wants him at one particular gate out of six hundred,
## walking is the test's own subject rather than its method. So the
## driver also places him (`place`, the spawn call the solver has always
## used) and points the view (`look`/`face`), and `walk_toward` is there
## for the checks that do want the last few units done on the keys.
##
## Shared by scripts/mission_solver.gd (--solve) and
## scripts/triggers/trigger_verifier.gd (--verify-triggers): one copy of
## "put the player there and let the game run N frames", so the two
## cannot drift apart.

extends RefCounted

## Clearance under the capsule when it is placed on a floor
## (mission_solver.LIFT — the controller's own safe_margin).
const LIFT: float = 4.0
## Eye height on foot (main.EYE_HEIGHT) — where the DOS proximity
## handlers measure from, and where `face` aims from.
const EYE: float = 75.0

## scripts/main.gd (untyped: its privates are read, as the solver does).
var main = null
var player: CharacterBody3D = null
## action name → the code currently held down, so release_all can undo
## a run that ended early.
var _held: Dictionary = {}

func setup(main_node) -> void:
	main = main_node
	player = main_node.player

func tree() -> SceneTree:
	return main.get_tree()

# ---------------------------------------------------------------------
# Where the player is and what he looks at
# ---------------------------------------------------------------------
## Put the player's FEET at `feet` (world), keeping his health, ammo and
## weapons — set_spawn(reset_state = false), the call --solve has always
## used. `yaw` NAN leaves the facing alone.
func place(feet: Vector3, yaw: float = NAN) -> void:
	var y: float = player.rotation.y if is_nan(yaw) else yaw
	player.set_spawn(feet + Vector3(0.0, LIFT, 0.0), y, false)

## Point the view (radians). fly_camera.set_view — the console's `aim`.
func look(yaw: float, pitch: float = 0.0) -> void:
	player.set_view(yaw, pitch)

## Look from the eye at a world point.
func face(target: Vector3) -> void:
	var d: Vector3 = target - eye()
	if d.length() < 0.001:
		return
	look(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))

## Where the DOS proximity handlers measure the player from.
func eye() -> Vector3:
	return main._eye_position()

func feet() -> Vector3:
	return player.global_position

# ---------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------
## Wait `n` drawn AND physics frames. The ActionSystem ticks in main's
## _physics_process, but a flood or a level build can run several physics
## steps inside one iteration, so waiting for physics frames alone can
## step past the tick that was supposed to see the player somewhere
## (mission_solver, 2026-09-11).
func frames(n: int) -> void:
	for _i in n:
		await tree().process_frame
		await tree().physics_frame

## Physics frames only — for a check counting ticks of the action sweep.
func physics(n: int) -> void:
	for _i in n:
		await tree().physics_frame

# ---------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------
## Hold (or let go of) the key bound to `action` (scripts/controls.gd
## names: forward, back, left, right, sprint, up, activate, fire …).
func hold(action: String, on: bool) -> void:
	var code: int = int(Controls.binds.get(action, 0))
	if code == 0:
		return
	if on:
		if _held.has(action):
			return
		_held[action] = code
	else:
		if not _held.has(action):
			return
		_held.erase(action)
	_send(code, on)

## One press and release of a bound key — the activate key, a weapon
## select, the throw key.
func press(action: String) -> void:
	var code: int = int(Controls.binds.get(action, 0))
	if code == 0:
		return
	_send(code, true)
	_send(code, false)

## One press and release of a raw keycode — the weapon number keys,
## which fly_camera reads straight off the event (KEY_1..KEY_9) rather
## than through a binding.
func press_key(code: int) -> void:
	_send(code, true)
	_send(code, false)

## The ACTIVATE key. fly_camera._unhandled_input → _act_on →
## _try_activate: the crosshair ray first, then use_pressed.
func activate() -> void:
	press("activate")

## One shot with the held weapon. FIRE is on a mouse button by default,
## and fly_camera only acts on mouse buttons while the view has the
## cursor — so the first press captures it, exactly as it does for a
## player who has just clicked into the window.
func fire() -> void:
	if Controls.is_mouse(int(Controls.binds.get("fire", 0))):
		ensure_capture()
	press("fire")

## Give the view the mouse, if it has not got it (a no-op on a key bind
## and in a headless run, where there is no cursor to take).
func ensure_capture() -> void:
	if bool(player.get("_captured")):
		return
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = _centre()
	down.global_position = down.position
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	var up: InputEventMouseButton = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()

## Let go of everything this driver is holding (a check that ended early
## must not leave the player walking into the next one).
func release_all() -> void:
	for action in _held.keys():
		_send(int(_held[action]), false)
	_held.clear()

func held(action: String) -> bool:
	return _held.has(action)

# ---------------------------------------------------------------------
# Walking
# ---------------------------------------------------------------------
## Walk toward `target` on the movement keys until the feet are within
## `stop` of it (horizontally) or `max_frames` physics frames have gone
## by. Returns how close it got. The view is turned toward the target
## every frame, because the keys move the player along it.
func walk_toward(target: Vector3, max_frames: int = 60, stop: float = 40.0,
		run: bool = false) -> float:
	var best: float = _flat(target)
	look(atan2(-(target.x - feet().x), -(target.z - feet().z)), 0.0)
	hold("forward", true)
	if run:
		hold("sprint", true)
	for _i in max_frames:
		await tree().physics_frame
		var d: float = _flat(target)
		best = minf(best, d)
		if d <= stop:
			break
		var dir := Vector3(target.x - feet().x, 0.0, target.z - feet().z)
		if dir.length() > 1.0:
			look(atan2(-dir.x, -dir.z), 0.0)
	hold("forward", false)
	if run:
		hold("sprint", false)
	await tree().physics_frame
	return best

func _flat(target: Vector3) -> float:
	return Vector2(target.x - feet().x, target.z - feet().z).length()

# ---------------------------------------------------------------------
# The event itself
# ---------------------------------------------------------------------
## A bind is a keycode, or a NEGATIVE mouse button index
## (scripts/controls.gd). Flushed at once: Godot buffers parsed events
## until the main loop's own flush, and a check that pressed a key and
## then stepped one physics frame would otherwise see the press land in
## the frame after the one it measured.
func _send(code: int, down: bool) -> void:
	if Controls.is_mouse(code):
		var mb := InputEventMouseButton.new()
		mb.button_index = -code
		mb.pressed = down
		mb.position = _centre()
		mb.global_position = mb.position
		Input.parse_input_event(mb)
	else:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = down
		k.echo = false
		Input.parse_input_event(k)
	Input.flush_buffered_events()

## The middle of the window — where the crosshair is, and so where a
## mouse press belongs.
func _centre() -> Vector2:
	var vp: Viewport = main.get_viewport()
	if vp == null:
		return Vector2.ZERO
	return (vp.get_visible_rect().size as Vector2) * 0.5
