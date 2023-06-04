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
.label ptr = zp.G 			// 2 bytes: also uses zp.GH

.const BG_COLOR = vid_cg3.YELLOW
.const BLUE = vid_cg3.BLUE
.const RED = vid_cg3.RED
.const GREEN = vid_cg3.GREEN
.const MAX_Y = 23

.segment Code [outPrg="tetris.prg", start=$1000] 
reset:
	set_vid_mode_cg3()
	init_sid_osc3_random()

get_rand_seed:
	lda sid.rand
	beq get_rand_seed
	sta rng

	fill_vid_screen_cg3(BG_COLOR)

	mov game_timer : prev_tick

	stz orientation

	ldy #0
	ldx #10

	jsr get_random_piece


	jsr load_current_piece_color
	jsr draw_piece

loop:

	lda game_timer
	and #%11111000 						// only look at higher order bits to slow down
	cmp prev_tick
	beq no_tick
	
	sta prev_tick

	mov #BG_COLOR : draw_color
	jsr draw_piece

	cpy #MAX_Y
	bne not_bottom
	ldy #0
	jsr get_random_piece
not_bottom:
	iny

	jsr load_current_piece_color
	jsr draw_piece

no_tick:

	jsr kb.get_press

	beq loop

	cmp #kb.ASCII_SPACE
	bne not_space

	mov #BG_COLOR : draw_color
	jsr draw_piece

	lda orientation
	inc
	and #%00000011
	sta orientation

	jsr load_current_piece_color
	jsr draw_piece

not_space:

	cmp #kb.K_LEFT
	bne not_left

	mov #BG_COLOR : draw_color
	jsr draw_piece

	dex

	jsr load_current_piece_color
	jsr draw_piece

not_left:


	cmp #kb.K_RIGHT
	bne not_right

	mov #BG_COLOR : draw_color
	jsr draw_piece

	inx

	jsr load_current_piece_color
	jsr draw_piece

not_right:



	jmp loop





// 	ldy #4
// 	ldx #4


// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #J_ID : current_piece
// 		jsr load_current_piece_color
// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}

// 	ldy #4
// 	ldx #8

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #L_ID : current_piece
// 		jsr load_current_piece_color
// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}


// 	ldy #4
// 	ldx #12

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #S_ID : current_piece
// 		jsr load_current_piece_color
// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}


// 	ldy #4
// 	ldx #16

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #Z_ID : current_piece
// 		jsr load_current_piece_color	
// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}

// 	ldy #4
// 	ldx #20

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #T_ID : current_piece
// 		jsr load_current_piece_color

// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}

// 	ldy #4
// 	ldx #24

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #O_ID : current_piece
// 		jsr load_current_piece_color
// 		jsr draw_piece

// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}

// 	ldy #4
// 	ldx #30

// 	.for(var i=0; i<4; i++) {
// 		mov #i : orientation
// 		mov #I_ID : current_piece
// 		jsr load_current_piece_color

// 		jsr draw_piece
// 		tya
// 		clc 
// 		adc #4
// 		tay
// 	}




// // wait_for_tick:
// // 	lda game_timer
// // 	cmp prev_tick
// // 	beq wait_for_tick

// // 	sta prev_tick

// // 	lda #BG_COLOR
// // 	jsr draw_block

// // 	iny
// // 	cpy #80
// // 	bne loop

done:
	jmp done



/**
 * Draw a 4x4 pixel square at the block coords X, Y
 */ 
draw_block:
	pha
	phx
	phy

	cpy #(MAX_Y+1)
	bcs no_draw

	txa
	asl
	asl
	tax 				// multiply X by 4 to convert form block coords to pixel

	tya
	asl
	asl
	tay 				// multiply Y by 4 to convert form block coords to pixel
	
	phy 				// stash Y pixel coord

	lda draw_color

	.for(var j=0; j<4; j++) {
		.for(var i=0; i<4; i++) {		
			jsr vid_cg3.write_pixel 		// could optimize this *a lot*
			iny
		}
		ply
		inx
		.if(j < 3) {
			phy
		}
		
	}

no_draw:
	ply
	plx
	pla
	rts



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
 * Put the draw color of current_piece into draw_color
 */ 
load_current_piece_color: {
	pha
	mov #RED : draw_color 				// default to red
	
	lda current_piece

	cmp #T_ID
	bcc not_blue
	mov #BLUE: draw_color
	jmp done
not_blue:

	bit #$01
	beq done
	mov #GREEN: draw_color

done:
	pla
	rts
}


/**
 * Set the speed to the value loaded in A
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
 * Set the board cell X, Y to filled 
 */ 
set_board:
	pha

	get_board_offset()
	tax 					// put board offset in x

	lda #$ff
	sta board,x

	pla
	rts

/**
 * Check if board cell X, Y is filled
 * Sets a to $ff if filled, 0 otherwise (and sets Z flag)
 */ 
get_board:

	get_board_offset()
	tax 					// put board offset in x

	lda board,x
	ora #0 					// set Z flag according to board

	rts


/**
 * Convert X, Y index into board array offset
 * Puts offset in A
 */ 
.macro get_board_offset() {
	tya 				// Compute index into board
	asl
	sta tmp
	asl
	asl
	clc
	adc tmp 			// Multiply Y by 10 (= 8Y + 2Y)

	stx tmp
	adc tmp 			// ... and add X			
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
	.fill 200, $00


score:
	.word $0000

current_piece:
	.byte $00

draw_color:
	.byte $00


