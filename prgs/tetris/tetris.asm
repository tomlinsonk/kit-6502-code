.cpu _65c02
.encoding "ascii"
.filenamespace tetris

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg3.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"
#import "../../lib/sid.lib"

.enum {J_ID=0, L_ID=1, S_ID=2, Z_ID=3, T_ID=4, O_ID=5, I_ID=6}


.label game_timer = zp.cursor_blink_count

.label rng = zp.B 			// 2 bytes: also uses zp.C
.label prev_tick = zp.D
.label tmp = zp.E
.label orientation = zp.F
.label ptr = zp.G 			// 2 bytes: also uses zp.H
.label x_stash = zp.I
.label y_stash = zp.J
.label old_orientation = zp.K
.label new_orientation = zp.L
.label cleared_line_index = zp.M



.const BG_COLOR = vid_cg3.YELLOW
.const BORDER_COLOR = vid_cg3.GREEN

.const BG_COLOR_4 = vid_cg3.YELLOW + (vid_cg3.YELLOW << 2) + (vid_cg3.YELLOW << 4) + (vid_cg3.YELLOW << 6)
.const BLUE_4 = vid_cg3.BLUE + (vid_cg3.BLUE << 2) + (vid_cg3.BLUE << 4) + (vid_cg3.BLUE << 6)
.const RED_4 = (vid_cg3.RED) + (vid_cg3.RED << 2) + (vid_cg3.RED << 4) + (vid_cg3.RED << 6)
.const GREEN_4 = vid_cg3.GREEN + (vid_cg3.GREEN << 2) + (vid_cg3.GREEN << 4) + (vid_cg3.GREEN << 6)


.const MAX_Y = 19

.segment Code [outPrg="tetris.prg", start=$1000] 
reset:
	set_vid_mode_cg3()
	init_sid_osc3_random()

get_rand_seed:
	lda sid.rand
	beq get_rand_seed
	sta rng

	fill_vid_screen_cg3(BORDER_COLOR)

	jsr draw_playfield
	jsr init_board

	mov game_timer : prev_tick

	stz orientation

	ldy #0
	ldx #5

	jsr get_random_piece

	jsr load_current_piece_color
	jsr draw_piece

loop:

	lda game_timer
	and #%11111000 						// only look at higher order bits to slow down
	cmp prev_tick
	beq no_tick
	
	sta prev_tick

try_down_move:
	iny
	jsr collision_check
	beq do_commit
	dey
	jmp move_down

do_commit:
	dey
	jsr commit

	jsr handle_line_clears

new_piece:
	ldy #0
	ldx #5
	stz orientation
	jsr get_random_piece

move_down:

	mov #BG_COLOR_4 : draw_color	// erase piece at old position
	jsr draw_piece

	iny

	jsr load_current_piece_color
	jsr draw_piece 					// draw piece at new position

no_tick:

	jsr kb.get_press

	beq loop

	cmp #kb.ASCII_SPACE
	bne not_space


	lda orientation
	sta old_orientation
	inc
	and #%00000011
	sta orientation
	sta new_orientation

	jsr collision_check
	bne do_rotation
	mov old_orientation : orientation
	jmp not_space

do_rotation:
	mov old_orientation : orientation

	mov #BG_COLOR_4 : draw_color
	jsr draw_piece

	mov new_orientation : orientation

	jsr load_current_piece_color
	jsr draw_piece

not_space:

	cmp #kb.K_LEFT
	bne not_left

	dex
	jsr collision_check
	bne do_left_move
	inx
	jmp not_left

do_left_move:
	inx
	mov #BG_COLOR_4 : draw_color
	jsr draw_piece

	dex

	jsr load_current_piece_color
	jsr draw_piece

not_left:


	cmp #kb.K_RIGHT
	bne not_right

	inx
	jsr collision_check
	bne do_right_move
	dex
	jmp not_right

do_right_move:

	dex
	mov #BG_COLOR_4 : draw_color
	jsr draw_piece

	inx

	jsr load_current_piece_color
	jsr draw_piece

not_right:

	cmp #kb.K_DOWN
	bne not_down
	jmp try_down_move
not_down:

	jmp loop


done:
	jmp done


/**
 * Draw a block at playfield coordinates X, Y (X = 1, ..., 10; Y = 0, ... 19)
 * Color based on draw_color
 */ 
draw_block: {
	pha
	phx
	phy

	jsr load_block_vid_ptr

	.for(var i=0; i<4; i++) {
		mov draw_color : (zp.vid_ptr)
		.if(i < 3) {
			clc
			add2 zp.vid_ptr : #32
		}
	}
	
	ply
	plx
	pla
	rts
}


