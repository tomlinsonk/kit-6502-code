.cpu _65c02
.encoding "ascii"

// RAM addresses

.label text_buffer = $0200                           // 31 bytes (0200-021f)
.label text_buffer_end = $021e                            
.label vram_inline_start = $71e1

// other RAM addresses


*=$8000                                             // ROM starts at address $8000
jump_table:
    jmp reset                                       // 8000
    jmp vid.write_ascii                             // 8003
    jmp vid.inc_vid_ptr                             // 8006

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

    brk                                             // start the monitor

loop:
    jmp loop


start_mon:                                              
    // Stack has R_HI, R_LO, P, X, A, Y <
    jsr reset_prompt

mon_loop:
    jsr kb.get_press
    bne key_pressed

    ldy #0
    blink_cursor #vid.CURSOR_ON : (zp.txt_ptr),y
    
    jmp mon_loop                        


key_pressed:
    bpl not_extended                                // handle extended
    jmp extended_pressed
not_extended:

    cmp #kb.ASCII_ESC                               // check for esc press
    bne not_esc
    jmp reset
not_esc:

    cmp #kb.ASCII_BACKSPACE                         // check for backspace
    bne not_backspace
    jmp backspace_pressed
not_backspace:

    cmp #kb.ASCII_NEWLINE                           // check for enter
    bne not_enter
    jmp enter_pressed
not_enter:

    ldy #0
    sta (zp.txt_ptr),y                              // save char and write to screen
    jsr vid.write_ascii
    jsr inc_vid_txt_ptrs
    force_cursor_update()

    jmp mon_loop



/*
Main monitor code. Parse and execute command
*/
enter_pressed:
    phx
    ldx #0                                          // load offset of 0 for indirect indexed addressing / offset for writing

    ldy #0                                          // cursor off
    lda (zp.txt_ptr),y
    jsr vid.write_ascii

    shift_vid_up(2, 0)                              // move display up                                                    
    set_vid_ptr(14, 0)

    ldy #0                                          // start at the beginning of the text buffer
    jsr parse_hex_byte                              // load hi hex byte into A and increment y
    sta zp.mon_addr+1                               // store the hi byte
    pha                                             // stash hi byte for writing
    jsr vid.write_hex                               // display it in hex
    
    iny                                             // increment y again to go to start of next byte
    jsr parse_hex_byte                              // load lo hex byte into A and increment y
    sta zp.mon_addr                                 // store the lo byte
    pha                                             // stash lo byte for writing
    jsr vid.write_hex                               // display it in hex

    iny                                             // increment y to go to char after addr
    lda text_buffer,y                               // read next char

    cmp #';'                                        // check if it's ;
    beq write_byte                                  // if so, go to write mode.
    ply
    ply                                             // remove mon addr from stack if we're not writing

    cmp #'r'                                        // check if it's r
    bne print_8_bytes                               // if it's not, dont run!
    jmp (zp.mon_addr)                               // if it is, RUN! :)
print_8_bytes:
    ldy #8                                          // 8 bytes to display
print_colon:
    lda #':'
    jsr vid.write_ascii                             // display colon
    inc zp.vid_ptr

print_data:
    lda #' '
    jsr vid.write_ascii                             // display space
    inc zp.vid_ptr
    lda (zp.mon_addr,x)                             // load the data at address mon_addr into A// x is still 0
    jsr vid.write_hex                               // display it
    inc zp.mon_addr                                 // increment address to print
    bne addr_no_carry                               // check if 0 after incrementing (if 0, need to carry)
    inc zp.mon_addr+1                               // if mon_addr became 0 after inc, need to carry to hi byte
addr_no_carry:
    dey                                             // decrement number of bytes left to print
    bne print_data                                  // if it's not zero, keep printing

enter_reset:
    jsr reset_prompt
    plx
    jmp mon_loop

write_byte:                                         // write data to mon_addr, starting with the byte at TEXT_BUFFER+y+1 (TEXT_BUFFER+y is //). x initialzed to 0
    iny
    lda text_buffer,y                               // load the next char to check if it's non-null
    beq print_after_write                           // if it's null, done writing. print the new data
    cmp #' '                                        // if it's space, consume it and move on
    beq write_byte
    jsr parse_hex_byte                              // parse the next byte, incrementing y
    sta (zp.mon_addr,x)                             // write the byte to mon addr pointer (x is 0)
    inc zp.mon_addr                                 // increment address to write to
    bne write_byte                                  // check if 0 after incrementing (if 0, need to carry)
    inc zp.mon_addr+1                               // if mon_addr became 0 after inc, need to carry to hi byte
    jmp write_byte   

