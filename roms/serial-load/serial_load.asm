.cpu _65c02
.encoding "ascii"

// VIA addresses
.label PORTA = $7811
.label PORTB = $7810
.label DDA = $7813
.label DDB = $7812
.label PCR = $781c
.label IFR = $781d
.label IER = $781e

// VIA Port B bits
.const E  = %00001000
.const RW = %00000100
.const RS = %00000010

// VIA interrupt bits
.const CA1_INT = %00000010
.const INT_ENABLE = %10000000
.const CA1_RISING = %00000001

// UART addresses
.label UART_RBR = $7820                                                    // receiver buffer register (read only)
.label UART_THR = $7820                                                    // transmitter holding register (write only)
.label UART_IER = $7821                                                    // interrupt enable register
.label UART_IIR = $7822                                                    // interrupt identification register
.label UART_FCR = $7822                                                    // FIFO control register
.label UART_LCR = $7823                                                    // line control register
.label UART_MCR = $7824                                                    // modem control register
.label UART_LSR = $7825                                                    // line status register
.label UART_MSR = $7826                                                    // modem status register
.label UART_DLL = $7820                                                    // divisor latch LSB (if DLAB=1)
.label UART_DLM = $7821                                                    // divisor latch MSB (if DLAB=1)

// UART settings
.const UART_TRIGGER_0 = %00000000
.const UART_NO_FIFO = %00000000
.const UART_DATA_INT = %00000001
.const UART_DLAB = %10000000
.const UART_8N1 = %00000011
.const UART_4800_LO = 13
.const UART_4800_HI = 0


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

// keyboard flags
.const R_SHIFT_DOWN = %00000001
.const L_SHIFT_DOWN = %00000010
.const RELEASE_NXT = %00000100
.const EXTENDED_NXT = %00001000

// keyboard scancodes
.const K_RELEASE = $f0
.const K_ESC = $76
.const K_BACKSPACE = $66
.const K_CAPS_LOCK = $58
.const K_ENTER = $5a
.const K_L_SHIFT = $12
.const K_R_SHIFT = $59
.const K_F11 = $78
.const K_F12 = $07

.const K_EXTENDED = $e0
.const KX_DOWN = $72
.const KX_UP = $75
.const KX_LEFT = $6b
.const KX_RIGHT = $74

// Zero page addresses
.label NUM1 = $00                                                    // two bytes
.label NUM2 = $02                                                    // two bytes
.label REM = $04                                                     // two bytes
.label NUM_TO_DEC = $06                                        // two bytes
.label DEC_REVERSE = $08                                     // five bytes
.label KB_READ_PTR = $0d                                     // one byte
.label KB_WRITE_PTR = $0e                                    // one byte
.label KB_FLAGS = $0f                                            // one byte
.label NIBBLE_STASH = $10                                    // one byte
.label UART_READ_PTR = $11                              // one byte
.label UART_WRITE_PTR = $12                             // one byte
.label VIDEO_PTR = $13                                  // two bytes

.label prg_start = $15                                  // two bytes
.label checksum1 = $17                                  // one byte
.label checksum2 = $18                                  // one byte
.label run_flag = $19                                   // one byte
.label prg_write_ptr = $1a                              // two bytes

.label UART_BUFFER = $f0                                // sixteen bytes

// Video addresses
.label VRAM = $7000
.label VRAM_INPUT = $71e0
.label VIDEO_START_LO = $00
.label VIDEO_START_HI = $70
.label VIDEO_END_LO = $FF
.label VIDEO_END_HI = $7F

// Video params
.const CURSOR_ON = %10001111
.const CURSOR_OFF = %10000000

// other RAM addresses


*=$8000                                                    // ROM starts at address $8000

reset:
    cli
    cld

    lda #CA1_RISING                                 // keyboard interrupt on rising edge
    sta PCR

    lda #(CA1_INT | INT_ENABLE)         // enable interrupts on CA1 (keyboard)
    sta IER

    lda #%11111110                                    // setup LCD pins as output
    sta DDB

    lda #%00000000                                    // setup kb pins as input
    sta DDA

    lda #FUNCTION_SET_0                         // tell LCD to use 4 bit mode
    sta PORTB
    eor #E
    sta PORTB
    eor #E
    sta PORTB

    lda #FUNCTION_SET
    jsr lcd_instruction

    lda #CLEAR_DISPLAY
    jsr lcd_instruction

    lda #ENTRY_MODE
    jsr lcd_instruction

    lda #DISPLAY_ON
    jsr lcd_instruction

    stz NUM_TO_DEC
    stz NUM_TO_DEC+1


    // Initialize the UART

    lda #UART_DLAB
    sta UART_LCR                                            // set the divisor latch access bit (DLAB)

    lda #UART_4800_LO
    sta UART_DLL                                            // store divisor low byte (4800 baud @ 1 MHz clock)

    lda #UART_4800_HI                                       
    sta UART_DLM                                            // store divisor hi byte

    lda UART_DLM
    jsr lcd_write_hex

    lda UART_DLL
    jsr lcd_write_hex

    lda #UART_8N1
    sta UART_LCR                                            // set 8 data bits, 1 stop bit, no parity, disable DLAB

    lda #UART_NO_FIFO
    sta UART_FCR                                            // disable the UART FIFO

    lda #UART_DATA_INT
    sta UART_IER                                            // enable received data interrupt

    stz UART_READ_PTR
    stz UART_WRITE_PTR


    // initialize loading variables
    stz checksum1
    stz checksum2
    stz prg_start
    stz prg_start+1    
    stz run_flag                                     



