"""Extract the SkyNET enemy AI data from Skynet.exe into enemy_ai_data.gd.

Sources (all verified by disassembly, see docs/implementation_plan.md section G):
  enemy type table  VA 0x44d00, 100 x 0x1C: +0x08 state id, +0x10 death spec,
                    +0x14 -> parameter block (36 dwords copied to the AI instance)
  AIS scripts       16-byte ops {fn, a, b, c}; opcode fns at 0x12a572..0x12a7d0
  anim blocks       {u32 type, u32 nframes, u32 fps, u16 flags, (u16 frame,u16 fl)*}
  ammo table        VA 0x40728 stride 0x32
Pointers stored in data are relative to 0x30000; file offset = VA + 0x538A4.
Run from the repo root:  python godot_project/tools/gen_enemy_ai.py
"""
import struct
exe = open('Skynet.exe', 'rb').read()
BASE = 0x30000
def fo(va): return va + 0x538A4
def i32(va): return struct.unpack_from('<i', exe, fo(va))[0]
def u32(va): return struct.unpack_from('<I', exe, fo(va))[0]
def u16(va): return struct.unpack_from('<H', exe, fo(va))[0]
def cstr(va):
    o = fo(va); e = exe.index(b'\0', o); return exe[o:e].decode('latin1')
def isptr(v): return 0x10000 < v < 0x40000

OPS = {0x12a572: ('if', 'le'), 0x12a586: ('if', 'lt'), 0x12a59a: ('if', 'gt'),
       0x12a5ae: ('if', 'eq0'), 0x12a5c1: ('if', 'ne0'), 0x12a5d4: ('goto',),
       0x12a5d9: ('wait',), 0x12a60c: ('anim',), 0x12a640: ('sound',),
       0x12a668: ('set',), 0x12a682: ('setfn',), 0x12a69e: ('add',)}
PREDS = {0x12a6b8: 'see', 0x12a6e9: 'dist', 0x12a6fd: 'bearing', 0x12a75a: 'bearing_abs',
         0x12a7ab: 'rand', 0x12a789: 'angle_to_player', 0x12a7c4: 'animflags',
         0x12a7d0: 'flags'}
ops = {}      # va -> [name, args...]
anims = {}    # va -> (fps, flags, frames)

def decode_anim(va):
    if va in anims:
        return
    typ, n, fps, flags = u32(va), u32(va + 4), u32(va + 8), u16(va + 12)
    frames = []
    p = va + 14
    for _ in range(128):
        f, fl = u16(p), u16(p + 2)
        frames.append(f)
        p += 4
        if fl & 1:
            break
    anims[va] = (fps if typ == 1 else 0, flags, frames)

def decode_script(start):
    work = [start]
    while work:
        va = work.pop()
        if va in ops:
            continue
        fn = u32(va) + BASE
        if fn not in OPS:
            ops[va] = ['end']
            continue
        kind = OPS[fn]
        a, b, c = i32(va + 4), i32(va + 8), i32(va + 12)
        if kind[0] == 'if':
            pred = PREDS.get(a + BASE, 'unknown%x' % (a + BASE))
            tgt = c + BASE
            ops[va] = ['if', pred, kind[1], b, tgt]
            work += [tgt, va + 16]
        elif kind[0] == 'goto':
            tgt = a + BASE
            ops[va] = ['goto', tgt]
            work.append(tgt)
        elif kind[0] == 'wait':
            ops[va] = ['wait', a, 1 if c != 0 else 0]
            work.append(va + 16)
        elif kind[0] == 'anim':
            blk = a + BASE
            decode_anim(blk)
            ops[va] = ['anim', blk]
            work.append(va + 16)
        elif kind[0] == 'sound':
            ops[va] = ['sound', a]
            work.append(va + 16)
        elif kind[0] == 'set':
            ops[va] = ['set', a, b]
            work.append(va + 16)
        elif kind[0] == 'setfn':
            ops[va] = ['setfn', a, PREDS.get(b + BASE, 'unknown')]
            work.append(va + 16)
        elif kind[0] == 'add':
            ops[va] = ['add', a, b]
            work.append(va + 16)

