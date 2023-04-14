.cpu _65c02
.encoding "ascii"
.filenamespace mandelbrot

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"


.label prodlo = zp.B
.label factor2 = zp.C
.label z_re = zp.D
.label z_im = zp.E
.label c_re = zp.F
.label c_im = zp.G
.label ror_stash = zp.H
.label re_sq = zp.I
.label im_sq = zp.J


.segment Code [outPrg="mandelbrot.prg", start=$4000] 
reset:

    lda #$ff
    sta vid.MODE_REG_DIR

    set_vid_mode_cg1()
    
    fill_vid_screen_cg1(vid_cg1.GREEN)

    ldx #63
row_loop:

    ldy #63 
col_loop:
    cli
    sei
    
    tya
    sec
    sbc #32
    sta c_im

    txa
    sec
    sbc #48
    sta c_re

    stz z_re
    stz z_im

    phx
    phy

    ldx #32
iter_loop:
    lda z_re
    ldy z_re
    jsr mul8_signed
    jsr ror_5
    sta re_sq

    lda z_im
    ldy z_im
    jsr mul8_signed
    jsr ror_5
    sta im_sq


    lda z_re
    ldy z_im
    jsr mul8_signed
    jsr ror_4
    clc
    adc c_im
    sta z_im

    lda im_sq
    eor #$ff
    inc
    clc
    adc re_sq
    adc c_re
    sta z_re

    lda im_sq
    sec
    adc re_sq

    cmp #128
    bcs over
    dex
    bne iter_loop

    ply
    plx
    lda #vid_cg1.BLUE
    jsr vid_cg1.write_pixel

end_iter:
    dey
    bmi row_done
    jmp col_loop
row_done:
    dex
    bmi done
    jmp row_loop


over:
    cpx #24
    bcc yellow
    cpx #28
    bcc red
green:
    ply
    plx
    lda #vid_cg1.GREEN
    jsr vid_cg1.write_pixel
    jmp end_iter
yellow:
    ply
    plx
    lda #vid_cg1.YELLOW
    jsr vid_cg1.write_pixel
    jmp end_iter
red:
    ply
    plx
    lda #vid_cg1.RED
    jsr vid_cg1.write_pixel
    jmp end_iter




done:
	jmp done


/**
 * Rotate Y,A right 5 times (i.e., divide the positive 
 * two byte number YA by 32).
 * Stores the result in A.
 */
ror_5:
    ror
    ror
    ror
    ror
    ror
    and #%00000111
    sta ror_stash

    tya 
    asl
    asl
    asl
    ora ror_stash

    rts


/**
 * Rotate Y,A right 4 times (i.e., divide the positive 
 * two byte number YA by 16).
 * Stores the result in A.
 */
ror_4:
    ror
    ror
    ror
    ror
    and #%00001111
    sta ror_stash

    tya 
    asl
    asl
    asl
    asl
    ora ror_stash

    rts


/**
 * Multiply A by Y as unsigned integers. 
 * Return low byte of product in A, high byte in Y
 * By tepples at https://www.nesdev.org/wiki/8-bit_Multiply
 */
mul8_unsigned:
    lsr
    sta prodlo
    tya
    beq mul8_early_return
    dey
    sty factor2
    lda #0
    .for(var i=0; i<8; i++) {
    	.if(i > 0) {
    		ror prodlo
    	}

	    bcc no_add
    	adc factor2
 no_add:
	    ror
    } 
    tay
    lda prodlo
    ror
mul8_early_return:
    rts


/**
 * Multiply A by Y as signed integers.
 * Return low byte of product in A, high byte in Y.  
 */
mul8_signed:
    phx
    ldx #0

    cmp #0                                                  // load N flag for A
    bpl a_pos
    dex                                                     // decrement X since A negative 
    eor #$ff
    inc                                                     // negate A to make positive
    jmp check_y_sign
a_pos:
    inx                                                     // increment X since A positive 
check_y_sign:
    pha                                                     // stash A
    tya                                                     // transfer Y to A
    cmp #0                                                  // load N flag for Y
    bpl y_pos
    dex                                                     // decrement X since Y negative 
    eor #$ff
    inc                                                     // negate Y to make positive
    jmp do_multiply
y_pos:
    inx                                                     // increment X since A positive 

do_multiply:
    tay                                                     // put Y back
    pla                                                     // restore A

    jsr mul8_unsigned                                       // do unsigned multiplication

    cpx #0                                                  // check if X is 0
    bne exit_mul8_signed                                    // if X is not 0, product is positive. Return.
    clc                                                     // Otherwise, need to negate result. clear carry bit
    eor #$ff                                                // negate A
    adc #1                                                  // add 1, setting carry bit if overflow
    pha                                                     // stash A
    tya                                                     // move Y to A
    eor #$ff                                                // Negate Y
    bcc no_carry                                            // If A didn't overflow, no carry
    inc                                                     // If A did overflow, carry
no_carry:
    tay                                                     // put Y back 
    pla                                                     // restore A

exit_mul8_signed:

    plx
    rts



