.cpu _65c02

// VIA addresses
.var PORTA = $7811
.var PORTB = $7810
.var DDA = $7813
.var DDB = $7812
.var PCR = $781c
.var IFR = $781d
.var IER = $781e
.var T1_LO = $7814
.var T1_HI = $7815
.var ACR = $781b

// VIA Port B bits
.var E    = %00001000
.var RW = %00000100
.var RS = %00000010

// VIA interrupt bits
.var CA1_INT = %00000010
.var TIMER1_INT = %01000000
.var INT_ENABLE = %10000000
.var CA1_RISING = %00000001

// VIA auxiliary control register bits
.var T1_CONTINUOUS = %01000000

// VIA interrupt flags
.var TIMER1_INT_F = %01000000
.var CA1_INT_F = %00000010

// LCD instructions
.var FUNCTION_SET_0 = %00100000
.var FUNCTION_SET = %00101000
.var DISPLAY_ON = %00001110
.var ENTRY_MODE = %00000110
.var CLEAR_DISPLAY = %00000001
.var CURSOR_RIGHT = %00010100
.var CURSOR_LEFT = %00010000
.var SCROLL_RIGHT = %00011100
.var SCROLL_LEFT = %00011000
.var RETURN_HOME = %00000010
.var SET_ADDR = %10000000

// keyboard flags
.var R_SHIFT_DOWN = %00000001
.var L_SHIFT_DOWN = %00000010
.var RELEASE_NXT = %00000100
.var EXTENDED_NXT = %00001000

// keyboard scancodes
.var K_RELEASE = $f0
.var K_ESC = $76
.var K_BACKSPACE = $66
.var K_CAPS_LOCK = $58
.var K_ENTER = $5a
.var K_L_SHIFT = $12
.var K_R_SHIFT = $59
.var K_F11 = $78
.var K_F12 = $07

.var K_EXTENDED = $e0
.var KX_DOWN = $72
.var KX_UP = $75
.var KX_LEFT = $6b
.var KX_RIGHT = $74

// Video addresses
.var VRAM = $7000
.var VIDEO_START_LO = $00
.var VIDEO_START_HI = $70
.var VIDEO_END_LO = $FF
.var VIDEO_END_HI = $7F

// Video params
.var CURSOR_ON = %10001111
.var CURSOR_OFF = %10000000

// Zero page addresses

.var NUM1 = $00                                                    // two bytes
.var NUM2 = $02                                                    // two bytes
.var REM = $04                                                     // two bytes
.var NUM_TO_DEC = $06                                        // two bytes
.var DEC_REVERSE = $08                                     // five bytes
.var KB_READ_PTR = $0d                                     // one byte
.var KB_WRITE_PTR = $0e                                    // one byte
.var KB_FLAGS = $0f                                            // one byte
.var NIBBLE_STASH = $10                                    // one byte
.var VIDEO_PTR = $11                                         // two bytes
.var CURSOR_BLINK_COUNT = $13                        // one byte
.var TEXT_PTR = $14                                            // two bytes    = text pointer offset from 7000, but from 0200
.var STASH_PTR = $15                                         // two bytes
.var MON_ADDR = $17


.var TEXT_BUFFER = $a0                                     // 32 bytes (a0-bf)
.var KB_BUFFER = $f0                                         // sixteen bytes (f0-ff)

// other RAM addresses


*=$8000                                                    // ROM starts at address $8000

jump_table:
    jmp reset                                             // 8000
    jmp vid_write_ascii                         // 8003
    jmp inc_vid_ptr                                 // 8006
    jmp shift_output_up                         // 8009

reset:
    cli
    cld

    lda #CA1_RISING                                 // keyboard interrupt on rising edge
    sta PCR

    lda #(CA1_INT | INT_ENABLE | TIMER1_INT)        // enable interrupts on CA1 (keyboard) and Timer 1 (cursor blink)
    sta IER

    lda #T1_CONTINUOUS
    sta ACR                                                 // set up timer 1 for continuous interrupts for cursor blink

    lda #%00000000                                    // setup kb pins as input
    sta DDA

    stz KB_FLAGS
    stz KB_READ_PTR
    stz KB_WRITE_PTR

    stz CURSOR_BLINK_COUNT                    // initialize cursor blink counter

    lda #$ff
    sta T1_LO                                             // write all 1s to timer 1 lo
    sta T1_HI                                             // write all 1s to timer 1 hi, starting the timer

    lda #CURSOR_OFF
    ldx #0

