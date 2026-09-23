# Command line

Every way the port can be started, read out of the code that parses it.
`godot` below is the Godot 4.7.2 executable; a released build is its own
executable (`SkyNET.exe`, `SkyNET.x86_64`, the `.app`) and takes the same
switches without `--path`.

## The two argument lists

The game reads its switches from **both** of Godot's argument lists — the
one before a bare `--` and the one after it. A switch is either
`--name=value` or a bare `--name`.

```sh
godot --path godot_project -- --map=MAP.230 --no-briefing
SkyNET.exe --map=MAP.230 --no-briefing
```

When you start the game through the Godot executable, put your switches
**after `--`**: everything before it is the engine's own (`--headless`,
`--path`, a scene path, `--write-movie`, `--fixed-fps`, `--resolution`).
An exported build has no engine arguments of its own to collide with, so
there both forms work.

A handful of switches are read **only** from the list after `--`, because
the code that reads them asks for that list alone:

- `--load-trace`
- `--no-client` (the network test suite)
- everything the map audit takes (`--maps=`, `--settle=`)

Two of the parsers are narrower than the general one and only see
`--name=value`, never a bare `--name`: the **menu** (see the note under
*Starting the game*) and the **map tools**. Where that matters it is said
in the entry.

---

## For a player

| Option | What it does |
| --- | --- |
| `--gamedata=DIR` | use this data directory for this run, instead of the remembered one |
| `--setup` | ask for the game folders again |
| `--map=MAP.230` | start straight on a map, no menu |
| `--host=MAP.605 --bots=3` | host a deathmatch at once |
| `--join=ADDRESS[:PORT]` | join one (port defaults to 27015) |
| `--import` | build the asset cache and quit |

Everything else on this page is a developer tool. It is all marked
**(dev)**.

---

## Data and cache

| Option | Value | What it does |
| --- | --- | --- |
| `--gamedata=DIR` | a directory | Use this data directory. Either the install root or its `GAMEDATA` folder works — it is recognised by `MDMDMAP2.BSA` (SkyNET) or `MDMDMAPS.BSA` (Future Shock). If it holds neither, the switch is ignored with a warning and the game falls back to what it remembers, then to a `gamedata` folder beside the project or the executable. |
| `--setup` | — | Open the first-start screen and ask for both game folders again, even when they are already remembered. |
| `--no-cache` | — | Turn the converted-asset cache off for this run: nothing is read from it and nothing is written to it. Everything is decoded from the original data each time, so loads are slow. **(dev)** |
| `--cache-read-only` | — | Read the cache, never write to it: a missing or stale file is built for this run and not saved, no scene is baked, a cache of another version is left unused instead of wiped, and the career statistics are not saved either. This is what lets several processes run on one project at once (the sharded gate); `--verify-shard=` implies it. A read-only run on a stale cache still gets the right answers, only slowly, and warns once per file it did not write — run `--import` first. **(dev)** |
| `--save-dir=DIR` | a directory | Keep the save slots there instead of the user folder's `saves` — how a copy of someone's saves is loaded (`--console=load 5`) without touching theirs. The test suites use a folder of their own (`user://test_saves`) whatever is given. Read only from the list after `--`. **(dev)** |
| `--import` | — | Convert the game data into the cache behind the progress screen, then quit. Also the way to rebuild a cache: it runs even when the import is already complete. |
| `--import-missions` | — | Bake only the mission scenes (a whole mission as one Godot scene) and quit. Exit code 0 when every mission the data holds came out. **(dev)** |
| `--import-triggers` | — | Rebuild only the generated trigger graphs and quit. Seconds rather than minutes — the whole rebuild after a change to the trigger rules. **(dev)** |
| `--level-scene=MAP.210` | one map | Bake that one level scene — the world in Godot's own format — and quit. **(dev)** |

The import switches are all checked *after* `--host`, `--screen`, `--join`
and `--map` have already left for the game, so do not combine them with
those: the one that comes first wins and the import never runs.

