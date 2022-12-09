.cpu _65c02
.encoding "ascii"
.filenamespace test1_coop

#import "cooperative-multitask/cooperative_multitask.sym"

#define MACROS_ONLY
#import "../lib/macros.lib"
#import "../lib/vid.lib"
#import "../lib/vid_cg1.lib"
#import "../lib/kb.lib"
#import "../lib/uart.lib"
#import "cooperative-multitask/cooperative_multitask.asm"


.const j_start = 40



.segment Code [outPrg="test1-coop.prg", start=$4000] 

first_subtask:
    fill_vid_screen_cg1(vid_cg1.GREEN)


	ldx #40
	stx curr_i
	
	ldx #0
	stx curr_x

	ldy #32
	sty curr_y

	jsr write_and_wait
	rts
	

subtask:
	ldx curr_x

	jsr write_and_wait
	rts


write_and_wait:
	lda #j_start
	sta curr_j

j_loop:
	dec curr_i
	bne skip_writing

	lda #40
	sta curr_i

	ldy curr_y
	lda #vid_cg1.BLUE

	inx
	stx curr_x
	cpx #64
	bne same_row
	ldx #0
	stx curr_x
	iny
	sty curr_y
same_row:

	jsr vid_cg1.write_pixel

	lda #1
	sta curr_j
skip_writing:

	ldy #$80
delay:
	dey
	bne delay

	dec curr_j
	bne j_loop

    lda #<subtask
    ldy #>subtask
    jsr coop.add_subtask  

	rts



.segment Variables [virtual, startAfter="Code", align=$100]
curr_x:
	.byte $00
curr_y:
	.byte $00
curr_i:
	.byte $00
curr_j:
	.byte $00