fill_blank:
    sta VRAM,x
    inx
    bne fill_blank                                    // first loop: 256 times
fill_blank2:
    sta VRAM+$0100,x
    inx
    bne fill_blank2                                 // second loop: 256 times

    jsr reset_prompt                                // write prompt, clear text buffer, place pointers appropriately


loop:                                                             // main loop
    sei                                                         // disable interrupts
    lda KB_READ_PTR                                 // load keyboard FIFO read pointer
    cmp KB_WRITE_PTR                                // check if its equal to the keyboard FIFO write pointer
    cli                                                         // reenable interrupts
    bne key_pressed                                 // if read != write, a key has been pressed. handle it

    ldy TEXT_PTR
    lda TEXT_BUFFER,y                             // load character under cursor
    bbr3 CURSOR_BLINK_COUNT,write_cursor        // if bit 3 of blink count is 0, turn off cursor
    lda #CURSOR_ON                                    // otherwise, load cursor char
write_cursor:
    jsr vid_write_ascii
    jmp loop                                                // loop


key_pressed:
    ldx KB_READ_PTR
    ldy KB_BUFFER,x                                 // load scancode into Y

    cpy #K_EXTENDED                                 // check for the extended scancode
    beq extended_pressed

    cpy #K_RELEASE                                    // check for the release scancode
    beq key_release_byte

    lda #RELEASE_NXT                                // check if this scancode is for a released key
    and KB_FLAGS
    bne key_released

    lda #EXTENDED_NXT                             // check if this is an extended key press
    and KB_FLAGS
    bne x_key_pressed_jmp

    cpy #K_L_SHIFT                                    // check for left shift press
    beq l_shift_pressed

    cpy #K_R_SHIFT                                    // check for right shift press
    beq r_shift_pressed

    cpy #K_ESC                                            // check for esc press
    beq esc_pressed

    cpy #K_ENTER                                        // check for enter press
    beq enter_pressed_jmp

    cpy #K_BACKSPACE                                // check for backspace
    beq backspace_pressed_jmp

    lda TEXT_PTR                                        // check if we are at the right of the line.
    cmp #30
    beq update_read_ptr                         // if so, don't allow more typing

    lda #(R_SHIFT_DOWN | L_SHIFT_DOWN)
    and KB_FLAGS                                        // check if either shift is down
    bne shift_down

    lda keymap,y                                        // load corresponding ascii into A
    jmp write_key_pressed

shift_down:
    lda keymap_shifted,y                        // load shifted ascii into A

write_key_pressed:
    jsr vid_write_ascii                         // write the pressed key
    ldy TEXT_PTR
    sta TEXT_BUFFER,y                             // save ascii to text buffer
    jsr inc_vid_ptr
    inc TEXT_PTR
    jmp update_read_ptr

set_kb_flag:
    ora KB_FLAGS
    sta KB_FLAGS

update_read_ptr:
    inx
    cpx #16
    bcc exit_key_pressed                        // if KB_READ_PTR reached 16, reset to 0
    ldx #0

exit_key_pressed:
    stx KB_READ_PTR                                 // update KB_READ_PTR
    jmp loop


x_key_pressed_jmp:
    jmp x_key_pressed                             // long range jump to fix branch out of range

backspace_pressed_jmp:
    jmp backspace_pressed                     // long range jump to fix branch out of range

enter_pressed_jmp:
    jmp enter_pressed                     // long range jump to fix branch out of range

extended_pressed:
    lda #EXTENDED_NXT
    jmp set_kb_flag


key_release_byte:
    lda #RELEASE_NXT
    jmp set_kb_flag