/**
 * Load the color at playfield coordinates X, Y (X = 1, ..., 10; Y = 0, ... 19)
 * into draw_color
 */ 
load_block_color: {
	pha
	phx
	phy

	jsr load_block_vid_ptr

	mov (zp.vid_ptr) : draw_color

	ply
	plx
	pla
	rts
}


/**
 * Convert X, Y from playfield block coords to screen block coords and
 * load zp.vid_ptr with the address of the first block byte
 */ 
load_block_vid_ptr: {
	iny
	iny 						// add 2 to Y to get screen block coords

	txa 
	clc
	adc #10
	tax 						// Add 10 to X to get screen block coords

	// Block coords to byte: VRAM_START + Y * 4 * 32 + X

	// VRAM high byte: >VRAM_START + Y // 2
	lda #>vid_cg3.VRAM_START
	sta zp.vid_ptr+1
	tya
	lsr
	clc
	adc zp.vid_ptr+1
	sta zp.vid_ptr+1 


	// VRAM low byte: (Y % 2) * 128 + X
	mov #128 : zp.vid_ptr
	tya
	bit #$01
	bne y_odd
	stz zp.vid_ptr
y_odd:

	txa
	clc
	adc zp.vid_ptr
	sta zp.vid_ptr

	rts
}


/**
 * Draw the piece whose ID is in current_piece with its center at the coordinates X, Y
 * Uses orientation to determine which orientation the piece is in
 * ONLY SUPPORTS 3x3 bounded pieces for now
 */ 
draw_piece: {
	pha
	phx	
	phy

	lda current_piece

	cmp #I_ID
	bne not_I_piece
	jmp draw_I
not_I_piece:
	
	tay
	mov pieces_lo,y : ptr
	mov pieces_hi,y : ptr+1 	// put a pointer to the piece in ptr

	ldy orientation
	lda (ptr),y	 				// load the piece with the correct orientation into A

	ply
	phy

	dey
	dex 						// go to block coords X-1, Y-1

	phx 							
	.for(var col=0; col<3; col++) { 	// draw top row 
		rol
		bcc no_block
		jsr draw_block
	no_block:
		.if(col < 2) {
			inx
		}
	}

	iny

	plx
	phx 						// go to X-1, Y

	rol
	bcc no_middle_left
	jsr draw_block
no_middle_left:

	inx
	jsr draw_block 				// always draw middle block

	inx

	rol
	bcc no_middle_right
	jsr draw_block	
no_middle_right:

	iny
	plx									// go to X-1, Y+1

	.for(var col=0; col<3; col++) { 	// draw bottom row 
		rol
		bcc no_block
		jsr draw_block
	no_block:
		.if(col < 2) {
			inx
		}
	}

done_draw:
	ply
	plx
	pla
	rts


draw_I:
	jsr draw_block

	lda #$01
	bit orientation
	bne vertical

	inx
	jsr draw_block
	dex
	dex
	jsr draw_block
	dex
	jsr draw_block

	jmp done_draw

vertical:
	iny
	jsr draw_block
	dey
	dey
	jsr draw_block
	dey
	jsr draw_block

	jmp done_draw
}



/**
 * Check if the current piece can occupy playfield coordinates X, Y in its
 * orientation. If piece would collide, set A to 0 and set Z flag.
 * If no collision, set A to $FF and clear Z flag.  
 */ 
collision_check: {
	phx
	phy

	sty y_stash

	lda current_piece

	cmp #I_ID
	bne not_I_piece
	jmp check_I_collision
not_I_piece:
	
	tay
	mov pieces_lo,y : ptr
	mov pieces_hi,y : ptr+1 	// put a pointer to the piece in ptr

	ldy orientation
	lda (ptr),y	 				// load the piece with the correct orientation into A

	ldy y_stash 				// restore Y

	dey
	dex 						// go to block coords X-1, Y-1

	stx x_stash

	.for(var col=0; col<3; col++) { 	// check top row collisions
		rol
		bcc no_block
		pha
		jsr get_cell
		bne yes_collision
		pla
	no_block:
		.if(col < 2) {
			inx
		}
	}

	iny

	ldx x_stash 				// go to X-1, Y

	rol
	bcc no_middle_left
	pha
	jsr get_cell
	bne yes_collision
	pla 		
no_middle_left:

	inx							// always check middle block
	
	pha
	jsr get_cell
	bne yes_collision
	pla 				

	inx

	rol
	bcc no_middle_right
	pha
	jsr get_cell
	bne yes_collision
	pla 			
no_middle_right:

	iny
	ldx x_stash									// go to X-1, Y+1

	.for(var col=0; col<3; col++) { 	// check bottom row collisions
		rol
		bcc no_block
		pha
		jsr get_cell
		bne yes_collision
		pla 		
	no_block:
		.if(col < 2) {
			inx
		}
	}


no_collision:
	lda #$ff
	jmp done

yes_collision:
	pla
yes_collision_no_pull:
	lda #0

done:
	ply
	plx

	ora #0 					// Set Z flag if A is 0
	rts

check_I_collision: 			// TODO
	jsr get_cell
	bne yes_collision_no_pull

	lda #$01
	bit orientation
	bne vertical

	inx
	jsr get_cell
	bne yes_collision_no_pull

	dex
	dex
	jsr get_cell
	bne yes_collision_no_pull

	dex
	jsr get_cell
	bne yes_collision_no_pull

	jmp no_collision

vertical:

	iny
	jsr get_cell
	bne yes_collision_no_pull

	dey
	dey
	jsr get_cell
	bne yes_collision_no_pull

	dey
	jsr get_cell
	bne yes_collision_no_pull

	jmp no_collision


}


