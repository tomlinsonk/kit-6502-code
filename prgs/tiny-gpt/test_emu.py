"""Run tiny-gpt in kit-emu (headless) and check it against the integer simulator.

    python test_emu.py --model titles                       # empty prompt
    python test_emu.py --model stories --prompt "the cat" --tokens 200
    python test_emu.py --model titles --installer           # install with install*.prg first

Assembles tinygpt.asm with -define TEST (fixed prompt and seed), installs the weights in a scratch
copy of the emulator's SSD image, runs until the program's breakpoint, and compares the generated
tokens with kitsim.Sim. Also checks the screen for stray bytes and reports CPU cycles per token.
"""
import argparse
import os
import re
import shutil
import subprocess
import tempfile

import numpy as np

import kitsim
import pack

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.join(HERE, '../../../kit-emu')
SEED = 0x1234
MODEL = PROMPT = None
TOKENS = 24
S = {}                                  # the model's settings.inc


def use(model, prompt='', tokens=24):
    global MODEL, PROMPT, TOKENS, S
    MODEL, PROMPT, TOKENS = model, prompt, tokens
    text = open(os.path.join(HERE, 'models', model, 'settings.inc')).read()
    S = {k: int(v) for k, v in re.findall(r'\.const (\w+) = (\d+)', text)}


def build_dir():
    return os.path.join(HERE, 'build', MODEL)


def load_img():
    return np.load(os.path.join(build_dir(), 'img.npy'), allow_pickle=True).item()


def tokenize(text, tok):
    """Global BPE merges, as the 6502 does it."""
    nchars = len(tok['vocab']) - len(tok['merges'])
    chars = tok['vocab'][:nchars]
    ids = [chars.index(ch) for ch in text if ch in chars[1:]]
    for r, (a, b) in enumerate(tok['merges']):
        out, i = [], 0
        while i < len(ids):
            if i + 1 < len(ids) and ids[i] == a and ids[i + 1] == b:
                out.append(nchars + r)
                i += 2
            else:
                out.append(ids[i])
                i += 1
        ids = out
    return ids


def simulate(img):
    """The tokens the TEST build generates (including end tokens), following its main loop."""
    sim = kitsim.Sim(img)
    rng = kitsim.Rng(SEED)
    prompt = tokenize(PROMPT, img['tok'])
    for t in [0] + prompt:
        z = sim.step(np.array([t]))[0]
    out, n = [], 0
    while True:
        t = kitsim.sample_token(z, rng, S['TEMP_MUL'], S['CUTOFF'])
        out.append(t)
        if t != 0:
            z = sim.step(np.array([t]))[0]
            if len(out) == TOKENS:
                break
            n += 1
            if n < S['MAX_TOKENS']:
                continue
        if len(out) == TOKENS or not S['STREAM'] or prompt:
            break
        z = sim.step(np.array([0]))[0]
        n = 0
    return out, sim


def assemble(test=True, extra=(), source='tinygpt.asm'):
    args = ['java', '-jar', os.path.join(HERE, '../../KickAss.jar'), *(['-define', 'TEST'] if test else []), *extra,
            '-libdir', os.path.join(HERE, '../../roms/kit-os'), '-libdir', build_dir(),
            '-libdir', os.path.join(HERE, 'models', MODEL), '-odir', build_dir(), os.path.join(HERE, source)]
    r = subprocess.run(args, capture_output=True, text=True)
    if 'Error' in r.stdout or 'FAILED' in r.stdout.replace('0 failed', ''):
        print(r.stdout[-3000:])
        raise SystemExit('assembly failed')


def workdir(emu, ssd_image=None):
    """Scratch emulator directory with the weights installed by pack.py (or a given SSD image)."""
    work = tempfile.mkdtemp(prefix='tinygpt-')
    for f in ('kit_os.bin', 'character-set.png', 'ssd.bin'):
        shutil.copy(os.path.join(emu, f), work)
    if ssd_image is None:
        ssd = bytearray(open(os.path.join(work, 'ssd.bin'), 'rb').read())
        pack.install_weights(ssd, MODEL, open(os.path.join(build_dir(), 'weights.bin'), 'rb').read())
        ssd_image = ssd
    open(os.path.join(work, 'ssd.bin'), 'wb').write(ssd_image)
    return work


