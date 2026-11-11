# KiT debugger

A 65C02 disassembler, single stepper, and hex editor for the KiT. Step
through a program, set breakpoints, and patch bytes in RAM or on the SSD.

## Build

From this directory, build the monitor and the debugger:

```sh
(cd ../../roms/video-mon && java -jar ../../KickAss.jar -libdir ../../lib -binfile video_mon.asm)
java -jar ../../KickAss.jar -libdir ../../roms/video-mon debugger.asm
```

This writes `debugger.prg`. It calls monitor routines, so the KiT must run
the matching `video_mon.bin`.

## Run

Load your program first, then load `debugger.prg` with the monitor's `l`
command and select `r`. The debugger starts at `$4800` with the user PC at
`$1000`, S at `$ff`, and the monitor's screen and zero page as the user's.

```
pc 1000 a 00 x 00 y 00 s ff
p 20 nvdizc  ssd 00         code
>  1000 a9 42    lda #$42
   1002 a2 02    ldx #$02
 * 1004 ca       dex
   ...
s n g b p r j k v . tab esc
```

Row 1 shows the flags (set flags are inverted), the SSD sector, and the
view. In the code view, `>` marks the PC and `*` marks a breakpoint. The
cursor's address is inverted.

| Key | Action |
| --- | --- |
| `s` | Step one instruction |
| `n` | Step over: run a `jsr` until it returns, otherwise step |
| `g` | Go: run until a breakpoint, `brk`, or F12 |
| `b` | Toggle a breakpoint at the cursor (code view, `$0200`-`$47ff`, up to 8) |
| `p` | Set the PC to the cursor |
| `.` | Move the cursor to the PC |
| `j` + 4 hex digits | Jump the cursor to an address |
| `r` + `a`/`x`/`y`/`p`/`s` + 2 hex digits | Set a register |
| `k` + 2 hex digits | Select the SSD sector (`00`-`3f`) shown at `$8000`-`$8fff` |
| `v` | Show the user's screen until a key is pressed |
| Tab | Switch between the code and hex views |
| Esc | Enter the monitor; its `x` command returns to the debugger |

Esc cancels a `j`, `r`, or `k` prompt.

Code view: up/down move by one instruction and left/right by one page.

Hex view: the arrows move the cursor by one byte or one row. Type two hex
digits to write a byte; the cursor then advances. Backspace cancels a
half-typed byte. The status row shows the instruction at the cursor. I/O
addresses (`$7800`-`$7fff`) show as `--` and are never read.

### SSD patches

Writing to `$8000`-`$8fff` patches the selected SSD sector. Flash can only
clear bits, so a byte that needs a 0 to become 1 is patched by copying the
sector to `$6200`-`$71ff`, erasing it, and writing it back. That overwrites
graphics memory in that range.

### Stepping and running

Most instructions are stepped by copying them to a trampoline and running
them with the user's registers. `brk`, `jsr`, `rts`, `rti`, `jmp`, and `wai`
are emulated. `stp` and code in I/O space are not stepped.

`g` writes `brk` over each breakpoint, swaps in the user's screen and zero
page, and runs. The debugger takes over on a `brk` or when F12 is pressed.
The emulator's GUI has no F12 key.

The debugger keeps its own copy of these zero-page bytes and the text
screen (`$6000`-`$61ff`), so the hex view and stepped code see the user's
values: `$00`-`$0f`, `$13`-`$1f`, `$30`-`$37`, and `$40`-`$45`. The keyboard
state (`$10`-`$12`, `$20`-`$2f`) is shared.

Limitations:

- Breakpoints and F12 need the monitor's IRQ handler. A program that
  installs its own handler at `$1e` runs until it hits a `brk`.
- Breakpoints work only in RAM below the debugger.
- The monitor (Esc) sees the debugger's screen and zero page, not the
  user's.
- The video mode is saved by reading VIA2 port A.

## Memory

| Address | Use |
| --- | --- |
| `$0100`-`$014f` | Debugger stack |
| `$0150`-`$01ff` | User stack |
| `$0200`-`$47ff` | Free for the program being debugged |
| `$4800`-`$5aff` | Debugger code and opcode tables |
| `$5c00`-`$5eff` | Saved user screen and zero page, breakpoints, variables |
| `$6200`-`$71ff` | Scratch while rewriting an SSD sector |

The assembler checks that the code ends before `$5c00` and the data before
`$6000`.

## Emulator tests

```sh
./test-debugger.sh [path/to/KickAss.jar] [path/to/kit-emu]
```

The defaults are `../../KickAss.jar` and `../../../kit-emu`. The script
rebuilds the monitor and debugger, compiles the emulator into a temporary
directory, and runs it there on a copy of `ssd.bin`.

The tests drive the real monitor loader and PS/2 keyboard. They check the
disassembly of all 256 opcodes against the emulator's instruction table,
with three sets of operand bytes. They also cover stepping (branches,
`bbr`/`bbs`, `jsr`/`rts`, `rti`, indirect jumps, the stack, `brk`),
register edits, breakpoints, step over, F12, and RAM, zero-page, screen,
and SSD edits. The SSD checks include a patch that needs an erase, which
must leave the rest of the sector unchanged. A final check returns from
the monitor.
