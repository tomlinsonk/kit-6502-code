.cpu _65c02
.encoding "ascii"
.filenamespace test

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg3.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"
#import "../../lib/sid.lib"

.enum {UP, DOWN, LEFT, RIGHT}

.label dividend = zp.B 							// two bytes -- also uses zp.C
.label divisor = zp.D 							// two bytes -- also uses zp.E
.label remainder = zp.M 						// two bytes -- also uses zp.N

.label not_eq = zp.F
.label extend_count = zp.G
.label head_ptr = zp.H
.label tail_ptr = zp.I
.label prev_tick = zp.J
.label curr_dir = zp.K
.label next_dir = zp.L
.label rng = zp.P 								// two bytes -- also uses zp.Q


.label game_timer = zp.cursor_blink_count
.const initial_length = 12
.const extend_length = 8

.const BG_COLOR = vid_cg3.YELLOW
.const SNAKE_COLOR = vid_cg3.BLUE
.const FOOD_COLOR = vid_cg3.RED

.const WIDTH = 128
.const HEIGHT = 96

.label stash = zp.B

.segment Code [outPrg="test.prg", start=$1000] 
reset:
	set_vid_mode_cg3()

	fill_vid_screen_cg3(vid_cg3.YELLOW)

	stz stash
	inc stash

	ldx #1
	ldy #0

x_loop:
	jsr delay
	dex
	jsr vid_cg3.read_pixel
	inx
	inc
	jsr vid_cg3.write_pixel
	inx
	cpx #128
	bcc x_loop
	inc stash
	ldx stash

	iny
	cpy #96
	bcc x_loop



done:
	jmp done



delay:
	phx
	phy

	ldx #0
	ldy #250
loop:
	inx
	bne loop
	iny
	bne loop


	ply
	plx
	rts
