"""The verification gate, run the fast way.

    python godot_project/tools/verify_gate.py quick
    python godot_project/tools/verify_gate.py full
    python godot_project/tools/verify_gate.py triggers [--spec=all] [--shards=N]
    python godot_project/tools/verify_gate.py missions [--shards=N]

Every Godot run goes through the same switches the gate always used (see
COMMANDS.md, "The gate"), plus `--fixed-fps 60`: the verifiers count
physics frames, never seconds, and without it every frame waits for the
wall clock. A run with it is the same run, only as fast as the machine.

`triggers` splits the maps over N Godot processes (`--verify-shard=I/N`,
scripts/triggers/trigger_verifier.gd) and merges their rows back into one
file in the order a single run writes them — the same file, byte for byte.
`missions` does the same with the mission specs, a mission per list entry;
each mission begins with a RESTART session, so where it runs is nothing
to it. Several processes may run at once because each of them only READS
the converted cache (`--cache-read-only`, scripts/asset_cache.gd); the
import that writes it stays alone.

`quick` = the four suites, --verify-graph, the missions in both runtimes
and --verify-triggers=changed. `full` = the same with every map instead of
the changed ones. Exit code 0 when everything held, 1 otherwise.

Options:
  --godot=EXE        the Godot executable (default: $GODOT, then PATH)
  --shards=N         processes for a sharded run (default: from the CPU count)
  --out=DIR          where the logs and rows go (default: a temp directory)
  --spec=SPEC        the --verify-triggers spec for `triggers` (default all)
  --base=REV         what `changed` compares against (default HEAD)
Standard library only.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
REPO = os.path.dirname(PROJECT)
LOCK = "godot_project/tests/rules/skynet.triggers.lock"
XFAIL = "godot_project/tests/rules/skynet.xfail"
SPEC = os.path.join(PROJECT, "tests", "rules", "skynet.missions.txt")

## The suite that WRITES the cache: it deletes and rebakes MAP.216's level
## scene and MISSION.210 (the bake is its subject), so it runs first and
## alone with the cache, and the others read what it left.
WRITER_SUITE = "action_smoke_test"
SUITES = ["game_smoke_test", "mission_smoke_test", "net_smoke_test"]
TRIGGER_ARGS = ["--map=MAP.200", "--no-briefing", "--no-mission-scene"]
MISSION_MODES = {"map": "--no-mission-scene", "scene": "--mission-scene"}

## Files a change to which cannot move a verifier row: loaded by no run of
## the verifier (the other tools, the menu screens, the viewers, the
## deathmatch), or not code at all. Anything else under godot_project/ that
## changed means every map. Prefixes, relative to the repo root.
NOT_IN_A_RUN = [
    "godot_project/tools/", "godot_project/tests/", "godot_project/addons/",
    "godot_project/export_presets.cfg", "godot_project/scripts/mission_solver.gd",
    "godot_project/scripts/map_dump.gd", "godot_project/scripts/map_audit.gd",
    "godot_project/scripts/load_bench.gd", "godot_project/scripts/net/",
    "godot_project/scripts/atlas_viewer.gd", "godot_project/scripts/object_viewer.gd",
    "godot_project/scripts/enemy_viewer.gd", "godot_project/scripts/sound_viewer.gd",
    "godot_project/scripts/action_smoke_test.gd", "godot_project/scripts/game_smoke_test.gd",
    "godot_project/scripts/mission_smoke_test.gd", "godot_project/scripts/net_smoke_test.gd",
]
NOT_CODE = (".md", ".txt", ".uid", ".py", ".png", ".import")


def say(msg):
    print(msg, flush=True)


def godot_exe(opt):
    exe = opt.get("godot") or os.environ.get("GODOT")
    if exe:
        return exe
    for name in ("Godot_v4.7.2-stable_win64_console.exe", "godot4", "godot"):
        found = shutil.which(name)
        if found:
            return found
    sys.exit("verify_gate: no Godot executable - pass --godot=EXE or set GODOT")


def default_shards():
    # A verifier process keeps one core busy and a level in memory; past
    # six the level loads start to queue on the disk and the memory of a
    # 32 GB machine, and the longest map decides the wall time anyway.
    return max(1, min(6, (os.cpu_count() or 2) // 3))


def launch(opt, name, godot_args, user_args, reader=True):
    """Start one headless Godot run; its log goes to <out>/<name>.log. A
    reader is --cache-read-only, which is what lets it share the cache."""
    log = open(os.path.join(opt["out"], name + ".log"), "w", encoding="utf-8", errors="replace")
    cmd = [godot_exe(opt), "--headless", "--fixed-fps", "60", "--path", PROJECT] \
        + godot_args + ["--"] + (["--cache-read-only"] if reader else []) + user_args
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=PROJECT), log


def wait_all(procs):
    codes = []
    for p, log in procs:
        codes.append(p.wait())
        log.close()
    return codes


def git(*args):
    r = subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


# ---------------------------------------------------------------------
# --verify-triggers, sharded
# ---------------------------------------------------------------------
def read_xfail():
    keys = set()
    with open(os.path.join(REPO, XFAIL), encoding="utf-8") as f:
        for line in f:
            tok = line.split()
            if len(tok) >= 5 and not line.startswith("#"):
                keys.add("%d %s" % (int(tok[0]), tok[1]))
    return keys


def merge_rows(parts, out_path):
    """Put the shards' rows back in the order of a single run: every shard
    writes, beside its rows, which maps it ran (their place in the run's
    own map list) and how many rows each of them wrote."""
    blocks = []
    for rows_path in parts:
        with open(rows_path, encoding="utf-8", newline="") as f:
            rows = f.read().splitlines(keepends=True)
        at = 0
        with open(rows_path + ".maps", encoding="utf-8") as f:
            for line in f:
                tok = line.split()
                if len(tok) != 3:
                    continue
                n = int(tok[2])
                blocks.append((int(tok[0]), tok[1], rows[at:at + n]))
                at += n
        if at != len(rows):
            raise RuntimeError("%s: %d rows, its map list accounts for %d" % (rows_path, len(rows), at))
    blocks.sort(key=lambda b: b[0])
    seen = set()
    for idx, nm, _rows in blocks:
        if idx in seen:
            raise RuntimeError("map %s was run by two shards" % nm)
        seen.add(idx)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        for _idx, _nm, rows in blocks:
            f.writelines(rows)
    return [r for b in blocks for r in b[2]]


def summarise_rows(rows):
    xf = read_xfail()
    count, new, maps = {}, [], set()
    for r in rows:
        tok = r.split(" ", 6)
        maps.add(int(tok[0]))
        count[tok[5]] = count.get(tok[5], 0) + 1
        if tok[5] == "FAIL":
            key = "%d %s" % (int(tok[0]), tok[1])
            if key in xf:
                xf.discard(key)
            else:
                new.append(r.rstrip("\r\n"))
    fixed = sorted(k for k in xf if int(k.split()[0]) in maps)
    say("[verify] %d rows: %d PASS, %d FAIL (%d new), %d UNREACHABLE, %d SKIP"
        % (len(rows), count.get("PASS", 0), count.get("FAIL", 0), len(new),
           count.get("UNREACHABLE", 0), count.get("SKIP", 0)))
    for r in new:
        say("[verify] NEW " + r)
    if fixed:
        say("[verify] %d pinned failure(s) no longer fail: %s" % (len(fixed), " ".join(fixed)))
    return len(new)


def changed_args(opt):
    """The switches that make `--verify-triggers=changed` compare against
    the base revision: the lock as it was committed there. None when a
    changed file means every map anyway."""
    base = opt.get("base", "HEAD")
    names = git("diff", "--name-only", base, "--", "godot_project")
    untracked = git("ls-files", "--others", "--exclude-standard", "--", "godot_project")
    if names is None or untracked is None:
        say("[gate] git is not answering - checking every map")
        return None
    for path in (names + untracked).split():
        if any(path.startswith(p) for p in NOT_IN_A_RUN) or path.endswith(NOT_CODE):
            continue
        say("[gate] %s changed - every map" % path)
        return None
    args = []
    for rel, flag in ((LOCK, "--verify-base-lock"), (XFAIL, "--verify-base-xfail")):
        text = git("show", "%s:%s" % (base, rel))
        if text is None:
            continue
        p = os.path.join(opt["out"], "base." + os.path.basename(rel))
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        args.append("%s=%s" % (flag, p))
    return args


def triggers(opt, spec="all"):
    t0 = time.time()
    extra = []
    if spec == "changed":
        extra = changed_args(opt)
        if extra is None:
            spec, extra = "all", []
    n = int(opt.get("shards", default_shards()))
    procs, parts = [], []
    for i in range(n):
        rows = os.path.join(opt["out"], "triggers.%d.rows" % i)
        if os.path.exists(rows + ".maps"):
            os.remove(rows + ".maps")
        parts.append(rows)
        procs.append(launch(opt, "triggers.%d" % i, [], TRIGGER_ARGS + [
            "--verify-triggers=" + spec, "--verify-shard=%d/%d" % (i, n),
            "--verify-out=" + rows] + extra))
    codes = wait_all(procs)
    bad = [i for i, c in enumerate(codes) if c != 0]
    out = os.path.join(opt["out"], "triggers.rows")
    try:
        rows = merge_rows(parts, out)
    except (OSError, RuntimeError) as e:
        say("[verify] the shards did not all finish: %s" % e)
        return 1
    if not rows and spec != "changed":
        say("[verify] the shards checked nothing")
        return 1
    new = summarise_rows(rows)
    say("%-22s exit %d  %6.0f s  (%d shards, rows in %s)"
        % ("verify-triggers=" + spec, 1 if new or bad else 0, time.time() - t0, n, out))
    return 1 if new or bad else 0


# ---------------------------------------------------------------------
# --verify-missions, sharded
# ---------------------------------------------------------------------
def mission_keys():
    keys = []
    with open(SPEC, encoding="utf-8") as f:
        for line in f:
            tok = line.split()
            if len(tok) == 2 and tok[0] == "mission":
                keys.append(int(tok[1]))
    return keys


def missions(opt, mode):
    t0 = time.time()
    keys = mission_keys()
    n = max(1, min(int(opt.get("shards", default_shards())), len(keys)))
    procs, parts = [], []
    for i in range(n):
        mine = keys[i::n]
        rows = os.path.join(opt["out"], "missions.%s.%d.rows" % (mode, i))
        parts.append((mine, rows))
        procs.append(launch(opt, "missions.%s.%d" % (mode, i), [], [
            "--map=MAP.210", "--no-briefing", MISSION_MODES[mode],
            "--verify-missions=" + ",".join(str(k) for k in mine),
            "--verify-out=" + rows]))
    codes = wait_all(procs)
    by_key = {}
    for mine, rows in parts:
        if not os.path.exists(rows):
            continue
        with open(rows, encoding="utf-8", newline="") as f:
            for r in f.read().splitlines(keepends=True):
                by_key.setdefault(int(r.split(" ", 1)[0]), []).append(r)
    out = os.path.join(opt["out"], "missions.%s.rows" % mode)
    count = {}
    with open(out, "w", encoding="utf-8", newline="") as f:
        for k in keys:
            for r in by_key.get(k, []):
                f.write(r)
                res = r.split(" ")[5]
                count[res] = count.get(res, 0) + 1
    missing = [k for k in keys if k not in by_key]
    code = 1 if any(codes) or missing else 0
    say("%-22s exit %d  %6.0f s  %d PASS / %d FAIL / %d XFAIL%s"
        % ("verify-missions " + mode, code, time.time() - t0, count.get("PASS", 0),
           count.get("FAIL", 0), count.get("XFAIL", 0),
           ("  (no rows for %s)" % missing) if missing else ""))
    return code


# ---------------------------------------------------------------------
# The gates
# ---------------------------------------------------------------------
def gate(opt, spec):
    t0 = time.time()
    fails = 0
    # The writing suite first, beside the lock check (which reads no cache
    # at all); then the other suites side by side, each only reading.
    steps = [[(WRITER_SUITE, ["res://scenes/%s.tscn" % WRITER_SUITE], [], False),
              ("verify-graph", [], ["--verify-graph"], True)],
             [(s, ["res://scenes/%s.tscn" % s], [], True) for s in SUITES]]
    for step in steps:
        procs = [launch(opt, n, g, u, r) for (n, g, u, r) in step]
        for ((name, _g, _u, _r), code) in zip(step, wait_all(procs)):
            say("%-22s exit %d" % (name, code))
            fails += code != 0
    say("%-22s        %6.0f s" % ("suites + graph", time.time() - t0))
    for mode in MISSION_MODES:
        fails += missions(opt, mode) != 0
    fails += triggers(opt, spec) != 0
    say("[gate] %s: %s in %.0f s (logs in %s)"
        % ("quick" if spec == "changed" else "full", "PASS" if fails == 0 else "FAIL",
           time.time() - t0, opt["out"]))
    return 0 if fails == 0 else 1


def main(argv):
    if not argv or argv[0] not in ("quick", "full", "triggers", "missions"):
        print(__doc__)
        return 2
    opt = {}
    for a in argv[1:]:
        if a.startswith("--") and "=" in a:
            k, v = a[2:].split("=", 1)
            opt[k] = v
    opt["out"] = os.path.abspath(opt.get("out") or tempfile.mkdtemp(prefix="verify_gate_"))
    os.makedirs(opt["out"], exist_ok=True)
    what = argv[0]
    if what == "quick":
        return gate(opt, "changed")
    if what == "full":
        return gate(opt, "all")
    if what == "triggers":
        return triggers(opt, opt.get("spec", "all"))
    code = 0
    for mode in MISSION_MODES:
        code |= missions(opt, mode)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