**Who may use the cache at the same time.** Every process that has the
cache open keeps a file `LOCK.<pid>` in it, fresh for a minute at a time.
The lock guards the one destructive thing there is: a process that finds a
cache of another version or of other game data wipes it, and it never does
while somebody else's lock is fresh. Readers can share the cache freely —
they only load files that were complete and recorded in the trust manifest
before they started. The **writers** are alone with it: `--import`,
`--import-missions` and `--import-triggers` refuse to start (exit code 1,
naming the process) while another process holds the cache or when the run
is `--cache-read-only`. An ordinary game run that fills in a missing file as
it plays is still a writer, so run the several-at-once tools only on a cache
that is fully built.

```sh
godot --headless --path godot_project -- --import
godot --headless --path godot_project -- --gamedata=DIR --import
```

## Source, derived, mod

There is exactly one source for a map: the original DOS `MAP.NNN` file in
the game's archive. Nothing in the port ever writes one, and there is no
way back from Godot into that format — you are not asked to edit game
data.

Everything under `converted/` is **derived** from that source. It is
generated, it is rewritten by every `--import`, and it carries a
`README.txt` saying so. Delete the folder whenever you like; do not edit
anything in it and do not check it in.

Your own changes are **mods**, in the `mods/` folder beside the game data
(`res://mods` in a development checkout):

| File | What it does |
| --- | --- |
| `mods/maps/MAP.210.level.scn` | Replaces the whole level scene of that map. The game instances this instead of `converted/maps/MAP.210.level.scn` — no import, no rebake, picked up the next time the map is loaded. The way to make one is to open the converted level in the editor (SkyNET Maps dock → *Open LEVEL*) and save it here under the same name. |
| `mods/maps/MAP.210.detail.tscn` | Added *on top of* whichever level is playing, instead of replacing it. Plain data only — it is scanned before it is loaded. |

A modded scene changes **what is presented and where it stands**, and
nothing else. Every trigger — every door, gate, button, exit, objective
and destructible — is read from the DOS `MAP` records, which the mod
cannot reach. So a node you add to a modded scene has no record behind
it and can never fire, and one you delete is still there as far as the
trigger runtime is concerned.

Two more things follow from that. A mission scene
(`converted/missions/MISSION.NNN.scn`) always stands on the derived
level scenes; the mod is put in the zone's place when the zone is built,
so the mission bake never has to be rerun for one. And a modded map is
left **unpinned** by `--verify-graph`: the trigger lock speaks for the
maps as shipped and as generated, which a modded one is not.

## Starting the game

| Option | Value | What it does |
| --- | --- | --- |
| `--map=MAP.230` | a map name | Skip the menu and start on that map. Case is fixed up for you. |
| `--screen=NAME` | see below | Open a menu screen instead of the title screen and stop there. **(dev)** |
| `--dev` | — | Enable the scene switcher and its overlay: CTRL+F1 the game, CTRL+F2 the texture atlas viewer, CTRL+F3 the object viewer, CTRL+F4 the enemy viewer, CTRL+F5 the sound browser. Without it those keys do nothing. CTRL is held because the bare F1-F5 belong to the game: they pick the thrown item. **(dev)** |

`--screen=` takes one of `netmenu`, `join`, `netjoin`, `newgame`, `load`,
`options`, `controls`, `mouse`, `detail`, `debug`, `maps`. `quit` shows the title
screen with its quit confirmation up. Any other word shows the title
screen.

**How the menu chooses.** The menu acts on the first of these it finds, in
this order, and then does nothing else: `--host`, `--screen`, `--join`,
`--map`, `--verify-graph`, `--accept-lock`, `--import-missions`,
`--import-triggers`, `--level-scene`, `--import`.
`--name` and `--menu-shot` are handled before all of them and combine with
any of them.

**The menu's parser only understands `--name=value`.** Its bare flags
(`--setup`, `--import`, `--import-missions`, `--import-triggers`,
`--accept-lock`, `--verify-graph`) are looked for separately and work as
written; but a bare flag that is *not* on that list is invisible to the
menu. See *Not implemented*.

`--map=` belongs to the menu, not to the game scene. Starting
`res://scenes/main.tscn` directly ignores it and comes up on the built-in
default map.

## The campaign and missions

| Option | Value | What it does |
| --- | --- | --- |
| `--no-briefing` | — | Skip the mission briefing screen and drop straight into the level. Only mission start maps have one. **(dev)** |
| `--mission-scene` | — | Force the mission-scene runtime on for this run — the whole mission as one scene — when the settings file says off. **(dev)** |
| `--no-mission-scene` | — | Put this run back on the per-map runtime, a map at a time, the way the port worked before. Beats `--mission-scene`. **(dev)** |