// -------- Blank screen ----------
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

    lda #$00
    sta VIDEO_PTR                                     // reset video pointer to $7000
    lda #$70
    sta VIDEO_PTR+1


load_addr_lo:
    sei                                             // disable interrupts
    lda UART_READ_PTR                               // load UART buffer read pointer
    cmp UART_WRITE_PTR                              // check if its equal to the UART buffer write pointer
    cli                                             // reenable interrupts
    beq load_addr_lo                                // loop until pointers differ

    ldx UART_READ_PTR
    lda UART_BUFFER,x                               // load byte into A
    sta prg_start
    jsr lcd_write_hex
    jsr update_read_ptr


load_addr_hi:
    sei                                             // disable interrupts
    lda UART_READ_PTR                               // load UART buffer read pointer
    cmp UART_WRITE_PTR                              // check if its equal to the UART buffer write pointer
    cli                                             // reenable interrupts
    beq load_addr_hi                                // loop until pointers differ

    ldx UART_READ_PTR
    lda UART_BUFFER,x                               // load byte into A
    sta prg_start+1
    jsr lcd_write_hex

    jsr update_read_ptr

    lda prg_start
    sta prg_write_ptr

    lda prg_start+1
    sta prg_write_ptr+1

load_prg:
    lda run_flag
    bne run_prg

    sei                                             // disable interrupts
    lda UART_READ_PTR                               // load UART buffer read pointer
    cmp UART_WRITE_PTR                              // check if its equal to the UART buffer write pointer
    cli                                             // reenable interrupts
    
    beq load_prg                                    // loop until pointers differ

    ldx UART_READ_PTR
    lda UART_BUFFER,x                               // load byte into A
    
    ldy #0
    sta (prg_write_ptr),y                           // write received byte
    inc prg_write_ptr                               // inc write ptr
    bne no_prg_write_carry                          
    inc prg_write_ptr+1                             // carry write ptr if needed

no_prg_write_carry:
    clc
    adc checksum1
    sta checksum1
    clc
    adc checksum2
    sta checksum2

    lda #SET_ADDR
    jsr lcd_instruction

    jsr update_read_ptr

    jmp load_prg


update_read_ptr:
   inx
   cpx #16
   bcc exit_update_read_ptr                          // if UART_READ_PTR reached 16, reset to 0
   ldx #0

exit_update_read_ptr:
   stx UART_READ_PTR                                 // update UART_READ_PTR
   rts


run_prg:
    lda #$43                                        // load C
    jsr lcd_write

    lda checksum1
    jsr lcd_write_hex
    lda checksum2
    jsr lcd_write_hex

    lda #$52                                        // load R
    jsr lcd_write

    lda prg_start+1
    jsr lcd_write_hex
    lda prg_start
    jsr lcd_write_hex

    jmp (prg_start)                                // run the loaded program!


divide:                                                         // divide two-byte NUM1 by two-byte NUM2. result goes in NUM1, remainder in REM
    pha
    phx
    phy

    ldx #16                                                 // counter for bits to rotate
    lda #0                                                    // initialize remainder to zero
    sta REM
    sta REM+1

div_loop:
    asl NUM1                                                // rotate zero into low bit of result, rotate into remainder
    rol NUM1+1
    rol REM
    rol REM+1

    sec                                 // set carry bit for borrowing, try subtracting num2 from remainder
    lda REM
    sbc NUM2
    tay
    lda REM+1
    sbc NUM2+1

    bcc div_after_save                            // if carry bit is clear, subtraction failed
    sty REM                                                 // if subtraction succeeded, save sub result and set bit of division result to 1
    sta REM+1
    inc NUM1

div_after_save:
    dex                                 // loop until x = 0 (16 times for two-byte division)
    bne div_loop

    ply
    plx
    pla
    rts

lcd_read_addr:                                            // read the LCD address counter into A
    lda #%00001110                                    // setup LCD data bits as input
    sta DDB

    lda #RW                                                 // tell LCD to send data
    sta PORTB
    lda #(RW | E)                                     // send enable bit to read high nibble
    sta PORTB
    lda PORTB                                             // read response
    and #%01110000                                    // zero out low nibble and busy flag
    sta NIBBLE_STASH                                // stash high nibble

    lda #RW
    sta PORTB
    lda #(RW | E)                                     // toggle enable bit to read low nibble
    sta PORTB
    lda PORTB
    ror
    ror
    ror
    ror
    and #%00001111                                    // shift low nibble and zero out high nibble
    ora NIBBLE_STASH                                // combine with stashed high nibble

    rts

