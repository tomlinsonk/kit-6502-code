#!/usr/bin/env python3
"""
Convert a C64 .sid file (PSID) into a song file for the KiT's sid-play program.

    python3 sid2kit.py Wizball.sid             # writes wizball.prg
    python3 sid2kit.py Wizball.sid -o wiz.prg

Send the result with pcb_serial_send.py and save it to the SSD from the monitor.

What it does:
  1. Moves the tune into KiT RAM ($0300-$4fff) with sidreloc, if it isn't there already.
  2. Points the tune's I/O accesses at shadow pages inside sid-play. Each SID store
     becomes a jsr to a small routine (added after the tune) that does the store on the
     shadow page and has sid-play send it straight to the real SID, with pitch and
     envelope correction.
  3. Runs every subtune in a 6502 emulator, before and after patching, and checks
     that the SID writes match call by call on a 65C02.
  4. Writes a .prg: a 128-byte header (name, author, entry points, speed) followed
     by the tune.

Requires py65 (python3 -m pip install py65) and sidreloc on the PATH (or --sidreloc).
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

try:
    from py65.devices.mpu6502 import MPU as NMOS
    from py65.devices.mpu65c02 import MPU as CMOS
except ImportError:
    sys.exit("sid2kit needs py65: python3 -m pip install py65")


# Must match sid_play.asm
TUNE_MIN = 0x0300
TUNE_MAX = 0x5000                       # tune must end below this
HDR_SIZE = 0x80
SHADOW_SID = 0x5D
SHADOW_CIA = 0x5E
SHADOW_IO = 0x5F
KIT_SID = 0x7E
COMMIT = 0x5003                         # player routine that sends a shadow register to the SID
HDR_VERSION = 1

KIT_CLOCK = 1843200
PAL_CLOCK = 985248
NTSC_CLOCK = 1022727
PAL_FRAME = 19656                       # C64 cycles per frame
NTSC_FRAME = 17045


# ---------------------------------------------------------------- 6502 opcodes
LEN = {"imp": 1, "acc": 1, "imm": 2, "zp": 2, "zpx": 2, "zpy": 2, "izx": 2, "izy": 2,
       "rel": 2, "abs": 3, "abx": 3, "aby": 3, "ind": 3}

OPS = {}                                # opcode -> (name, mode), documented NMOS opcodes only


def ops(name, **modes):
    for mode, code in modes.items():
        OPS[code] = (name, mode)


for name, base in (("ora", 0x00), ("and", 0x20), ("eor", 0x40), ("adc", 0x60),
                   ("lda", 0xA0), ("cmp", 0xC0), ("sbc", 0xE0)):
    ops(name, izx=base + 0x01, zp=base + 0x05, imm=base + 0x09, abs=base + 0x0D,
        izy=base + 0x11, zpx=base + 0x15, aby=base + 0x19, abx=base + 0x1D)
ops("sta", izx=0x81, zp=0x85, abs=0x8D, izy=0x91, zpx=0x95, aby=0x99, abx=0x9D)
for name, base in (("asl", 0x00), ("rol", 0x20), ("lsr", 0x40), ("ror", 0x60)):
    ops(name, zp=base + 0x06, acc=base + 0x0A, abs=base + 0x0E, zpx=base + 0x16, abx=base + 0x1E)
ops("dec", zp=0xC6, abs=0xCE, zpx=0xD6, abx=0xDE)
ops("inc", zp=0xE6, abs=0xEE, zpx=0xF6, abx=0xFE)
ops("ldx", imm=0xA2, zp=0xA6, abs=0xAE, zpy=0xB6, aby=0xBE)
ops("ldy", imm=0xA0, zp=0xA4, abs=0xAC, zpx=0xB4, abx=0xBC)
ops("stx", zp=0x86, abs=0x8E, zpy=0x96)
ops("sty", zp=0x84, abs=0x8C, zpx=0x94)
ops("cpx", imm=0xE0, zp=0xE4, abs=0xEC)
ops("cpy", imm=0xC0, zp=0xC4, abs=0xCC)
ops("bit", zp=0x24, abs=0x2C)
ops("jmp", abs=0x4C, ind=0x6C)
ops("jsr", abs=0x20)
for name, code in (("bpl", 0x10), ("bmi", 0x30), ("bvc", 0x50), ("bvs", 0x70),
                   ("bcc", 0x90), ("bcs", 0xB0), ("bne", 0xD0), ("beq", 0xF0)):
    ops(name, rel=code)
for name, code in (("brk", 0x00), ("php", 0x08), ("clc", 0x18), ("plp", 0x28), ("sec", 0x38),
                   ("rti", 0x40), ("pha", 0x48), ("cli", 0x58), ("rts", 0x60), ("pla", 0x68),
                   ("sei", 0x78), ("dey", 0x88), ("txa", 0x8A), ("tya", 0x98), ("txs", 0x9A),
                   ("tay", 0xA8), ("tax", 0xAA), ("clv", 0xB8), ("tsx", 0xBA), ("iny", 0xC8),
                   ("dex", 0xCA), ("cld", 0xD8), ("inx", 0xE8), ("nop", 0xEA), ("sed", 0xF8)):
    ops(name, imp=code)

READS = {"lda", "ldx", "ldy", "cmp", "cpx", "cpy", "bit", "and", "ora", "eor", "adc", "sbc"}


class SidError(Exception):
    pass


# ---------------------------------------------------------------- PSID file
class Psid:
    def __init__(self, data):
        if len(data) < 0x76:
            raise SidError("file is too short to be a .sid")
        if data[:4] == b"RSID":
            raise SidError("RSID tunes need a full C64 environment and aren't supported")
        if data[:4] != b"PSID":
            raise SidError("not a .sid file")
        (self.version, offset, load, self.init, self.play, self.songs, self.start,
         self.speed) = struct.unpack(">HHHHHHHI", data[4:22])
        self.name, self.author, self.released = (
            data[22 + 32 * i:54 + 32 * i].split(b"\0")[0].decode("latin-1") for i in range(3))
        self.flags = struct.unpack(">H", data[0x76:0x78])[0] if self.version >= 2 else 0
        body = data[offset:]
        if load == 0:
            load = body[0] | body[1] << 8
            body = body[2:]
        self.load = load
        self.body = bytearray(body)
        if self.init == 0:
            self.init = load
        if self.flags & 0x02:
            raise SidError("BASIC tunes aren't supported")
        if self.play == 0:
            raise SidError("this tune installs its own interrupt handler, which isn't supported")
        if self.version >= 3 and data[0x7A]:
            print("warning: this is a multi-SID tune; only the first SID is played", file=sys.stderr)

    @property
    def end(self):
        return self.load + len(self.body)

    @property
    def ntsc(self):
        return (self.flags >> 2) & 3 == 2

    def cia_timed(self, song):
        return bool((self.speed >> min(song - 1, 31)) & 1)


# ---------------------------------------------------------------- emulation
class Memory:
    """64K of RAM that logs writes, and reads from the given pages."""

    def __init__(self, read_pages):
        self.ram = bytearray(65536)
        self.read_pages = read_pages
        self.hits = []

    def __getitem__(self, addr):
        if isinstance(addr, slice):
            return self.ram[addr]
        if (addr >> 8) in self.read_pages:
            self.hits.append(("r", addr))
        return self.ram[addr]

    def __setitem__(self, addr, value):
        if isinstance(addr, slice):
            self.ram[addr] = value
            return
        self.hits.append(("w", addr))
        self.ram[addr] = value

    def __len__(self):
        return 65536


class Run:
    """What happened while running one subtune."""

    def __init__(self):
        self.frames = []                # SID registers after each play call
        self.writes = []                # (register, value) SID writes during each play call
        self.init_writes = ()
        self.cia = 0                    # CIA 1 timer A after init
        self.executed = set()
        self.io = {}                    # pc -> I/O addresses it accessed
        self.indirect_io = set()
        self.illegal = set()
        self.tune_writes = set()        # addresses written inside the tune
        self.outside_writes = set()     # addresses written outside the tune, zero page, and stack
        self.rom_reads = set()


def run_tune(cpu_class, image, load, init, play, song, frames, sid_page, cia_page, extra=b""):
    """Run init and then play `frames` times. On the KiT layout (sid_page = SHADOW_SID),
    SID writes are the calls the thunks make to the player's commit routine."""
    mem = Memory(set(range(0xA0, 0xC0)) | set(range(0xD0, 0x100)))
    mem.ram[load:load + len(image)] = image
    end = load + len(image)
    mem.ram[end:end + len(extra)] = extra
    kit = sid_page == SHADOW_SID
    if kit:
        mem.ram[COMMIT] = 0x60                  # stand-in for the player's commit routine
    mpu = cpu_class(memory=mem)
    run = Run()
    stub = 0xFF00 if load <= 0x0203 and end > 0x0200 else 0x0200
    writes = []

    def call(addr, a, budget):
        mem.ram[stub:stub + 3] = bytes([0x20, addr & 0xFF, addr >> 8])
        mpu.pc, mpu.sp, mpu.a, mpu.x, mpu.y = stub, 0xFF, a, 0, 0
        mpu.p &= ~mpu.DECIMAL
        for _ in range(budget):
            pc = mpu.pc
            if pc == stub + 3:
                return
            if kit and pc == COMMIT:
                reg = mpu.y & 0x1F
                if reg < 0x19:
                    writes.append((reg, mem.ram[SHADOW_SID * 256 + reg]))
            op = mem.ram[pc]
            run.executed.add(pc)
            if op not in OPS:
                run.illegal.add(pc)
            mem.hits.clear()
            mpu.step()
            for kind, a in mem.hits:
                page = a >> 8
                if kind == "w":
                    if load <= a < end:
                        run.tune_writes.add(a)
                    elif page > 1:
                        run.outside_writes.add(a)
                    if not kit and 0xD4 <= page < 0xD8 and (a & 0x1F) < 0x19:
                        writes.append((a & 0x1F, mem.ram[a]))
                if 0xD0 <= page < 0xE0 and op in OPS:
                    if OPS[op][1] in ("izx", "izy"):
                        run.indirect_io.add(pc)
                    else:
                        run.io.setdefault(pc, set()).add(a)
                elif kind == "r" and (0xA0 <= page < 0xC0 or page >= 0xE0):
                    run.rom_reads.add(a)
        raise SidError("subtune %d: the %s routine at $%04x didn't return (is it waiting on hardware?)"
                       % (song, "init" if addr == init else "play", addr))

    call(init, song - 1, 2_000_000)
    run.init_writes = tuple(writes)
    run.cia = mem.ram[cia_page * 256 + 4] | mem.ram[cia_page * 256 + 5] << 8
    for _ in range(frames):
        writes.clear()
        call(play, 0, 200_000)
        run.frames.append(bytes(mem.ram[sid_page * 256:sid_page * 256 + 25]))
        run.writes.append(tuple(writes))
    return run


