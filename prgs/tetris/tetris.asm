/**
 * KiT Tetris 
 * @author Kiran Tomlinson
 * 
 * Original game designed by Alexey Pajitnov
 * 
 * Todos:
 * - Top-out detection
 * - Playfield border
 * - Scoring - check!
 *   - High scores
 * - NES controller input
 * - Two player mode???
 * - Sound
 * 	 - Music
 *   - Sound effects
 */  



.cpu _65c02
.encoding "ascii"
.filenamespace tetris

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/math.lib"
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


.const NEXT_X = 14
.const NEXT_Y = 10

.const MAX_Y = 19
.const SPAWN_X = 6


// Sound constants
.label OFF = %00000000
.label TIMER_INT_HI = $60
.const SH = $f0 
.const LOOP = $fe
.const END = $ff


.segment Code [outPrg="tetris.prg", start=$1000] 
reset:
	set_vid_mode_cg3()
	init_sid_osc3_random()

	jsr setup_sid

	jsr high_scores.ensure_score_file

get_rand_seed:
	lda sid.rand
	beq get_rand_seed
	sta rng

	fill_vid_screen_cg3(BORDER_COLOR)

	jsr draw_playfield
	jsr init_board

	mov game_timer : prev_tick

	stz orientation
	stz current_piece 
	stz next_piece

	ldy #0
	ldx #SPAWN_X

	mov2 #0 : score
	jsr display_score

	jsr get_random_piece
	jsr draw_next_piece

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
	ldy #-1
	ldx #SPAWN_X
	stz orientation
	jsr get_random_piece
	jsr draw_next_piece

    jsr collision_check             // if new piece collides, game over!
    bne move_down
    jmp game_over

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


game_over:
	jsr high_scores.display_high_scores

wait:
	jsr kb.get_press
	beq wait

	cmp #kb.ASCII_NEWLINE
	bne wait

	jmp reset


/**
 * Draw a block at playfield coordinates X, Y (X = 1, ..., 10; Y = 0, ... 19)
 * Color based on draw_color
 */ 
draw_block: {
	pha
	phx
	phy

	cpy #(MAX_Y+1)
	bcs done

	jsr load_block_vid_ptr

	.for(var i=0; i<4; i++) {
		mov draw_color : (zp.vid_ptr)
		.if(i < 3) {
			clc
			add2 zp.vid_ptr : #32
		}
	}
	
done:
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
		jsr has_mino
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
	jsr has_mino
	bne yes_collision
	pla 		
no_middle_left:

	inx							// always check middle block
	
	pha
	jsr has_mino
	bne yes_collision
	pla 				

	inx

	rol
	bcc no_middle_right
	pha
	jsr has_mino
	bne yes_collision
	pla 			
no_middle_right:

	iny
	ldx x_stash									// go to X-1, Y+1

	.for(var col=0; col<3; col++) { 	// check bottom row collisions
		rol
		bcc no_block
		pha
		jsr has_mino
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

check_I_collision: 			// 
	jsr has_mino
	bne yes_collision_no_pull

	lda #$01
	bit orientation
	bne vertical

	inx
	jsr has_mino
	bne yes_collision_no_pull

	dex
	dex
	jsr has_mino
	bne yes_collision_no_pull

	dex
	jsr has_mino
	bne yes_collision_no_pull

	jmp no_collision

vertical:

	iny
	jsr has_mino
	bne yes_collision_no_pull

	dey
	dey
	jsr has_mino
	bne yes_collision_no_pull

	dey
	jsr has_mino
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
		jsr set_mino
	no_block:
		.if(col < 2) {
			inx
		}
	}

	iny

	ldx x_stash 				// go to X-1, Y

	rol
	bcc no_middle_left
	jsr set_mino	
no_middle_left:

	inx							// always set middle block
	
	jsr set_mino		

	inx

	rol
	bcc no_middle_right
	jsr set_mino
no_middle_right:

	iny
	ldx x_stash									// go to X-1, Y+1

	.for(var col=0; col<3; col++) { 	// check bottom row collisions
		rol
		bcc no_block
		jsr set_mino
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

	jsr set_mino

	lda #$01
	bit orientation
	bne vertical

	inx
	jsr set_mino

	dex
	dex
	jsr set_mino


	dex
	jsr set_mino

	jmp done

vertical:

	iny
	jsr set_mino


	dey
	dey
	jsr set_mino


	dey
	jsr set_mino

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
 * Set the current piece to next piece and set next piece to a random one. 
 * Uses NES Tetris logic:
 * 1) generate random num 0-7. If 7 or equal to previous piece do roll 2.
 *    otherwise, return piece id
 * 2) generate random num 0-6, use piece
 */ 
