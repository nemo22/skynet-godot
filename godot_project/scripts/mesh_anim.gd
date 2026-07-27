## Vertex-frame mesh animation for a MeshInstance3D.
##
## XnGine .3D actor meshes store one vertex block per animation frame.
## LevelLoader pre-builds an ArrayMesh per frame; this node cycles its
## `mesh` through them at a fixed rate. A single-frame (static) mesh
## simply shows frame 0 and never ticks.

extends MeshInstance3D

var _frames: Array = []      ## Array[ArrayMesh]
var _fps: float = 10.0
var _accum: float = 0.0
var _index: int = 0

## Assign the pre-built per-frame meshes and start playback.
func setup(frame_meshes: Array, frames_per_sec: float = 10.0) -> void:
	_frames = frame_meshes
	_fps = maxf(frames_per_sec, 0.1)
	_index = 0
	if not _frames.is_empty():
		mesh = _frames[0]
	set_process(_frames.size() > 1)

func _process(delta: float) -> void:
	if _frames.size() < 2:
		return
	_accum += delta
	var step := 1.0 / _fps
	while _accum >= step:
		_accum -= step
		_index = (_index + 1) % _frames.size()
	mesh = _frames[_index]