Neither flag can turn the mission runtime on where it never applies: a
deathmatch, Future Shock data and a loose map that belongs to no mission
always play a map at a time.

`--screenshot` and `--campath` and `--walk` skip the briefing by
themselves, so `--no-briefing` is only needed for a plain run. The
exception is `--screenshot` together with `--tab`, which is how the
briefing screen itself is captured.

## Automation and debugging

All of these are **(dev)**.

### Where the player stands

| Option | Value | What it does |
| --- | --- | --- |
| `--pos=X,Y,Z` | three numbers | Put the player at that point (an eye position, in DOS units, as the markers are written). Implies `--noclip` unless `--walk` is also given. |
| `--yaw=DEG` | degrees | Face that way. Without `--pitch`, the pitch is left alone. |
| `--pitch=DEG` | degrees | Look up or down. Defaults to 0 when `--yaw` is given without it. |
| `--noclip` | — | No collisions, no gravity. |
| `--god` | — | Invincible. |
| `--player-radius=N` | units | Change the radius of the player's capsule, to measure what a level was built for. The height stays as it is. |
| `--near=GROUP[:N[:DIST]]` | a node group | Stand 260 units from the first node of a group, looking at it. `pickup`, `fire`, `enemy` and the like; `:N` picks the N-th node, `:N:DIST` stands that far off instead. It works by rewriting `--pos`, `--yaw` and `--pitch`, so it beats whatever you passed in them. |
| `--walk=ROUTE` | see below | With collisions **on**, walk to each point in turn and log the body twice a second — the reproduction of a "cannot get past this" report. |
| `--campath=SPEC` | see below | Fly the camera along a scripted path and quit at the end of it. For a recorded clip: with the engine's `--write-movie` the frame delta is fixed, so the same path renders the same frames every time. |

`--walk=` is `x,z;x,z;…` — waypoints in the ground plane, in order. One
element that is a single number is the time limit in seconds instead
(default 30). Example: `--walk=1200,-3400;1500,-3600;45`.

`--campath=` is either the path to a JSON file holding a `keys` array (at
least two keys of `t`, `pos`, `yaw`, `pitch`, `fire`), or `auto`, or
`auto:` followed by `key=value` pairs out of `secs`, `speed`, `turn`,
`rise`, `fire` — a straight move from wherever the player spawned.
Example: `--campath=auto:secs=8,speed=220,turn=-30`.

### Screenshots and timing

| Option | Value | What it does |
| --- | --- | --- |
| `--screenshot=PATH` | a .png path | Wait for the delay, re-apply the requested view, capture the window and print where it went. The briefing is skipped unless `--tab` is given. |
| `--menu-shot=PATH` | a .png path | The same for the **menu**: capture the window once it has settled. It is taken by an autoload rather than by the menu, so it still fires when `--map=` has already swapped the menu for the game. |
| `--shot-delay=SEC` | seconds | How long to wait before the capture. 1.5 in the game; in the menu 1.5, or 1.0 when `--screen=` is also given. |
| `--quit-after-shot` | — | Quit once the picture is saved. Also ends a `--perf` run, despite the name. In the **menu** it does not work as a bare flag — see *Not implemented* — but a menu shot without `--screen=` quits anyway. |
| `--tab=NAME` | `BEGIN`, `BRIEFING`, `TACTICAL`, `STATISTICS` | Capture the mission briefing screen with that tab selected, instead of the level. Only read together with `--screenshot`. |
| `--automap` | — | Turn the automap on right before the capture. Only read together with `--screenshot`. |
| `--console2=CMDS` | `;`-separated | Run console commands in the last moment before the capture, so short-lived effects are still on screen. Only read together with `--screenshot`. |
| `--perf[=SEC]` | seconds | Stand still with vsync off and report the distribution of frame times, not the average. A bare `--perf` measures for 1 second — pass a number. |
| `--quit-after=SEC` | seconds | Leave any network game and quit after that many seconds. What a headless second instance is started with. |

### Console

