.cpu _65c02
.encoding "ascii"
.filenamespace pong

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_rg1.lib"
#import "../../lib/kb.lib"

.enum {UP, DOWN, NONE}


.label ball_x = zp.D
.label ball_y = zp.E
.label ball_vx = zp.F
.label ball_vy = zp.G
.label prev_tick = zp.H
.label left_y = zp.I
.label right_y = zp.J
.label extended_next = zp.K 
.label release_next = zp.L
.label stash = zp.M



.label rng = zp.P 								// two bytes -- also uses zp.Q

.label game_timer = zp.cursor_blink_count

.const start_y = 30
.const paddle_size = 12

.const MAX_X = 127
.const MAX_Y = 63
.const LEFT_X = 7
.const RIGHT_X = 120


.segment Code [outPrg="pong.prg", start=$1000] 
reset:

// 	stz release_next
// 	stz extended_next 

// 	set_vid_mode_text()
// 	jsr vid.blank_screen


// 	clear_held_loop:
// 	stz held_keys,x
// 	inx
// 	bne clear_held_loop

// 	// lda zp.kb_read_ptr
// 	// jsr vid.write_hex
// 	// lda zp.kb_write_ptr
// 	// jsr vid.write_hex

// loop:
// 	jsr update_held_keys
// 	jmp loop


	set_vid_mode_rg1()

	jsr vid_rg1.clear_screen

	lda #start_y
	sta left_y
	sta right_y

	stz release_next
	stz extended_next 

	ldx #0
clear_held_loop:
	stz held_keys,x
	inx
	bne clear_held_loop


	ldx #64
	stx ball_x
	ldy #start_y
	sty ball_y
	jsr vid_rg1.set_pixel

	lda #1
	sta ball_vx
	sta ball_vy

	ldy #start_y
left_loop:
	ldx #(LEFT_X + 1)
	jsr vid_rg1.set_pixel
	ldx #LEFT_X
	jsr vid_rg1.set_pixel
	iny
	cpy #(start_y + paddle_size)
	bcc left_loop

	ldy #start_y
right_loop:
	ldx #RIGHT_X
	jsr vid_rg1.set_pixel
	ldx #(RIGHT_X-1)
	jsr vid_rg1.set_pixel	
	iny
	cpy #(start_y + paddle_size)
	bcc right_loop

loop:
	jsr update_held_keys

no_press:

	sei
	lda game_timer
	cmp prev_tick
	cli

	beq loop
	sta prev_tick

{
	ldx #kb.K_UP
	lda held_keys,x
	beq not_up
	jsr move_right_up
not_up:

	ldx #kb.K_DOWN
	lda held_keys,x
	beq not_down
	jsr move_right_down
not_down:

	ldx #kb.K_W
	lda held_keys,x
	beq not_w
	jsr move_left_up
not_w:

	ldx #kb.K_S
	lda held_keys,x
	beq not_s
	jsr move_left_down
not_s:
}
	
	jsr wall_bounce
	jsr paddle_bounce
	jsr check_for_score

	ldx ball_x
	ldy ball_y
	jsr vid_rg1.clear_pixel

	clc
	lda ball_vx
	adc ball_x
	sta ball_x

	clc
	lda ball_vy
	adc ball_y
	sta ball_y

	ldx ball_x
	ldy ball_y
	jsr vid_rg1.set_pixel

	jmp loop


wall_bounce: {
	lda ball_y
	beq bounce

	cmp #MAX_Y
	bne done

bounce:
	sec
	lda #0
	sbc ball_vy
	sta ball_vy

done:
	rts

}


paddle_bounce: {
	ldx ball_x
	ldy ball_y

	lda ball_vy
	clc
	adc ball_y 							// load ball y+vy into A 
	sta stash

	cpx #(LEFT_X+2)
	bne not_left_bounce
	dex
	jsr vid_rg1.read_pixel
	bne bounce 							// bounce if pixel left of ball is paddle
	ldy stash
	jsr vid_rg1.read_pixel
	bne bounce 							// also bounce if pixel left of ball + vy is paddle
	ldy ball_y
not_left_bounce:

	cpx #(RIGHT_X-2)
	bne done

	inx
	jsr vid_rg1.read_pixel
	bne bounce
	ldy stash
	jsr vid_rg1.read_pixel
	beq done


bounce:
	lda left_y
	cpx #(MAX_X/2) 
	bcc not_right_bounce
	lda right_y
not_right_bounce:

	clc
	adc #4
	cmp ball_y
	bcs upper_bounce

	adc #3
	cmp ball_y
	bcc lower_bounce

middle_bounce:
	jmp negate_vx

upper_bounce:
	lda #-1
	sta ball_vy
	jmp negate_vx

lower_bounce:
	lda #1
	sta ball_vy

negate_vx:
	sec
	lda #0
	sbc ball_vx
	sta ball_vx 						// negate vx
done:
	rts
}


