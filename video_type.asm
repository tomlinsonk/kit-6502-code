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
.var E  = %00001000
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

.var NUM1 = $00                          // two bytes
.var NUM2 = $02                          // two bytes
.var REM = $04                           // two bytes
.var NUM_TO_DEC = $06                    // two bytes
.var DEC_REVERSE = $08                   // five bytes
.var KB_READ_PTR = $0d                   // one byte
.var KB_WRITE_PTR = $0e                  // one byte
.var KB_FLAGS = $0f                      // one byte
.var NIBBLE_STASH = $10                  // one byte
.var VIDEO_PTR = $11                     // two bytes
.var CURSOR_BLINK_COUNT = $13            // one byte
.var TEXT_PTR = $14                      // two bytes  = text pointer offset from 7000, but from 0200

.var KB_BUFFER = $f0                     // sixteen bytes (f0-ff)

// other RAM addresses
.var TEXT_BUFFER = $0200                 // 512 bytes (0200-03ff)



    *=$8000                          // ROM starts at address $8000

reset:
    cli
    cld

    lda #CA1_RISING                 // keyboard interrupt on rising edge
    sta PCR

    lda #(CA1_INT | INT_ENABLE | TIMER1_INT)    // enable interrupts on CA1 (keyboard) and Timer 1 (cursor blink)
    sta IER

    lda #T1_CONTINUOUS
    sta ACR                         // set up timer 1 for continuous interrupts for cursor blink

    lda #%00000000                  // setup kb pins as input
    sta DDA

    stz KB_FLAGS
    stz KB_READ_PTR
    stz KB_WRITE_PTR


    stz VIDEO_PTR                   // initialize video pointer to $7000
    lda #$70
    sta VIDEO_PTR+1

    stz CURSOR_BLINK_COUNT          // initialize cursor blink counter

    stz TEXT_PTR                    // reset text pointer to $0200
    lda #$02
    sta TEXT_PTR+1

    jsr clear_text_buffer           // clear the text buffer

    lda #$ff
    sta T1_LO                       // write all 1s to timer 1 lo
    sta T1_HI                       // write all 1s to timer 1 hi, starting the timer

    lda #CURSOR_OFF
    ldx #0

fill_blank:
    sta VRAM,x
    inx
    bne fill_blank                  // first loop: 256 times
fill_blank2:
    sta VRAM+$0100,x
    inx
    bne fill_blank2                 // second loop: 256 times

    stz VIDEO_PTR                   // reset video pointer to $7000
    lda #$70
    sta VIDEO_PTR+1

loop:                               // main loop
    sei                             // disable interrupts
    lda KB_READ_PTR                 // load keyboard FIFO read pointer
    cmp KB_WRITE_PTR                // check if its equal to the keyboard FIFO write pointer
    cli                             // reenable interrupts
    bne key_pressed                 // if read != write, a key has been pressed. handle it

    ldy #0
    lda (TEXT_PTR),y                // load character under cursor
    bbr3 CURSOR_BLINK_COUNT,write_cursor    // if bit 3 of blink count is 0, turn off cursor
    lda #CURSOR_ON                  // otherwise, load cursor char
write_cursor:
    jsr vid_write_ascii
    jmp loop                        // loop


key_pressed:
    ldx KB_READ_PTR
    ldy KB_BUFFER,x                 // load scancode into Y

    cpy #K_EXTENDED                 // check for the extended scancode
    beq extended_pressed

    cpy #K_RELEASE                  // check for the release scancode
    beq key_release_byte

    lda #RELEASE_NXT                // check if this scancode is for a released key
    and KB_FLAGS
    bne key_released

    lda #EXTENDED_NXT               // check if this is an extended key press
    and KB_FLAGS
    bne x_key_pressed_jmp

    cpy #K_L_SHIFT                  // check for left shift press
    beq l_shift_pressed

    cpy #K_R_SHIFT                  // check for right shift press
    beq r_shift_pressed

    cpy #K_ESC                      // check for esc press
    beq esc_pressed

    cpy #K_ENTER                    // check for enter press
    beq enter_pressed

    cpy #K_BACKSPACE                // check for backspace
    beq backspace_pressed_jmp

    lda #(R_SHIFT_DOWN | L_SHIFT_DOWN)
    and KB_FLAGS                    // check if either shift is down
    bne shift_down

    lda keymap,y                    // load corresponding ascii into A
    jsr vid_write_ascii             // write the pressed key to VRAM
    ldy #0
    sta (TEXT_PTR),y                // save ascii to text buffer
    jsr inc_vid_txt_ptrs
    jmp update_read_ptr

