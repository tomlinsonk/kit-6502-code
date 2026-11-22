# Code for the KiT 6502 computer

For more info on the KiT, see [https://www.kirantomlinson.com/categories/6502/](https://www.kirantomlinson.com/category/6502/).

## Repository layout
- `lib/` contains libraries imported by other programs (e.g., for keyboard and display routines)
- `roms/` contains self-contained programs for flashing the EEPROM. The most important is [`kit-os`](roms/kit-os/README.md), the KiT's operating system: a machine language monitor with a file manager, assembler, debugger, and loading over serial or Wi-Fi.
- `prgs/` contains programs designed to be loaded by `kit-os` over the serial port or Wi-Fi, including `mandelbrot`, `snake`, `preempt`, `cooperative-multitask`, and `tiny-gpt` (transformer language models that make up arXiv paper titles and children's stories).  

## Instructions
Download Kick Assembler from http://theweb.dk/KickAssembler and minipro from https://gitlab.com/DavidGriffith/minipro/.

Add the alias:

`alias ka='java -jar /path/to/KickAss.jar'`

To assemble a program for flashing to ROM:

`ka -libdir ../../lib -binfile source.asm` 

To program EEPROM:

`minipro -p AT28C256 -w source.bin`

To read EEPROM:

`minipro -p AT28C256 -r rom.bin`

To assemble a program for loading over the serial port:

`ka -libdir ../../roms/kit-os prg.asm`