# ---------------------------------------------------------------- static disassembly
def disassemble(image, load, seeds):
    """Find the instructions reachable from seeds by following control flow."""
    end = load + len(image)
    seen = set()
    todo = [s for s in seeds if load <= s < end]
    while todo:
        pc = todo.pop()
        while load <= pc < end and pc not in seen:
            op = image[pc - load]
            if op not in OPS:
                break
            name, mode = OPS[op]
            if pc + LEN[mode] > end:
                break
            seen.add(pc)
            if mode == "rel":
                off = image[pc + 1 - load]
                todo.append(pc + 2 + (off - 256 if off > 127 else off))
            elif name in ("jsr", "jmp") and mode == "abs":
                todo.append(image[pc + 1 - load] | image[pc + 2 - load] << 8)
            if name in ("jmp", "rts", "rti", "brk"):
                break
            pc += LEN[mode]
    return seen


def io_target(name, mode, operand):
    """New high byte for an absolute access to C64 I/O, or None to leave it alone."""
    page = operand >> 8
    if not 0xD0 <= page < 0xE0:
        return None
    if 0xD4 <= page < 0xD8:
        if name in READS and mode == "abs" and 0x19 <= (operand & 0x1F) <= 0x1C:
            return KIT_SID                      # pots, osc 3, envelope 3: read the real SID
        return SHADOW_SID
    if page == 0xDC:
        return SHADOW_CIA
    return SHADOW_IO