| Option | Value | What it does |
| --- | --- | --- |
| `--console=CMDS` | `;`-separated | Run console commands once the **first** level is up, each reply into the log. They run after `--pos` and `--near` have placed the player. |
| `--console-NNN=CMDS` | `;`-separated | The same, but on the map whose number is `NNN` — it runs when that map comes up. Example: `--console-013=tp 100,0,-200;use`. |
| `--console-open[=TEXT]` | text | Drop the console itself open, with `TEXT` already typed in the input line — a screenshot of the console UI. |

### Probes and traces

| Option | Value | What it does |
| --- | --- | --- |
| `--floormap=SPEC` | see below | Print an ASCII plan of the collision floor. `;`-separated for several. |
| `--slice=SPEC` | see below | Print a vertical cross-section of the collision geometry. `;`-separated for several. |
| `--spawn-probe` | — | Report what is above and below the spawn point, and how many entities ended up outside the tree. |
| `--load-trace` | — | Print where the seconds of a level load actually go, phase by phase. Read only from the list after `--`. |

`--floormap=x0,z0,x1,z1,step,y[,ceil|ceilfine]` — rows are z, columns are
x. A ray per cell: `.` floor within 40 units of `y`, `#` something higher
than `y+40`, a digit = floor that many hundred units lower, a space =
nothing. With `ceil` the digits are the clearance above the feet in 40-unit
steps; `ceilfine` uses letters in 10-unit steps, which reads doorways
better.

`--slice=x,z0,z1,y0,y1,step[,x]` — the plane `x` = const, rows are y from
the top down, columns are z. `#` where a short ray from the cell centre
hits a surface. Add a trailing `,x` to slice along the other axis, in which
case the first number is the fixed `z`.

```sh
godot --path godot_project -- --map=MAP.252 --no-briefing \
      --pos=1420,-380,-2900 --yaw=95 --screenshot=shot.png --quit-after-shot
```

## Multiplayer

| Option | Value | What it does |
| --- | --- | --- |
| `--host=MAP.605` | an arena map | Host a deathmatch on that arena at once. The arena's settings come from `NETLEVEL.PRS`; an unknown map gets the built-in defaults. |
| `--bots=N` | a count | Bots to fill the arena with. Default 0. |
| `--skill=N` | 0, 1 or 2 | Bot skill. Default 1. |
| `--frags=N` | a count | Frag limit. 0 (the default) = none. |
| `--time=MIN` | minutes | Time limit. 0 (the default) = none. |
| `--port=N` | a port | Listen on that port instead of 27015. |
| `--name=NAME` | a name | The player name, remembered for later runs as if it had been typed in the menu. Works with `--host` and with `--join`. |
| `--join=ADDRESS[:PORT]` | host or host:port | Connect to a server. Without a port, 27015. |

All of these except `--join` and `--name` are read by `--host` only. They
all need the `=` form.

```sh
godot --path godot_project -- --host=MAP.605 --bots=3 --skill=2 --frags=20
godot --path godot_project -- --join=192.168.1.20 --name=SECOND
```

The host owns the arena, the map included. A door someone opens, a lever
someone pulls, a car someone shoots to pieces and an ambient loop a chain
switches off are all the server's to decide: a client that walks into a
trigger, presses the use key or lands a shot on something breakable sends
that as an **intent**, the server runs it through the same entry point its
own player's key reaches — the record's own radius, its state bits, its
chain — and sends back what changed. A joiner's welcome carries the whole
of it, so somebody arriving in the middle of a round walks into the doors
that are already open. Positions are not on that wire: the flip goes out
with where the mover stood, and every peer animates the travel from its
own copy of the map. The campaign is single-player and is untouched by
any of this.

Both sides must be the same build — the wire protocol version is checked
when a client says hello, and a mismatch is refused with a message saying
so.

## The trigger tooling

All **(dev)**. Three layers: the graph as it was reviewed and pinned (the
lock), the graph rebuilt and diffed against it, and the verifier that
drives every trigger in the running game.

