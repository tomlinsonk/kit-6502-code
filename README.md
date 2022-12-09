# Code for the KiT 6502 computer

For more info on the KiT, see https://www.cs.cornell.edu/~kt/categories/6502/.

## Repository layout
- `lib/` contains libraries imported by other programs (e.g., for keyboard and display routines)
- `roms/` contains self-contained programs for flashing the EEPROM. The most important program is `video-mon`, which is the KiT's machine language monitor that serves as its main operating system. 
- `prgs/` contains programs designed to be loaded over the serial port by `video-mon`, including `mandelbrot`, `snake`, `preempt`, and `cooperative-multitask`.  

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