# ---------------------------------------------------------------- conversion
def find_sidreloc(path):
    found = path or shutil.which("sidreloc") or os.environ.get("SIDRELOC")
    if not found:
        raise SidError("this tune needs relocating, but sidreloc wasn't found.\n"
                       "Build it from https://www.linusakesson.net/software/sidreloc/ and put it\n"
                       "on your PATH, or pass --sidreloc /path/to/sidreloc")
    return found


def relocate(src_path, psid, sidreloc):
    size = len(psid.body)
    page = 0x10 if 0x1000 + size <= TUNE_MAX else (TUNE_MIN + HDR_SIZE + 0xFF) >> 8
    if (page << 8) + size > TUNE_MAX:
        raise SidError("tune is too big: %d bytes (max %d)" % (size, TUNE_MAX - (page << 8)))
    print("relocating $%04x-$%04x to $%04x with sidreloc" % (psid.load, psid.end - 1, page << 8))
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out.sid")
        result = subprocess.run([sidreloc, "-q", "-k", "-p", "%02x" % page, src_path, out],
                                capture_output=True, text=True)
        if result.returncode & 0x1F or not os.path.exists(out):
            msg = (result.stdout + result.stderr).strip().splitlines()
            raise SidError("sidreloc failed (exit %d): %s"
                           % (result.returncode, msg[-1] if msg else ""))
        with open(out, "rb") as f:
            return Psid(f.read())