lcd_wait:
    pha
    phx
    lda #%00001110                                    // setup LCD data bits as input
    sta DDB

lcd_busy:
    lda #RW                                                 // tell LCD to send data
    sta PORTB

    lda #(RW | E)                                     // send enable bit
    sta PORTB

    lda PORTB                                             // read response
    tax                                 // stash for second read

    lda #RW
    sta PORTB
    lda #(RW | E)                                     // toggle enable bit, ignore read
    sta PORTB
    lda PORTB

    txa
    and #%10000000                                    // check the busy flag
    bne lcd_busy                                        // if busy flag set, loop

    lda #RW
    sta PORTB

    lda #%11111110                                    // setup LCD pins as output
    sta DDB

    plx
    pla
    rts

lcd_instruction:                                        // sends the byte in register A
    jsr lcd_wait
    pha                                 // store on stack
    and #%11110000                                    // discard low nibble

    sta PORTB
    eor #E                                                    // toggle enable bit on
    sta PORTB
    eor #E                                                    // toggle enable bit off
    sta PORTB

    pla                                 // reload to send low nibble
    asl
    asl
    asl
    asl
    and #%11110000

    sta PORTB
    eor #E                                                    // toggle enable bit on
    sta PORTB
    eor #E                                                    // toggle enable bit off
    sta PORTB

    rts


lcd_write:                                                    // write the contents of A
    jsr lcd_wait
    pha                                 // store on stack
    and #%11110000                                    // discard low nibble
    ora #RS                                                 // turn RS bit on to write

    sta PORTB
    eor #E                                                    // toggle enable bit on
    sta PORTB
    eor #E                                                    // toggle enable bit off
    sta PORTB

    pla                                 // reload to send low nibble
    asl
    asl
    asl
    asl
    and #%11110000
    ora #RS                                                 // turn RS bit on to write

    sta PORTB
    eor #E                                                    // toggle enable bit on
    sta PORTB
    eor #E                                                    // toggle enable bit off
    sta PORTB

    rts


lcd_write_dec:                                            // write the number at NUM_TO_DEC (two bytes) in decimal
    pha
    phx
    ldx #0

    lda NUM_TO_DEC
    sta NUM1
    lda NUM_TO_DEC+1
    sta NUM1+1

store_dec_loop:
    lda #10
    sta NUM2
    lda #0
    sta NUM2+1

    jsr divide                                            // divide NUM1 by 10

    lda REM
    clc
    adc #'0'                                                // convert to ASCII code
    sta DEC_REVERSE,x                             // store digits in reverse order
    inx

    lda NUM1                                                // check if result is 0
    ora NUM1+1

    bne store_dec_loop                            // if not, divide again
    dex

write_dec_loop:
    lda DEC_REVERSE,x                             // write digits in reverse order
    jsr lcd_write
    dex
    bpl write_dec_loop

    plx
    pla
    rts


lcd_write_hex:                                            // write the number in reg A to the LCD

    phx

    tax                                 // stash in X

    ror
    ror
    ror
    ror
    and #%00001111                                    // pick out high nibble

    cmp #$0a
    bcc hi_nibble_num                             // branch if high nibble is number

    clc
    adc #('A'-10)                                     // set A to ascii letter (
    jmp write_hi_nibble

hi_nibble_num:
    clc
    adc #'0'                                                // set A to ascii number

write_hi_nibble:
    jsr lcd_write                                     // write the high nibble of number

    txa
    and #%00001111                                    // pick out low nibble

    cmp #$0a
    bcc lo_nibble_num                             // branch if low nibble is number

    clc
    adc #('A'-10)                                     // set A to ascii letter
    jmp write_lo_nibble

lo_nibble_num:
    clc
    adc #'0'                                                // set A to ascii number

write_lo_nibble:
    jsr lcd_write                                     // write the low nibble of number

    plx

    rts


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


irq:
    pha
    phx

    lda IFR                                                 // read VIA interrupt flags
    rol                                                     // IRQ flag -> C
    rol                                                     // Timer1 flag -> C
    rol                                                     // Timer 2 flag -> C
    rol                                                     // CB1 flag -> C
    rol                                                     // CB2 flag -> C
    rol                                                     // Shift reg flag -> C
    rol                                                     // CA1 flag -> C
    bcc keyboard_done
    // Handle keyboard interrupt
    lda PORTA                                               // clear kb interrupt
    dec run_flag
keyboard_done:

    lda UART_IIR
    ora #%00000100                                          // check for UART interrupt      
    beq uart_done                           

irq_uart:
   // Handle UART interrupt
    lda UART_RBR                                         // clear UART interrupt

    ldx UART_WRITE_PTR
    sta UART_BUFFER,x                                    // store received byte in buffer
    inx                                                  // increment write pointer
    cpx #16                                              // check if we've reached FIFO size
    bcc exit_irq_uart                                    // if UART_WRITE_PTR < 16, we're good to save it
    ldx #0                                               // otherwise, reset to 0
exit_irq_uart:
    stx UART_WRITE_PTR                                   // update KB_WRITE_PTR

uart_done:
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
