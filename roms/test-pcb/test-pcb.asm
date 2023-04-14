.cpu _65c02
.encoding "ascii"

#define PCB

// Library code
*=$8000 
#import "lcd.lib"
#import "kb.lib"
#import "macros.lib"
#import "vid.lib"
#import "uart.lib"


// Main code


reset:
    lda #$ff
    sta via.DDB

    jsr kb.init
    jsr vid.init
    // jsr uart.init_38400


on_loop:
    jsr kb.get_press
    beq on_loop

    jsr vid.write_ascii
    inc_vid_ptr()

    lda #$ff
    sta via.PORTB

off_loop:
    jsr kb.get_press
    beq off_loop

        jsr vid.write_ascii
    inc_vid_ptr()

    lda #$00
    sta via.PORTB

    jmp on_loop


// reset:
//     // jsr kb.init

//     lda #$ff
//     sta via.DDB

//     sta via.PORTB

// loop:
//     jmp loop





irq:
    phx                                                     // stash X on stack
    // tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    // inx 
    // inx                                                     // increment X twice so it points to the processor flags
    // lda $100,x                                              // load the processor flags on the stack
    // and #$10                                                // check for brk
    // bne break                                               // if break bit is set, go to break handler
    phy
       
    lda via.IFR

    ror
//     bcc no_ca2_irq
//     handle_ca2_irq()
// no_ca2_irq:

    ror 
    bcc no_ca1_irq
    handle_kb_irq()   
no_ca1_irq:

    ror
//     bcc no_shift_irq
//     handle_shift_irq()
// no_shift_irq:

    ror
//     bcc no_cb2_irq
//     handle_cb2_irq()
// no_cb2_irq:

    ror
//     bcc no_cb1_irq
//     handle_cb1_irq()
// no_cb1_irq:

    ror
//     bcc no_timer2_irq
//     stz via.T2_LO                                                   // write zeros to timer 2 lo
//     ldx #$ff
//     stx via.T2_HI 
// no_timer2_irq:

    ror
//     bcc no_timer1_irq
//     handle_cursor_timer_irq()
// no_timer1_irq:

    // check_and_handle_uart_irq()

    ply
    pla
    plx
    rti


*=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