shift_down:
    lda keymap_shifted,y            // load shifted ascii into A
    jsr vid_write_ascii             // write the pressed key
    ldy #0
    sta (TEXT_PTR),y                // save ascii to text buffer
    jsr inc_vid_txt_ptrs
    jmp update_read_ptr

set_kb_flag:
    ora KB_FLAGS
    sta KB_FLAGS

update_read_ptr:
    inx
    cpx #16
    bcc exit_key_pressed            // if KB_READ_PTR reached 16, reset to 0
    ldx #0

exit_key_pressed:
    stx KB_READ_PTR                 // update KB_READ_PTR
    jmp loop


x_key_pressed_jmp:
    jmp x_key_pressed               // long range jump to fix branch out of range

backspace_pressed_jmp:
    jmp backspace_pressed           // long range jump to fix branch out of range

extended_pressed:
    lda #EXTENDED_NXT
    jmp set_kb_flag


key_release_byte:
    lda #RELEASE_NXT
    jmp set_kb_flag


key_released:
    lda KB_FLAGS
    and #EXTENDED_NXT
    bne exit_key_released           // if we're releasing an extended key, don't check shift release

    cpy #K_L_SHIFT
    beq l_shift_released

    cpy #K_R_SHIFT
    beq r_shift_released

exit_key_released:
    lda KB_FLAGS
    eor #RELEASE_NXT                // flip release next bit, since we're handling it
    and #(~EXTENDED_NXT)            // zero out the extended next bit
    sta KB_FLAGS

    jmp update_read_ptr


l_shift_pressed:
    lda #L_SHIFT_DOWN
    jmp set_kb_flag


r_shift_pressed:
    lda #R_SHIFT_DOWN
    jmp set_kb_flag


esc_pressed:
  jmp reset

enter_pressed:
    ldy #0
    lda (TEXT_PTR),y                // load the char under the cursor
    jsr vid_write_ascii             // write it to the cursor position

    lda #%11100000
    and VIDEO_PTR
    sta VIDEO_PTR                   // reset video pointer to start of line

    lda #%11100000
    and TEXT_PTR
    sta TEXT_PTR                    // reset text pointer to start of line

    lda #32
    jsr add_vid_txt_ptrs            // add 32 to video and text pointers to jump to start of next line

    jmp update_read_ptr

backspace_pressed:
    ldy #0
    lda (TEXT_PTR),y                // load the char under the cursor
    jsr vid_write_ascii             // write it to the cursor position

    jsr dec_vid_txt_ptrs            // decrement video pointer

    lda #0
    sta (TEXT_PTR),y                // save a null to the previous character
    jsr vid_write_ascii             // write that null to the screen

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


x_key_pressed:
    lda KB_FLAGS
    and #(~EXTENDED_NXT)
    sta KB_FLAGS                    // clear the extended flag

    cpy #KX_DOWN
    beq down_pressed

    cpy #KX_UP
    beq up_pressed

    cpy #KX_RIGHT
    beq right_pressed

    cpy #KX_LEFT
    beq left_pressed

    jmp update_read_ptr

down_pressed:
    ldy #0
    lda (TEXT_PTR),y                // load the char under the cursor
    jsr vid_write_ascii             // write it to the cursor position

    lda #32
    jsr add_vid_txt_ptrs            // add 32 to the text and video pointers to move down one line
    jmp update_read_ptr

up_pressed:
    jmp update_read_ptr

right_pressed:
    ldy #0
    lda (TEXT_PTR),y                // load the char under the cursor
    jsr vid_write_ascii             // write it to the cursor position

    jsr inc_vid_txt_ptrs            // increment video and text pointers
    jmp update_read_ptr


left_pressed:
    ldy #0
    lda (TEXT_PTR),y                // load the char under the cursor
    jsr vid_write_ascii             // write it to the cursor position

    jsr dec_vid_txt_ptrs            // decrement video and text pointers
    jmp update_read_ptr



// subroutine
// write the ascii char in A to the address in VIDEO_PTR+0, +1
// writes upper case as inverted, assuming data bit 6 in text mode is INV
// also increments the video pointer and text pointer, and wraps at 512
vid_write_ascii:
    pha
    phy

    bmi video_write                 // if leading bit is 1, this is a graphic char. write it.

    bne write_ascii_symbol          // if this is a not a 0, write the symbol
    lda #CURSOR_OFF
    jmp video_write                 // if this is a 0, write blank

write_ascii_symbol:
    cmp #$60                        // check if code is $60 or more
    bcc video_write                 // if it's below $60, we can immediately write it
    and #%00011111                  // otherwise, it's a lowercase letter. only keep bottom 5 bits

