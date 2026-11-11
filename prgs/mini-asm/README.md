# mini-asm

A line assembler for the KiT. Type 65C02 instructions and it writes the
machine code to memory as you go, like the Apple II mini-assembler. It
knows the full 65C02 instruction set, including `rmb`/`smb`/`bbr`/`bbs`,
`tsb`/`trb`, `wai`, and `stp`.

## Build

From this directory, build the monitor and mini-asm:

```sh
(cd ../../roms/video-mon && java -jar ../../KickAss.jar -libdir ../../lib -binfile video_mon.asm)
java -jar ../../KickAss.jar -libdir ../../roms/video-mon mini-asm.asm
```

This writes `mini-asm.prg`. It calls monitor routines, so the KiT must
run the matching `../../roms/video-mon/video_mon.bin`.

## Run

Load `mini-asm.prg` with the monitor's `l` command and select `r`, or
save it to the SSD and start it with `f XX`. It runs at `$5000` and uses
`$5000`-`$5dd2`; it refuses to write over itself.

The prompt shows the address of the next instruction, starting at `$1000`.
Type an instruction and press Enter. The line is replaced by its bytes
and the instruction as assembled, and the prompt moves to the next address.
Typing `ldx #0`, `inx`, `bne 1002`, and `brk` shows:

```
1000: a2 00    ldx #$00
1002: e8       inx
1003: d0 fd    bne $1002
1005: 00       brk
1006:
```

Start a line with an address and a colon to move somewhere else:
`2000:` on its own, or `2000: lda #$41`.

| Syntax | Mode |
| --- | --- |
| `nop` | implied |
| `asl` or `asl a` | accumulator |
| `lda #$12` or `lda #'a` | immediate |
| `lda $12` | zero page |
| `lda $12,x` / `ldx $12,y` | zero page indexed |
| `lda $1234` | absolute |
| `lda $1234,x` / `lda $1234,y` | absolute indexed |
| `lda ($12)` | zero page indirect |
| `lda ($12,x)` | indexed indirect |
| `lda ($12),y` | indirect indexed |
| `jmp ($1234)` / `jmp ($1234,x)` | absolute indirect |
| `bne $1234` | relative (type the target address) |
| `rmb3 $12` / `smb3 $12` | zero page bit |
| `bbr3 $12,$1234` / `bbs3 $12,$1234` | zero page bit and branch |

- Numbers are hex with an optional `$`. One or two digits mean zero page,
  so `lda $0012` is absolute. `'c` is the character code for `c`.
- Input is case-insensitive except for characters after `'`.
- Backspace edits the line. A bad line prints `? message` and assembles
  nothing.

## Directives

| Directive | Effect |
| --- | --- |
| `.b 01 02 ff 'a` | Write bytes (spaces or commas between them) |
| `.t Hello` | Write text as typed, with no terminator |
| `.s ss start [end]` | Save `start` up to `end` (default: the current address) to SSD sector `ss` |

`.s` asks before overwriting a used sector, then asks for a file name.
Run the saved program from the monitor with `f ss`; it starts at `start`.

## Leaving and returning

Escape returns to the monitor. From there:

- `x` or `g 5000` returns to mini-asm at the same address.
- `g 1000` runs your code at `$1000`. End it with `brk` to return to the
  monitor, then use `g 5000` to go back to mini-asm.

## Emulator tests

```sh
./test-mini-asm.sh [KickAss.jar] [kit-emu directory]
```

The defaults are `../../KickAss.jar` and `../../../kit-emu`. The script
builds the monitor and mini-asm and runs the emulator from a temporary
directory, so the emulator's SSD image is not changed.

The tests assemble every 65C02 opcode and check the bytes against Kick
Assembler, check the listing, syntax, directives, and error messages, run
an assembled program, and save it to the SSD and run it with `f`.
