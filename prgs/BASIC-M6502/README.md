# KiT BASIC v1.1

Microsoft BASIC, copyright Microsoft 1976-1978, for the PCB KiT.
Uses Kick Assembler, the KiT keyboard, and the 32-column text display.
Includes integer arrays and five-byte floating-point numbers.

## Build

From this directory, build the monitor and BASIC:

```sh
(cd ../../roms/video-mon && java -jar ../../KickAss.jar -libdir ../../lib -binfile video_mon.asm)
java -jar ../../KickAss.jar -libdir ../../roms/video-mon m6502.asm
```

This writes `m6502.prg`, `m6502.sym`, and `upload.prg` (used by
`bas2prg.py`). BASIC calls routines from the
monitor's symbol file, so the KiT must run the matching
`../../roms/video-mon/video_mon.bin`. Flash that ROM for hardware use;
kit-emu reads it directly.

## Run

Load `m6502.prg` through the monitor's `l` command, then select `r`.
The PRG loads and starts at `$1000`; it initializes its own workspace
without overwriting the monitor's buffers.

In kit-emu, start `java KiT --no-save-ssd` from the emulator directory,
use **Load** to select `m6502.prg`, and enter `l`, Enter, then `r`
at the monitor.

At BASIC's `OK` prompt:

```basic
10 FOR I=1 TO 5
20 PRINT I;I*I
30 NEXT I
RUN
```

- Keywords and variable names are uppercased automatically; quoted strings
  keep their case.
- Backspace edits the current line. Lines may contain up to 239 characters;
  longer lines are rejected.
- Escape stops a running program or cancels `INPUT`. `CONT` resumes a
  stopped program.
- Escape at the command prompt returns to the KiT monitor. `g 1000`
  starts BASIC again, clearing its program and variables.
- `GET A$` reads a key without waiting, returning an empty string if no
  key is available.

## Saving programs

`SAVE` and `LOAD` keep programs on the SSD:

```basic
SAVE "HELLO"
LOAD "HELLO"
SAVE 5,"HELLO"
LOAD 5
```

- `SAVE "NAME"` replaces the saved file with that name, or uses the first
  free sectors. `SAVE S,"NAME"` writes to sector `S` and, for programs over
  3,840 bytes, the sectors after it.
- `LOAD` replaces the current program, clears variables, and returns to
  `OK`, including when used inside a program.
- Names are 1-16 characters and case-sensitive. BASIC sector numbers are
  decimal 0-63; the monitor's `d` and `e` commands use hex.
- Programs are saved as KSF data files (type `$20`), one header per sector.
  `SAVE` only overwrites empty sectors or a data file that starts at that
  sector, and erases sectors left over from a longer version.

Errors:

| Message | Meaning |
| --- | --- |
| `?FILE NOT FOUND` | No file with that name, or the sector is empty |
| `?BAD FILE` | Not a data file, or a bad checksum. Bad program links clear the current program |
| `?SECTOR IN USE` | A needed sector holds another file |
| `?SSD FULL` | Not enough sectors after the starting sector |

## Uploading programs from text

`bas2prg.py` turns a BASIC text file into a prg that saves the program
to the SSD. Build BASIC first; the script reads `m6502.prg`,
`m6502.sym`, and `upload.prg` from this directory.

```sh
python3 bas2prg.py hello.bas
python3 bas2prg.py hello.bas --name HELLO --sector 12 -o hello.prg
```

Load the output with the monitor's `l` command and select `r`. It saves
the program and returns to the monitor with `saved to sector N`. Then
start BASIC and `LOAD "hello"`.

- The default name is the file name without `.bas`. Without `--sector`,
  the upload replaces the file with that name or uses the first free
  sectors, like `SAVE "NAME"`.
- Lines need line numbers and are tokenized the same way as typed lines,
  including the 239-character limit. Lines are sorted, a repeated line
  number replaces the earlier line, and a line number on its own deletes
  that line.
- Programs can be up to about 9.5 KB, slightly less than BASIC's free
  space.
- Select `r`, not `s`: the monitor's save would store the upload prg
  itself, not the BASIC program.

| Message | Meaning |
| --- | --- |
| `error: sector in use` | A needed sector holds another file |
| `error: ssd full` | Not enough sectors after the starting sector |

## Examples

`examples/` has programs to upload with `bas2prg.py`:

| Program | What it does |
| --- | --- |
| `mandel.bas` | Draws the Mandelbrot set in colour (about a minute) |
| `lissajous.bas` | Draws Lissajous curves in 64x32 pixel graphics; press a key for the next curve |
| `music.bas` | Plays a tune on the SID and draws it as a scrolling piano roll |

```sh
python3 bas2prg.py examples/mandel.bas
```

They draw by `POKE`ing video memory at `24576` (`$6000`), 32 columns by
16 rows. A value of 128 + 16 × colour + pixels shows a 2x2 block of
pixels in one of 8 colours; the pixel bits are 8 (top left), 4 (top
right), 2 (bottom left), and 1 (bottom right). The SID's registers start
at `32256` (`$7E00`).

## Memory and entry points

| Address | Use |
| --- | --- |
| `$0000`-`$007f` | KiT monitor/library zero page; not used for BASIC state |
| `$0080`-`$00fe` | BASIC zero-page workspace and character-fetch routine |
| `$0100`-`$01ff` | CPU stack |
| `$0200`-`$0231` | Monitor buffers; preserved while BASIC runs |
| `$0300`-`$0375` | BASIC flags, floating-point output buffer, console state, key queue |
| `$03fc`-`$04ef` | Input-buffer prefix and line buffer |
| `$1000` | Cold-start entry, followed by interpreter code and tables |
| `$3701`-`$5fff` | BASIC program, variables, arrays, and strings |
| `$6000` and above | Video memory, devices, and ROM; excluded from BASIC allocation |

The current build reports **10,495 bytes free** at startup. Program storage
is page-aligned after the interpreter, so its starting address can change
when the code grows. The assembler checks that it fits below video memory.
`PEEK` and `POKE` still access arbitrary addresses; use them carefully.

## Emulator tests

```sh
./test-kit.sh
KICKASS=/path/to/KickAss.jar ./test-kit.sh /path/to/kit-emu
```

The default emulator directory is `../../../kit-emu`; pass another path
as the first argument if needed. Set `KICKASS` if `KickAss.jar` is not at
the repository root. Tests rebuild the monitor and BASIC and
compile the emulator into a temporary directory, then run it there with
the new monitor and a copy of the emulator's `ssd.bin`.

Tests use the emulator's host-key mappings, the real monitor loader,
PS/2 keyboard interrupts, and video memory. They cover BASIC statements,
punctuation input, line editing and limits, scrolling,
string garbage collection, heap/stack exhaustion, Escape/CONT, SSD
`SAVE`/`LOAD`, `bas2prg.py` uploads, the examples, monitor return, and
cold restart. They do not change the
emulator's `ssd.bin`.