/**
 * Lock in the current piece in X, Y. Saves it to the board state
 */ 
commit: {
	pha
	phx
	phy

	sty y_stash
	
	lda current_piece

	cmp #I_ID
	bne not_I_piece
	jmp commit_I_piece
not_I_piece:
	
	tay
	mov pieces_lo,y : ptr
	mov pieces_hi,y : ptr+1 	// put a pointer to the piece in ptr

	ldy orientation
	lda (ptr),y	 				// load the piece with the correct orientation into A

	ldy y_stash 				// restore Y

	dey
	dex 						// go to block coords X-1, Y-1

	stx x_stash

	.for(var col=0; col<3; col++) { 	// check top row collisions
		rol
		bcc no_block
		jsr set_cell
	no_block:
		.if(col < 2) {
			inx
		}
	}

	iny

	ldx x_stash 				// go to X-1, Y

	rol
	bcc no_middle_left
	jsr set_cell	
no_middle_left:

	inx							// always set middle block
	
	jsr set_cell		

	inx

	rol
	bcc no_middle_right
	jsr set_cell
no_middle_right:

	iny
	ldx x_stash									// go to X-1, Y+1

	.for(var col=0; col<3; col++) { 	// check bottom row collisions
		rol
		bcc no_block
		jsr set_cell
	no_block:
		.if(col < 2) {
			inx
		}
	}


done:
	ply
	plx
	pla

	rts


commit_I_piece:

	jsr set_cell

	lda #$01
	bit orientation
	bne vertical

	inx
	jsr set_cell

	dex
	dex
	jsr set_cell


	dex
	jsr set_cell

	jmp done

vertical:

	iny
	jsr set_cell


	dey
	dey
	jsr set_cell


	dey
	jsr set_cell

	jmp done
}


/**
 * Put the draw color of current_piece into draw_color
 */ 
load_current_piece_color: {
	pha
	mov #RED_4 : draw_color 				// default to red
	
	lda current_piece

	cmp #T_ID
	bcc not_blue
	mov #BLUE_4: draw_color
	jmp done
not_blue:

	bit #$01
	beq done
	mov #GREEN_4: draw_color

done:
	pla
	rts
}


/**
 * Set the timer speed to the value loaded in A
 */ 
set_speed: {
    stz via.T1_LO                       			// write all 0s to timer 1 lo
    sta via.T1_HI                       			// write all 1s to timer 1 hi, starting the timer

	rts
}






/**
 * Set the current piece to a random one. Uses NES Tetris logic:
 * 1) generate random num 0-7. If 7 or equal to previous piece do roll 2.
 *    otherwise, return piece id
 * 2) generate random num 0-6, use piece
 */ 
get_random_piece: {
	pha
	phy
	phx
	jsr galois16o

	lda rng
	and #%00000111

	cmp current_piece
	beq second_try

	cmp #7
	beq second_try

	jmp done

second_try:
	lda rng+1

subtract:
	cmp #7
	bcc done
	sec
	sbc #7
	jmp subtract

done:
	sta current_piece
plx
	ply
	pla
	rts
}


/**
 * Draw the UI and playfield
 */ 
draw_playfield:
	pha
	phx
	phy

	mov #BG_COLOR_4 : draw_color

	ldy #19

row_loop:
	ldx #10
col_loop:
	jsr draw_block
	dex
	bne col_loop
	dey
	bpl row_loop

	ply
	plx
	pla
	rts


