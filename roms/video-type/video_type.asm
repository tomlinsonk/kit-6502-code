.cpu _65c02
.encoding "ascii"

// RAM addresses

.label txt_buffer = $0300                            // 512 bytes (0200-03ff)
.label txt_buffer_end = $04ff                            



*=$8000                                             // ROM starts at address $8000
#import "kb.lib"
#import "macros.lib"
#import "vid.lib"
#import "lcd.lib"

reset:
    cli
    cld

    jsr kb.init
    jsr vid.init
    jsr vid.init_cursor
    jsr lcd.init

    jsr clear_txt_buffer     

    lda #(<txt_buffer)
    sta zp.txt_ptr                                  // reset text pointer to $0200
    lda #(>txt_buffer)
    sta zp.txt_ptr+1    

loop:                               
    jsr kb.get_press
    bne key_pressed

    ldy #0
    blink_cursor #vid.CURSOR_ON : (zp.txt_ptr),y
    
    jmp loop                        


key_pressed:
    bmi extended_pressed                            // handle extended

    cmp #kb.ASCII_ESC                               // check for esc press
    beq esc_pressed

    cmp #kb.ASCII_BACKSPACE                         // check for backspace
    beq backspace_pressed

    ldy #0
    sta (zp.txt_ptr),y                              // save char and write to screen
    jsr vid.write_ascii
    jsr inc_vid_txt_ptrs
    force_cursor_update()

    jmp loop



esc_pressed:
    jmp reset


backspace_pressed:
    ldy #0
    lda (zp.txt_ptr),y                              // load the char under the cursor
    jsr vid.write_ascii                             // write it to the cursor position

    jsr dec_vid_txt_ptrs                            // decrement video pointer

    lda #0
    sta (zp.txt_ptr),y                              // save a null to the previous character
    jsr vid.write_ascii                             // write that null to the screen
    force_cursor_update()

    jmp loop


extended_pressed:
    ldy #0

    cmp #kb.K_DOWN
    bne not_down
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    add_vid_txt_ptrs #32                            // decrement text pointer
    force_cursor_update()  
not_down:

    cmp #kb.K_UP
    bne not_up
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    add_neg_vid_txt_ptrs #(-32)                     // decrement text pointer
    force_cursor_update() 
not_up:

    cmp #kb.K_LEFT
    bne not_left
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr dec_vid_txt_ptrs                            // decrement text pointer
    force_cursor_update()   
    jmp loop
not_left:

    cmp #kb.K_RIGHT
    bne not_right
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr inc_vid_txt_ptrs                            // increment text pointer
    force_cursor_update()
    jmp loop    
not_right:
    
    jmp loop


inc_vid_txt_ptrs:
    pha
    inc2 zp.vid_ptr
    clamp_max2 zp.vid_ptr : vid.VRAM_TXT_END
    inc2 zp.txt_ptr
    clamp_max2 zp.txt_ptr : txt_buffer_end
    pla
    rts


dec_vid_txt_ptrs:
    pha
    dec2 zp.vid_ptr
    clamp_min2 zp.vid_ptr : vid.VRAM_START
    dec2 zp.txt_ptr
    clamp_min2 zp.txt_ptr : txt_buffer
    pla
    rts


.pseudocommand add_vid_txt_ptrs num {
    pha
    add2 zp.vid_ptr : num
    clamp_max2 zp.vid_ptr : vid.VRAM_TXT_END
    add2 zp.txt_ptr : num
    clamp_max2 zp.txt_ptr : txt_buffer_end
    pla
}

.pseudocommand add_neg_vid_txt_ptrs num {
    pha
    add2 zp.vid_ptr : num
    clamp_min2 zp.vid_ptr : vid.VRAM_START
    add2 zp.txt_ptr : num
    clamp_min2 zp.txt_ptr : txt_buffer
    pla
}


// subroutine
// fills the text buffer with 0s
clear_txt_buffer:
    phx

    ldx #0

clear_text_loop:                    // write 0s to the first half of the text buffer
    stz txt_buffer,x
    inx
    bne clear_text_loop

clear_text_loop2:
    stz txt_buffer+$0100,x         // write 0s to the second half of the text buffer
    inx
    bne clear_text_loop2

    plx
    rts


irq:
    pha
    phx
    phy
       
    lda via.IFR

    ror
//     bcc no_ca2_irq
//     handle_ca2_irq()
// no_ca2_irq:

    ror 
    bcc no_ca1_irq
    kb_handle_irq()   
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
//     handle_timer2_irq()
// no_timer2_irq:

    ror
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    ply
    plx
    pla
    rti


    *=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
