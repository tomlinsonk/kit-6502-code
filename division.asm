PORTA = $7811
PORTB = $7810
DDA = $7813
DDB = $7812

LCD_DATA = $00      ; one byte for stashing LCD display char
NUM1 = $01          ; two bytes at $01 and $02
NUM2 = $03          ; two bytes at $03 and $04
REM = $05           ; two bytes at $05 and $06
NUM_TO_DEC = $07    ; two bytes at $07 and $08
STASH = $09         ; two bytes at $09 and $0a

DEC_REVERSE = $f0   ; up to five bytes (f0-f4)

DIVIDEND_LO = $21
DIVIDEND_HI = $6e   ; 28193

DIVISOR_LO = $7b
DIVISOR_HI = $03    ; 891


E  = %00001000
RW = %00000100
RS = %00000010

FUNCTION_SET = %00101000
FUNCTION_SET_0 = %00100000

DISPLAY_ON = %00001110
ENTRY_MODE = %00000110
CLEAR_DISPLAY = %00000001

  .org $8000          ; ROM starts at address $8000

start:

  lda #%11111110      ; setup LCD pins as output
  sta DDB

  lda #FUNCTION_SET_0 ; tell LCD to use 4 bit mode
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

  lda #$21
  sta NUM1
  lda #$6e
  sta NUM1+1

  lda #DIVIDEND_LO
  sta NUM_TO_DEC
  lda #DIVIDEND_HI
  sta NUM_TO_DEC+1

  jsr lcd_write_dec   ; write dividend

  lda #"/"
  jsr lcd_write

  lda #DIVISOR_LO
  sta NUM_TO_DEC
  lda #DIVISOR_HI
  sta NUM_TO_DEC+1

  jsr lcd_write_dec   ; write divisor

  lda #"="
  jsr lcd_write

  lda #DIVIDEND_LO
  sta NUM1
  lda #DIVIDEND_HI
  sta NUM1+1

  lda #DIVISOR_LO
  sta NUM2
  lda #DIVISOR_HI
  sta NUM2+1

  jsr divide

  lda REM             ; stash remainder for printing after
  sta STASH
  lda REM+1
  sta STASH+1

  lda NUM1
  sta NUM_TO_DEC
  lda NUM1+1
  sta NUM_TO_DEC+1

  jsr lcd_write_dec   ; write quotient

  lda #"R"
  jsr lcd_write

  lda STASH
  sta NUM_TO_DEC
  lda STASH+1
  sta NUM_TO_DEC+1

  jsr lcd_write_dec   ; write remainder

done:
  jmp done


divide:               ; divide two-byte NUM1 by two-byte NUM2. result goes in NUM1, remainder in REM
  pha
  phx
  phy

  ldx #16             ; counter for bits to rotate
  lda #0              ; initialize remainder to zero
  sta REM
  sta REM+1

div_loop:
  asl NUM1            ; rotate zero into low bit of result, rotate into remainder
  rol NUM1+1
  rol REM
  rol REM+1

  sec                 ; set carry bit for borrowing, try subtracting num2 from remainder
  lda REM
  sbc NUM2
  tay
  lda REM+1
  sbc NUM2+1

  bcc div_after_save  ; if carry bit is clear, subtraction failed
  sty REM             ; if subtraction succeeded, save sub result and set bit of division result to 1
  sta REM+1
  inc NUM1

div_after_save:
  dex                 ; loop until x = 0 (16 times for two-byte division)
  bne div_loop

  ply
  plx
  pla
  rts

lcd_read_busy:
  pha
  phx
  lda #%00001110      ; setup LCD data bits as input
  sta DDB

lcd_busy:
  lda #RW             ; tell LCD to send data
  sta PORTB

  lda #(RW | E)       ; send enable bit
  sta PORTB

  lda PORTB           ; read response
  tax                 ; stash for second read

  lda #RW
  sta PORTB
  lda #(RW | E)       ; toggle enable bit, ignore read
  sta PORTB

  txa
  and #%10000000      ; check the busy flag
  bne lcd_busy        ; if busy flag set, loop

  lda #RW
  sta PORTB

  lda #%11111110      ; setup LCD pins as output
  sta DDB

  plx
  pla
  rts


lcd_instruction:      ; sends the byte in register A
  jsr lcd_wait
  sta LCD_DATA
  and #%11110000      ; discard low nibble

  sta PORTB
  eor #E              ; toggle enable bit on
  sta PORTB
  eor #E              ; toggle enable bit off
  sta PORTB

  lda LCD_DATA        ; reload to send low nibble
  asl
  asl
  asl
  asl
  and #%11110000

  sta PORTB
  eor #E              ; toggle enable bit on
  sta PORTB
  eor #E              ; toggle enable bit off
  sta PORTB

  rts


lcd_write:            ; write the contents of A
  sta LCD_DATA
  and #%11110000      ; discard low nibble
  ora #RS             ; turn RS bit on to write

  sta PORTB
  eor #E              ; toggle enable bit on
  sta PORTB
  eor #E              ; toggle enable bit off
  sta PORTB

  lda LCD_DATA        ; reload to send low nibble
  asl
  asl
  asl
  asl
  and #%11110000
  ora #RS              ; turn RS bit on to write

  sta PORTB
  eor #E              ; toggle enable bit on
  sta PORTB
  eor #E              ; toggle enable bit off
  sta PORTB

  rts


lcd_write_dec:    ; write the number at NUM_TO_DEC (two bytes) in decimal
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

  jsr divide          ; divide NUM1 by 10

  lda REM
  clc
  adc #"0"            ; convert to ASCII code
  sta DEC_REVERSE,x   ; store digits in reverse order
  inx

  lda NUM1            ; check if result is 0
  ora NUM1+1

  bne store_dec_loop  ; if not, divide again
  dex

write_dec_loop:
  lda DEC_REVERSE,x  ; write digits in reverse order
  jsr lcd_write
  dex
  bpl write_dec_loop

  plx
  pla
  rts


  .org $fffc          ; the CPU reads address $fffc to read start of program address
  .word start         ; jump to start label
  .word $0000         ; two empty bytes in $fffe and $ffff so that binary is exactly 32KB
