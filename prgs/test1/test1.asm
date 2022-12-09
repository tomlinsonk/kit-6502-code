.cpu _65c02
.encoding "ascii"
.filenamespace test0

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"


.segment Code [outPrg="test1.prg", start=$4000] 


// test:
// 	lda #'1'

// loop:
	
// 	jsr vid.write_ascii
// 	inc_vid_ptr()

// 	jmp loop

start:
	sei
    fill_vid_screen_cg1(vid_cg1.GREEN)
    cli
    
	lda #vid_cg1.BLUE

	ldx #0
	ldy #32

loop:
	sei
	jsr vid_cg1.write_pixel
	cli

	inx
	cpx #64
	bne same_row
	ldx #0
	iny
same_row:
	jsr delay_loop
	jmp loop







delay_loop:
	phx
	phy

	ldx #0

outer_delay:
	ldy #20
inner_delay:
	dey
	bne inner_delay

	dex
	bne outer_delay

	ply
	plx
	rts

