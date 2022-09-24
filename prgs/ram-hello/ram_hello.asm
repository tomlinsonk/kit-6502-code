#import "serial_load.sym"

.cpu _65c02
.encoding "ascii"

*=$1000							// start at address 1000

	lda #$00
	sta VIDEO_PTR
	lda #$70
	sta VIDEO_PTR+1

	ldx #0

hello:


	lda message,x
	beq done
	jsr vid_write_ascii
	jsr inc_vid_ptr
	inx
	jmp hello

done:
	jmp done


message:

	.text "A new test"
	.byte $00 					// null terminated ascii








