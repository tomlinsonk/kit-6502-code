# make MODEL=titles export     export models/titles/model.pt to build/titles/
# make MODEL=titles            assemble the program and installers
# make MODEL=titles test       compare with the simulator in kit-emu
# make MODEL=titles emu-install   install into kit-emu's ssd.bin
PY ?= .venv/bin/python
KA ?= java -jar ../../KickAss.jar
EMU ?= ../../../kit-emu
MODEL ?= titles
B = build/$(MODEL)
ASM = $(KA) -libdir ../../roms/kit-os -libdir $(B) -libdir models/$(MODEL) -odir $(B)
INC = $(B)/model.inc $(B)/tables.inc models/$(MODEL)/settings.inc

.PHONY: all export test emu-install clean

all: $(B)/$(MODEL).prg $(B)/install1.prg $(B)/install2.prg

export:
	$(PY) export.py models/$(MODEL)/model.pt

$(B)/$(MODEL).prg: tinygpt.asm $(INC)
	$(ASM) tinygpt.asm

$(B)/install%.prg: install.asm $(B)/model.inc $(B)/weights.bin $(B)/headers.bin
	$(ASM) install.asm :PART=$*

test:
	$(PY) test_emu.py --model $(MODEL) --emu $(EMU) --tokens 100
	$(PY) test_emu.py --model $(MODEL) --emu $(EMU) --installer

emu-install: $(B)/$(MODEL).prg
	$(PY) pack.py --ssd $(EMU)/ssd.bin --model $(MODEL) --prg

clean:
	rm -f $(B)/*.prg $(B)/*.sym
