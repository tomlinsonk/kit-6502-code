"""Install a tiny-gpt model into a KiT SSD image (kit-emu's ssd.bin) as KSF files.

    python pack.py --ssd ../../../kit-emu/ssd.bin --model titles --prg
    python pack.py --ssd ssd.bin --model stories --sector 0x30 --prg --prg-sector 0x2e
    python pack.py --ssd ssd.bin --remove stories --remove stories-weights

The weights become the data file "<model>-weights" (one header per sector, see lib/ssd.lib),
in the first run of free sectors unless --sector is given. With --prg, build/<model>/<model>.prg
is also saved as the program file "<model>", so the monitor's `f` command runs it. Installing
replaces earlier files with the same names.
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SECTOR = 4096
DATA = 3840


def weights_name(model):
    return f'{model}-weights'


def fletcher(data):
    s1 = s2 = 0
    for b in data:
        s1 = (s1 + b) % 256
        s2 = (s2 + s1) % 256
    return s1, s2


def free_sectors(ssd):
    return [i for i in range(64) if ssd[i * SECTOR] != 0]


def owned_sectors(ssd, name):
    name = name.encode() if isinstance(name, str) else name
    return [i for i in range(64) if ssd[i * SECTOR] == 0 and ssd[i * SECTOR + 0x10:i * SECTOR + 0x20].split(b'\0')[0] == name]


def header(i, n, data, ftype, start, name, nxt, vid_mode=0xff):
    """First 32 bytes of the header page of sector i (of n) of a file, as ssd_save_file writes it."""
    h = bytearray(32)
    h[1] = ftype
    addr = start + i * DATA
    remaining = len(data) - i * DATA
    h[2:4] = bytes([addr & 0xff, (addr >> 8) & 0xff])
    h[4:6] = bytes([remaining & 0xff, (remaining >> 8) & 0xff])
    h[6:8] = bytes(fletcher(data))
    h[8] = nxt if i + 1 < n else 0xff
    h[9] = vid_mode
    h[0x10:0x10 + len(name)] = name
    return bytes(h)


def write_file(ssd, sectors, data, ftype, start, name):
    """Write data across the given sectors the way ssd_save_file does."""
    name = name.encode() if isinstance(name, str) else name
    assert len(sectors) * DATA >= len(data)
    for i, sec in enumerate(sectors):
        page = bytearray(b'\xff' * SECTOR)
        page[0:256] = bytes(256)
        page[0:32] = header(i, len(sectors), data, ftype, start, name, sectors[i + 1] if i + 1 < len(sectors) else 0)
        chunk = data[i * DATA:(i + 1) * DATA]
        page[256:256 + len(chunk)] = chunk
        ssd[sec * SECTOR:(sec + 1) * SECTOR] = page


def erase(ssd, sectors):
    for s in sectors:
        ssd[s * SECTOR:(s + 1) * SECTOR] = b'\xff' * SECTOR


def pick(ssd, n, first):
    free = set(free_sectors(ssd))
    if first is not None:
        run = list(range(first, first + n))
        bad = [s for s in run if s not in free]
        assert not bad, f'sectors in use: {[hex(s) for s in bad]}'
        return run
    for s in range(64 - n + 1):
        if all(t in free for t in range(s, s + n)):
            return list(range(s, s + n))
    raise SystemExit(f'no run of {n} free sectors')


def install_weights(ssd, model, weights, first=None):
    """Replace the model's weight file; returns its sectors."""
    erase(ssd, owned_sectors(ssd, weights_name(model)))
    n = len(weights) // DATA
    secs = pick(ssd, n, first)
    write_file(ssd, secs, weights[:n * DATA], 0x20, 0x0000, weights_name(model))
    return secs


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ssd', required=True, help='SSD image to modify')
    p.add_argument('--model', help='model name: installs build/MODEL/weights.bin')
    p.add_argument('--sector', type=lambda v: int(v, 0), help='first weight sector (default: first free run)')
    p.add_argument('--prg', action='store_true', help='also save build/MODEL/MODEL.prg')
    p.add_argument('--prg-sector', type=lambda v: int(v, 0))
    p.add_argument('--remove', action='append', default=[], help='delete the file with this name first')
    args = p.parse_args()

    ssd = bytearray(open(args.ssd, 'rb').read())
    assert len(ssd) == 64 * SECTOR
    for name in args.remove:
        secs = owned_sectors(ssd, name)
        erase(ssd, secs)
        print(f'removed {name}: {len(secs)} sectors')
    if args.model:
        build = os.path.join(HERE, 'build', args.model)
        secs = install_weights(ssd, args.model, open(os.path.join(build, 'weights.bin'), 'rb').read(), args.sector)
        print(f'{weights_name(args.model)}: sectors {secs[0]:02x}-{secs[-1]:02x}')
        if args.prg:
            erase(ssd, owned_sectors(ssd, args.model))
            prg = open(os.path.join(build, args.model + '.prg'), 'rb').read()
            load = prg[0] | prg[1] << 8
            body = prg[2:]
            psecs = pick(ssd, (len(body) + DATA - 1) // DATA, args.prg_sector)
            write_file(ssd, psecs, body, 0x00, load, args.model)
            print(f'{args.model}: {len(body)} bytes at ${load:04x} in sectors {psecs[0]:02x}-{psecs[-1]:02x} '
                  f'(run with: f {psecs[0]:02x})')
    open(args.ssd, 'wb').write(ssd)


if __name__ == '__main__':
    main()