get_random_piece: {
	pha
	phy
	phx

	mov next_piece : current_piece

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
	sta next_piece
	plx
	ply
	pla
	rts
}



/**
 * Draw the next piece in the "next" square
 */ 
draw_next_piece: {
	pha
	phx
	phy

	ldx #NEXT_X
	ldy #NEXT_Y

	mov #BG_COLOR_4 : draw_color
	jsr draw_piece

	lda current_piece
	pha

	mov next_piece : current_piece
	jsr load_current_piece_color
	jsr draw_piece

	pla
	sta current_piece

	ply
	plx
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

	ldy #MAX_Y

row_loop:
	ldx #10
col_loop:
	jsr draw_block
	dex
	bne col_loop
	dey
	bpl row_loop

	ldy #12

ns_row_loop:
	ldx #16
ns_col_loop:

	jsr draw_block
	dex
	cpx #11
	bne ns_col_loop
	dey
	cpy #8
	bne ns_row_loop

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
	jsr set_mino
	dey
	bpl left_loop

	ldx #11
	ldy #19
right_loop:
	jsr set_mino
	dey
	bpl right_loop


	ldx #11
	ldy #20
bottom_loop:
	jsr set_mino
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
set_mino: {
	pha
	phx

	lda #0
	cpy #(MAX_Y+2)
	bcs done

	jsr get_board_offset
	tax 					// put board offset in x

	lda #$ff
	sta board,x

done:
	plx
	pla
	rts
}

/**
 * Set the board cell X, Y to empty 
 */ 
clear_mino: {
	pha
	phx

	cpy #(MAX_Y+2)
	bcs done

	jsr get_board_offset
	tax 					// put board offset in x

	stz board,x

done:
	plx
	pla
	rts
}

/**
 * Check if board cell X, Y is filled
 * Sets a to $ff if filled, 0 otherwise (and sets Z flag)
 */ 
has_mino: {
	phx

	lda #0
	cpy #(MAX_Y+2)
	bcs done

	jsr get_board_offset
	tax 					// put board offset in x

	lda board,x

done:
	plx
	ora #0 					// set Z flag according to board
	rts
}

/**
 * Convert X, Y index into board array offset
 * Puts offset in A
 */ 
get_board_offset: {
	tya 				// Compute index into board
	asl
	asl
	sta tmp	
	asl
	clc
	adc tmp 			// Multiply Y by 12 (= 8Y + 4Y)

	stx tmp
	adc tmp 			// ... and add X
	rts			
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

	jsr has_mino
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

delay:
    phx
    phy
    ldx #40
	ldy #0	
delay_loop:
	dey
	bne delay_loop
	dex
	bne delay_loop

    ply
    plx

	dex
	bne erase_row_loop

	ldx cleared_line_index
	tya
	sta cleared_lines,x
	inc cleared_line_index 	// store line cleared
	inc2 score
	jsr display_score

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
	jsr has_mino
	beq empty
	jsr load_block_color
	iny
	jsr set_mino

	jsr draw_block

	jmp next_col

empty:
	iny
	jsr clear_mino
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
 * Display the current score
 */ 
display_score: {
	pha
	phx
	phy

	mov2 score : math.dividend
	mov2 #(vid_cg3.VRAM_START + 25 + 32*36) : zp.vid_ptr


divide_loop:
	mov2 #10 : math.divisor
	jsr math.divide16

	lda math.remainder
	asl
	asl							// multiply by 4

	clc
	adc math.remainder
	adc math.remainder			// add 2*remainder to get 6*remainder for table offset
	tax

	ldy #6
digit_loop:

	lda font_numbers,x
	sta (zp.vid_ptr)
	inx
	add2 zp.vid_ptr : #32
	dey
	bne digit_loop

	lda math.dividend+1
	bne next_digit
	lda math.dividend
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



setup_sid: {
	lda #%10000010
	sta sid.res_filter

	mov2 #$1fff : sid.filter_cutoff

	lda #$1F
	sta sid.mode_vol

	lda #$ff
	sta track_curr_note
	sta track_curr_note + 1
	sta track_curr_note + 2

	stz track_duration_left
	stz track_duration_left + 1
	stz track_duration_left + 2

	sei
	mov2 #irq : zp.irq_addr 
	lda via.IER
	ora #(via.INT_ENABLE | via.TIMER2_INT)
	sta via.IER 									// enable timer 2 interrupts
	
	stz via.T2_LO                                   // set up timer 2 for 50Hz interrupts
    ldx #TIMER_INT_HI
    stx via.T2_HI
	cli

	rts
}


music_irq: {
    pha

    ldx #0
    jsr play_track
    ldx #1
    jsr play_track
    ldx #2
    jsr play_track

music_irq_done:
    pla
    rts
}


// Play track number in X
play_track: {

    // Check if the current note is done; if not, just decrement the duration
    lda track_duration_left,x
    beq new_note
    dec track_duration_left,x
    jmp done

    // Play a new note
new_note:
    // Set up the zp addr registers for this track
    lda track_lengths_lo,x
    sta zp.sid_ptr
    lda track_lengths_hi,x
    sta zp.sid_ptr+1

    inc track_curr_note,x
    ldy track_curr_note,x
    lda (zp.sid_ptr),y
    dec
    sta track_duration_left,x

    lda track_notes_lo,x
    sta zp.sid_ptr
    lda track_notes_hi,x
    sta zp.sid_ptr+1

    lda (zp.sid_ptr),y
    cmp #LOOP
    bne play_note
    // If the track is done, immediately loop
    mov #$ff : track_curr_note,x
    stz track_duration_left,x
    jmp play_track

play_note:
    jsr sid.setup_voice_registers
    cmp #SH
    beq do_rest

    tay
    mov note_table.lo,y : (zp.sid_freq_addr)
    lda note_table.hi,y
    ldy #1
    sta (zp.sid_freq_addr),y

    mov inst_atk_dec,x : (zp.sid_atk_dec_addr)
    mov inst_sus_rel,x : (zp.sid_sus_rel_addr)
    mov inst_pw_lo,x : (zp.sid_pw_addr)
    mov inst_pw_hi,x : (zp.sid_pw_addr),y
    mov inst_control,x : (zp.sid_control_addr)

    jmp done

do_rest:
    lda #OFF
    sta (zp.sid_control_addr)

done:
    rts
}

/**
* Special interrupt handler for music playing!
*/
irq: {
    phx                                                     // stash X on stack
    tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    inx 
    inx                                                     // increment X twice so it points to the processor flags
    lda $100,x                                              // load the processor flags on the stack
    and #$10                                                // check for brk
    beq no_break                                            // if break bit is set, go to break handler
    jmp break
no_break:
    phy
       
    lda via.IFR

    ror
//     bcc no_ca2_irq
//     handle_ca2_irq()
// no_ca2_irq:

    ror 
    bcc no_ca1_irq
    handle_kb_irq()   
no_ca1_irq:

    ror
//     bcc no_shift_irq
//     handle_shift_irq()
// no_shift_irq:

    ror
//     bcc no_cb2_irq
//     handle_cb2_irq()
// no_cb2_irq:

    ror
//     bcc no_cb1_irq
//     handle_cb1_irq()
// no_cb1_irq:

    ror
    bcc no_timer2_irq
    stz via.T2_LO                                                   // write zeros to timer 2 lo
    ldx #TIMER_INT_HI
    stx via.T2_HI
    jsr music_irq 
no_timer2_irq:

    ror
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    // check_and_handle_uart_irq()

    ply
    pla
    plx
    rti
}


// .align $100
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


font_numbers:
	// .byte 101,153,153,153,101,85    // 0; yellow background
	// .byte 101,165,101,101,169,85    // 1
	// .byte 165,89,101,149,169,85     // 2
	// .byte 169,89,105,89,169,85      // 3
	// .byte 153,153,169,89,89,85      // 4
	// .byte 169,149,169,89,165,85     // 5
	// .byte 105,149,169,153,169,85    // 6
	// .byte 169,89,101,149,149,85     // 7
	// .byte 169,153,169,153,169,85    // 8
	// .byte 169,153,169,89,165,85     // 9
	.byte 32,136,136,136,32,0    	// 0; green background
	.byte 32,160,32,32,168,0    	// 1
	.byte 160,8,32,128,168,0    	// 2
	.byte 168,8,40,8,168,0    		// 3
	.byte 136,136,168,8,8,0    		// 4
	.byte 168,128,168,8,160,0    	// 5
	.byte 40,128,168,136,168,0    	// 6
	.byte 168,8,32,128,128,0    	// 7
	.byte 168,136,168,136,168,0    	// 8
	.byte 168,136,168,8,160,0    	// 9



// --------------------------------- MUSIC -----------------------------------------
// Notes! For easier typing 
.const C0 = 0
.const c0 = 1
.const D0 = 2
.const d0 = 3
.const E0 = 4
.const F0 = 5
.const f0 = 6
.const G0 = 7
.const g0 = 8
.const A0 = 9
.const a0 = 10
.const B0 = 11
.const C1 = 12
.const c1 = 13
.const D1 = 14
.const d1 = 15
.const E1 = 16
.const F1 = 17
.const f1 = 18
.const G1 = 19
.const g1 = 20
.const A1 = 21
.const a1 = 22
.const B1 = 23
.const C2 = 24
.const c2 = 25
.const D2 = 26
.const d2 = 27
.const E2 = 28
.const F2 = 29
.const f2 = 30
.const G2 = 31
.const g2 = 32
.const A2 = 33
.const a2 = 34
.const B2 = 35
.const C3 = 36
.const c3 = 37
.const D3 = 38
.const d3 = 39
.const E3 = 40
.const F3 = 41
.const f3 = 42
.const G3 = 43
.const g3 = 44
.const A3 = 45
.const a3 = 46
.const B3 = 47
.const C4 = 48
.const c4 = 49
.const D4 = 50
.const d4 = 51
.const E4 = 52
.const F4 = 53
.const f4 = 54
.const G4 = 55
.const g4 = 56
.const A4 = 57
.const a4 = 58
.const B4 = 59
.const C5 = 60
.const c5 = 61
.const D5 = 62
.const d5 = 63
.const E5 = 64
.const F5 = 65
.const f5 = 66
.const G5 = 67
.const g5 = 68
.const A5 = 69
.const a5 = 70
.const B5 = 71
.const C6 = 72
.const c6 = 73
.const D6 = 74
.const d6 = 75
.const E6 = 76
.const F6 = 77
.const f6 = 78
.const G6 = 79
.const g6 = 80
.const A6 = 81
.const a6 = 82
.const B6 = 83
.const C7 = 84
.const c7 = 85
.const D7 = 86
.const d7 = 87
.const E7 = 88
.const F7 = 89
.const f7 = 90
.const G7 = 91
.const g7 = 92
.const A7 = 93
.const a7 = 94

// Compute the lo and hi bytes for 8 octaves (C0 - B7) of notes
// Based on A4 = 440Hz and a 1.8432Mhz clock
note_table: 
	.lohifill 96, 440 * pow(2, i/12 - 4.75) / (1843200 / 16777216)



track_notes_lo:
	.byte <track1_notes, <track2_notes, <track3_notes

track_notes_hi:
	.byte >track1_notes, >track2_notes, >track3_notes

track_lengths_lo:
	.byte <track1_lengths, <track2_lengths, <track3_lengths

track_lengths_hi:
	.byte >track1_lengths, >track2_lengths, >track3_lengths


// Index into note_table
track1_notes:
	.byte  E5,  SH,  B4,  SH,  C5,  SH,  D5,  SH
	.byte  C5,  SH,  B4,  SH,  A4,  SH,  A4,  SH
	.byte  C5,  SH,  E5,  SH,  D5,  SH,  C5,  SH
	.byte  B4,  SH,  C5,  SH,  D5,  SH,  E5,  SH
	.byte  C5,  SH,  A4,  SH,  A4,  SH
	.byte  SH,  D5,  SH,  F5,  SH,  A5,  SH,  G5
	.byte  SH,  F5,  SH,  E5,  SH,  C5,  SH,  E5
	.byte  SH,  D5,  SH,  C5,  SH,  B4,  SH,  B4
	.byte  SH,  C5,  SH,  D5,  SH,  E5,  SH,  C5
	.byte  SH,  A4,  SH,  A4,  SH, LOOP

track1_lengths:
	.byte  16,  16,  04,  12,  04,  12,  16,  16
	.byte  04,  12,  04,  12,  16,  16,  04,  12
	.byte  04,  12,  16,  16,  04,  12,  04,  12
	.byte  32,  16,  04,  12,  16,  16,  16,  16
	.byte  16,  16,  16,  16,  48,  16
	.byte  16,  16,  16,  04,  12,  16,  16,  04
	.byte  12,  04,  12,  32,  16,  04,  12,  16
	.byte  16,  04,  12,  04,  12,  16,  16,  04
	.byte  12,  04,  12,  16,  16,  16,  16,  16
	.byte  16,  16,  16,  16,  48, LOOP


track2_notes:
	.byte  E2,  SH,  E3,  SH,  E2,  SH,  E3,  SH
	.byte  E2,  SH,  E3,  SH,  E2,  SH,  E3,  SH
	.byte  A2,  SH,  A3,  SH,  A2,  SH,  A3,  SH
	.byte  A2,  SH,  A3,  SH,  A2,  SH,  A3,  SH
	.byte  g2,  SH,  g3,  SH,  g2,  SH,  g3,  SH
	.byte  g2,  SH,  g3,  SH,  g2,  SH,  g3,  SH
	.byte  A2,  SH,  A3,  SH,  A2,  SH,  A3,  SH
	.byte  A2,  SH,  A3,  SH,  B2,  SH,  C3,  SH
	.byte  D3,  SH,  D2,  SH,  D3,  SH,  D2,  SH
	.byte  D3,  SH,  D2,  SH,  A2,  SH,  F2,  SH
	.byte  C2,  SH,  C3,  SH,  C2,  SH,  C3,  SH
	.byte  C2,  SH,  C3,  SH,  G2,  SH,  G3,  SH
	.byte  B2,  SH,  B3,  SH,  B2,  SH,  B3,  SH
	.byte  E2,  SH,  E3,  SH,  g2,  SH,  g3,  SH
	.byte  A2,  SH,  E3,  SH,  A2,  SH,  E3,  SH
	.byte  A2,  SH, LOOP

track2_lengths:
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  60, LOOP




track3_notes:
	.byte  SH, a7, SH,  a7, SH,  a7, SH, a7
	.byte  SH, a7, SH,  a7, SH
	.byte  SH, a7, SH,  a7, SH,  a7, SH, a7
	.byte  SH, a7, SH, LOOP


track3_lengths:
	.byte  16,  04,  28,  04,  28,  04,  04,  04
	.byte  04,  04,  12,  04,  12
	.byte  16,  04,  28,  04,  28,  04,  12,  04
	.byte  12,  04,  12, LOOP

// track3_insts:
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02
// 	.byte  02,  02,  02,  02,  02
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02
// 	.byte  02,  02,  02, END



// Instruments
inst_pw_lo:
	.byte $40, $80, $00
inst_pw_hi:
	.byte $80, $00, $80
inst_atk_dec:
	.byte $62, $88, $14
inst_sus_rel:
	.byte $6d, $8a, $33
inst_control:
	.byte $21, $41, $81

#import "high-scores.asm"


.segment Variables [virtual, startAfter="Code", align=$100] 
board:
	.fill 256, $00

cleared_lines:
	.fill 5, $00

score:
	.word $0000

current_piece:
	.byte $00

next_piece:
	.byte $00

draw_color:
	.byte $00


// Music
track_duration_left:
    .byte $00, $00, $00
track_curr_note:
    .byte $00, $00, $00


high_score_file:
	.fill 256, $00
