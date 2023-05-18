.cpu _65c02
.encoding "ascii"
.filenamespace high_scores

#define PCB

#define MACROS_ONLY
#import "../../lib/ssd.lib"


.const high_score_sector = $3f


/**
High score file format:
- Sequence of score entries, with last score entry $00
- At most 10 entries, sorted in decreasing score order
- Each score entry:
	Byte    | Contents
	$00     | Always $ff, signifying non-null entry
	$01-$02 | Two-byte score (little-endian)
	$03-... | Null-terminated string name (at most ~16 characters)

- If the byte after the null-terminated string is $ff, there is another entry
- If the byte after the null-terminated string is $00, this is the end of the file
*/ 


/**
 * Check for a score file, create one if needed
 * Clobbers A
 */ 
ensure_score_file: {
	set_ssd_sector(high_score_sector)

	lda ssd.file_type_addr
	cmp #ssd.DATA


	bne save
	jmp done
save:
	mov2 #1 : fsize
	stz snake.high_score_file
	jsr save_file
done:
	rts
}

name:
	.text "kiran"
	.byte $00

/**
 * Save the game's score to the high score file
 */ 
save_high_score: {
	pha
	phx
	phy

	// For now, just append
	jsr load_score_file

	mov2 ssd.file_size_addr : fsize
	mov2 #snake.high_score_file : zp.write_ptr

	add2 zp.write_ptr : fsize
	dec2 zp.write_ptr

	lda #$ff
	sta (zp.write_ptr)
	inc2 zp.write_ptr

	lda snake.score
	sta (zp.write_ptr)
	inc2 zp.write_ptr

	lda snake.score+1
	sta (zp.write_ptr)
	inc2 zp.write_ptr

	ldx #0
name_loop:
	lda name,x
	beq name_done
	sta (zp.write_ptr)
	inc2 zp.write_ptr
	inx
	jmp name_loop

name_done:
	sta (zp.write_ptr)
	inc2 zp.write_ptr
	sta (zp.write_ptr)

	add2 fsize : #9

	jsr save_file

	ply
	plx
	pla



	rts
}





save_file:
	ssd_save_file(start_addr, load_addr, fsize, checksum, fname, ftype, vid_mode)
	rts


load_score_file:
	set_ssd_sector(high_score_sector)
	move_block_size_addr(ssd.file_start_addr, snake.high_score_file, ssd.file_size_addr)
	rts


display_high_scores: {
	pha
	phx
	phy

	jsr load_score_file

	jsr vid.blank_screen
	set_vid_mode_text()

	set_vid_ptr(0, 10)
	vid_write_string("high scores")

	mov2 #snake.high_score_file : zp.read_ptr
	set_vid_ptr(2, 3)

	ldx #0											// count number of entries in x
	ldy #1 											// y = 1 means haven't inserted new score yet

print_score_loop:
	lda (zp.read_ptr)
	bne check_num_printed 							// if header byte of entry is $00, done
	jmp done

check_num_printed:
	cpx #10											// Check if we've displayed 10 scores already
	bcc print_next_entry 		
	jmp done

print_next_entry:
	inc2 zp.read_ptr
	inx

read_score:
	mov (zp.read_ptr) : snake.dividend
	inc2 zp.read_ptr
	mov (zp.read_ptr) : snake.dividend+1
	inc2 zp.read_ptr

	cpy #1
	bcc new_not_larger 								// if we've already made row for new score, skip checking for larger

	lda snake.dividend+1 
	cmp snake.score+1
	bcc new_larger
	lda snake.dividend 
	cmp snake.score
	bcs new_not_larger 								// check if the new score is larger then the one about to be printed

new_larger:
	dey 											// decrement y to 0 to remember that we've made new score row 		
	mov2 zp.vid_ptr : new_score_row 				// store which row the new score is in
	add2 zp.read_ptr : #-3								// reset read_ptr to read beaten score again
	mov2 snake.score : snake.dividend 				// set up to print new score
	jsr print_score
	jmp next_line 									// print the score, but not the name

new_not_larger:	
	jsr print_score

read_name:
	lda (zp.read_ptr)
	beq name_done
	jsr vid.write_ascii
	inc_vid_ptr()
	inc2 zp.read_ptr
	jmp read_name

name_done:
	inc2 zp.read_ptr								// set read_ptr to header byte of next entry 

next_line:
	lda zp.vid_ptr 									// set vid_ptr to column 0
	and #%11100000
	sta zp.vid_ptr									
	add2 zp.vid_ptr : #35 							// go to next row, column 3

	jmp print_score_loop

done: 

	cpy #0
	beq new_high_score
	cpx #10
	beq play_again

	mov2 zp.vid_ptr : new_score_row 				// store which row the new score is in
	mov2 snake.score : snake.dividend 				// set up to print new score
	jsr print_score

new_high_score:
	set_vid_ptr(14, 3)
	vid_write_string("new high score! type name")


play_again:
	set_vid_ptr(15, 3)
	vid_write_string("press enter to play again")

	ply
	plx
	pla
	rts
}

print_score: {
divide_loop:
	mov2 #10 : snake.divisor
	jsr snake.divide
	lda snake.remainder

	clc
	adc #'0'

	jsr vid.write_ascii
	dec_vid_ptr()

	lda snake.dividend
	bne divide_loop

	lda zp.vid_ptr 									// set vid_ptr to column 5
	and #%11100000									// to do this, set to column 0 and add 5
	clc
	adc #5
	sta zp.vid_ptr

	rts
}



fname:
	.text "high scores"
	.byte $00

checksum:
	.word $efbe

load_addr:
	.word snake.high_score_file

start_addr:
	.word $adde

fsize:
	.word $0001

ftype:
	.byte ssd.DATA

vid_mode:
	.byte $00

new_score_row:
	.word $0000