l_shift_pressed:
    lda #L_SHIFT_DOWN
    jmp set_kb_flag


r_shift_pressed:
    lda #R_SHIFT_DOWN
    jmp set_kb_flag


esc_pressed:
    jmp reset

key_released:
    lda KB_FLAGS
    and #EXTENDED_NXT
    bne exit_key_released                     // if we're releasing an extended key, don't check shift release

    cpy #K_L_SHIFT
    beq l_shift_released

    cpy #K_R_SHIFT
    beq r_shift_released

exit_key_released:
    lda KB_FLAGS
    eor #RELEASE_NXT                                // flip release next bit, since we're handling it
    and #(~EXTENDED_NXT)                        // zero out the extended next bit
    sta KB_FLAGS

    jmp update_read_ptr



l_shift_released:
    lda KB_FLAGS
    eor #L_SHIFT_DOWN
    sta KB_FLAGS
    jmp exit_key_released

r_shift_released:
    lda KB_FLAGS
    eor #R_SHIFT_DOWN
    sta KB_FLAGS
    jmp exit_key_released


enter_pressed:
    phx
    ldx #0                                                    // load offset of 0 for indirect indexed addressing / offset for writing

    jsr shift_output_up

    lda #$71
    sta VIDEO_PTR+1
    lda #$c0
    sta VIDEO_PTR

    ldy #0                                                    // start at the beginning of the text buffer
    jsr parse_hex_byte                            // load hi hex byte into A and increment y
    sta MON_ADDR+1                                    // store the hi byte
    jsr vid_write_hex                             // display it in hex
    iny                                                         // increment y again to go to start of next byte
    jsr parse_hex_byte                            // load lo hex byte into A and increment y
    sta MON_ADDR                                        // store the lo byte
    jsr vid_write_hex                             // display it in hex

    iny                                                         // increment y to go to char after addr
    lda TEXT_BUFFER,y                             // read next char

    cmp #';'                                                // check if it's ;
    beq write_byte                                    // if so, go to write mode.

    cmp #'r'                                                // check if it's r
    bne dont_run                                        // if it's not, dont run!
    jmp (MON_ADDR)                                    // if it is, RUN! :)
dont_run:
    ldy #1                                                    // y is now number of bytes to print. 1 if no -
    cmp #'-'                                                // check if next char is -
    bne print_colon                                 // skip next line if -
    ldy #8                                                    // 8 bytes to display
print_colon:
    lda #':'
    jsr vid_write_ascii                         // display colon
    inc VIDEO_PTR

print_data:
    lda #' '
    jsr vid_write_ascii                         // display space
    inc VIDEO_PTR
    lda (MON_ADDR,x)                                // load the data at address MON_ADDR into A// x is still 0
    jsr vid_write_hex                             // display it
    inc MON_ADDR                                        // increment address to print
    bne addr_no_carry                             // check if 0 after incrementing (if 0, need to carry)
    inc MON_ADDR+1                                    // if MON_ADDR became 0 after inc, need to carry to hi byte
addr_no_carry:
    dey                                                         // decrement number of bytes left to print
    bne print_data                                    // if it's not zero, keep printing

enter_reset:
    jsr reset_prompt
    plx
    jmp update_read_ptr

write_byte:                                             // write data to MON_ADDR, starting with the byte at TEXT_BUFFER+y+1 (TEXT_BUFFER+y is //). x initialzed to 0
    iny
    lda TEXT_BUFFER,y                             // load the next char to check if it's non-null
    beq enter_reset                                 // if it's null, done writing
    cmp #' '                                                // if it's space, consume it and move on
    beq write_byte
    jsr parse_hex_byte                            // parse the next byte, incrementing y
    sta (MON_ADDR,x)                                // write the byte to mon addr pointer (x is 0)
    inc MON_ADDR                                        // increment address to write to
    bne write_byte                                    // check if 0 after incrementing (if 0, need to carry)
    inc MON_ADDR+1                                    // if MON_ADDR became 0 after inc, need to carry to hi byte
    jmp write_byte                                    // write next byte


