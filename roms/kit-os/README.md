# kit-os

The KiT's operating system, in ROM: a machine language monitor with a file manager, a line
assembler, a debugger, and loading over serial or Wi-Fi.

## Build and flash

```sh
cd roms/kit-os
java -jar ../../KickAss.jar -libdir ../../lib -binfile kit_os.asm
minipro -p AT28C256 -w kit_os.bin
```

This writes `kit_os.bin` (the ROM) and `kit_os.sym` (symbols for programs). For
[kit-emu](https://github.com/tomlinsonk/kit-emu), copy `kit_os.bin` into the emulator's
directory.

## Commands

Type a command at the `>` prompt and press Enter. Numbers are hex.

| Command | Action |
| --- | --- |
| `r 1000` | Show 8 bytes at `$1000` |
| `w 1000 a9 42` | Write bytes starting at `$1000` |
| `g 1000` | Run code at `$1000` |
| `s` | Show the registers |
| `u pc p a x y s` | Change the registers (`-` keeps one), e.g. `u 1000 - 42` |
| `x` | Leave the monitor and continue the program |
| `l` | Load a program over the serial port |
| `f` | File manager |
| `f 06` | Run (or show) the file in SSD sector `06` |
| `a`, `a 2000` | Assembler |
| `b`, `b 1000` | Debugger |
| `t` | Wi-Fi card terminal |
| `h` | Help |

Esc at the prompt resets the KiT. F1-F10 switch video modes. A program returns to the monitor
with `brk`.

## Loading programs

After a load, the monitor shows the start address (`A`), size (`B`), and checksum (`C`), then
asks `Run, Save, or Cancel?`. Save asks for a name and writes the file to the lowest free SSD
sectors, for example `saved to 06`. Run it later with `f 06`.

- **Serial:** type `l`, then send the program with `support-software/pcb_serial_send.py`.
- **Wi-Fi:** with the Wi-Fi card in slot 3, send the program from your computer:

  ```sh
  python3 support-software/wifi_send.py snake.prg
  ```

  When the prompt is idle with nothing typed, the monitor loads it by itself. See
  `esp32/kit-wifi` for setting up the card.

## Wi-Fi terminal (`t`)

`t` talks to the Wi-Fi card's menu, for choosing a network (`w`) and showing its address and
latest upload (`i`). Esc returns to the monitor. Without a card, `t` says
`no wifi card in slot 3`.

## File manager (`f`)

`f` lists the files on the SSD:

```
 ssd files   14 files  43 free
sc t name             bytes sec
00 p snake              542   1
08 i neil              6144   2
0a p basic             8619   3
...
program at $1000
pppppp..iippp.iipppppp..........
..............................dd
ent:run n:name d:del c:cpy esc
```

Each row shows the file's first sector, type (`p` program, `i` image, `d` data), name, size,
and number of sectors. The two rows at the bottom map all 64 sectors: `.` is free, a letter is
the type of the file using it, and the selected file's sectors are in inverse video.

| Key | Action |
| --- | --- |
| up / down | Pick a file |
| left / right, pgup / pgdn | Page through the list |
| Enter | Run a program, or show an image until a key is pressed |
| `n` | Rename |
| `d` | Delete (asks `y/n`) |
| `c` | Copy to the lowest free sectors, under a new name |
| Esc | Back to the monitor |

When renaming or copying, edit the name on the bottom row (up to 16 characters), then press
Enter, or Esc to cancel.

- `!` before a name marks a file whose chain of sectors is broken. Deleting it erases only
  the sectors listed for it.
- Renaming needs one free sector: each sector of the file is copied there with the new name,
  erased, and copied back. Don't power off while it runs.
- Images that would load outside `$0300-$77ff` aren't shown.

## Assembler (`a`)

`a 2000` starts the line assembler at `$2000`. `a` on its own continues where you left off
(`$1000` the first time). Type a 65C02 instruction and press Enter: the line is replaced by
the bytes and the instruction as assembled, and the prompt moves to the next address.

```
1000: a2 00    ldx #$00
1002: e8       inx
1003: d0 fd    bne $1002
1005: 00       brk
```

- Start a line with `2000:` to move somewhere else (`2000: lda #$41` also works).
- Numbers are hex with an optional `$`; one or two digits mean zero page. `'c` is a
  character code.
- Branches take the target address: `bne 1002`. Bit instructions: `rmb3 $12`,
  `bbs7 $80,$1234`.
- Backspace edits the line. A bad line prints `? message` and writes nothing.
- Code can only go in RAM `$0000-$5fff`.
- Esc returns to the monitor. Run your code with `g 1000`; end it with `brk` to come back.

| Directive | Effect |
| --- | --- |
| `.b 01 02 ff 'a` | Write bytes |
| `.t Hello` | Write text, no terminator |
| `.s ss start [end]` | Save `start` up to `end` (default: the current address) to SSD sector `ss` |

`.s` asks before overwriting a used sector, then asks for a name. Run the saved program with
`f ss`.

## Debugger (`b`)

A 65C02 disassembler, single stepper, and hex editor.

- `b 1000` starts a new session with the PC at `$1000`, A, X, and Y `00`, P `20`, S `ff`,
  and no breakpoints. The monitor's screen becomes the program's screen.
- `b` continues the last session. If the debugger's memory was overwritten (by graphics or
  an image), it starts a new session at `$1000`.