| Option | Value | What it does |
| --- | --- | --- |
| `--verify-graph[=SPEC]` | `all`, or map numbers | Rebuild every shipped map's trigger graph and diff it against the pinned lock. Says which map, which node and how it moved. Reads no cache and writes nothing. Exits non-zero when anything moved. `--verify-graph=210,217` checks only those maps. |
| `--accept-lock` | — | Rewrite the lock from the current rules. A deliberate act, after reading what `--verify-graph` printed. Exits non-zero if it refuses to write. |
| `--verify-triggers[=SPEC]` | see below | In the **running game**: for every trigger node of every map in the spec, put the player where the node says he must stand, activate it through the real input path, and lay what happened against what the graph predicted. Known failures are listed in the project's xfail file; the run exits non-zero only on a failure that is not in it. |
| `--verify-out=PATH` | a file | Write one line per checked node — map, id, act byte, kind, mode, result, reason — for triage. |
| `--verify-shard=I/N` | `0/4` … `3/4` | Check only this process's share of the maps: the spec's list split into N parts, whole mission decades at a time (a variant map is checked after its world, as in a full run), the heaviest decade first to the part with least work. N processes with the same spec check every map once. Beside the rows it writes `PATH.maps` — which maps, by their place in the full list, and how many rows each — so the parts merge back into the single-run file. Implies `--cache-read-only`. |
| `--verify-base-lock=PATH` | a lock file | With `changed`: also every map whose lock lines differ from this older lock — the maps an accepted lock change moved. |
| `--verify-base-xfail=PATH` | an xfail file | With `changed`: also every map with a known-failure line that is in one of the two lists and not the other. |
| `--verify-limit=N` | a count | Check at most N nodes per map. |
| `--verify-nodes=ID,ID` | hex ids | Check only those node ids (as `--verify-graph` and the dump print them). |
| `--verify-missions[=SPEC]` | `all`, or mission start maps | Play the hand-written mission specs (`tests/rules/skynet.missions.txt`) — one block per campaign mission, the steps in the order a player performs them, across the maps of the mission and through the real input path. Says PASS/FAIL/XFAIL per step and per mission, and exits non-zero only on a failure the spec does not excuse with an `xfail` tag. `--verify-missions=240,280` plays only those. |
| `--triggers=SPEC` | a map, or `all` | Print a map's generated trigger graph for review: what each node is, the bytes it came from, the rule that applies, how a player sets it off, the chain it flips, and what the first and second activation do. `all` prints one line per map plus the warning totals. Runs in the map dump scene, so it needs the `=` form. |

`--verify-triggers=` takes `all` (or nothing), `mission:210` for the whole
decade a mission's maps sit in, `maps:215,217` for exactly those, or
`changed` for only the maps whose freshly built graph no longer matches
the lock — and, given `--verify-base-lock` / `--verify-base-xfail`, the maps
whose pinned lines or known failures differ from those. The game never
asks git; `tools/verify_gate.py` hands in the committed files and decides
when a change to the code means every map. The verifier drives its own
level changes, so give it a map to start on and let it go.

Give every verifier run Godot's own `--fixed-fps 60` (an engine switch,
before `--`). The verifiers wait in physics frames, never in seconds, and
with it no frame waits for the wall clock: a full `--verify-triggers=all`
takes about 5 minutes instead of 20, row for row the same file.

```sh
godot --headless --path godot_project -- --verify-graph
godot --headless --fixed-fps 60 --path godot_project -- --map=MAP.200 --no-briefing \
      --no-mission-scene --verify-triggers=all --verify-out=rows.txt
godot --headless --fixed-fps 60 --path godot_project -- --map=MAP.210 --no-briefing \
      --no-mission-scene --verify-missions=all --verify-out=rows.txt
godot --headless --path godot_project res://scenes/map_dump.tscn -- --triggers=215
```

`--verify-missions=` is the layer above `--verify-triggers`: the verifier
proves one trigger at a time on a map put back as its file has it, and
this plays a whole MISSION — the doorways taken, the map changing under
the run, nothing reset between steps and the mission counter the one the
game keeps. A step is `use|use_below|prox|shoot|exit|wait|walk|stay <map>
<id> expect <effects>`, read as "these effects happened" and not "exactly these";
`stay` does nothing at all — the player stays where the step before left
him (a doorway's arrival, MAP.250's torpedo ride) and the game runs;
`must_not` says what an action must NOT come to (the four regressions the
spec pins), `counter N` is what the mission counter must read at the end,
and `xfail <tag>` excuses a step, or a whole mission, that cannot be
played through yet. The effect names are the graph's own, as `--triggers=`
and the lock print them.

