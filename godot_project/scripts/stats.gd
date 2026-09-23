## Autoload `Stats`: the mission and career counters the STATISTICS tab
## of the mission screen shows.
##
## DOS keeps four ints per mission at DAT_000534d0 — shots fired, hits,
## enemies present, kills — and career totals at 0x53310..0x5331c; the
## screen (FUN_001346e5) prints four percentages from them and nothing
## else: this mission's hit ratio and share of enemies destroyed, then
## the same two for the career.
##
## What counts as a "hit" here: a shot of the PLAYER'S that damages an
## enemy. Splash from the player's own rockets and grenades counts once
## per enemy caught in it.

extends Node

const CFG_PATH: String = "user://stats.cfg"

# This mission.
var shots: int = 0
var hits: int = 0
var kills: int = 0
var enemies: int = 0
## The mission these counters belong to (its start-map number), -1 none.
var mission_key: int = -1
## Enemies already counted this mission, by identity (main.gd): a map
## entered again, or a save loaded, must not add its robots a second time.
var _counted: Dictionary = {}
## Held while a map's saved state is re-applied: the robots an 0xF3 spawn
## point had already let out come back out through enemy.gd's spawn_in(),
## which counts them — they were counted when they first appeared.
var hold_enemy_count: bool = false
# Career (persisted).
var total_shots: int = 0
var total_hits: int = 0
var total_kills: int = 0
var total_enemies: int = 0

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		total_shots = int(cfg.get_value("career", "shots", 0))
		total_hits = int(cfg.get_value("career", "hits", 0))
		total_kills = int(cfg.get_value("career", "kills", 0))
		total_enemies = int(cfg.get_value("career", "enemies", 0))

func _save() -> void:
	# A read-only run (the sharded verifier, N of them at once) keeps the
	# career to itself: two processes saving one file lose an update.
	if Assets.read_only:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("career", "shots", total_shots)
	cfg.set_value("career", "hits", total_hits)
	cfg.set_value("career", "kills", total_kills)
	cfg.set_value("career", "enemies", total_enemies)
	cfg.save(CFG_PATH)

## A new mission starts: the per-mission counters go back to zero.
func begin_mission(key: int = -1) -> void:
	shots = 0
	hits = 0
	kills = 0
	enemies = 0
	mission_key = key
	_counted.clear()

## Enemies that appeared (added up across a mission's maps).
func add_enemies(n: int) -> void:
	if hold_enemy_count:
		return
	enemies += n
	total_enemies += n

## One enemy of the mission, counted the first time its `identity` is
## seen. True when it was new.
func count_enemy(identity: String) -> bool:
	if _counted.has(identity):
		return false
	_counted[identity] = true
	add_enemies(1)
	return true

## The mission's counters for a save file.
func mission_state() -> Dictionary:
	return {"key": mission_key, "shots": shots, "hits": hits, "kills": kills,
		"enemies": enemies, "counted": _counted.keys()}

## Back to a saved mission's counters (the career totals stay as they are —
## they live in stats.cfg, not in a save).
func restore_mission(d: Dictionary) -> void:
	mission_key = int(d.get("key", -1))
	shots = int(d.get("shots", 0))
	hits = int(d.get("hits", 0))
	kills = int(d.get("kills", 0))
	enemies = int(d.get("enemies", 0))
	_counted.clear()
	for k in (d.get("counted", []) as Array):
		_counted[String(k)] = true

func shot() -> void:
	shots += 1
	total_shots += 1

func hit() -> void:
	hits += 1
	total_hits += 1

func kill() -> void:
	kills += 1
	total_kills += 1
	_save()

## "43%" — or "---%" when there is nothing to divide by, as in DOS.
static func pct(part: int, whole: int) -> String:
	if whole <= 0:
		return "---%"
	return "%d%%" % int(clampf(float(part) * 100.0 / float(whole), 0.0, 100.0))
