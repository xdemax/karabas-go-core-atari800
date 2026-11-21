#!/usr/bin/env python3
"""ATR -> one-byte-per-line hex for sim/tb_atari_machine.v ($readmemh).

Usage: sim/gen_atr_hex.py <image.atr> <out.hex>

Prints the geometry; the testbench currently has Numen Side A constants
(133136 bytes, 128-byte sectors, 1040 sectors).  For another image update
ATR_SIZE / ATR_SSIZE / ATR_SCOUNT in the testbench.
"""
import sys

if len(sys.argv) != 3:
    raise SystemExit(__doc__)

data = open(sys.argv[1], "rb").read()
if len(data) < 16 or data[0] != 0x96 or data[1] != 0x02:
    raise SystemExit("not an ATR (bad 0x96 0x02 header)")

# same header interpretation as atari_atr_loader.v
paras = (data[7] << 24) | (data[6] << 16) | (data[3] << 8) | data[2]
if data[5] == 1 and data[4] == 0:
    ssize = 256
    scount = 3 + ((paras - 24) >> 4) if paras >= 24 else 0
else:
    ssize = 128
    scount = paras >> 3
if paras == 0:
    if data[5] == 1 and data[4] == 0:
        scount = 3 + ((len(data) - 400) >> 8) if len(data) > 400 else 0
    else:
        scount = (len(data) - 16) >> 7 if len(data) > 16 else 0

with open(sys.argv[2], "w") as f:
    for b in data:
        f.write("%02x\n" % b)

print("ATR %s: %d bytes, %d-byte sectors, %d sectors, paras 0x%x"
      % (sys.argv[1], len(data), ssize, scount, paras))
