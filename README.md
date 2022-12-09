# Code for the KiT 6502 computer

For more info on the KiT, see https://www.cs.cornell.edu/~kt/categories/6502/.

Download Kick Assembler from http://theweb.dk/KickAssembler and minipro from https://gitlab.com/DavidGriffith/minipro/.

Add the alias:

`alias ka='java -jar /path/to/KickAss.jar'`

To assemble a program for flashing to ROM:

`ka -libdir ../../lib -binfile source.asm` 

To program EEPROM:

`minipro -p AT28C256 -w source.bin`

To read EEPROM:

`minipro -p AT28C256 -r rom.bin`
