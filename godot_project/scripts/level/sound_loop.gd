## An AMBIENT LOOP — DOS act 0xEE (handler 0x12a47a): the sound id sits
## at sub+2 and the handle of the playing voice at sub+4, which is why the
## handler keeps no enable edge of its own. It is a LEVEL kind, not a cue:
## the loop runs for as long as the entity's bit 0 is up, and a chain that
## takes the bit away is what stops it (rules_skynet: fire "level",
## on_fire "none").
##
## The node IS the player, as the one-shot cue is (scripts/level/
## sound_cue.gd): the stream is the cached clip, so the editor's inspector
## can audition it, and the bake fills the id, act, sound id and state in
## as METADATA — behaviour.gd reads them through state_of/act_of/id_of,
## and a property of the same name here would shadow what the bake wrote.
## That is also why the chain's next node arrives as the `target` meta.
##
## Until 2026-09-16 this node was scriptless and had no `fire` at all, so
## the Behaviour branch's chain walk passed straight over it: MAP.231's
## first gate (@04c97) switches on four of these — the base alarm and its
## machinery — and not one of them started, nor was anything said about it
## on the bus (M3 step 4 called that loop_no_handler).

extends AudioStreamPlayer3D

## What a chain flip does to this node: the loop starts, and keeps
## running — unlike a cue, it does not clear its own enable bit.
##
## The scene still autoplays, which is how the ambient beds a map means to
## sound from its first second have always come up (the submarine's alarm
## carries a whole deck); which records DOS starts armed is a reading of
## the map data that belongs with the rest of the level kinds, not here.
## So a loop already sounding is left alone.
func fire() -> void:
	if stream == null or not is_inside_tree() or playing:
		return
	play()

## …and a chain that takes the bit away again stops it (behaviour.flip).
func silence() -> void:
	if playing:
		stop()