def emulate(emu, work, prg, timeout_ms, extra=()):
    r = subprocess.run(['java', '-cp', os.path.abspath(os.path.join(emu, 'build', 'classes')), '-Djava.awt.headless=true',
                        'KiT', '--headless', '--prg', os.path.abspath(prg), '--timeout-ms', str(timeout_ms), *extra],
                       cwd=work, capture_output=True, text=True)
    return r.stdout


def run_emu(emu, timeout_ms, hexdump=False, ssd_image=None):
    work = workdir(emu, ssd_image)
    out = emulate(emu, work, os.path.join(build_dir(), MODEL + '-test.prg'), timeout_ms,
                  ['--no-save-ssd', '--count-cycles', '1000-8fff'] + (['--dump-screen-hex'] if hexdump else []))
    shutil.rmtree(work)
    return out


def screen_bytes(out, rows=16):
    lines = out.split('Screen hex:')[1].strip().splitlines()[:rows]
    return bytes(int(b, 16) for row in lines for b in row.split())


def test_installer(emu):
    """Run install1.prg, install2.prg, ... on a copy of the emulator's SSD; compare with pack.py's result."""
    weights = open(os.path.join(build_dir(), 'weights.bin'), 'rb').read()
    parts = (len(weights) // pack.DATA + 3) // 4
    for part in range(1, parts + 1):
        assemble(test=False, extra=(f':PART={part}',), source='install.asm')
    work = workdir(emu, open(os.path.join(emu, 'ssd.bin'), 'rb').read())
    for part in range(1, parts + 1):
        out = emulate(emu, work, os.path.join(build_dir(), f'install{part}.prg'), 15000)
        print('\n'.join(line for line in out.split('Screen:')[1].splitlines() if line.strip()))
    got = open(os.path.join(work, 'ssd.bin'), 'rb').read()
    shutil.rmtree(work)
    want = bytearray(open(os.path.join(emu, 'ssd.bin'), 'rb').read())
    pack.install_weights(want, MODEL, weights)
    print('installer image matches pack.py:', got == bytes(want))
    return got


def dump(emu, stage, start=0x0d00, step=0):
    """Assemble with :DUMP=stage and return 512 bytes of RAM from start, at that stage of forward pass `step`."""
    assemble(extra=(f':DUMP={stage}', f':DUMPFROM={start}', f':DUMPSTEP={step}', f':PROMPT={PROMPT}', ':TOKENS=255'))
    return screen_bytes(run_emu(emu, 60000, hexdump=True))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model', default='titles')
    p.add_argument('--emu', default=EMU)
    p.add_argument('--timeout-ms', type=int, default=300000)
    p.add_argument('--installer', action='store_true', help='install with install*.prg instead of pack.py')
    p.add_argument('--prompt', default='')
    p.add_argument('--tokens', type=int, default=TOKENS, help='at most 255')
    args = p.parse_args()
    use(args.model, args.prompt, args.tokens)
    image = test_installer(args.emu) if args.installer else None
    img = load_img()
    want, _ = simulate(img)
    settings = (f':PROMPT={PROMPT}', f':TOKENS={TOKENS}')

    # generated tokens, read from TOKBUF when the run ends
    assemble(extra=settings + (':DUMP=99', f':DUMPFROM={0x3000}'))
    out = run_emu(args.emu, args.timeout_ms, hexdump=True, ssd_image=image)
    got = list(screen_bytes(out)[:len(want)])
    m = re.search(r'Cycles: (\d+)', out)

    # the screen, which should hold only text
    assemble(extra=settings)
    out = run_emu(args.emu, args.timeout_ms, hexdump=True, ssd_image=image)
    print(out.split('Screen:')[1].split('Screen hex:')[0])
    stray = [v for v in screen_bytes(out) if v < 1 or 26 < v < 32 or v > 63]

    print('sim :', repr(PROMPT + kitsim.decode(img['tok'], want)))
    print('emu :', repr(PROMPT + kitsim.decode(img['tok'], got)))
    if m:
        n = 1 + len(tokenize(PROMPT, img['tok'])) + len(got)
        cyc = int(m.group(1))
        print(f'{cyc} cycles for about {n} forward passes: {cyc / n / 1.8432e6:.2f} s per token')
    print('stray screen bytes:', stray)
    print('MATCH' if got == want and not stray else 'MISMATCH')


if __name__ == '__main__':
    main()