```
pc 1000 a 00 x 00 y 00 s ff
p 20 nvdizc  ssd 00         code
>  1000 a9 42    lda #$42
   1002 a2 02    ldx #$02
 * 1004 ca       dex
   ...
s n g b p r j k v . tab esc
```

Row 1 shows the flags (set flags are inverted), the SSD sector, and the view. In the code
view, `>` marks the PC and `*` marks a breakpoint.

| Key | Action |
| --- | --- |
| `s` | Step one instruction |
| `n` | Step over: run a `jsr` until it returns, otherwise step |
| `g` | Run until a breakpoint, `brk`, or F12 |
| `b` | Toggle a breakpoint at the cursor (code view, `$0300-$5fff`, up to 8) |
| `p` | Set the PC to the cursor |
| `.` | Move the cursor to the PC |
| `j` + 4 hex digits | Jump the cursor to an address |
| `r` + `a`/`x`/`y`/`p`/`s` + 2 hex digits | Set a register |
| `k` + 2 hex digits | Select the SSD sector shown at `$8000-$8fff` |
| `v` | Show the program's screen until a key is pressed |
| Tab | Switch between the code and hex views |
| Esc | Back to the monitor |

Esc cancels a `j`, `r`, or `k` prompt. In the code view, up/down move by one instruction and
left/right by one page. In the hex view, the arrows move the cursor, typing two hex digits
writes a byte, and Backspace cancels a half-typed byte. I/O (`$7800-$7fff`) shows as `--`.
Writing to `$8000-$8fff` patches the selected SSD sector.

Esc leaves the program's registers on the monitor's stack, as if it had run `brk`: `s` shows
them, `u` changes them, `x` continues the program, and `b` picks them up again.

Limitations:

- Breakpoints and F12 need the monitor's IRQ handler. A program that installs its own handler
  runs until it hits a `brk`, which goes to the monitor.
- The program's stack must stay above `$0150`.
- The 6 KB graphics modes overwrite the debugger's data at `$6e00-$71ff`. Breakpoints and
  registers survive a run that draws there; stepping such an instruction clears the
  breakpoints ("debugger memory overwritten").
- An SSD patch that needs an erase copies the sector through `$6200-$6dff` and `$7200-$75ff`,
  overwriting graphics there.

## Writing programs

Assemble against `kit_os.sym` to call kit-os routines:

```
#import "kit_os.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
```

```sh
java -jar ../../KickAss.jar -libdir ../../roms/kit-os prog.asm
```

Public routines (`vid.write_ascii`, `kb.get_press`, `ssd.set_sector`, `wifi.send_byte`, ...)
are entries in fixed jump tables at `$fd00-$ffff`, listed in `lib/api.lib`. They keep their
addresses when kit-os changes, so programs keep working with newer ROMs. Each library defines
its table at the end of its routines. Only add entries at the end of a table.

Routines outside the tables can move between ROM builds; programs that use them need to be
assembled again.

## Memory

| Address | Use |
| --- | --- |
| `$00-$0f` | Scratch for programs and kit-os apps (saved by the monitor, restored by `g`/`x`) |
| `$10-$7f` | kit-os: keyboard, video, monitor, SSD, SID, math |
| `$0100-$01ff` | Stack (the debugger uses `$0100-$014f`) |
| `$0200-$025f` | kit-os: prompt, Wi-Fi card, assembler and debugger state |
| `$0300-$5fff` | User RAM; kit-os never writes here except to load what you ask for |
| `$6000-$61ff` | Text screen |
| `$6200-$75ff` | Scratch for the file manager, assembler, and debugger (text mode only) |
| `$7800-$7aff` | VIA 1, VIA 2, serial UART |
| `$7c00-$7eff` | Slots 3-5 (Wi-Fi card at `$7c00`, SID at `$7e00`) |
| `$8000-$8fff` | Selected SSD sector |
| `$9000-$ffff` | kit-os ROM |

## Tests

```sh
roms/kit-os/test/test-files.sh [KickAss.jar] [kit-emu]
roms/kit-os/test/test-mini-asm.sh [KickAss.jar] [kit-emu]
roms/kit-os/test/test-debugger.sh [KickAss.jar] [kit-emu]
roms/kit-os/test/test-wifi.sh [KickAss.jar] [kit-emu]
```

The defaults are `KickAss.jar` at the top of this repo and `kit-emu` next to it. Each script
builds kit-os and runs it headless in kit-emu from a temporary directory, on a copy of
kit-emu's `ssd.bin` (the file manager test uses the committed one). The Wi-Fi test simulates
the card in slot 3.
