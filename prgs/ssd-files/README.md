# ssd-files

A file manager for the KiT's SSD. It lists each file once, however many sectors it spans, shows which sectors are free, and runs, renames, deletes, and copies files.

```
 ssd files   14 files  43 free
sc t name             bytes sec
00 p snake              542   1
01 p life              1317   1
02 p mandelbrot         357   1
03 p pong               488   1
04 p sid               1598   1
05 p char-draw          876   1
08 i neil              6144   2
0a p basic             8619   3
0e i neil-bw           6144   2
10 p sid-play          3049   1
program at $1000
pppppp..iippp.iipppppp..........
..............................dd
ret:run r:ren d:del c:copy esc
```

Each row shows the file's first sector, its type (`p` program, `i` image, `d` data), name, size, and how many sectors it uses. The two rows at the bottom are a map of all 64 sectors: `.` is free, a letter is the type of the file using it, and the selected file's sectors are in inverse video.

## Build

```sh
(cd ../../roms/video-mon && java -jar ../../KickAss.jar -libdir ../../lib -binfile video_mon.asm)
java -jar ../../KickAss.jar -libdir ../../roms/video-mon ssd_files.asm
```

In the monitor, type `l`, send `ssd_files.prg`, press `s`, and save it to a free sector. Run it with `f` and that sector, for example `f 06`.

## Keys

| Key | Action |
| --- | --- |
| up / down | pick a file |
| left / right, pgup / pgdn | page through the list |
| return | run a program, or show an image until a key is pressed |
| r | rename |
| d | delete (asks `y/n`) |
| c | copy to the lowest free sectors, under a new name |
| esc | back to the monitor |

When renaming or copying, edit the name on the bottom row (up to 16 characters), then press return, or esc to cancel.

## Notes

- A file's later sectors are found by following each header's next-sector link. A link only counts if it points to a used sector with the same name, so a sector reused by another file isn't shown as part of the wrong one.
- `!` before a name marks a file whose chain is broken: a link points to a free sector, another file, or back into itself. Deleting it erases only the sectors listed for it.
- Renaming rewrites every sector of the file: each sector is copied to RAM, erased, and written back with the new name. Don't power off while it runs.
- Images that would load over the file manager ($1000-$3fff) aren't shown.

Memory:

| Range | Use |
| --- | --- |
| $1000-$1fff | program |
| $2000-$2fff | sector tables |
| $3000-$3fff | one-sector buffer for rename and copy |

## Tests

`test-ssd-files.sh` builds the monitor and the program, then drives them in [kit-emu](https://github.com/tomlinsonk/kit-emu) with a copy of its `ssd.bin`:

```sh
./test-ssd-files.sh path/to/KickAss.jar path/to/kit-emu
```

The defaults are `../../KickAss.jar` and `../../../kit-emu`.