backspace_pressed:
    ldy TEXT_PTR
    beq return_from_x_press                 // if we're at 0 in the text buffer, can't go left

    lda TEXT_BUFFER,y                             // load the char under the cursor
    jsr vid_write_ascii                         // write it to the cursor position

    jsr dec_vid_ptr                                 // decrement video pointer
    dec TEXT_PTR

    lda #0
    ldy TEXT_PTR
    sta TEXT_BUFFER,y                             // save a null to the previous character
    jsr vid_write_ascii                         // write that null to the screen

    jmp update_read_ptr


x_key_pressed:
    lda KB_FLAGS
    and #(~EXTENDED_NXT)
    sta KB_FLAGS                                        // clear the extended flag

    cpy #KX_DOWN
    beq down_pressed

    cpy #KX_UP
    beq up_pressed

    cpy #KX_RIGHT
    beq right_pressed

    cpy #KX_LEFT
    beq left_pressed
return_from_x_press:
    jmp update_read_ptr

down_pressed:
    jmp update_read_ptr

up_pressed:
    jmp update_read_ptr

right_pressed:
    ldy TEXT_PTR
    cpy #30
    beq return_from_x_press                 // if we're at 30ß in the text buffer, can't go right

    lda TEXT_BUFFER,y                             // load the char under the cursor
    jsr vid_write_ascii                         // write it to the cursor position

    jsr inc_vid_ptr                                 // increment video pointer
    inc TEXT_PTR                                        // increment text pointer
    jmp update_read_ptr


left_pressed:
    ldy TEXT_PTR
    beq return_from_x_press                 // if we're at 0 in the text buffer, can't go left

    lda TEXT_BUFFER,y                             // load the char under the cursor
    jsr vid_write_ascii                         // write it to the cursor position

    jsr dec_vid_ptr                                 // decrement video and text pointers
    dec TEXT_PTR
    jmp update_read_ptr



// subroutine
// write the ascii char in A to the address in VIDEO_PTR+0, +1
// writes upper case as inverted, assuming data bit 6 in text mode is INV
// also increments the video pointer and text pointer, and wraps at 512
vid_write_ascii:
    pha
    phy

    bmi video_write                                 // if leading bit is 1, this is a graphic char. write it.

    bne write_ascii_symbol                    // if this is a not a 0, write the symbol
    lda #CURSOR_OFF
    jmp video_write                                 // if this is a 0, write blank

write_ascii_symbol:
    cmp #$60                                                // check if code is $60 or more
    bcc video_write                                 // if it's below $60, we can immediately write it
    and #%00011111                                    // otherwise, it's a lowercase letter. only keep bottom 5 bits

video_write:
    ldy #0
    sta (VIDEO_PTR),y                             // write six bit ascii to memory at address in VIDEO_PTR

    ply
    pla
    rts


// subroutine
// increment the video and pointer, wrapping from 512 to 0
inc_vid_ptr:
    inc VIDEO_PTR                                     // increment the video pointer
    bne exit_inc_ptr                                // check if it became 0 when incremented. If not, we're good to return
    inc VIDEO_PTR+1                                 // also carry to hi byte of video ptr
    bbr1 VIDEO_PTR+1,exit_inc_ptr     // if 2s bit of hi byte is 0, we're good to return
    rmb1 VIDEO_PTR+1                                // otherwise, we're passing 512 chars and need to reset to 0
exit_inc_ptr:
    rts


// subroutine
// decrement the video pointer, wrapping from 0 to 512
dec_vid_ptr:
    pha
    dec VIDEO_PTR                                     // decrement the video pointer
    lda #$ff
    cmp VIDEO_PTR                                     // check if we carried
    bne exit_dec_video_ptr                    // if not, good to return
    dec VIDEO_PTR+1                                 // if we did carry, decrement hi byte
    lda VIDEO_PTR+1                                 // load the video pointer hi byte
    cmp #VIDEO_START_HI                         // compare with smallest valid hi byte for VRAM
    bcs exit_dec_video_ptr                    // if video pointer hi byte is >=, can return
    lda #$71                                                // otherwise, reset it to end of screen
    sta VIDEO_PTR+1