WRITES = {"sta", "stx", "sty", "asl", "lsr", "rol", "ror", "inc", "dec"}


def thunk(op, mode, lo):
    """Code that does a SID store on the shadow page, then has the player send that
    register to the real SID. Registers and flags come back unchanged."""
    code = bytes([op, lo, SHADOW_SID])          # the original instruction, on the shadow page
    code += bytes([0x08, 0x48, 0xDA, 0x5A])     # php pha phx phy
    if mode == "abs":
        code += bytes([0xA0, lo])               # ldy #reg
    else:
        code += bytes([0x8A if mode == "abx" else 0x98, 0x18, 0x69, lo, 0xA8])  # txa/tya clc adc tay
    code += bytes([0x20, COMMIT & 0xFF, COMMIT >> 8])   # jsr commit
    code += bytes([0x7A, 0xFA, 0x68, 0x28, 0x60])       # ply plx pla plp rts
    return code


def convert(path, frames, sidreloc_path):
    with open(path, "rb") as f:
        psid = Psid(f.read())

    unmoved = None
    if not (TUNE_MIN + HDR_SIZE <= psid.load and psid.end <= TUNE_MAX):
        unmoved = psid
        psid = relocate(path, psid, find_sidreloc(sidreloc_path))

    load, end, image = psid.load, psid.end, bytes(psid.body)

    # Run the tune as it would on a C64: find its I/O accesses and record its SID writes
    original, executed, io, tune_writes, outside, problems = [], set(), {}, set(), set(), []
    for song in range(1, psid.songs + 1):
        r = run_tune(NMOS, image, load, psid.init, psid.play, song, frames, 0xD4, 0xDC)
        original.append(r)
        executed |= r.executed
        tune_writes |= r.tune_writes
        outside |= r.outside_writes
        for pc, addrs in r.io.items():
            io.setdefault(pc, set()).update(addrs)
        if r.illegal:
            problems.append("subtune %d uses undocumented 6510 opcodes (at $%04x), "
                            "which the 65C02 can't run" % (song, min(r.illegal)))
        if r.indirect_io:
            problems.append("subtune %d reaches I/O through a pointer (at $%04x), "
                            "which can't be patched" % (song, min(r.indirect_io)))
        bad = sorted(a for a in r.outside_writes
                     if not (TUNE_MIN <= a < TUNE_MAX or 0xD000 <= a < 0xE000 or a >> 8 == 2))
        if bad:
            problems.append("subtune %d writes to $%04x, which isn't free on the KiT" % (song, bad[0]))
        if r.rom_reads:
            print("warning: subtune %d reads C64 ROM at $%04x; it may sound wrong"
                  % (song, min(r.rom_reads)), file=sys.stderr)
    if problems:
        raise SidError("\n".join(problems))

    if unmoved:
        for song, r in enumerate(original, 1):
            u = run_tune(NMOS, bytes(unmoved.body), unmoved.load, unmoved.init, unmoved.play,
                         song, frames, 0xD4, 0xDC)
            diff = next((n for n, (a, b) in enumerate(zip(u.writes, r.writes)) if a != b), None)
            if diff is not None:
                print("warning: subtune %d sounds different after relocation from play call %d"
                      % (song, diff), file=sys.stderr)

    # Patch every absolute I/O access, both those seen running and those found by disassembly.
    # SID stores become calls to thunks placed after the tune.
    patched = bytearray(image)
    thunks = bytearray()
    thunk_addr = {}
    code = disassemble(image, load, executed | {psid.init, psid.play})
    n_run = n_static = n_shadow = 0
    for pc in sorted(code | set(io)):
        if not load <= pc < end - 2:
            continue
        op = image[pc - load]
        if op not in OPS:
            raise SidError("the code at $%04x that reaches I/O is rewritten while the tune runs, "
                           "which can't be patched" % pc)
        name, mode = OPS[op]
        if mode not in ("abs", "abx", "aby") or name in ("jmp", "jsr"):
            continue
        operand = image[pc + 1 - load] | image[pc + 2 - load] << 8
        target = io_target(name, mode, operand)
        if target is None:
            continue
        if pc in io:
            n_run += 1
        else:
            n_static += 1
        modified = {pc, pc + 1, pc + 2} & tune_writes
        if target == SHADOW_SID and name in WRITES and not modified:
            key = (op, operand & 0xFF)
            if key not in thunk_addr:
                thunk_addr[key] = end + len(thunks)
                thunks += thunk(op, mode, operand & 0xFF)
            addr = thunk_addr[key]
            patched[pc - load:pc + 1 - load + 2] = bytes([0x20, addr & 0xFF, addr >> 8])
        else:
            patched[pc + 2 - load] = target
            if target == SHADOW_SID and name in WRITES:
                n_shadow += 1

    if end + len(thunks) > TUNE_MAX:
        raise SidError("tune is too big to fit with its SID write code")
    clash = sorted(a for a in outside if end <= a < end + len(thunks))
    if clash:
        raise SidError("the tune uses memory at $%04x, right after itself, which sid2kit needs"
                       % clash[0])

    # Run the patched tune on a 65C02 and compare its SID writes with the original
    for song, orig in enumerate(original, 1):
        r = run_tune(CMOS, bytes(patched), load, psid.init, psid.play, song, frames,
                     SHADOW_SID, SHADOW_CIA, bytes(thunks))
        if r.io:
            raise SidError("subtune %d still touches C64 I/O at $%04x after patching"
                           % (song, min(r.io)))
        for n, (a, b) in enumerate(zip(orig.frames, r.frames)):
            if a != b:
                raise SidError("subtune %d plays differently on the KiT from play call %d"
                               % (song, n))
        if not n_shadow:
            for n, (a, b) in enumerate(zip(orig.writes, r.writes)):
                if a != b:
                    raise SidError("subtune %d writes the SID in a different order on the KiT "
                                   "from play call %d" % (song, n))
        if r.cia != orig.cia:
            raise SidError("subtune %d sets a different CIA timer after patching" % song)

    print("patched %d I/O accesses (%d seen running, %d found by disassembly)"
          % (n_run + n_static, n_run, n_static))
    if n_shadow:
        print("warning: %d SID stores modify themselves, so they reach the SID once per frame "
              "instead of immediately" % n_shadow, file=sys.stderr)
    print("checked %d subtune%s for %d play calls each"
          % (psid.songs, "s" * (psid.songs != 1), frames))
    for song, r in enumerate(original, 1):
        if psid.cia_timed(song):
            hz = (NTSC_CLOCK if psid.ntsc else PAL_CLOCK) / (r.cia + 1) if r.cia else 60
            print("  subtune %d plays at %.1f Hz" % (song, hz))
    return psid, bytes(patched) + bytes(thunks)


