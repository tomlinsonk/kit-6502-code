.cpu _65c02
.encoding "ascii"
.filenamespace snake

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

.segment Code [outPrg="snake.prg", start=$1000] 
reset:
#if PCB 
	set_vid_mode_cg3()

// 	fill_vid_screen_cg3(vid_cg3.RED)

// loop2:
// 	jmp loop2

	lda #$1F
	sta sid.mode_vol

	mov #$34 : sid.voice1_atk_dec
	mov #$88 : sid.voice1_sus_rel
	init_sid_osc3_random()
#endif

get_rand_seed:
	lda sid.rand
	beq get_rand_seed
	sta rng

	stz curr_sound
	stz extend_count


	fill_vid_screen_cg3(BG_COLOR)

	mov2 #0 : score
	jsr display_score

	jsr high_scores.ensure_score_file


	stz tail_ptr
	ldx #(initial_length-1)
	stx head_ptr
	ldy #34

init_snake_loop:
	tya
	sta snake_x,x
	lda #32
	sta snake_y,x
	dey
	dex 
	bpl init_snake_loop

	lda game_timer
	sta prev_tick

	lda #RIGHT
	sta curr_dir
	sta next_dir

	jsr new_food


// game_timer increments 15x per second. Use this for updates

loop:
	jsr kb.get_press
	beq no_press

{
	ldy curr_dir

	cmp #kb.K_LEFT
	bne not_left
	cpy #RIGHT
	beq not_left 												// if we're going right, ignore left press
	ldx #LEFT
	stx next_dir
not_left:

	cmp #kb.K_RIGHT
	bne not_right
	cpy #LEFT
	beq not_right 												// if we're going left, ignore right press
	ldx #RIGHT
	stx next_dir
not_right:

	cmp #kb.K_UP
	bne not_up
	cpy #DOWN
	beq not_up 													// if we're going down, ignore up press
	ldx #UP
	stx next_dir
not_up:

	cmp #kb.K_DOWN
	bne not_down
	cpy #UP
	beq not_down 												// if we're going up, ignore down press
	ldx #DOWN
	stx next_dir
not_down:
}

no_press:

	sei
	lda game_timer
	cmp prev_tick
	cli

	beq loop
	sta prev_tick

	mov #0 : sid.voice1_control

	lda next_dir
	sta curr_dir

	cmp #LEFT
	bne not_left
	ldx #-1
	ldy #0
	jsr update_snake
	jmp loop
not_left:

	cmp #RIGHT
	bne not_right
	ldx #1
	ldy #0
	jsr update_snake
	jmp loop
not_right:

	cmp #UP
	bne not_up
	ldx #0
	ldy #-1
	jsr update_snake
	jmp loop
not_up:

	cmp #DOWN
	bne not_down
	ldx #0
	ldy #1
	jsr update_snake
	jmp loop
not_down:

	jmp loop


/**
 Increment the head and tail pointers and set the new head value to 
 old_x + X and old_y + Y. Also erase the tail and draw the head. 
 */
update_snake:
	pha
	phx
	phy

	ldx head_ptr 												// lead head pointer into X
	pla 														// pull Y off of stack
	clc
	adc snake_y,x 												// add to current Y
	inx
	sta snake_y,x 												// increment X to new head_ptr and put new Y into snake_y
	dex 														// decrement so get old head_ptr

	pla 														// pull X off of stack
	clc
	adc snake_x,x 												// add to current X
	inx
	sta snake_x,x 												// store in snake_x at new head_ptr
	stx head_ptr 												// update head_ptr

	stz not_eq													// use not_eq to test if we ate food.
	lda snake_y,x												// load head y position into A
	cmp #HEIGHT 												// check if we're out of Y bounds
	bcc in_y_bounds 											// if Y < 64, we're in bounds 
	jsr play_death_sound	
	jmp reset 													// otherwise, dead! reset.
in_y_bounds:
	tay
	cmp food_y
	beq is_food_y
	inc not_eq
is_food_y:
	lda snake_x,x
	cmp #WIDTH													// check if we're out of X bounds
	bcc in_x_bounds 											// if Y < 64, we're in bounds 
	jsr play_death_sound	
	jmp reset 													// otherwise, dead! reset.
