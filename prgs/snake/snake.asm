.cpu _65c02
.encoding "ascii"
.filenamespace snake

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"
#import "../../lib/sid.lib"

.enum {UP, DOWN, LEFT, RIGHT}

.label not_eq = zp.D
.label head_ptr = zp.H
.label tail_ptr = zp.I
.label prev_tick = zp.J
.label curr_dir = zp.K
.label next_dir = zp.L
.label food_x = zp.M
.label food_y = zp.N
.label rng = zp.P 								// two bytes -- also uses zp.Q


.label game_timer = zp.cursor_blink_count
.const initial_length = 8

.const BG_COLOR = vid_cg1.YELLOW
.const SNAKE_COLOR = vid_cg1.BLUE
.const FOOD_COLOR = vid_cg1.RED

.segment Code [outPrg="snake.prg", start=$1000] 
reset:
#if PCB
	set_vid_mode_cg1()

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

	fill_vid_screen_cg1(BG_COLOR)

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
	cmp #64 													// check if we're out of Y bounds
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
	cmp #64 													// check if we're out of X bounds
	bcc in_x_bounds 											// if Y < 64, we're in bounds 
	jsr play_death_sound	
	jmp reset 													// otherwise, dead! reset.
in_x_bounds:
	tax
	cmp food_x
	beq is_food_x
	inc not_eq 												
is_food_x:

	jsr vid_cg1.read_pixel 										// read the pixel value at new head location
	cmp #SNAKE_COLOR 											// check if it's the snake color
	bne no_collision	 										// if not, we didn't collide.
	jsr play_death_sound
	jmp reset 													// otherwise, dead! reset.
no_collision:

	lda #SNAKE_COLOR
	jsr vid_cg1.write_pixel 											// draw the head

	lda not_eq
	bne not_food
	jsr play_food_sound
	jsr new_food
	jmp after_tail_update
not_food:
	
	ldx tail_ptr
	lda snake_y,x
	tay
	lda snake_x,x
	tax
	lda #BG_COLOR
	jsr vid_cg1.write_pixel 											// erase the tail

	inc tail_ptr
after_tail_update:
	
	pla
	rts


/**
 * Generate new food at random position and draw it
 */
 new_food: {
	jsr galois16o

	lda rng
	and #%00111111 												// take mod 64 for row
	tay
	lda rng+1
	and #%00111111 												// take mod 64 for col
	tax
	jsr vid_cg1.read_pixel 										// read the pixel value at new rng location
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
	jsr vid_cg1.write_pixel

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

wait:
	jsr kb.get_press
	beq wait

	mov #$00 : sid.voice1_control

	rts


note_table: 
	.lohifill 12, 440 * pow(2, (i+48)/12 - 4.75) / (1843200 / 16777216)



*=$2000 "Variables" virtual
snake_x:
	.fill 256, 0
snake_y:
	.fill 256, 0
curr_sound:
	.byte $00