# Per-state parameter layouts (dword indices into the 36-dword block).
# fire = (mx, my, mz, ammo, speed, rate, range) indices.
LAYOUT = {
    7:  dict(speed=4, near=6, turn=7, fire=(11, 12, 13, 14, 15, 18, 19), script=26, events=29),
    6:  dict(speed=4, near=6, turn=7, fire=(12, 13, 14, 15, 16, 19, 20), script=21),
    2:  dict(axis=4, amin=5, amax=6, turn=7, range=8, fire=(12, 13, 14, 15, 16, 19, 20)),
    8:  dict(axis=4, amin=5, amax=6, turn=7, range=8, fire=(12, 13, 14, 15, 16, 19, 20), script=24, events=27),
    9:  dict(speed=4, turn=5, fire=(17, 18, 19, 20, 21, 24, 25), script=14, engine=(26, 27)),
    13: dict(speed=6, turn=5, script=12, engine=(22, 23)),
    10: dict(script=6),
}
types = []
for i in range(256):
    b = 0x44d00 + 0x1c * i
    res, _c, st, seg, death, prm, f18 = [u32(b + 4 * k) for k in range(7)]
    if res == 0:
        break
    name = cstr(res + BASE + 4).lower().replace('.3d', '') if res else ''
    p = [i32(prm + BASE + 4 * k) for k in range(36)] if prm else [0] * 36
    lay = LAYOUT.get(st, {})
    t = {'n': name, 'st': st, 'hp': max(0, min(p[0], 0x7fff))}
    for key in ('speed', 'near', 'turn', 'axis', 'amin', 'amax', 'range'):
        if key in lay:
            t[key] = p[lay[key]]
    if 'fire' in lay:
        f = [p[k] for k in lay['fire']]
        t['fire'] = f if f[5] > 0 and f[6] > 0 else []
    if 'script' in lay and isptr(p[lay['script']]):
        sva = p[lay['script']] + BASE
        decode_script(sva)
        t['script'] = sva
    if 'events' in lay and isptr(p[lay['events']]):
        eva = p[lay['events']] + BASE
        ev = []
        for k in range(0, 80, 2):
            fr, sn = i32(eva + 4 * k), i32(eva + 4 * k + 4)
            if fr == -1:
                break
            ev += [fr, sn]
        t['events'] = ev
    if 'engine' in lay and p[lay['engine'][0]] == 5:
        t['engine'] = p[lay['engine'][1]]
    # Death spec (+0x10): 0/1 = none, else -> {kind, arg}: kind 0 = one debris
    # type, kind 1 = list of {cont, type, ox, oy, oz, ...} 32-byte entries.
    parts = []
    if death > 1:
        dva = death + BASE
        kind, arg = i32(dva), i32(dva + 4)
        if kind == 0:
            parts.append([arg, 0, 0, 0])
        elif kind == 1:
            lva = arg + BASE
            for _ in range(12):
                cont = i32(lva)
                parts.append([i32(lva + 4), i32(lva + 8), i32(lva + 12), i32(lva + 16)])
                if cont == 0:
                    break
                lva += 32
    t['death'] = parts
    types.append(t)

ammo = []
for a in range(25):
    b = 0x40728 + 0x32 * a
    cb, mdl = u32(b), u32(b + 4)
    model = cstr(mdl + BASE + 4).upper() if isptr(mdl) else ''   # record +4 = name
    fam = {0: 0, 0xf3414: 1, 0xf344d: 2}.get(cb, 0)
    bank = i32(b + 8)
    ammo.append([fam, model, bank >> 7 if bank > 0 else 0, i32(b + 0xc), i32(b + 0x10),
                 i32(b + 0x18), i32(b + 0x1c), i32(b + 0x20)])

def gd(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return '"%s"' % v
    if isinstance(v, (list, tuple)):
        return '[' + ', '.join(gd(x) for x in v) + ']'
    if isinstance(v, dict):
        return '{' + ', '.join('%s: %s' % (gd(k), gd(x)) for k, x in v.items()) + '}'
    raise TypeError(v)

out = []
out.append('## GENERATED by godot_project/tools/gen_enemy_ai.py from Skynet.exe - do not edit.')
out.append('## Enemy AI data: per-type parameters (table 0x44d00), AIS behaviour')
out.append('## scripts (16-byte ops), animation blocks and the ammo table (0x40728).')
out.append('## See docs/implementation_plan.md section G for the field semantics.')
out.append('extends RefCounted')
out.append('')
out.append('## Per enemy type: n name, st AI state id, hp, speed (u/s), near (stop')
out.append('## distance), turn (2048 = 360 deg/s), axis/amin/amax (turret segment),')
out.append('## range (engage), fire [mx,my,mz, ammo, speed, rate, range], script VA,')
out.append('## events [frame, sound, ...], engine (loop sound id), death parts')
out.append('## [[type, ox, oy, oz], ...].')
out.append('const TYPES: Array = [')
for t in types:
    out.append('\t%s,' % gd(t))
out.append(']')
out.append('')
out.append('## AIS ops keyed by VA. ["if", pred, cmp, arg, target] jumps to target when')
out.append('## pred cmp arg holds; ["goto", va]; ["wait", ticks(1/70 s), freeze];')
out.append('## ["anim", block]; ["sound", id]; ["set"/"add", offset, value];')
out.append('## ["setfn", offset, pred]; ["end"]. The next op is va + 16.')
out.append('const OPS: Dictionary = {')
for va in sorted(ops):
    out.append('\t0x%x: %s,' % (va, gd(ops[va])))
out.append('}')
out.append('')
out.append('## Animation blocks keyed by VA: [fps, flags (4 one-shot, 8 loop,')
out.append('## 0x100 firing pose), frames].')
out.append('const ANIMS: Dictionary = {')
for va in sorted(anims):
    fps, flags, frames = anims[va]
    out.append('\t0x%x: [%d, %d, %s],' % (va, fps, flags, gd(frames)))
out.append('}')
out.append('')
out.append('## Ammo types: [family (0 hitscan, 1 gravity, 2 straight bolt), model,')
out.append('## impact bank, damage (negative = blast), blast radius, life ticks,')
out.append('## fire sound, impact sound].')
out.append('const AMMO: Array = [')
for a in ammo:
    out.append('\t%s,' % gd(a))
out.append(']')
open('godot_project/scripts/enemy_ai_data.gd', 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
print('types', len(types), 'ops', len(ops), 'anims', len(anims))
print('unknown preds:', sorted({o[1] for o in ops.values() if o[0] == 'if' and o[1].startswith('unknown')}))
for i in (33, 7, 1, 4, 30, 32, 3, 45, 77, 58, 61):
    print(i, types[i])