def build_header(psid):
    clock = NTSC_CLOCK if psid.ntsc else PAL_CLOCK
    frame = NTSC_FRAME if psid.ntsc else PAL_FRAME

    def text(s):
        b = bytes(c if 0x20 <= c < 0x7F else 0x3F for c in s.encode("latin-1", "replace"))
        return b[:32].ljust(32, b"\0")

    hdr = bytearray(b"\x00KSID")                    # BRK first, so running it from the monitor is harmless
    hdr.append(HDR_VERSION)
    hdr += struct.pack("<HHHH", psid.load, len(psid.body), psid.init, psid.play)
    hdr += bytes([psid.songs, max(1, min(psid.start, psid.songs))])
    hdr += struct.pack("<I", psid.speed)
    hdr.append(round(clock / KIT_CLOCK * 256))      # frequency scale, /256
    hdr.append(round((KIT_CLOCK / clock - 1) * 256))  # CIA timer scale, 1 + n/256
    hdr += struct.pack("<H", round(frame * KIT_CLOCK / clock) - 2)  # VIA latch for 50/60 Hz
    hdr += text(psid.name) + text(psid.author) + text(psid.released)
    hdr += bytes(HDR_SIZE - len(hdr))
    assert len(hdr) == HDR_SIZE
    return hdr