in_x_bounds:
	tax
	cmp food_x
	beq is_food_x
	inc not_eq 												
is_food_x:

	jsr vid_cg3.read_pixel 										// read the pixel value at new head location
	cmp #SNAKE_COLOR 											// check if it's the snake color
	bne no_collision	 										// if not, we didn't collide.
	jsr play_death_sound
	jmp reset 													// otherwise, dead! reset.
no_collision:

	lda #SNAKE_COLOR
	jsr vid_cg3.write_pixel 											// draw the head

	lda not_eq
	bne not_food
	jsr play_food_sound
	jsr new_food
	inc2 score
	jsr display_score

	lda #extend_length
	adc extend_count
	sta extend_count
not_food:

	lda extend_count
	beq tail_update
	dec extend_count
	jmp after_tail_update
	
tail_update:
	ldx tail_ptr
	lda snake_y,x
	tay
	lda snake_x,x
	tax
	lda #BG_COLOR
	jsr vid_cg3.write_pixel 											// erase the tail

	inc tail_ptr
after_tail_update:
	
	pla
	rts


/**
 * Display the current score
 */ 
display_score: {
	pha
	phx
	phy

	mov2 score : dividend
	mov2 #(vid_cg3.VRAM_START + 31 + 32*90) : zp.vid_ptr


divide_loop:
	mov2 #10 : divisor
	jsr divide

	lda remainder
	asl
	asl							// multiply by 4

	clc
	adc remainder
	adc remainder				// add 2*remainder to get 6*remainder for table offset
	tax

	ldy #6
digit_loop:

	lda font_numbers,x
	sta (zp.vid_ptr)
	inx
	add2 zp.vid_ptr : #32
	dey
	bne digit_loop

	lda dividend+1
	bne next_digit
	lda dividend
	bne next_digit
	jmp done
next_digit:
	clc
	add2 zp.vid_ptr : #(-6 * 32 - 1)
	jmp divide_loop

done:
	ply
	plx
	pla
	rts
}

/**
 * Generate new food at random position and draw it
 */
 new_food: {
	jsr galois16o

	lda rng
	and #%01111111
	cmp #90 													// take mod 90 for row (more likely to be in low rows, oh well)
	bcc no_subtract
	sec
	sbc #90
no_subtract:
	tay
	sta food_y

	lda rng+1
	and #%01111111												// take mod 128 for col
	tax
	sta food_x

	jsr vid_cg3.read_pixel 										// read the pixel value at new rng location
	cmp #SNAKE_COLOR 											// check if it's the snake color
	beq new_food	 											// if it's on top of snake, retry

	lda #FOOD_COLOR
	jsr vid_cg3.write_pixel

	rts
}

/**
 16-bit RNG from https://github.com/bbbradsmith/prng_6502/blob/master/galois16.s
 Uses a linear feedback shift register and puts (pseudo-)random bits in rng,rng+1
 */
galois16o:
	lda rng+1
	tay // store copy of high byte
	// compute rng+1 ($39>>1 = %11100)
	lsr // shift to consume zeroes on left...
	lsr
	lsr
	sta rng+1 // now recreate the remaining bits in reverse order... %111
	lsr
	eor rng+1
	lsr
	eor rng+1
	eor rng+0 // recombine with original low byte
	sta rng+1
	// compute rng+0 ($39 = %111001)
	tya // original high byte
	sta rng+0
	asl
	eor rng+0
	asl
	eor rng+0
	asl
	asl
	asl
	eor rng+0
	sta rng+0
	rts


play_food_sound:
	phx
	pha
	
	ldx curr_sound
	mov note_table.lo,x : sid.voice1_freq
	mov note_table.hi,x : sid.voice1_freq+1

	inx
	cpx #12
	bne no_wrap
	ldx #0
no_wrap:
	stx curr_sound

	mov #$11 : sid.voice1_control

	pla
	plx
	rts


