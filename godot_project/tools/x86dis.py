"""Disassemble a VA range of Skynet.exe (DOS/4GW LE, data/code VA -> file = VA + 0x538A4).
Usage (repo root): python godot_project/tools/x86dis.py 0x12a572 0x12a800
Needs: pip install capstone
"""
import sys, capstone

exe = open('Skynet.exe','rb').read()
def fo(va): return va + 0x538A4
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
md.skipdata = True
start = int(sys.argv[1], 16); end = int(sys.argv[2], 16)
code = exe[fo(start):fo(end)]
for ins in md.disasm(code, start):
    print("%06x  %-8s %s" % (ins.address, ins.mnemonic, ins.op_str))
