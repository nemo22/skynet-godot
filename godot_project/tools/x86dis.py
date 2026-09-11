"""Disassemble a range of GAME.EXE (SkyNET v1.01) at Ghidra addresses —
the FUN_/DAT_ numbers of the retro-kit decompile in
ghidra_out/game_exe/decomp (a code pointer stored in data is already a
full address there).
Usage (repo root): python godot_project/tools/x86dis.py 0x139e98 0x13a000
Needs: pip install capstone

skynet_gh.c is the OLDER v1.00 build: its addresses are 0x500..0x800
lower in the code (SpawnEnemiesInit 0x129000 -> 0x129500, ObjDoAction
0x139698 -> 0x139e98) and 0x300 lower in the data. Find the new address
through a string the function uses (fixups.txt) before disassembling.

SKYNET.EXE in the game dir is only the 2017 launcher (it runs
GAME.EXE /g); the address -> file offset map comes from GAME.EXE's own
LE object table, so it holds whichever extender stub the exe is bound to.
"""
import struct, sys, capstone

CANDIDATES = ['skynet.EXE', 'SKYNET.EXE', 'Skynet.exe', 'GAME.EXE', 'game.exe']
exe = b''
for name in CANDIDATES:                      # Marek renames the exe now and then
    try:
        with open(name, 'rb') as f:
            data = f.read()
    except OSError:
        continue
    if data.find(b'LE\x00\x00') > 0 and b'TFS: SkyNet' in data:
        exe = data
        break
assert exe, 'no SkyNET DOS/4G exe here - looked for %s' % ', '.join(CANDIDATES)
if b'TFS: SkyNet v1.01' not in exe:
    print('# WARNING: not the v1.01 build the decompile came from - addresses will not match',
          file=sys.stderr)
LE = exe.find(b'LE\x00\x00')
# A bound exe is extender stub + an inner MZ whose e_lfanew points at the
# LE; the LE's data-page offset counts from that inner MZ, not the file.
BASE = next(p for p in range(LE - 2, -1, -1)
            if exe[p:p + 2] == b'MZ' and struct.unpack_from('<I', exe, p + 0x3c)[0] == LE - p)
OBJ_TAB, N_OBJ = struct.unpack_from('<II', exe, LE + 0x40)
PAGE = struct.unpack_from('<I', exe, LE + 0x28)[0]
PAGES = BASE + struct.unpack_from('<I', exe, LE + 0x80)[0]
OBJECTS = []
for i in range(N_OBJ):
    vsize, base, flags, page, count, _ = struct.unpack_from('<6I', exe, LE + OBJ_TAB + i * 24)
    OBJECTS.append((base, vsize, PAGES + (page - 1) * PAGE))

def fo(addr):
    for base, vsize, off in OBJECTS:
        if base <= addr < base + vsize:
            return addr - base + off
    raise SystemExit('0x%x is in no LE object' % addr)

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
md.skipdata = True
start = int(sys.argv[1], 16); end = int(sys.argv[2], 16)
code = exe[fo(start):fo(end)]
for ins in md.disasm(code, start):
    print("%06x  %-8s %s" % (ins.address, ins.mnemonic, ins.op_str))
