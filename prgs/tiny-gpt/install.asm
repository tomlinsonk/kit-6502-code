/* =========================================================================
   TINY GPT INSTALLER
   Writes part of a tiny-gpt model's weight file ("<model>-weights") to the
   SSD. The weights take NSECTORS sectors, more than fit in RAM at once, so
   they come in parts of up to 4 sectors. Run every part, in order: load
   installN.prg with the monitor's `l` command and choose `r`.

   Part 1 deletes earlier weights with the same name, then uses the lowest
   run of NSECTORS free sectors. Later parts find the file part 1 started.

   Assemble (export.py writes build/<model>/):
     ka -libdir ../../roms/kit-os -libdir build/titles -odir build/titles install.asm :PART=1
   ========================================================================= */

.cpu _65c02
.encoding "ascii"
.filenamespace install

#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "kit_os.sym"
#import "model.inc"

.const PART = cmdLineVars.get("PART").asNumber()
.const PER_PART = 4
.const FIRST = (PART - 1) * PER_PART
.const COUNT = min(PER_PART, NSECTORS - FIRST)
.const PARTS = ceil(NSECTORS / PER_PART)
.assert "part exists", COUNT > 0, true

.label SECREG = $7900
.label SECDDR = $7902
.label src = $46                    // data being written
.label base = $48                   // first sector of the weight file
.label idx = $49                    // file sector index
.label cnt = $4a
.label tmp = $4b

.segment Code [outPrg="install" + PART + ".prg", start=$1000]
.assert "name fits", WEIGHTS_NAME.size() <= 15, true

start:
    lda #$ff
    sta SECDDR
    jsr vid.blank_screen
    set_vid_ptr(15, 0)
    vid_write_string(WEIGHTS_NAME + ", part ")
    lda #'0' + PART
    jsr vid.write_ascii
    jsr vid.inc_vid_ptr
    vid_write_string(" of ")
    lda #'0' + PARTS
    jsr vid.write_ascii
    jsr vid.shift_up_1_clear_bottom

.if (PART == 1) {
    // delete earlier weights
    ldx #0
!:  jsr is_ours
    bcc !+
    txa
    jsr ssd.set_sector
    jsr ssd.erase_sector
!:  inx
    cpx #64
    bne !--
    // lowest run of NSECTORS free sectors
    ldx #0
find_run:
    stx base
    ldy #NSECTORS
!:  stx SECREG
    lda $8000
    beq run_used
    inx
    dey
    bne !-
    bra found
run_used:
    ldx base
    inx
    cpx #64 - NSECTORS + 1
    bne find_run
    vid_write_string("not enough free sectors")
    jmp done
} else {
    // first sector of the file written by part 1
    ldx #0
!:  stx base
    jsr is_first
    bcs found
    inx
    cpx #64
    bne !-
    vid_write_string("run part 1 first")
    jmp done
}

found:
    lda #<data
    sta src
    lda #>data
    sta src+1
    lda #FIRST
    sta idx
sector_loop:
    vid_write_string("sector ")
    lda base
    clc
    adc idx
    pha
    jsr vid.write_hex
    jsr vid.shift_up_1_clear_bottom
    pla
    jsr ssd.set_sector
    jsr ssd.erase_sector

    // header: template, next-sector link, zeros
    stz zp.ssd_write_addr
    lda #$80
    sta zp.ssd_write_addr+1
    lda idx
    asl
    asl
    asl
    asl
    asl
    tax                             // template offset = idx * 32
    ldy #0
hdr_loop:
    cpy #32
    bcs hdr_zero
    lda headers,x
    cpy #8
    bne hdr_put
    cmp #$ff
    beq hdr_put
    lda base                        // link to the next sector
    clc
    adc idx
    inc
    bra hdr_put
hdr_zero:
    lda #0
hdr_put:
    phx
    phy
    jsr ssd.write_byte
    ply
    plx
    inc zp.ssd_write_addr
    inx
    iny
    bne hdr_loop

    // data: 15 pages at $8100, skipping erased ($ff) bytes
    lda #$81
    sta zp.ssd_write_addr+1
    stz zp.ssd_write_addr
data_loop:
    lda (src)
    cmp #$ff
    beq !+
    jsr ssd.write_byte
!:  inc src
    bne !+
    inc src+1
!:  inc zp.ssd_write_addr
    bne data_loop
    inc zp.ssd_write_addr+1
    lda zp.ssd_write_addr+1
    cmp #$90
    bne data_loop

    inc idx
    lda idx
    cmp #FIRST + COUNT
    beq !+
    jmp sector_loop
!:
.if (PART < PARTS) {
    vid_write_string("done. now run install")
    lda #'1' + PART
    jsr vid.write_ascii
} else {
    vid_write_string("done! run " + NAME + ".prg")
}
done:
    jsr vid.shift_up_1_clear_bottom
    vid_write_string("press a key")
!:  jsr kb.get_press
    beq !-
    jsr vid.blank_screen
    brk
    nop

// Carry set if sector X is the first sector of this weight file: our name, data starting with KGPT and the model id
is_first:
    jsr is_ours
    bcc no
    lda $8001
    cmp #$20
    bne no
    ldy #7
!:  lda $8100,y
    cmp magic,y
    bne no
    dey
    bpl !-
    sec
    rts
no:
    clc
    rts

// Carry set if sector X belongs to a file named WEIGHTS_NAME
is_ours:
    stx SECREG
    lda $8000
    bne no
    ldy #WEIGHTS_NAME.size()
!:  lda $8010,y
    cmp name,y
    bne no
    dey
    bpl !-
    sec
    rts

magic:
    .text "KGPT"
    .fill 4, MODEL_ID.get(i)
name:
    .text WEIGHTS_NAME
    .byte 0

headers:
    .import binary "headers.bin"
data:
    .import binary "weights.bin", FIRST * 3840, COUNT * 3840

.assert "fits in RAM", * <= $6000, true