exit_dec_video_ptr:
    pla
    rts


// subroutine
// add the value in A to the the video pointer, wrapping from 512 to 0
add_vid_ptr:                                                // retrieve A from the stack
    clc
    adc VIDEO_PTR                                     // add A to the video pointer
    sta VIDEO_PTR

    bcc exit_add_ptrs                             // check if we need to carry. If not, we're good to return
    inc VIDEO_PTR+1                                 // also carry to hi byte of video ptr

    bbr1 VIDEO_PTR+1,exit_add_ptrs    // if 2s bit of hi byte is 0, we're good to return
    rmb1 VIDEO_PTR+1                                // otherwise, we're passing 512 chars and need to reset to 512
exit_add_ptrs:
    rts


// subroutine
// fills the text buffer with 0s
clear_text_buffer:
    pha
    phx

    ldx #31
    lda #0

clear_text_loop:                                        // write 0s to the text buffer
    sta TEXT_BUFFER,x
    dex
    bpl clear_text_loop

    plx
    pla
    rts


vid_write_hex:                                        // write the number in reg A to the screen starting at VIDEO_PTR. also incremenrt vid ptr twice
    pha                                                         // stash number on stack

    ror
    ror
    ror
    ror
    and #%00001111                                    // pick out high nibble

    cmp #$0a
    bcc hi_nibble_num                             // branch if high nibble is number

    clc
    adc #('a'-10)                                     // set A to ascii letter (
    jmp write_hi_nibble

hi_nibble_num:
    clc
    adc #'0'                                                // set A to ascii number

write_hi_nibble:
    jsr vid_write_ascii                         // write the high nibble of number
    jsr inc_vid_ptr

    pla                                                         // retrieve number from stack
    and #%00001111                                    // pick out low nibble

    cmp #$0a
    bcc lo_nibble_num                             // branch if low nibble is number

    clc
    adc #('a'-10)                                     // set A to ascii letter
    jmp write_lo_nibble

lo_nibble_num:
    clc
    adc #'0'                                                // set A to ascii number

write_lo_nibble:
    jsr vid_write_ascii                         // write the low nibble of number
    jsr inc_vid_ptr

    rts


parse_hex_byte:                                     // parse the hex byte (lowercase) ascii number starting at TEXT_BUFFER,y and store the result in A. Also increments y
    lda TEXT_BUFFER,y                             // load the first symbol
    jsr parse_hex_char                            // parse it

    asl
    asl
    asl
    asl                                                         // move it into the hi nibble
    sta NIBBLE_STASH                                // stash hi nibble

    iny
    lda TEXT_BUFFER,y
    jsr parse_hex_char                            // parse lo nibble

    ora NIBBLE_STASH                                // load in hi nibble into A
    rts


parse_hex_char:                                         // parse the hex char (lower case) in A, store the result in A
    cmp #'a'                                                // check if it's a letter
    bcs parse_letter
    sec
    sbc #'0'                                                // get the offset from '0' for 0-9
    rts
parse_letter:
    sec
    sbc #('a'-10)                                     // get the offset from 'a' (plus 10) for a-f
    rts


reset_prompt:
    ldy #31
    lda #CURSOR_OFF

reset_prompt_loop:
    sta VRAM,y
    dey
    bpl reset_prompt_loop

    lda #$e0
    sta VIDEO_PTR                                     // reset video pointer to $71e0
    lda #$71
    sta VIDEO_PTR+1

    lda #'>'                                                // write prompt
    jsr vid_write_ascii
    inc VIDEO_PTR

    jsr clear_text_buffer                     // clear the text buffer
    stz TEXT_PTR
    rts


shift_output_up:
    pha
    phy
    phx

    lda #$70
    sta VIDEO_PTR+1
    lda #$00
    sta VIDEO_PTR                                     // start video ptr at $7000

    lda #$70
    sta STASH_PTR+1
    lda #32
    sta STASH_PTR

    ldx #14                                                 // copy next line down 14 times// row index

