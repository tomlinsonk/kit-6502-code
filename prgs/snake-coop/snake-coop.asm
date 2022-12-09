.cpu _65c02
.encoding "ascii"
.filenamespace snake_coop

#import "cooperative-multitask/cooperative_multitask.sym"

#define MACROS_ONLY
#import "../lib/macros.lib"
#import "../lib/vid.lib"
#import "../lib/kb.lib"
#import "../lib/uart.lib"
#import "cooperative-multitask/cooperative_multitask.asm"


.enum {UP, DOWN, LEFT, RIGHT}

.label stash = vars
.label new_pixel = vars+1
.label not_eq = vars+2
.label head_ptr = vars+3
.label tail_ptr = vars+4
.label prev_tick = vars+5
.label curr_dir = vars+6
.label next_dir = vars+7
.label food_x = vars+8
.label food_y = vars+9
.label rng = vars+10 								// two bytes -- also uses vars+11
.label dead = vars+12

.label game_timer = zp.cursor_blink_count
.const initial_length = 8
.const GREEN = 0
.const YELLOW = 1
.const BLUE = 2
.const RED = 3

.const BG_COLOR = YELLOW
.const BG_BYTE = %01010101 
.const SNAKE_COLOR = BLUE
.const FOOD_COLOR = RED

.segment Code [outPrg="snake-coop.prg", start=$1000] 
reset_task:
{
	jsr clear_screen

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

	add_subtask(main_loop_task)
	rts
}

/**
 * This task first gets a keypress from the kb_buffer and stores it, if one exists.
 * Then checks if a game ticks has passed. If so, process update.
 * Otherwise, queue up another task and return.
 */
main_loop_task:
{
	stz dead

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

	beq task_done

	sta prev_tick

	lda next_dir
	sta curr_dir

	cmp #LEFT
	bne not_left
	ldx #-1
	ldy #0
	jsr update_snake
	jmp task_done
not_left:

	cmp #RIGHT
	bne not_right
	ldx #1
	ldy #0
	jsr update_snake
	jmp task_done
not_right:

	cmp #UP
	bne not_up
	ldx #0
	ldy #-1
	jsr update_snake
	jmp task_done
not_up:

	cmp #DOWN
	bne not_down
	ldx #0
	ldy #1
	jsr update_snake
not_down:

task_done:
	lda dead
	beq not_dead
	add_subtask(reset_task)
	rts

not_dead:
	add_subtask(main_loop_task)
	rts
}



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
	cmp #64 													// check if we're out of Y bounds
	bcc in_y_bounds 											// if Y < 64, we're in bounds 
	inc dead 													// otherwise, dead!
in_y_bounds:
	tay
	cmp food_y
	beq is_food_y
	inc not_eq
is_food_y:
	lda snake_x,x
	cmp #64 													// check if we're out of X bounds
	bcc in_x_bounds 											// if Y < 64, we're in bounds 
	inc dead 													// otherwise, dead! 
in_x_bounds:
	tax
	cmp food_x
	beq is_food_x
	inc not_eq 												
is_food_x:

	jsr read_pixel 												// read the pixel value at new head location
	cmp #SNAKE_COLOR 											// check if it's the snake color
	bne no_collision	 										// if not, we didn't collide.
	inc dead 													// otherwise, dead!
no_collision:

	lda #SNAKE_COLOR
	jsr write_pixel 											// draw the head

	lda not_eq
	bne not_food
	jsr new_food
	jmp after_tail_update
not_food:
	
	ldx tail_ptr
	lda snake_y,x
	tay
	lda snake_x,x
	tax
	lda #BG_COLOR
	jsr write_pixel 											// erase the tail

	inc tail_ptr
after_tail_update:
	
	pla
	rts

	
/* --------------------------------------------------------------------------------------- 
Set the screen to solid bg_color
*/
clear_screen: 
	pha
	phx
	phy

	lda #<vid.VRAM_START
	sta zp.vid_ptr
	lda #>vid.VRAM_START
	sta zp.vid_ptr+1

	stz stash
	ldx #4
	lda #BG_BYTE
	ldy #0

	jmp no_carry

clear_loop:
	inc zp.vid_ptr
	bne no_carry
	inc zp.vid_ptr+1
no_carry:
	sta (zp.vid_ptr),y
	inc stash
	bne clear_loop
	dex
	bpl clear_loop

	ply
	plx
	pla
	rts