### The gate

What has to hold before a change is committed, run by
`godot_project/tools/verify_gate.py` (Python 3, standard library only). It
starts every Godot process with `--headless --fixed-fps 60` and
`--cache-read-only`, runs them side by side, writes the logs and the rows
into `--out=DIR` (a temporary folder by default) and exits 0 only when all
of it held. The Godot executable is `--godot=EXE`, else `$GODOT`, else
found on the PATH. Build the cache first (`--import`) — the gate only reads
it.

| Command | What it runs | Time (20 threads) |
| --- | --- | --- |
| `python godot_project/tools/verify_gate.py quick` | the four suites and `--verify-graph` at once; `--verify-missions=all` in both runtimes, the missions split over the same processes; `--verify-triggers=changed` against the last commit, sharded | about 2 minutes; when a file the runs load has changed, `changed` is every map and it takes as long as `full` |
| `python godot_project/tools/verify_gate.py full` | the same with `--verify-triggers=all`, sharded over six processes | about 3 minutes (the trigger part about 1) |
| `python godot_project/tools/verify_gate.py triggers [--spec=SPEC] [--shards=N]` | only the verifier, sharded | 1 to 2 minutes for `all` |
| `python godot_project/tools/verify_gate.py missions` | only the mission specs, both runtimes | 25 seconds |

The shards' rows are merged back into `DIR/triggers.rows` in the order a
single process writes them — the same file, byte for byte, as
`--verify-triggers=all --verify-out=` from one process — and the summary
(PASS/FAIL/UNREACHABLE/SKIP, the new failures, the pinned failures that no
longer fail) is worked out from that file. `--shards=N` overrides the six
processes it picks from the CPU count; more than that buys nothing, because
the longest mission decade (the 28x maps, one to two minutes) is one process's
work whatever N is.

`quick` compares with `--base=REV` (default `HEAD`): a changed lock or
known-failure list checks the maps whose lines moved, a changed file that
no verifier run loads (the tools, the tests folder, the solver, the viewers,
the deathmatch code, text) checks nothing more, and any other changed file
under `godot_project/` checks every map.

## The solver

All **(dev)**. The solver plays a mission the way a player has to — with
collisions, never noclip — and reports whether it can be finished and, if
not, exactly where it stops.

| Option | Value | What it does |
| --- | --- | --- |
| `--solve[=SEC]` | seconds | Play the mission from the map the run starts on. The value is the time limit; a bare `--solve`, or a number of 10 or less, means 1500 seconds. Exit code 0 for PASS, 1 for FAIL. |
| `--solve-out=DIR` | a directory | Write a top view of the reachable space per map, next to the report. |
| `--solve-stay` | — | Diagnose this one map and never leave it, so the report covers the map the run fails on instead of backing out of it. |

```sh
godot --headless --path godot_project -- --map=MAP.252 --no-briefing --solve
```

## The map tools

All **(dev)**. These run in the map dump scene and read the original data
directly — no game, no cache needed beyond what they decode themselves.
**Every one of them needs the `=` form**, a bare flag is not seen; where a
switch has nothing to say, pass it empty (`--variants=`).

```sh
godot --headless --path godot_project res://scenes/map_dump.tscn -- --maps=210,230
```

### Maps

| Option | Value | What it does |
| --- | --- | --- |
| `--maps=N,N` | map numbers | The marker, sprite, mesh, light and enemy inventory of each map, one line per map. Also the map filter for `--inventory=`. |
| `--header=1` | any value | With `--maps=`: the raw header words of each map. |
| `--find=NAME` | a name part, `*`, `lights` or `sprites` | With `--maps=`: the position of every matching entity, in Godot coordinates. |
| `--links=N,N` | map numbers | Every entity that takes part in an action chain — state byte, act type, hit points, link target — with the chain walked from each head. |
| `--names=N,N` | map numbers | The raw name slots of a map header next to the ones the parser accepted, and every mesh whose name index could not be resolved. |
| `--radiation=N,N` | map numbers | The radiation sources of each map, their strength and lethal core, and how far the player start sits from the nearest. |
| `--objectives=N,N` | mission numbers | Can each mission still reach zero objectives? Counts the briefing entries against the map entities that retire them. |
| `--borders=N,N` | map numbers, or empty for all | The border boxes per map, and whether everything the player must reach lies inside them. |
| `--variants=N` | a percentage, or empty | Which maps are variants of one world — the same place later in a mission. The number lowers the match threshold from 50 %. |
| `--mission=SPEC` | map numbers, or `all` | The shape of a mission as one scene: its zones, its phases, the diff between consecutive phases, every portal with its target and spawn marker set. Add `--out=DIR` to also write the data as JSON. |
| `--inventory=DIR` | a directory | What the maps are made of: every billboard sprite as a PNG with its use count, every placed mesh with count and size, every enemy type. Writes a text index into that directory. Narrow it with `--maps=`. |
| `--texusage=DIR` | a directory | Which texture records the placed meshes use, weighted by placement. Needs the index `--inventory=` wrote in the same directory. |

### Art, meshes and archives

| Option | Value | What it does |
| --- | --- | --- |
| `--img=NAME,NAME` | image names | Decode menu art to PNG into `--out=`. |
| `--arc=NAME.BSA` | an archive | Which archive `--img=` reads from. Default is the 320x200 image archive; the hi-res one holds the 640x480 art. |
| `--pal=NAME.COL` | a palette | Which palette `--img=` uses. Default is the menu palette. |
| `--cfa=NAME.CFA` | animation names | Every frame of a cel animation as PNG into `--out=`. |
| `--tex=BANK:REC` | `bank:record` pairs | Does that texture record resolve, and at what size? With `--out=` it also writes the record as a PNG. |
| `--bankdump=N,N` | texture banks | Every record of those banks as PNG into `--out=`. |
| `--texframes=N,N` | texture banks | How many animation frames each record of a bank stores. |
| `--scan=SPEC` | `magenta`, or `r,g,b[,tol]` | Every texture record with a large share of pixels near a colour — how a strangely coloured surface is traced back to its art. |
| `--mesh=NAME,NAME` | mesh names | A mesh's bounds, its surfaces and their textures, and the collider the port would build for it. |
| `--faces=NAME,NAME` | mesh names | Per-face detail. **This one flag runs two different dumps**: a histogram of which texture each face uses, and then the per-face vertex extent, stored normal and raw UV deltas. |
| `--frames=NAME,NAME` | mesh names | The per-frame bounding box of an animated mesh. |
| `--modelshot=NAME,NAME` | mesh names | Render named models to PNG into `--out=`, to look at them rather than measure them. |
| `--shotsize=N` | pixels | The size of a `--modelshot=` picture. Default 320. |
| `--bsa=NAME.BSA` | an archive | List what an archive holds. |
| `--filter=WORD` | a word | Narrow that listing. |
| `--strings=WORD,WORD` | words | The game's string table entries whose key or text contains a word. |
| `--brief=N,N` | mission numbers | The raw briefing record of each mission. |
| `--out=DIR` | a directory | Where the tools above write. Default is the working directory. |

### The map audit

A scene of its own: it walks maps through the **real game** and reports the
problem classes the playtests keep finding — the player falling through a
spawn, enemies sunk into or floating above the floor, mesh surfaces with no
texture, faces with a texel smeared over them, and loader errors. It always
audits one map at a time, whatever the mission-scene setting says.

| Option | Value | What it does |
| --- | --- | --- |
| `--maps=N,N` | map numbers or names | Audit only those. Default is every map in the archive. |
| `--settle=SEC` | seconds | How long to let each map settle before measuring. Default 2.5. |

Both are read only from the list after `--`.

```sh
godot --headless --path godot_project res://scenes/map_audit.tscn -- \
      --no-briefing --maps=210,230 --settle=3
```

## The scenes

Instead of the game, the project can be started on one of these scenes by
naming it on the command line. All **(dev)** except the game itself.

