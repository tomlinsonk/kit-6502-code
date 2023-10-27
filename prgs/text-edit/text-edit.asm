.cpu _65c02
.encoding "ascii"
.filenamespace text_edit

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"


.label filesize = zp.B 					// Two bytes, also uses zp.C


.segment Code [outPrg="text-edit.prg", start=$1000] 
reset:


	set_vid_mode_text()

	jsr vid.blank_screen
	set_vid_ptr(0, 0)

	stz txt_buffer
	mov2 #txt_buffer : zp.txt_ptr
	mov2 #$0000 : filesize

	bpt


input_loop:
	jsr kb.get_press
	bne key_pressed

    ldy #0
    blink_cursor #vid.CURSOR_ON : (zp.txt_ptr),y

	jmp input_loop

key_pressed:

	jsr write_char
	force_cursor_update()

	jmp input_loop




write_char: {
	ldy #0
	sta (zp.txt_ptr),y
	jsr vid.write_ascii
	inc2 zp.vid_ptr
	inc2 zp.txt_ptr
	inc2 filesize

	lda #0
	sta (zp.txt_ptr),y

done:
	rts
}



*=$2000 "Text Buffer" virtual
txt_buffer:
	.fill 512, 0
