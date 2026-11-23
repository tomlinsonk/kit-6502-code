"""Compare the KiT's state with kitsim.py, stage by stage, for the first forward pass (token 0).

    python debug_emu.py titles            # all stages
    python debug_emu.py titles 3 4        # just these

Each stage assembles a TEST build that copies $0d00-$0eff (the activation vectors) to the
screen at that point in tinygpt.asm (see the stage() macro) and stops.
"""
import os
import sys

import numpy as np

import kitsim
import test_emu

test_emu.use(sys.argv[1])
img = test_emu.load_img()
c = img['cfg']
D, HD, FF = c['d'], c['head_dim'], c['ff']
trace = {}
kitsim.Sim(img).step(np.array([0]), trace=trace)


def s8(b):
    return np.frombuffer(bytes(b), dtype=np.int8).astype(int)


def x16(m):
    return np.frombuffer(bytes(m[0:D]), np.uint8).astype(int) | (s8(m[0x40:0x40 + D]) << 8)


CHECKS = {1: [('x0', x16)],
          2: [('h1.0', lambda m: s8(m[0x80:0x80 + D]))],
          3: [('q.0', lambda m: s8(m[0xc0:0xc0 + D])), ('k.0', lambda m: s8(m[0x100:0x100 + HD])),
              ('v.0', lambda m: s8(m[0x100 + HD:0x100 + 2 * HD]))],
          4: [('o.0', lambda m: s8(m[0x140:0x140 + D]))],
          5: [('xa.0', x16), ('h2.0', lambda m: s8(m[0x80:0x80 + D]))],
          6: [('u.0', lambda m: s8(m[0x180:0x180 + FF]))],
          7: [('xf.0', x16)],
          17: [('xf.1', x16)],
          30: [('hf', lambda m: s8(m[0x80:0x80 + D]))]}

for stage in [int(a) for a in sys.argv[2:]] or sorted(CHECKS):
    mem = test_emu.dump(test_emu.EMU, stage)
    for name, read in CHECKS[stage]:
        got, want = read(mem), trace[name]
        bad = np.nonzero(got != want)[0]
        print(f'stage {stage} {name}: {"OK" if not len(bad) else f"{len(bad)} differ"}')
        if len(bad):
            print('  index', bad[:12])
            print('  kit  ', got[bad[:12]])
            print('  sim  ', want[bad[:12]])
