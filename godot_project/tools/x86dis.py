"""Disassemble a range of Skynet.exe at Ghidra addresses (the FUN_/DAT_
numbers in skynet_gh.c; a code pointer stored in data is that + 0x30000).
Usage (repo root): python godot_project/tools/x86dis.py 0x12a572 0x12a800
Needs: pip install capstone

The Ghidra -> file offset delta is measured, not assumed: the string
"hummer.3d" sits at Ghidra 0x44720, so wherever it is in the file fixes
the delta for whichever DOS extender stub the exe is bound to. With the
original DOS/4GW stub it was 0x538A4; Marek rebound the exe to DOS/32A
on 2026-09-11 (delta 0x22500).
"""
import sys, capstone

exe = open('Skynet.exe','rb').read()
ANCHOR = exe.find(b'hummer.3d\x00')
assert ANCHOR > 0, 'hummer.3d not found - not a SkyNET exe?'
DELTA = ANCHOR - 0x44720
def fo(addr): return addr + DELTA
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
md.skipdata = True
start = int(sys.argv[1], 16); end = int(sys.argv[2], 16)
code = exe[fo(start):fo(end)]
for ins in md.disasm(code, start):
    print("%06x  %-8s %s" % (ins.address, ins.mnemonic, ins.op_str))