check_for_score:
	lda ball_x
	bne not_score_on_left
	jmp reset
not_score_on_left:

	cmp #MAX_X
	bne not_score_on_right
	jmp reset
not_score_on_right:

	rts

	

move_right_up: {
	lda right_y
	beq done 								// if at top, don't move

	lda #(paddle_size - 1)
	clc
	adc right_y
	tay
	ldx #RIGHT_X
	jsr vid_rg1.clear_pixel
	ldx #(RIGHT_X-1)
	jsr vid_rg1.clear_pixel

	dec right_y

	ldy right_y
	ldx #RIGHT_X
	jsr vid_rg1.set_pixel
	ldx #(RIGHT_X-1)
	jsr vid_rg1.set_pixel
done:
	rts
}



move_right_down: {
	lda #paddle_size
	clc
	adc right_y

	cmp #(MAX_Y+1)
	beq done 								// if at bottom, don't move

	tay
	ldx #RIGHT_X
	jsr vid_rg1.set_pixel
	ldx #(RIGHT_X-1)
	jsr vid_rg1.set_pixel


	ldy right_y
	ldx #RIGHT_X
	jsr vid_rg1.clear_pixel
	ldx #(RIGHT_X-1)
	jsr vid_rg1.clear_pixel

	inc right_y
done:
	rts
}

move_left_up: {
	lda left_y
	beq done 								// if at top, don't move

	lda #(paddle_size - 1)
	clc
	adc left_y
	tay
	ldx #LEFT_X
	jsr vid_rg1.clear_pixel
	ldx #(LEFT_X+1)
	jsr vid_rg1.clear_pixel

	dec left_y

	ldy left_y
	ldx #LEFT_X
	jsr vid_rg1.set_pixel
	ldx #(LEFT_X+1)
	jsr vid_rg1.set_pixel
done:
	rts
}


move_left_down: {
	lda #paddle_size
	clc
	adc left_y

	cmp #(MAX_Y+1)
	beq done 							// if at bottom, don't move

	tay
	ldx #LEFT_X
	jsr vid_rg1.set_pixel
	ldx #(LEFT_X+1)
	jsr vid_rg1.set_pixel


	ldy left_y
	ldx #LEFT_X
	jsr vid_rg1.clear_pixel
	ldx #(LEFT_X+1)
	jsr vid_rg1.clear_pixel

	inc left_y
done:
	rts
}


update_held_keys: {

read_from_buffer:
    sei                                             // disable interrupts
    ldx zp.kb_read_ptr                              // load keyboard buffer read pointer
    cpx zp.kb_write_ptr                             // check if its equal to the keyboard buffer write pointer
    cli                                             // reenable interrupts
    
    bne has_scancode                                // if read != write, there is a scancode to process
    jmp no_scancode

has_scancode:
    ldy zp.kb_buffer,x                              // load the scancode in the keyboard buffer at the read pointer

    cpy #kb.K_EXTENDED                              // check for the extended scancode
    bne not_extended
    inc extended_next
    update_kb_read_ptr()                               // update the read pointer 
    jmp read_from_buffer                            // consume the next scancode in the buffer to get real keypress
not_extended:

    cpy #kb.K_RELEASE                                  // check for the release scancode
    bne not_release
    inc release_next
    update_kb_read_ptr()                               // update the read pointer 
    jmp read_from_buffer                            // consume the next scancode in the buffer to get real keypress
not_release:

	lda extended_next
	beq not_extended_key
	tya
	ora #%10000000
	tay
	stz extended_next
not_extended_key:

	lda release_next
	beq not_reased_key
	phx
	tya
	tax
	stz held_keys,x
	plx
	stz release_next
	jmp done
not_reased_key:

	phx
	tya
	tax
	lda #1
	sta held_keys,x
	plx

done:
    update_kb_read_ptr()                               // update the read pointer 
    
no_scancode:
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



*=$2000 "Variables" virtual
held_keys:
	.fill 256, 0

