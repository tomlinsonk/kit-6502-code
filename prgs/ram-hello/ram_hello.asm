#import "video_mon.sym"

.cpu _65c02
.encoding "ascii"

*=$1000							// start at address 4321

	lda #<vid.VRAM_START
	sta zp.vid_ptr
	lda #>vid.VRAM_START
	sta zp.vid_ptr+1

	ldx #0

hello:


	lda message,x
	beq done
	jsr vid.write_ascii
	jsr vid.inc_vid_ptr
	inx
	jmp hello

done:
	brk


message:

	.text "program upload worked!!!"
	.byte $00 					// null terminated ascii








