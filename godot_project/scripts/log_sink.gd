## Autoload `Log` — captures everything the engine prints (print(),
## push_warning/push_error, script errors) through Godot's Logger hook
## and keeps the last LINES of it, so the in-game console can show the
## engine's own output ("what is loading, what is happening") instead of
## only command replies. Lines are plain text; the console colours
## errors.
##
## A level load prints hundreds of lines in a burst. The buffer is a ring
## (no Array.pop_front shifting 2 000 entries per line), the Logger hands
## its lines over in one deferred call per frame rather than one per line,
## and nothing is signalled per line: a reader remembers `total` and asks
## since() for what came after (the console does, once a frame, while it
## is open).
extends Node

const LINES: int = 2000

## Lines ever pushed — a reader keeps the value it has consumed up to.
var total: int = 0

var _ring: Array = []            # [text, error], at most LINES
var _next: int = 0               # the slot the next line overwrites once full

class Sink extends Logger:
	var owner: Node = null
	var _mutex := Mutex.new()
	var _pending: Array = []
	var _scheduled: bool = false

	func _log_message(message: String, error: bool) -> void:
		_queue(message.strip_edges(false, true), error)

	func _log_error(function: String, file: String, line_no: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		var what: String = rationale if not rationale.is_empty() else code
		_queue("%s (%s:%d %s)" % [what, file.get_file(), line_no, function], true)

	## Any thread may log: collect under the lock, drain on the main thread.
	func _queue(text: String, error: bool) -> void:
		if owner == null:
			return
		_mutex.lock()
		_pending.append([text, error])
		var schedule: bool = not _scheduled
		_scheduled = true
		_mutex.unlock()
		if schedule:
			owner.call_deferred("_drain")

	func take() -> Array:
		_mutex.lock()
		var out: Array = _pending
		_pending = []
		_scheduled = false
		_mutex.unlock()
		return out

var _sink: Sink = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_sink = Sink.new()
	_sink.owner = self
	OS.add_logger(_sink)

func _exit_tree() -> void:
	if _sink != null:
		OS.remove_logger(_sink)
		_sink = null

func _drain() -> void:
	if _sink == null:
		return
	for m in _sink.take():
		_push(String(m[0]), bool(m[1]))

func _push(text: String, error: bool) -> void:
	if text.is_empty():
		return
	for t in text.split("\n"):
		if t.is_empty():
			continue
		if _ring.size() < LINES:
			_ring.append([t, error])
		else:
			_ring[_next] = [t, error]
			_next = (_next + 1) % LINES
		total += 1

## The lines pushed after a reader's `seen` (a `total` it read earlier),
## oldest first — at most the LINES still held; the reader can tell how
## many scrolled out from total - seen - size().
func since(seen: int) -> Array:
	var n: int = mini(total - seen, _ring.size())
	if n <= 0:
		return []
	var out: Array = []
	out.resize(n)
	var oldest: int = _next if _ring.size() >= LINES else 0
	var start: int = oldest + _ring.size() - n
	for i in n:
		out[i] = _ring[(start + i) % _ring.size()]
	return out