/* --------------------------------------------------------------------------------------- 
Color Graphics One.
Draw the color in A (bottom two bits: 00 = green, 01 = yellow, 10 = blue, 11 = red) to the coordinates
in X and Y (X: column 0 - 63, Y: row 0 - 63)
*/
write_pixel:
	phx
	phy
	pha

	tya 														// load row into A
	ror
	ror
	ror
	ror															// divide by 16
	and #%00001111
	ora #>vid.VRAM_START 										// add vram start hi byte (%01110000)
	sta zp.vid_ptr+1 											// store in vid pointer hi byte

	tya 														// load row into A
	and #%00001111 												// take mod 16
	asl
	asl
	asl
	asl 														// shift into high nibble
	sta stash  													// stash high nibble

	txa 														// load col into A
	ror
	ror 														// divide by 4
	and #%00001111 												// zero out high nibble
	ora stash 													// combine with high nibble
	sta zp.vid_ptr 												// store in vid pointer low byte

	ldy #0
	lda (zp.vid_ptr),y 											// load current 4 pixels
	sta stash 													// stash in B

	txa 														// load col into A
	ror 														// shift bottom bit into carry

	bcc bits_x0
bits_x1:
	ror
	bcc bits_01
bits_11: 														// col bottom bits are 11. A already good (last bit pair)
	pla
	pha
	sta new_pixel
	lda #%11111100 												// put new pixel in X and mask in A
	jmp save_pixel 													

bits_x0:
	ror
	bcc bits_00
bits_10: 														// col bits are 10. Shift A left two bits
	pla
	pha
	asl
	asl
	sta new_pixel
	lda #%11110011 												// put new pixel in X and mask in A
	jmp save_pixel 	
	
bits_01: 														// col bits are 01. Shift A left four bits
	pla
	pha
	asl
	asl
	asl
	asl
	sta new_pixel
	lda #%11001111												// put new pixel in X and mask in A
	jmp save_pixel 

bits_00: 														// col bits are 00. Shift A left six bits
	pla
	pha
	ror 	
	ror
	ror
	and #%11000000 												// 3 rors + zero out bottom 6 bits = 6 asls
	sta new_pixel
	lda #%00111111 												// put new pixel in X and mask in A	
	jmp save_pixel 
	
save_pixel:
	and stash 													// zero out new pixels
	ora new_pixel  												// add in new pixels
	sta (zp.vid_ptr),y 											// save new byte to VRAM (y still 0)	 													

	pla
	ply
	plx
	rts


/* --------------------------------------------------------------------------------------- 
Color Graphics One.
Read the pixel in coordinates X and Y (X: column 0 - 63, Y: row 0 - 63) into the bottom two bits of A
*/
read_pixel: {
	phx
	phy

	tya 														// load row into A
	ror
	ror
	ror
	ror															// divide by 16
	and #%00001111
	ora #>vid.VRAM_START 										// add vram start hi byte (%01110000)
	sta zp.vid_ptr+1 											// store in vid pointer hi byte

	tya 														// load row into A
	and #%00001111 												// take mod 16
	asl
	asl
	asl
	asl 														// shift into high nibble
	sta stash  													// stash high nibble

	txa 														// load col into A
	ror
	ror 														// divide by 4
	and #%00001111 												// zero out high nibble
	ora stash 													// combine with high nibble
	sta zp.vid_ptr 												// store in vid pointer low byte

	ldy #0
	lda (zp.vid_ptr),y 											// load current 4 pixels
	sta stash 													// stash the 4 pixels containing our pixel of interest

	txa 														// load col into A
	ror 														// shift bottom bit into carry

	bcc bits_x0
bits_x1:
	ror
	bcc bits_01
bits_11: 														// col bottom bits are 11. Pixel is last bit pair of stash
	lda stash 													// pick out bottom two bits of stash
	jmp return 													

bits_x0:
	ror
	bcc bits_00
bits_10: 														// col bits are 10. Pixel is bits 3 and 2 of stash.
	lda stash
	ror
	ror 														// Shift stash right two bits
	jmp return 	
	
bits_01: 														// col bits are 01. Pixel is bits 5 and 4 of stash
	lda stash
	ror
	ror
	ror
	ror
	jmp return 

bits_00: 														// col bits are 00. Shift A left six bits
	lda stash
	rol
	rol
	rol
	jmp return

return:
	ply
	plx
	and #%00000011 												// zero out everything except bottom two bits
	rts
}

/**
 * Generate new food at random position and draw it
 */
 new_food: {
 	jsr galois16o 												// get random number in rng

	lda rng
	and #%00111111 												// take mod 64 for row
	tay
	lda rng+1
	and #%00111111 												// take mod 64 for col
	tax
	jsr read_pixel 												// read the pixel value at new rng location
	cmp #SNAKE_COLOR 											// check if it's the snake color
	beq new_food	 											// if it's on top of snake, retry

	lda rng
	and #%00111111 												// take mod 64 for row
	sta food_y
	tay
	lda rng+1
	and #%00111111
	sta food_x
	tax
	lda #FOOD_COLOR
	jsr write_pixel

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



.segment Variables [virtual, startAfter="Code", align=$100]
snake_x:
	.fill 256, 0
snake_y:
	.fill 256, 0
vars:
	.fill 16, 0
