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


print_score_loop:
	lda (zp.read_ptr)
	bne print_next_entry 							// if header byte of entry is $00, done
	jmp done

print_next_entry:
	inc2 zp.read_ptr


read_score:
	mov (zp.read_ptr) : snake.dividend
	inc2 zp.read_ptr
	mov (zp.read_ptr) : snake.dividend+1
	inc2 zp.read_ptr

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

read_name:
	lda (zp.read_ptr)
	beq name_done
	jsr vid.write_ascii
	inc_vid_ptr()
	inc2 zp.read_ptr
	jmp read_name

name_done:
	lda zp.vid_ptr 									// set vid_ptr to column 0
	and #%11100000
	sta zp.vid_ptr									
	add2 zp.vid_ptr : #35 							// go to next row, column 3

	inc2 zp.read_ptr								// set read_ptr to header byte of next entry 
	jmp print_score_loop

done: 

	set_vid_ptr(15, 3)
	vid_write_string("press enter to play again")

	ply
	plx
	pla
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