/**
 * Initialize the board to empty. Then fill in the dummy blocks
 * surrounding the playfield for wall collision detection
 */ 
init_board: {
	pha
	phx
	phy

	ldx #0
clear_board_loop:
	stz board,x
	inx
	bne clear_board_loop


	ldx #0
	ldy #19
left_loop:
	jsr set_cell
	dey
	bpl left_loop

	ldx #11
	ldy #19
right_loop:
	jsr set_cell
	dey
	bpl right_loop


	ldx #11
	ldy #20
bottom_loop:
	jsr set_cell
	dex
	bpl bottom_loop

	ply
	plx
	pla
	rts
}

/**
 * Set the board cell X, Y to filled 
 */ 
set_cell:
	pha
	phx

	get_board_offset()
	tax 					// put board offset in x

	lda #$ff
	sta board,x

	plx
	pla
	rts


/**
 * Set the board cell X, Y to empty 
 */ 
clear_cell:
	pha
	phx

	get_board_offset()
	tax 					// put board offset in x

	stz board,x

	plx
	pla
	rts


/**
 * Check if board cell X, Y is filled
 * Sets a to $ff if filled, 0 otherwise (and sets Z flag)
 */ 
get_cell:
	phx

	get_board_offset()
	tax 					// put board offset in x

	lda board,x

	plx
	ora #0 					// set Z flag according to board
	rts


/**
 * Convert X, Y index into board array offset
 * Puts offset in A
 */ 
.macro get_board_offset() {
	tya 				// Compute index into board
	asl
	asl
	sta tmp	
	asl
	clc
	adc tmp 			// Multiply Y by 12 (= 8Y + 4Y)

	stx tmp
	adc tmp 			// ... and add X			
}



/**
 * Check if any lines have been cleared and handle them.
 */ 
handle_line_clears: {
	pha
	phx
	phy

	.for(var i=0; i<5; i++) {
		stz cleared_lines + i 	// reset cleared lines
	}

	stz cleared_line_index

	ldy #MAX_Y

row_loop:
	ldx #0
col_loop:

	jsr get_cell
	bne has_block 			// check if col has block
	dey
	bpl row_loop 			// if next row exists, go to next row

	jmp shift_lines 	// otherwise, done checking for clears. Shift lines


has_block:
	inx
	cpx #11
	bcc col_loop 			// check next column if next column exists

	// else, row cleared!
	dex
	mov #BG_COLOR_4 : draw_color
erase_row_loop:
	jsr draw_block
	jsr delay
	dex
	bne erase_row_loop

	ldx cleared_line_index
	tya
	sta cleared_lines,x
	inc cleared_line_index 	// store line cleared
	
	dey
	bpl row_loop 			// check next row, if it exists



	// for each cleared line in reverse order, shift everything above it down one, both in board state and screen
shift_lines:
	dec cleared_line_index
	bmi done

	phx
	ldx cleared_line_index
	lda cleared_lines,x
	plx

	tay

shift_loop:
	ldx #10

shift_row_loop:
	dey
	jsr get_cell
	beq empty
	iny
	jsr set_cell

	// jsr load_block_color
	mov #BLUE_4 : draw_color
	jsr draw_block

	jmp next_col

empty:
	iny
	jsr clear_cell
	mov #BG_COLOR_4 : draw_color
	jsr draw_block

next_col:
	dex
	bne shift_row_loop
	dey
	cpy #1
	bcs shift_loop
	jmp shift_lines
							
done:
	ply
	plx
	pla
	rts
}




/**
 * Short delay
 */ 
delay: {
	pha
	phx
	phy

	ldx #50
	ldy #0	
loop:
	dey
	bne loop
	dex
	bne loop

	ply
	plx
	pla

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


.align $100
pieces_lo:
	.byte <j_piece, <l_piece, <s_piece, <z_piece, <t_piece,  <o_piece

pieces_hi:
	.byte >j_piece, >l_piece, >s_piece, >z_piece, >t_piece,  >o_piece

j_piece:
	.byte %00011001, %01000110, %10011000, %01100010

l_piece:
	.byte %00011100, %11000010, %00111000, %01000011

s_piece:
	.byte %00001110, %01001001, %00001110, %01001001

z_piece:
	.byte %00010011, %00101010, %00010011, %00101010

t_piece:
	.byte %00011010, %01010010, %01011000, %01001010

o_piece:
	.byte %00001011, %00001011, %00001011, %00001011


.segment Variables [virtual, startAfter="Code", align=$100] 
board:
	.fill 256, $00

cleared_lines:
	.fill 5, $00

score:
	.word $0000

current_piece:
	.byte $00

draw_color:
	.byte $00


