.cpu _65c02
.encoding "ascii"

#define PCB

#if PCB
    .print "Assembling for PCB KiT"
#else 
    .print "Assembling for Breadboard KiT"
#endif

*=$8000                                             // ROM starts at address $8000

#import "kb.lib"
#import "macros.lib"
#import "vid.lib"
#import "uart.lib"
#import "vid_cg1.lib"
#import "vid_rg1.lib"

#if !PCB
    #import "lcd.lib"
#endif


reset:
    jsr vid.init
    jsr vid.init_cursor

    lda #$ff
    sta vid.MODE_REG_DIR
    stz vid.MODE_REG



loop:
    blink_cursor #vid.CURSOR_ON : #' '

    jmp loop


// reset:
//     sei
//     mov2 #irq : zp.irq_addr                         // set up irq handler
//     cli

//     cld

//     jsr kb.init
//     jsr vid.init

//     jsr uart.init_38400

//     set_vid_ptr(0, 0)
//     vid_write_string("IIR ")
//     lda uart.IIR
//     jsr vid.write_hex

//     set_vid_ptr(1, 0)
//     vid_write_string("LCR ")
//     lda uart.LCR
//     jsr vid.write_hex

//     set_vid_ptr(2, 0)
//     vid_write_string("MCR ")
//     lda uart.MCR
//     jsr vid.write_hex


//     set_vid_ptr(3, 0)
//     vid_write_string("LSR ")
//     lda uart.LSR
//     jsr vid.write_hex


//     set_vid_ptr(4, 0)
//     vid_write_string("MSR ")
//     lda uart.MSR
//     jsr vid.write_hex


//     set_vid_ptr(5, 0)
//     vid_write_string("IIR ")
//     lda uart.IIR
//     jsr vid.write_hex




//     lda uart.LCR
//     ora #%10000000
//     sta uart.LCR

//     set_vid_ptr(6, 0)
//     vid_write_string("DIV ")
//     lda uart.DLM
//     jsr vid.write_hex
//     lda uart.DLL
//     jsr vid.write_hex

//     lda uart.LCR
//     and #%01111111
//     sta uart.LCR


//     set_vid_ptr(9, 0)

// loop:
//     jsr uart.read_byte
//     jsr vid.write_hex
//     inc_vid_ptr()
//     jmp loop



// init_38400:
//     pha

//     lda #uart.DLAB
//     sta uart.LCR                                                 // set the divisor latch access bit (DLAB)

//     lda #uart.DIV_38400_LO
//     sta uart.DLL                                                 // store divisor low byte (4800 baud @ 1 MHz clock)

//     lda #uart.DIV_38400_HI                                       
//     sta uart.DLM                                                 // store divisor hi byte

//                                               // set 8 data bits, 1 stop bit, no parity, disable DLAB

//     // set_vid_ptr(7, 0)
//     // lda uart.LCR 
//     // jsr vid.write_hex                                                // set 8 data bits, 1 stop bit, no parity, disable DLAB

//     lda #uart.FIFO_ENABLE
//     sta uart.FCR                                                 // enable the UART FIFO

//     lda #uart.POLLED_MODE
//     sta uart.IER     

//     lda #uart.LCR_8N1
//     sta uart.LCR                                               // disable all interrupts

//     // stz zp.uart_read_ptr
//     // stz zp.uart_write_ptr

//     pla
//     rts



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


raw_irq:
    jmp (zp.irq_addr)


*=$fffc                                             // the CPU reads address $fffc to read start of program address
    .word reset                                     // reset address
    .word raw_irq                                   // IRQ handler address