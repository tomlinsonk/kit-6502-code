# sid-play

Plays C64 `.sid` tunes on the KiT's SID by running the tune's own 6502 code. Tunes are converted on your computer, then saved to the SSD alongside the player.

```
 sid play                3 songs
*wizball
 glider rider
 commando

--------------------------------
wizball
martin galway
1987 ocean

tune 4/9                    0:08
c-5 #####  --- .....  c-6 #####
ret play  <> tune  spc stop  esc
```

## Setup

You need [py65](https://pypi.org/project/py65/) and [sidreloc](https://www.linusakesson.net/software/sidreloc/):

```sh
python3 -m pip install py65

curl -O https://hd0.linusakesson.net/files/sidreloc-1.0.tgz
tar xzf sidreloc-1.0.tgz
make -C sidreloc-1.0
cp sidreloc-1.0/sidreloc /usr/local/bin/     # or pass --sidreloc PATH to sid2kit.py
```

Build the player and save it to the SSD once:

```sh
ka -libdir ../../roms/video-mon sid_play.asm
```

In the monitor, type `l`, then send the program:

```sh
python3 pcb_serial_send.py sid_play.prg
```

Press `s`, pick a free sector, and name it (for example `sid play`).

## Adding a song

```sh
python3 sid2kit.py ~/Music/C64Music/MUSICIANS/G/Galway_Martin/Wizball.sid
```

```
relocating $4600-$63da to $1000 with sidreloc
patched 68 I/O accesses (60 seen running, 8 found by disassembly)
checked 9 subtunes for 3000 play calls each
  subtune 4 plays at 200.5 Hz
  ...
wizball.prg: "Wizball" by Martin Galway, 9 subtunes, $0f80-$3036, 8375 bytes (3 SSD sectors)
```

Load and save `wizball.prg` the same way as the player. A song that needs more than one sector also fills the sectors after the one you pick (sectors 10, 11, and 12 for Wizball saved at 10), so make sure they're free. Use `d` in the monitor to see what's where.

## Playing

Run the player with `f` and its sector, for example `f 05`. It lists every converted song on the SSD.

| Key | Action |
| --- | --- |
| up / down | pick a song |
| return | load and play it |
| left / right | previous / next subtune |
| space | stop, or start the subtune again |
| esc | back to the monitor |

## What works

Most PSID tunes up to about 19 KB, including multi-speed tunes like Wizball's 200 Hz main theme. `sid2kit.py` refuses tunes it can't convert and says why:

- RSID tunes, and tunes without a play routine, which need a full C64 environment
- tunes over about 19 KB (for example Last Ninja)
- tunes that use undocumented 6510 opcodes, which the KiT's 65C02 can't run
- tunes that reach the SID through a pointer, or need memory the KiT doesn't have free

Sampled sound (digis) won't play properly, and only the first SID of multi-SID tunes plays.

## How it works

The KiT clocks its SID at 1.8432 MHz and a C64 at about 1 MHz, so a tune's notes would come out almost an octave sharp and its envelopes nearly twice as fast. `sid2kit.py` moves the tune into $0300-$4fff and turns each SID store into a `jsr` to a few bytes of code added after the tune. That code does the store on a shadow page in the player, then calls the player's `sid_commit`, which sends the register to the real SID with the frequency scaled and the attack, decay, and release rates swapped for the closest match. Every write reaches the SID in the tune's own order, so tricks like retriggering the gate inside one play call still work.

The player calls the tune from VIA timer 1, at 50 Hz or the rate the tune set on its CIA timer. Tunes use zero page freely, so the KiT's part of it ($00-$2f) is swapped out around each call.

Memory:

| Range | Use |
| --- | --- |
| $0300-$4fff | song: 128-byte header, tune, SID store code |
| $5000-$5cff | player |
| $5d00-$5fff | shadow SID, CIA, and other I/O pages |