play_death_sound:
	mov2 #8000 : sid.voice1_freq

	mov #$81 : sid.voice1_control

	mov #$00 : sid.voice1_control

	// jsr high_scores.save_high_score
	jsr high_scores.display_high_scores

wait:
	jsr kb.get_press
	beq wait

	cmp #kb.ASCII_NEWLINE
	bne wait


	rts


// fill_score_area: {
// 	mov #>vid_cg3.VRAM_START : zp.vid_ptr+1
// 	lda #<vid_cg3.VRAM_START 
// 	clc
// 	adc #24
// 	sta zp.vid_ptr 	

// 	ldx #96
// col_loop:
// 	lda #0
// 	ldy #7
// row_loop:
// 	sta (zp.vid_ptr),y
// 	dey
// 	bpl row_loop
	
// 	add2 zp.vid_ptr : #32 

// 	dex
// 	bne col_loop
// 	rts
// }

/**
 * divide two-byte dividend by two-byte divisor. result goes in dividend, remainder in remainder
 * 
 */ 
divide: {                            
	pha
	phx
	phy

	ldx #16                         // counter for bits to rotate
	stz remainder					// initialize remainder to zero
	stz remainder+1

div_loop:
	asl dividend                    // rotate zero into low bit of result, rotate into remainder
	rol dividend+1
	rol remainder
	rol remainder+1

	sec                 			// set carry bit for borrowing, try subtracting divisor from remainder
	lda remainder
	sbc divisor
	tay
	lda remainder+1
	sbc divisor+1

	bcc div_after_save              // if carry bit is clear, subtraction failed
	sty remainder                   // if subtraction succeeded, save sub result and set bit of division result to 1
	sta remainder+1
	inc dividend

div_after_save:
	dex                 			// loop until x = 0 (16 times for two-byte division)
	bne div_loop

	ply
	plx
	pla
	rts
}



note_table: 
	.lohifill 12, 440 * pow(2, (i+48)/12 - 4.75) / (1843200 / 16777216)


font_letters:
	.byte 169,153,169,153,153,85    // A
	.byte 165,153,165,153,165,85    // B
	.byte 105,149,149,149,105,85    // C
	.byte 165,153,153,153,165,85    // D
	.byte 169,149,169,149,169,85    // E
	.byte 169,149,169,149,149,85    // F
	.byte 105,149,153,153,105,85    // G
	.byte 153,153,169,153,153,85    // H
	.byte 169,101,101,101,169,85    // I
	.byte 89,89,89,153,169,85       // J
	.byte 153,153,165,153,153,85    // K
	.byte 149,149,149,149,169,85    // L
	.byte 153,169,153,153,153,85    // M
	.byte 169,153,153,153,153,85    // N
	.byte 169,153,153,153,169,85    // O
	.byte 169,153,169,149,149,85    // P
	.byte 169,153,153,169,89,85     // Q
	.byte 165,153,165,153,153,85    // R
	.byte 105,149,101,89,165,85     // S
	.byte 169,101,101,101,101,85    // T
	.byte 153,153,153,153,169,85    // U
	.byte 153,153,153,153,101,85    // V
	.byte 153,153,153,169,153,85    // W
	.byte 153,153,101,153,153,85    // X
	.byte 153,153,169,101,101,85    // Y
	.byte 169,89,101,149,169,85     // Z
font_numbers:
	.byte 101,153,153,153,101,85    // 0
	.byte 101,165,101,101,169,85    // 1
	.byte 165,89,101,149,169,85     // 2
	.byte 169,89,105,89,169,85      // 3
	.byte 153,153,169,89,89,85      // 4
	.byte 169,149,169,89,165,85     // 5
	.byte 105,149,169,153,169,85    // 6
	.byte 169,89,101,149,149,85     // 7
	.byte 169,153,169,153,169,85    // 8
	.byte 169,153,169,89,165,85     // 9


#import "high-scores.asm"



.segment Variables [virtual, startAfter="Code", align=$100] 
snake_x:
	.fill 256, 0
snake_y:
	.fill 256, 0
curr_sound:
	.byte $00
food_x:
	.byte $00
food_y:
	.byte $00
score:
	.word $0000

high_score_file:


