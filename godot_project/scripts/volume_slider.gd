## Segmented volume slider drawn over an OPTIONS.IMG slider track.
##
## `channel` picks which level it drives: "sound" (the master bus, the
## SOUND row) or "music" (the Music bus, the MUSIC row).
##
## The original DOS slider shows the level as a row of discrete filled
## squares (not a continuous bar), so this draws N blocks from the left
## edge of the track. Setting the value drives the master audio bus
## through the Audio autoload (which also persists it).

extends Control

const SEGMENTS: int = 16

var value: float = 1.0
var channel: String = "sound"

func _ready() -> void:
	value = Audio.music_volume if channel == "music" else Audio.master_volume
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	var apply := false
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		apply = true
	elif event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		apply = true
	if apply and size.x > 0.0:
		var seg := clampi(
			int(round((event.position.x / size.x) * SEGMENTS)), 0, SEGMENTS)
		value = float(seg) / float(SEGMENTS)
		if channel == "music":
			Audio.set_music_volume(value)
		else:
			Audio.set_master_volume(value)
		queue_redraw()
		accept_event()

func _draw() -> void:
	# Discrete filled squares from the left edge of the track.
	var filled := int(round(value * SEGMENTS))
	var gap := maxf(1.0, size.x * 0.012)
	var seg_w := (size.x - gap * float(SEGMENTS - 1)) / float(SEGMENTS)
	if seg_w <= 0.0:
		return
	for i in filled:
		var x := float(i) * (seg_w + gap)
		draw_rect(Rect2(x, 0.0, seg_w, size.y),
			Color(0.55, 0.80, 0.95) if channel == "music" else Color(0.55, 0.95, 0.70), true)
