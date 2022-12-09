.cpu _65c02
.encoding "ascii"
.filenamespace preempt

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"

.label active_task = $0d00 								// one byte

.label a0_stash = $0d10 								// one byte
.label x0_stash = $0d11 								// one byte
.label y0_stash = $0d12 								// one byte
.label p0_stash = $0d13 								// one byte
.label s0_stash = $0d14 								// one byte
.label pc0_stash = $0d15 								// two bytes

.label a1_stash = $0d20 								// one byte
.label x1_stash = $0d21 								// one byte
.label y1_stash = $0d22 								// one byte
.label p1_stash = $0d23 								// one byte
.label s1_stash = $0d24 								// one byte
.label pc1_stash = $0d25 								// two bytes

.label zp0_stash = $0d30                                // 16 bytes

.label zp1_stash = $0d40                                // 16 bytes


// .label stack0_stash = $0e00 							// 256 bytes

// .label stack1_stash = $0f00 							// 256 bytes


.const timer_count = $80

.segment Code [outPrg="preempt.prg", start=$0300] 


/* --------------------------------------------------------------------------------------- 
Set up the start address of each task, set the interrupt handler, and start the first task.
*/
start:
    ldx #$ff
    txs

    sei
    stz active_task

    mov2 #$1000 : pc0_stash
    mov2 #$4000 : pc1_stash

    mov #$7f : s1_stash
    mov #$20 : p1_stash

    mov2 #preempt_irq : zp.irq_addr
    jsr init_timer
    cli

    jmp (pc0_stash)


/* --------------------------------------------------------------------------------------- 
Initialize Timer 2 on the VIA to generate interrupts every timer_count * 256 clock cycles.
*/
init_timer:
    lda via.IER
    ora #(via.INT_ENABLE | via.TIMER2_INT)
    sta via.IER                                             // enable timer 2 interrupts

    lda via.ACR
    and #(~via.T2_ONE_SHOT)                                 // set up timer 2 for one shot interrupts

    reset_timer()                                           // start the timer
    rts


/* --------------------------------------------------------------------------------------- 
Swap out task0 and swap in task1.
*/
switch0to1:
    ply
    sty y0_stash

    pla
    sta a0_stash

    plx
    stx x0_stash

    pla
    sta p0_stash

    pla
    sta pc0_stash

    pla
    sta pc0_stash+1

    tsx
    stx s0_stash

    inc active_task

    move_block_no_stack(zp.B, zp0_stash, 16)
    move_block_no_stack(zp1_stash, zp.B, 16)

    ldx s1_stash
    txs

    lda pc1_stash+1
    pha

    lda pc1_stash
    pha

    lda p1_stash
    pha

    lda a1_stash
    ldx x1_stash
    ldy y1_stash

    rti


/* --------------------------------------------------------------------------------------- 
Swap out task1 and swap in task0.
*/
switch1to0:

    ply
    sty y1_stash

    pla
    sta a1_stash

    plx
    stx x1_stash

    pla
    sta p1_stash

    pla
    sta pc1_stash

    pla
    sta pc1_stash+1

    tsx
    stx s1_stash

    stz active_task

    move_block_no_stack(zp.B, zp1_stash, 16)
    move_block_no_stack(zp0_stash, zp.B, 16)

    ldx s0_stash
    txs

    lda pc0_stash+1
    pha

    lda pc0_stash
    pha

    lda p0_stash
    pha

    lda a0_stash
    ldx x0_stash
    ldy y0_stash
    
    rti

/* --------------------------------------------------------------------------------------- 
Interrupt handler with task switching. Also handles interrupts from the keyboard, 
cursor timer, and break instruction.
*/
preempt_irq:
    phx                                      // stash X on stack
    tsx                                      // put stack pointer in X
    pha                                      // stash A on stack
    inx 
    inx                                      // increment X twice so it points to the processor flags
    lda $100,x                               // load the processor flags on the stack
    and #$10                                 // check for brk
    beq no_break                             // if break bit is set, go to break handler
    jmp break
no_break:
    phy

    lda via.IFR

    ror
    ror 
    bcc no_ca1_irq
    handle_kb_irq()   
no_ca1_irq:

    ror
    ror
    ror
    ror
    bcc no_timer2_irq
    handle_timer2_irq()
no_timer2_irq:

    ror
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    ply
    pla
    plx
    rti


/* --------------------------------------------------------------------------------------- 
Reset Timer 2.
*/
.macro reset_timer() {
    stz via.T2_LO                                           // write zeros to timer 2 lo
    ldx #timer_count
    stx via.T2_HI                                           // write to timer 2 hi, starting the timer
}

/* --------------------------------------------------------------------------------------- 
Reset Timer 2 and swap out the active task.
*/
.macro handle_timer2_irq() {
    reset_timer()

    ldx active_task
    beq task0_active
    jmp switch1to0
task0_active:
    jmp switch0to1
}


/* --------------------------------------------------------------------------------------- 
Move a block of size bytes (at most 256) starting at source to target.
Differs from move_block() since it doesn't touch the stack.
Clobbers A and X, however.
*/
.macro @move_block_no_stack(source, target, size) {
    .if (size > $100) .error "Add 2-byte index support to move_block"
    ldx #(size-1)

loop:
    lda source,x
    sta target,x
    dex
    bpl loop        
}