| Scene | What it is |
| --- | --- |
| `res://scenes/menu.tscn` | The game. This is what starts by default; naming it is the same as naming nothing. |
| `res://scenes/main.tscn` | The game scene without the menu in front of it. Comes up on the built-in default map — `--map=` is the menu's and is ignored here. |
| `res://scenes/action_smoke_test.tscn` | Test suite: loads every campaign map, then exercises the action and link system — a proximity button driving a door, an HP-depletion chain, the damage stages, a rotator, and a gate/teleport pair. Nothing here boots the game scene. |
| `res://scenes/game_smoke_test.tscn` | Test suite: the real game scene, a map at a time. Boots through the briefing, fires every weapon slot, walks an exit round trip and checks marker spawns, carry-over, the per-map state overlay and a save/load round trip. |
| `res://scenes/mission_smoke_test.tscn` | Test suite: the mission-scene runtime — a mission as one scene, its doorways, its phases, finishing it where it is played, and the saves taken inside it. |
| `res://scenes/net_smoke_test.tscn` | Test suite: hosts a deathmatch with bots on the real game scene and checks the whole machinery, including a second Godot process joining as a client. Add `--no-client` (after `--`) to skip that second process. |
| `res://scenes/map_dump.tscn` | The map tools above. Does nothing without one of their switches, and quits when it is done. |
| `res://scenes/map_audit.tscn` | The map audit above. |
| `res://scenes/load_bench.tscn` | Times a level load for a few maps — cold with the cache being built, warm with it hit — and prints the cache statistics. Takes no switches. |
| `res://scenes/atlas_viewer.tscn` | Every texture record in the data, laid out in a scrollable grid. Interactive, also on F2 with `--dev`. |
| `res://scenes/object_viewer.tscn` | Browse every object mesh. Arrows step, PageUp/Down jump ten, drag orbits, wheel zooms. F3 with `--dev`. |
| `res://scenes/enemy_viewer.tscn` | The same for the enemy meshes, with their animation frames. F4 with `--dev`. |
| `res://scenes/sound_viewer.tscn` | List and play every sound in the effects archive. F5 with `--dev`. |

The four test suites exit non-zero on a failure, so they can be run from a
script.

```sh
godot --headless --path godot_project res://scenes/action_smoke_test.tscn
godot --headless --path godot_project res://scenes/game_smoke_test.tscn
godot --headless --path godot_project res://scenes/mission_smoke_test.tscn
godot --headless --path godot_project res://scenes/net_smoke_test.tscn
godot --headless --path godot_project res://scenes/net_smoke_test.tscn -- --no-client
```

There is also a small probe that runs without a scene at all — it prints
what a baked level scene holds and whether its collision came with it:

```sh
godot --headless --path godot_project --script res://tools/probe_scene.gd \
      -- res://converted/maps/MAP.220.level.scn
```

---

## Not implemented, or not what the name says

- **`--quit-after-shot` does nothing in the menu.** The menu's parser only
  registers `--name=value` switches, and this one is a bare flag, so the
  menu never sees it. It is only consulted there together with
  `--menu-shot=`, and a menu shot without `--screen=` quits of its own
  accord anyway — so the case it was meant for, `--menu-shot=` with
  `--screen=`, cannot be made to quit. In the game scene the flag works
  normally.
- **A bare `--perf` measures for 1 second, not 8.** The 8-second default
  written into the code can never be reached, because the default is only
  used when the switch is absent. Pass the number: `--perf=8`.
- **The map tools need `=` even where their own notes show a bare flag.**
  `--variants`, `--borders`, `--header` and `--find` are all documented in
  the tool sources as bare flags; written that way they do nothing. Write
  `--variants=`, `--borders=`, `--header=1`.
- **`--faces=` runs two dumps.** One flag, two different reports, one after
  the other.
- **`--quit-after-shot` also ends a `--perf` run**, which has nothing to do
  with a screenshot.
- **`--map=` is listed in the game scene's own header comment** among the
  switches it handles, but the game scene never reads it — the menu does.
  Starting `res://scenes/main.tscn` directly ignores it.
- **`--noclip` is implied by `--pos=`** unless `--walk=` is given too, so a
  positioned run floats by default.
- **`--near=` overwrites `--pos=`, `--yaw=` and `--pitch=`** rather than
  combining with them.
- **A switch that wants a value and is written bare becomes the word
  `true`.** The general parser stores a bare flag as a boolean, and the
  code that reads it turns that into a string or a number. So
  `--screenshot` on its own writes a file called `true`,
  `--console-open` opens the console with that word already typed,
  `--shot-delay` means one second, and a bare `--tab` selects nothing.
  Always give these a value.

---

The running game has a console of its own — `~` opens it, or start with
`--console-open`. Its `help` command lists what it can do.