shift_row_loop:
    ldy #31                                                 // column index

shift_col_loop:
    lda (STASH_PTR),y
    sta (VIDEO_PTR),y                             // copy row into previous row
    dey
    bpl shift_col_loop

    lda STASH_PTR
    clc
    adc #32                                                 // add 32 to stash ptr
    sta STASH_PTR
    bcc no_inc_stash_hi
    inc STASH_PTR+1

no_inc_stash_hi:
    lda VIDEO_PTR
    clc
    adc #32                                                 // add 32 to vid pointer
    sta VIDEO_PTR
    bcc no_inc_vid_hi
    inc VIDEO_PTR+1

no_inc_vid_hi:
    dex
    bne shift_row_loop

    lda #$71
    sta VIDEO_PTR+1
    lda #$c0
    sta VIDEO_PTR                                     // set video ptr to $71c0

    ldy #31
    lda #CURSOR_OFF

clear_output_line_loop:
    sta (VIDEO_PTR),y
    dey
    bpl clear_output_line_loop

    plx
    ply
    pla
    rts


irq:
    pha
    phx
    lda IFR                                                 // read interrupt flags
    rol                                                         // IRQ flag -> C
    rol                                                         // Timer1 flag -> C
    bcc timer1_done

    // Handle Timer 1 interrupt
    ldx T1_LO                                             // clear timer 1 interrupt by reading lo t1 byte
    inc CURSOR_BLINK_COUNT                    // increment the blink counter

timer1_done:
    rol                                                         // Timer 2 flag -> C
    rol                                                         // CB1 flag -> C
    rol                                                         // CB2 flag -> C
    rol                                                         // Shift reg flag -> C
    rol                                                         // CA1 flag -> C
    bcc keyboard_done

    // Handle keyboard interrupt
    lda PORTA                                             // read scancode
    ldx KB_WRITE_PTR
    sta KB_BUFFER,x                                 // store keyboard scancode in buffer
    inx                                                         // increment write pointer
    cpx #16                                                 // check if we've reached FIFO size
    bcc exit_irq_keyboard                     // if KB_WRITE_PTR < 16, we're good to save it
    ldx #0                                                    // otherwise, reset to 0
exit_irq_keyboard:
    stx KB_WRITE_PTR                                // update KB_WRITE_PTR

keyboard_done:

    plx
    pla
    rti

keymap:
    .text "????????????? `?"            // 00-0F
    .text "?????q1???zsaw2?"            // 10-1F
    .text "?cxde43?? vftr5?"            // 20-2F
    .text "?nbhgy6???mju78?"            // 30-3F
    .text "?,kio09??./l;p-?"            // 40-4F
    .text "??'?[=?????]?\??"            // 50-5F
    .text "?????????1?47???"            // 60-6F
    .text "0.2568???+3-*9??"            // 70-7F
    .text "????????????????"            // 80-8F
    .text "????????????????"            // 90-9F
    .text "????????????????"            // A0-AF
    .text "????????????????"            // B0-BF
    .text "????????????????"            // C0-CF
    .text "????????????????"            // D0-DF
    .text "????????????????"            // E0-EF
    .text "????????????????"            // F0-FF
keymap_shifted:
    .text "????????????? ~?"            // 00-0F
    .text "?????Q!???ZSAW@?"            // 10-1F
    .text "?CXDE#$?? VFTR%?"            // 20-2F
    .text "?NBHGY^???MJU&*?"            // 30-3F
    .text "?<KIO)(??>?L:P_?"            // 40-4F
    .text @"??\"?{+?????}?|??"            // 50-5F
    .text "?????????1?47???"            // 60-6F
    .text "0.2568???+3-*9??"            // 70-7F
    .text "????????????????"            // 80-8F
    .text "????????????????"            // 90-9F
    .text "????????????????"            // A0-AF
    .text "????????????????"            // B0-BF
    .text "????????????????"            // C0-CF
    .text "????????????????"            // D0-DF
    .text "????????????????"            // E0-EF
    .text "????????????????"            // F0-FF



*=$fffc                                         // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address