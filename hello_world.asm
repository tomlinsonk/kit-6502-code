
LCD_DATA = $00
PORTA = $7811
PORTB = $7810
DDA = $7813
DDB = $7812

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

  lda #FUNCTION_SET_0  ; tell LCD to use 4 bit mode
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

  ldx #0

print:
  lda message,x
  beq done
  jsr lcd_write

  inx
  jmp print

done:
  jmp done

message:
  .string "  Kiran's 6502"


lcd_wait:
  pha
  phx
  lda #%00001110                  ; setup LCD data bits as input
  sta DDB

lcd_busy:
  lda #RW                         ; tell LCD to send data
  sta PORTB

  lda #(RW | E)                   ; send enable bit
  sta PORTB

  lda PORTB                       ; read response
  tax                             ; stash for second read

  lda #RW
  sta PORTB
  lda #(RW | E)                   ; toggle enable bit, ignore read
  sta PORTB
  lda PORTB

  txa
  and #%10000000                  ; check the busy flag
  bne lcd_busy                    ; if busy flag set, loop

  lda #RW
  sta PORTB

  lda #%11111110                  ; setup LCD pins as output
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

lcd_write:
  sta LCD_DATA
  and #%11110000      ; discard low nibble
  ora #RS              ; turn RS bit on to write

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


  .org $fffc          ; the CPU reads address $fffc to read start of program address
  .word start         ; jump to start label
  .word $0000         ; two empty bytes in $fffe and $ffff so that binary is exactly 32KB
