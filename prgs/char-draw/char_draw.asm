.cpu _65c02
.encoding "ascii"
.filenamespace char_draw

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"


.label EMPTY_CHAR = %10000000
.label draw_buffer_end = char_draw.draw_buffer + (32 * 14)

.segment Code [outPrg="char_draw.prg", start=$1000] 
	.label draw_ptr = zp.B

	fill_vid_screen(EMPTY_CHAR)
	jsr clear_draw_buffer

	jsr draw_palette
	stz curr_color
	stz curr_shape
	stz curr_x
	stz curr_y

	lda #EMPTY_CHAR
	sta curr_char


	lda #<draw_buffer
	sta draw_ptr
	lda #>draw_buffer
	sta draw_ptr+1

input_loop:
	jsr kb.get_press
	beq input_loop

	tay													// store keypress in Y

	bmi not_command 									// if keypress starts with 1, it's not a command
	lda command_map,y
	beq not_command 									// if command_map is 0 for key, not a command
	cmp #$20
	bcc not_set_color
	jmp set_color
not_set_color:
	jmp set_shape 
not_command:


	cpy #kb.ASCII_ESC
	bne not_esc
	brk
not_esc:

	cpy #kb.K_LEFT
	bne not_left
	lda curr_x
	beq not_left
	jsr draw_char
	dec curr_x
	jmp display_cursor
not_left:

	cpy #kb.K_RIGHT
	bne not_right
	lda curr_x
	cmp #31
	beq not_right
	jsr draw_char
	inc curr_x
	jmp display_cursor
not_right:

	cpy #kb.K_UP
	bne not_up
	lda curr_y
	beq not_up
	jsr draw_char
	dec curr_y
	jmp display_cursor
not_up:

	cpy #kb.K_DOWN
	bne not_down
	lda curr_y
	cmp #13
	beq not_down
	jsr draw_char
	inc curr_y
	jmp display_cursor
not_down:

	cpy #kb.ASCII_SPACE
	bne not_space
	ldy #0
	lda curr_char
	sta (draw_ptr),y
not_space:

	cpy #kb.ASCII_NEWLINE
	bne not_enter
	jsr send_draw_buffer
not_enter:


	jmp input_loop

draw_char:
	ldy #0
	lda (draw_ptr),y
	sta (zp.vid_ptr),y
	rts


display_cursor:
	update_ptrs()
	lda curr_char
	jsr vid.write_ascii


	
	// set_vid_ptr(0, 0)
	// lda #>draw_buffer
	// jsr vid.write_hex
	// lda #<draw_buffer
	// jsr vid.write_hex
	// inc_vid_ptr()

	// lda draw_ptr+1
	// jsr vid.write_hex
	// lda draw_ptr
	// jsr vid.write_hex
	

	jmp input_loop



update_char:
	lda curr_color
	asl 
	asl
	asl
	asl
	ora curr_shape
	ora #%10000000
	sta curr_char
	rts


set_color:
	and #%00000111
	cmp curr_color
	bne new_color
	jmp input_loop
new_color:
	tay
	pha
	set_vid_ptr(15, 24)

	lda (zp.vid_ptr),y
	ora #%01000000
	sta (zp.vid_ptr),y

	ldy curr_color
	lda (zp.vid_ptr),y
	and #%10111111
	sta (zp.vid_ptr),y

	pla
	sta curr_color

	jsr update_char
	
	jsr draw_shapes

	jmp display_cursor


set_shape:
	and #%00001111
	cmp curr_shape
	bne new_shape
	jmp input_loop
new_shape:
	tay
	pha
	set_vid_ptr(15, 0)

	lda (zp.vid_ptr),y
	ora #%01000000
	sta (zp.vid_ptr),y

	ldy curr_shape
	lda (zp.vid_ptr),y
	and #%10111111
	sta (zp.vid_ptr),y

	pla
	sta curr_shape

	jsr update_char

	jmp display_cursor


/* --------------------------------------------------------------------------------------- 
Draw the palette, including shapes, colors, and controls.
*/
draw_palette:
	jsr draw_shapes

set_vid_ptr(15, 0)
	vid_write_string(@"\$11234567890qwerty")

	set_vid_ptr(14, 24)

	ldx #8
	lda #%10001111
	
draw_colors_loop:
	jsr vid.write_ascii
	inc_vid_ptr()
	clc
	adc #%00010000
	dex
	bne draw_colors_loop

	set_vid_ptr(15, 24)
	vid_write_string("Zxcvbnm,")

	rts


draw_shapes:
	pha
	phx
	set_vid_ptr(14, 0)
	
	ldx #16

	lda curr_color
	asl 
	asl
	asl
	asl
	ora #EMPTY_CHAR
draw_char_loop:
	jsr vid.write_ascii
	inc_vid_ptr()
	inc
	dex
	bne draw_char_loop

	plx
	pla

	rts


clear_draw_buffer:
	lda #<draw_buffer
	sta draw_ptr
	lda #>draw_buffer
	sta draw_ptr+1

	ldy #0
	lda #EMPTY_CHAR

fill_loop:
	sta (draw_ptr),y
	inc2 draw_ptr
	ldx draw_ptr+1
	cpx #>draw_buffer_end
	bcc fill_loop

fill_loop2:
	sta (draw_ptr),y
	inc2 draw_ptr
	ldx draw_ptr
	cpx #<draw_buffer_end
	bcc fill_loop2

	rts


/* --------------------------------------------------------------------------------------- 
Send the draw buffer over UART
*/
send_draw_buffer:
	pha
	phy
	phx

	ldy #2
	ldx #0
send_loop:
	lda draw_buffer,x
	jsr uart.write_byte
	inx
	bne send_loop
	dey
	bne send_loop

	set_vid_ptr(15, 18)
	vid_write_string("sent")

wait_for_press:
	jsr kb.get_press
	beq wait_for_press

	set_vid_ptr(15, 18)
	vid_write_string(@"\$80\$80\$80\$80")
	update_vid_ptr()

	plx
	ply
	pla
	rts



curr_color:
	.byte $00

curr_shape:
	.byte $00

curr_char:
	.byte $00

curr_x:
	.byte $00

curr_y:
	.byte $00

command_map:
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 	// 00-0F
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 	// 10-1F
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$27,$00,$00,$00 	// 20-1F
    .byte $19,$10,$11,$12,$13,$14,$15,$16,$17,$18,$00,$00,$00,$00,$00,$00 	// 30-1F
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 	// 40-1F
    .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 	// 50-1F
    .byte $00,$00,$24,$22,$00,$1c,$00,$00,$00,$00,$00,$00,$00,$26,$25,$00 	// 60-1F
    .byte $00,$1a,$1d,$00,$1e,$00,$23,$1b,$21,$1f,$20,$00,$00,$00,$00,$00 	// 70-1F

vram_row_starts:
	.lohifill 16,$7000+i*32

draw_buf_row_starts:
	.lohifill 16,draw_buffer+i*32

*=$1400
draw_buffer:


.macro update_vid_ptr() {
	ldy curr_y
	lda vram_row_starts.lo,y
	clc
	adc curr_x
	sta zp.vid_ptr
	lda vram_row_starts.hi,y
	sta zp.vid_ptr+1	
}


.macro update_ptrs() {
	pha
	phy

	update_vid_ptr()

	ldy curr_y
	lda draw_buf_row_starts.lo,y
	clc
	adc curr_x
	sta draw_ptr
	lda draw_buf_row_starts.hi,y
	sta draw_ptr+1	

	ply
	pla
}
