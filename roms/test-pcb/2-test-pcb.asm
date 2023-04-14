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
    jsr kb.init
    jsr vid.init

loop:
    jsr kb.get_press
    beq loop

    jsr vid.write_ascii
    inc_vid_ptr()

    // jsr delay

    jmp loop


// get_scancode:
//     phx
//     phy

//     lda zp.B
//     inc zp.B



// // read_scancode:
// //     lda #0                                          // initialize A to 0

// //     sei                                             // disable interrupts
// //     ldx zp.kb_read_ptr                              // load keyboard buffer read pointer
// //     cpx zp.kb_write_ptr                             // check if its equal to the keyboard buffer write pointer
// //     cli                                             // reenable interrupts
    
// //     bne has_scancode                                // if read != write, there is a scancode to process
// //     jmp get_scancode_done                              // otherwise, buffer is empty. Return the 0 in A

// // has_scancode:
// //     lda zp.kb_buffer,x
// //     update_kb_read_ptr()

// get_scancode_done:
//     ply
//     plx

//     ora #%00000000                                  // set zero flag if A is 0 and negative flag if A is negative

//     rts



// get_press:
//     phx
//     phy

// read_from_buffer:
//     lda #0                                          // initialize A to 0

//     sei                                             // disable interrupts
//     ldx zp.kb_read_ptr                              // load keyboard buffer read pointer
//     cpx zp.kb_write_ptr                             // check if its equal to the keyboard buffer write pointer
//     cli                                             // reenable interrupts
    
//     bne has_scancode                                // if read != write, there is a scancode to process
//     jmp get_press_done                              // otherwise, buffer is empty. Return the 0 in A

// has_scancode:
//     ldy zp.kb_buffer,x                              // load the scancode in the keyboard buffer at the read pointer

//     cpy #kb.K_EXTENDED                                 // check for the extended scancode
//     bne not_extended
//     set_bits(zp.kb_flags, kb.EXTENDED_NXT)             // if it is extended scancode, set the extended flag
//     update_kb_read_ptr()                               // update the read pointer 
//     jmp read_from_buffer                            // consume the next scancode in the buffer to get real keypress
// not_extended:

//     cpy #kb.K_RELEASE                                  // check for the release scancode
//     bne not_release
//     set_bits(zp.kb_flags, kb.RELEASE_NXT)              // if it is release scancode, set the release flag
//     update_kb_read_ptr()                               // update the read pointer 
//     jmp read_from_buffer                            // consume the next scancode in the buffer to get real keypress
// not_release:

//     handle_modifier(kb.K_L_SHIFT, kb.L_SHIFT_DOWN)        // check for and handle left shift scancode

//     handle_modifier(kb.K_R_SHIFT, kb.R_SHIFT_DOWN)        // check for and handle right shift scancode

//     lda zp.kb_flags                                 // check if this scancode is for a released key
//     bit #kb.RELEASE_NXT 
//     beq not_released_key
// released_key:
//     clear_bits(zp.kb_flags, kb.RELEASE_NXT | kb.EXTENDED_NXT)  // clear the released and extended flags
//     update_kb_read_ptr()
//     jmp read_from_buffer                            // consume the next scancode in the buffer to get real keypress
// not_released_key:

//     bit #kb.EXTENDED_NXT                               // check if this is an extended key press
//     beq not_extended_key
//     clear_bits(zp.kb_flags, kb.EXTENDED_NXT)           // if it's extended, clear the extended flag
//     tya                                             // move scancode into A
//     ora #%10000000                                  // and set bit 7
//     jmp inc_read_ptr                                // then we can return
// not_extended_key:

//     cpy #$80                                        // make sure the scancode has bit 7 clear
//     bcc valid_scancode                              // if scancode is < $80, then it's valid
//     lda #$ff                                        // otherwise, it's a weird scancode. Put $ff in A
//     jmp inc_read_ptr

// valid_scancode:
    
//     bit #(kb.R_SHIFT_DOWN | kb.L_SHIFT_DOWN)              // check if either shift is down
//     beq shift_up                                    // if not, branch
//     lda kb.keymap_shifted,y                            // if shift down, load shifted ascii into A
//     bra inc_read_ptr                                // and skip next instruction

// shift_up:
//     lda kb.keymap,y                                    // load unshifted ascii into A

// inc_read_ptr:
//     update_kb_read_ptr()
// get_press_done:
//     plx
//     ply
//     ora #%00000000                                  // set zero flag if A is 0 and negative flag if A is negative
//     rts



delay:
    ldx #0
    ldy #0

delay1:
    inx
    bne delay1

    iny
    bne delay1

    rts


// reset:
//     // jsr kb.init

//     lda #$ff
//     sta via.DDB

//     sta via.PORTB

// loop:
//     jmp loop





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



*=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
