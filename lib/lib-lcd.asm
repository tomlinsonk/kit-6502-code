#importonce
.filenamespace lcd

#import "lib-via.asm"
#import "lib-zp.asm"
#import "lib-math.asm"


.cpu _65c02
.encoding "ascii"

// VIA Port B bits
.const E  = %00001000
.const RW = %00000100
.const RS = %00000010

// LCD instructions
.const FUNCTION_SET_0 = %00100000
.const FUNCTION_SET = %00101000
.const DISPLAY_ON = %00001110
.const ENTRY_MODE = %00000110
.const CLEAR_DISPLAY = %00000001
.const CURSOR_RIGHT = %00010100
.const CURSOR_LEFT = %00010000
.const SCROLL_RIGHT = %00011100
.const SCROLL_LEFT = %00011000
.const RETURN_HOME = %00000010
.const SET_ADDR = %10000000

// aliases
.label num_to_dec = math.dividend


/* ---------------------------------------------------------------------------------------
Initialize the LCD. Set up 4-bit mode, clear the display, and turn it on.
*/
init:
    pha

    lda #%11111110                                  // setup LCD pins as output
    sta via.DDB

    lda #FUNCTION_SET_0                             // tell LCD to use 4 bit mode
    sta via.PORTB
    eor #E
    sta via.PORTB
    eor #E
    sta via.PORTB

    lda #FUNCTION_SET
    jsr send_instruction

    lda #CLEAR_DISPLAY
    jsr send_instruction

    lda #ENTRY_MODE
    jsr send_instruction

    lda #DISPLAY_ON
    jsr send_instruction

    pla
    rts



/* --------------------------------------------------------------------------------------- 
Read the LCD address counter into register A 
*/
read_addr:
    lda #%00001110                                  // setup LCD data bits as input
    sta via.DDB

    lda #RW                                         // tell LCD to send data
    sta via.PORTB
    lda #(RW | E)                                   // send enable bit to read high nibble
    sta via.PORTB
    lda via.PORTB                                   // read response
    and #%01110000                                  // zero out low nibble and busy flag
    sta zp.B                                        // stash high nibble

    lda #RW
    sta via.PORTB
    lda #(RW | E)                                   // toggle enable bit to read low nibble
    sta via.PORTB
    lda via.PORTB
    ror
    ror
    ror
    ror
    and #%00001111                                  // shift low nibble and zero out high nibble
    ora zp.B                                        // combine with stashed high nibble

    rts


/* --------------------------------------------------------------------------------------- 
Set the LCD address to the value in register A 
*/
set_addr:
    ora #SET_ADDR
    jsr send_instruction
    rts


/* --------------------------------------------------------------------------------------- 
Wait until the LCD is ready for a new instruction.
*/
wait:
    pha
    phx
    lda #%00001110                                  // setup LCD data bits as input
    sta via.DDB

busy:
    lda #RW                                         // tell LCD to send data
    sta via.PORTB

    lda #(RW | E)                                   // send enable bit
    sta via.PORTB

    lda via.PORTB                                   // read response

    ldx #RW                                         // do a second read, but ignore it
    stx via.PORTB
    ldx #(RW | E)                                   
    stx via.PORTB
    ldx via.PORTB

    and #%10000000                                  // check the busy flag from first read
    bne busy                                        // if busy flag set, loop

    lda #RW                                         // disable enable bit
    sta via.PORTB

    lda #%11111110                                  // setup LCD pins as output
    sta via.DDB

    plx
    pla
    rts


/* --------------------------------------------------------------------------------------- 
Send the instruction in register A to the LCD
*/
send_instruction:                                        
    jsr wait
    pha                                             // store on stack
    and #%11110000                                  // discard low nibble

    sta via.PORTB
    eor #E                                          // toggle enable bit on
    sta via.PORTB
    eor #E                                          // toggle enable bit off
    sta via.PORTB

    pla                                             // reload to send low nibble
    asl
    asl
    asl
    asl
    and #%11110000

    sta via.PORTB
    eor #E                                          // toggle enable bit on
    sta via.PORTB
    eor #E                                          // toggle enable bit off
    sta via.PORTB

    rts


/* --------------------------------------------------------------------------------------- 
Write the ASCII character in register A to the LCD
*/
write_ascii:                                                    
    jsr wait
    pha                                             // store on stack
    and #%11110000                                  // discard low nibble
    ora #RS                                         // turn RS bit on to write

    sta via.PORTB
    eor #E                                          // toggle enable bit on
    sta via.PORTB
    eor #E                                          // toggle enable bit off
    sta via.PORTB

    pla                                             // reload to send low nibble
    asl
    asl
    asl
    asl
    and #%11110000
    ora #RS                                         // turn RS bit on to write

    sta via.PORTB
    eor #E                                          // toggle enable bit on
    sta via.PORTB
    eor #E                                          // toggle enable bit off
    sta via.PORTB

    rts


/* --------------------------------------------------------------------------------------- 
Write the two byte number in (zp.B, zp.C) = math.dividend to the LCD in decimal.
Uses zp.H,I,J,K,L to reverse the digits.
*/
write_dec16:
    pha
    phx
    ldx #0

store_dec_loop:
    lda #10
    sta math.divisor
    lda #0
    sta math.divisor+1

    jsr math.divide16                             // divide math.dividend by 10

    lda math.remainder
    clc
    adc #'0'                                      // convert to ASCII code
    sta zp.H,x                                    // store digits in reverse order
    inx

    lda math.quotient                             // check if result is 0
    ora math.quotient+1

    bne store_dec_loop                            // if not, divide again
    dex

write_dec_loop:
    lda zp.H,x                                    // write digits in reverse order
    jsr write_ascii
    dex
    bpl write_dec_loop

    plx
    pla
    rts


/* --------------------------------------------------------------------------------------- 
Write the byte in register A to the LCD in hex. Non-destructive.
*/
write_hex:
    pha                                           
    
    pha                                             // stash byte on the stack

    ror
    ror
    ror
    ror
    and #%00001111                                  // pick out high nibble

    cmp #$0a
    bcc hi_nibble_num                               // branch if high nibble is number

    clc
    adc #('A'-10)                                   // set A to ascii letter
    jmp write_hi_nibble

hi_nibble_num:
    clc
    adc #'0'                                        // set A to ascii number

write_hi_nibble:
    jsr write_ascii                                 // write the high nibble of number

    pla                                             // restore byte from stack
    and #%00001111                                  // pick out low nibble

    cmp #$0a
    bcc lo_nibble_num                               // branch if low nibble is number

    clc
    adc #('A'-10)                                   // set A to ascii letter
    jmp write_lo_nibble

lo_nibble_num:
    clc
    adc #'0'                                        // set A to ascii number

write_lo_nibble:
    jsr write_ascii                                 // write the low nibble of number

    pla
    rts


