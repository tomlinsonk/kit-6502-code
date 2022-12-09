.cpu _65c02
.encoding "ascii"
.filenamespace life

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"


.const GREEN = 0
.const YELLOW = 1
.const BLUE = 2
.const RED = 3

.segment Code [outPrg="life.prg", start=$4000] 
reset:
	jsr clear_screen


loop:

	jmp loop
