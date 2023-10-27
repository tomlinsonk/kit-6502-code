.cpu _65c02
.encoding "ascii"

#define PCB


// *=$8000   
// .fill 4096, 0

// *=$9000       

#import "kb.lib"
#import "via.lib"
#import "vid.lib"
#import "zp.lib"

*=$1000
reset:
    jsr kb.init

    jsr vid.init_cursor


    jsr vid.blank_screen
    set_vid_ptr(0, 0)


loop:
    jsr kb.get_press
    bne has_press


    blink_cursor #vid.CURSOR_ON : #' '

    jmp loop

has_press:


    jsr vid.write_ascii
    inc_vid_ptr()
    jmp loop

done:
    jmp done

irq:
    phx                                                     // stash X on stack
    tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    inx 
    inx                                                     // increment X twice so it points to the processor flags
    lda $100,x                                              // load the processor flags on the stack
    and #$10                                                // check for brk
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
    bcc no_timer2_irq
    stz via.T2_LO                                                   // write zeros to timer 2 lo
    ldx #$ff
    stx via.T2_HI 
no_timer2_irq:

    ror
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    // check_and_handle_uart_irq()

    ply
    pla
    plx
    rti


    *=$fffc                                     
    .word reset                               
    .word irq                              