def main():
    parser = argparse.ArgumentParser(description="Convert a C64 .sid file for sid-play on the KiT.")
    parser.add_argument("sid", help="input .sid file")
    parser.add_argument("-o", "--output", help="output .prg (default: named after the input)")
    parser.add_argument("--frames", type=int, default=3000,
                        help="play calls per subtune to check (default: 3000)")
    parser.add_argument("--sidreloc", help="path to the sidreloc program")
    args = parser.parse_args()

    try:
        psid, image = convert(args.sid, args.frames, args.sidreloc)
    except (SidError, OSError) as e:
        sys.exit("%s: %s" % (os.path.basename(args.sid), e))

    out = args.output or (os.path.splitext(os.path.basename(args.sid))[0]
                          .lower().replace(" ", "_") + ".prg")
    hdr_addr = psid.load - HDR_SIZE
    with open(out, "wb") as f:
        f.write(struct.pack("<H", hdr_addr))
        f.write(build_header(psid))
        f.write(image)
    size = HDR_SIZE + len(image)
    sectors = -(-size // 0xF00)
    print("%s: \"%s\" by %s, %d subtune%s, $%04x-$%04x, %d bytes (%d SSD sector%s)"
          % (out, psid.name, psid.author, psid.songs, "s" * (psid.songs != 1),
             hdr_addr, psid.load + len(image) - 1, size, sectors, "s" * (sectors != 1)))


if __name__ == "__main__":
    main()