video_write:
    ldy #0
    sta (VIDEO_PTR),y               // write six bit ascii to memory at address in VIDEO_PTR

    ply
    pla
    rts


// subroutine
// increment the video and text pointers, wrapping from 512 to 0
inc_vid_txt_ptrs:
    inc TEXT_PTR                    // increment the text pointer
    inc VIDEO_PTR                   // increment the video pointer
    bne exit_inc_ptrs               // check if it became 0 when incremented. If not, we're good to return
    inc TEXT_PTR+1                  // if it became 0, carry to hi byte of text ptr
    inc VIDEO_PTR+1                 // also carry to hi byte of video ptr
    bbr1 VIDEO_PTR+1,exit_inc_ptrs  // if 2s bit of hi byte is 0, we're good to return
    rmb1 VIDEO_PTR+1                // otherwise, we're passing 512 chars and need to reset to 0
    pha
    lda #$02                        // also reset text ptr hi byte to 02
    sta TEXT_PTR+1
    pla
exit_inc_ptrs:
    rts


// subroutine
// decrement the video and text pointers, wrapping from 0 to 512
dec_vid_txt_ptrs:
    pha
    dec TEXT_PTR
    dec VIDEO_PTR                   // decrement the video pointer
    lda #$ff
    cmp VIDEO_PTR                   // check if we carried
    bne exit_dec_video_ptr          // if not, good to return
    dec TEXT_PTR+1
    dec VIDEO_PTR+1                 // if we did carry, decrement hi byte
    lda VIDEO_PTR+1                 // load the video pointer hi byte
    cmp #VIDEO_START_HI             // compare with smallest valid hi byte for VRAM
    bcs exit_dec_video_ptr          // if video pointer hi byte is >=, can return
    lda #$71                        // otherwise, reset it to end of screen
    sta VIDEO_PTR+1
    lda #$03
    sta TEXT_PTR+1                  // also reset text pointer to end of buffer
exit_dec_video_ptr:
    pla
    rts


// subroutine
// add the value in A to the the video and text pointers, wrapping from 512 to 0
add_vid_txt_ptrs:
    pha                             // stash A on the stack
    clc
    adc TEXT_PTR                    // add A to the text pointer
    sta TEXT_PTR

    pla                             // retrieve A from the stack
    clc
    adc VIDEO_PTR                   // add A to the video pointer
    sta VIDEO_PTR

    bcc exit_add_ptrs               // check if we need to carry. If not, we're good to return
    inc TEXT_PTR+1                  // if it became 0, carry to hi byte of text ptr
    inc VIDEO_PTR+1                 // also carry to hi byte of video ptr

    bbr1 VIDEO_PTR+1,exit_inc_ptrs  // if 2s bit of hi byte is 0, we're good to return
    rmb1 VIDEO_PTR+1                // otherwise, we're passing 512 chars and need to reset to 0
    pha
    lda #$02                        // also reset text ptr hi byte to 02
    sta TEXT_PTR+1
    pla
exit_add_ptrs:
    rts


// subroutine
// fills the text buffer with 0s
clear_text_buffer:
    pha
    phx

    ldx #0
    lda #0

clear_text_loop:                    // write 0s to the first half of the text buffer
    sta TEXT_BUFFER,x
    inx
    bne clear_text_loop

clear_text_loop2:
    sta TEXT_BUFFER+$0100,x         // write 0s to the second half of the text buffer
    inx
    bne clear_text_loop2

    plx
    pla
    rts


irq:
    pha
    phx
    lda IFR                         // read interrupt flags
    rol                             // IRQ flag -> C
    rol                             // Timer1 flag -> C
    bcc timer1_done

    // Handle Timer 1 interrupt
    ldx T1_LO                       // clear timer 1 interrupt by reading lo t1 byte
    inc CURSOR_BLINK_COUNT          // increment the blink counter

timer1_done:
    rol                             // Timer 2 flag -> C
    rol                             // CB1 flag -> C
    rol                             // CB2 flag -> C
    rol                             // Shift reg flag -> C
    rol                             // CA1 flag -> C
    bcc keyboard_done

    // Handle keyboard interrupt
    lda PORTA                       // read scancode
    ldx KB_WRITE_PTR
    sta KB_BUFFER,x                 // store keyboard scancode in buffer
    inx                             // increment write pointer
    cpx #16                         // check if we've reached FIFO size
    bcc exit_irq_keyboard           // if KB_WRITE_PTR < 16, we're good to save it
    ldx #0                          // otherwise, reset to 0
exit_irq_keyboard:
    stx KB_WRITE_PTR                // update KB_WRITE_PTR

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


    *=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
