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
	var cfg := ConfigFile.new()
	cfg.set_value("career", "shots", total_shots)
	cfg.set_value("career", "hits", total_hits)
	cfg.set_value("career", "kills", total_kills)
	cfg.set_value("career", "enemies", total_enemies)
	cfg.save(CFG_PATH)

## A new mission starts: the per-mission counters go back to zero.
func begin_mission() -> void:
	shots = 0
	hits = 0
	kills = 0
	enemies = 0

## How many enemies this map holds (added up across a mission's maps).
func add_enemies(n: int) -> void:
	enemies += n
	total_enemies += n

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