print_after_write:
    pla                                             // get mon addr lo byte from stack
    sta zp.mon_addr                                 // reset mon addr lo byte
    pla                                             // get mon addr hi byte from stack
    sta zp.mon_addr+1                               // reset mon addr hi byte
    jmp print_8_bytes




/*
Handle a backspace press
*/
backspace_pressed:
    ldy #0
    lda (zp.txt_ptr),y                              // load the char under the cursor
    jsr vid.write_ascii                             // write it to the cursor position

    jsr dec_vid_txt_ptrs                            // decrement video pointer

    lda #' '
    sta (zp.txt_ptr),y                              // save a space to the previous character
    jsr vid.write_ascii                             // write that space to the screen
    force_cursor_update()

    jmp mon_loop


/*
Handle the extended keypresses (arrow keys)
*/
extended_pressed:
    ldy #0

    cmp #kb.K_LEFT
    bne not_left
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr dec_vid_txt_ptrs                            // decrement text pointer
    force_cursor_update()   
    jmp mon_loop
not_left:

    cmp #kb.K_RIGHT
    bne not_right
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr inc_vid_txt_ptrs                            // increment text pointer
    force_cursor_update()
    jmp mon_loop    
not_right:
    
    jmp mon_loop


/*
Fill the text buffer with 0s
*/
clear_text_buffer:
    pha
    phx

    ldx #31
    lda #0

clear_text_loop:                                        // write 0s to the text buffer
    sta text_buffer,x
    dex
    bpl clear_text_loop

    plx
    pla
    rts

/*
parse the hex byte (lowercase) ascii number starting at TEXT_BUFFER,y and store the result in A. Also increments y
*/
parse_hex_byte:                                         
    lda text_buffer,y                                    // load the first symbol
    jsr parse_hex_char                                  // parse it

    asl
    asl
    asl
    asl                                                 // move it into the hi nibble
    sta zp.B                                            // stash hi nibble in B

    iny
    lda text_buffer,y
    jsr parse_hex_char                                  // parse lo nibble

    ora zp.B                                            // load in hi nibble into A
    rts

parse_hex_char:                                         // parse the hex char (lower case) in A, store the result in A
    cmp #'a'                                            // check if it's a letter
    bcs parse_letter
    sec
    sbc #'0'                                            // get the offset from '0' for 0-9
    rts
parse_letter:
    sec
    sbc #('a'-10)                                       // get the offset from 'a' (plus 10) for a-f
    rts


/*
Redraw the prompt, clear the text buffer, and reset the vid and txt pointers
*/
reset_prompt:
    set_vid_ptr(15, 0)
    ldy #31
    lda #vid.CURSOR_OFF

reset_prompt_loop:
    sta (zp.vid_ptr),y
    dey
    bpl reset_prompt_loop

    lda #'>'                                                // write prompt
    jsr vid.write_ascii
    inc zp.vid_ptr

    jsr clear_text_buffer                                   // clear the text buffer
    set_txt_ptr(text_buffer)
    rts


inc_vid_txt_ptrs:
    pha
    inc2 zp.vid_ptr
    clamp_max2 zp.vid_ptr : vid.VRAM_TXT_END
    inc2 zp.txt_ptr
    clamp_max2 zp.txt_ptr : text_buffer_end
    pla
    rts


dec_vid_txt_ptrs:
    pha
    dec2 zp.vid_ptr
    clamp_min2 zp.vid_ptr : vram_inline_start
    dec2 zp.txt_ptr
    clamp_min2 zp.txt_ptr : text_buffer
    pla
    rts


.macro set_txt_ptr(addr) {
    lda #(<addr)
    sta zp.txt_ptr                                  
    lda #(>addr)
    sta zp.txt_ptr+1 
}


break:
    phy
    // Now stack has R_HI, R_LO, P, X, A, Y <
    jmp start_mon

irq:
    phx                                                     // stash X on stack
    tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    inx 
    inx                                                     // increment X twice so it points to the processor flags
    lda $100,x                                              // load the processor flags on the stack
    and #$10                                                // check for brk
    bne break                                               // if break bit is set, go to break handler
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
    pla
    plx
    rti



*=$fffc                                         // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address