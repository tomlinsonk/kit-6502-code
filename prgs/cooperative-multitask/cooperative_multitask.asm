.cpu _65c02
.encoding "ascii"
.filenamespace coop

#if !MACROS_ONLY

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"

.label head_ptr = $0e00                                
.label tail_ptr = $0e01                                 
.label task_addr = $0e02                                
.label queue = $0f00                                    

.segment Code [outPrg="cooperative_multitask.prg", start=$0300] 


/* --------------------------------------------------------------------------------------- 
Initialize the subtask queue pointers and enqueue the start subtasks for both tasks.
Then, enter the main task loop that gets the next subtask from the queue and executes it
as a subroutine.
*/
start:
    stz head_ptr
    dec head_ptr
    stz tail_ptr

    lda #$00
    ldy #$10
    jsr add_subtask

    lda #$00
    ldy #$40
    jsr add_subtask

loop:
    ldx tail_ptr
    cpx head_ptr
    beq done

    lda queue,x
    sta task_addr

    inx
    lda queue,x
    sta task_addr+1

    inc tail_ptr
    inc tail_ptr

    jsr run_subtask
    jmp loop

run_subtask:
    jmp (task_addr)

done:
    jmp done


/* --------------------------------------------------------------------------------------- 
Enqueue a subtask with start address in A (low byte) and Y (high byte) 
*/
add_subtask:
    phx

    ldx head_ptr
    inx
    sta queue,x

    tya
    inx
    sta queue,x

    stx head_ptr

    plx
    rts

#endif
