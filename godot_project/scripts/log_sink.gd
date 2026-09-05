## Autoload `Log` — captures everything the engine prints (print(),
## push_warning/push_error, script errors) through Godot's Logger hook
## and keeps the last LINES of it, so the in-game console can show the
## engine's own output ("what is loading, what is happening") instead of
## only command replies. Lines are plain text; the console colours
## errors.
extends Node

signal line(text: String, error: bool)

const LINES: int = 2000

var lines: Array = []            # [text, error]
## Lines ever pushed — `lines` is a ring, so a reader remembers how many
## it has consumed and takes the tail from there.
var total: int = 0

class Sink extends Logger:
	var owner: Node = null
	func _log_message(message: String, error: bool) -> void:
		if owner != null:
			owner.call_deferred("_push", message.strip_edges(false, true), error)
	func _log_error(function: String, file: String, line_no: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		if owner != null:
			var what: String = rationale if not rationale.is_empty() else code
			owner.call_deferred("_push", "%s (%s:%d %s)" % [what, file.get_file(), line_no, function], true)

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

func _push(text: String, error: bool) -> void:
	if text.is_empty():
		return
	for t in text.split("\n"):
		if t.is_empty():
			continue
		lines.append([t, error])
		total += 1
		if lines.size() > LINES:
			lines.pop_front()
		line.emit(t, error)
