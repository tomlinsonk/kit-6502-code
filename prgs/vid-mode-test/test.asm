.cpu _65c02
.encoding "ascii"
.filenamespace test


#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"
#import "video_mon.sym"


*=$1000                                             // ROM starts at address $8000
start:

	// lda #%00000001
	// sta $7901

	set_vid_mode_text()

	jsr vid.blank_screen

	set_vid_ptr(0, 0)

	lda #0
loop:	
	jsr vid.write_ascii
	inc_vid_ptr()
	inc
	cmp #254
	bcc loop

done:
	jmp done

	

	
// loop:
// 	jsr vid.write_ascii
// 	inc
// 	jsr vid.inc_vid_ptr
// 	jmp loop	





