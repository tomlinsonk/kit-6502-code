; VIA addresses
PORTA = $7801
PORTB = $7800
DDA = $7803
DDB = $7802
PCR = $780c
IFR = $780d
IER = $780e

; VIA Port B bits
E  = %00001000
RW = %00000100
RS = %00000010

; VIA interrupt bits
CA1_INT = %00000010
INT_ENABLE = %10000000
CA1_RISING = %00000001

; LCD instructions
FUNCTION_SET_0 = %00100000
FUNCTION_SET = %00101000
DISPLAY_ON = %00001110
ENTRY_MODE = %00000110
CLEAR_DISPLAY = %00000001
CURSOR_RIGHT = %00010100
CURSOR_LEFT = %00010000
SCROLL_RIGHT = %00011100
SCROLL_LEFT = %00011000
RETURN_HOME = %00000010
SET_ADDR = %10000000

; keyboard flags
R_SHIFT_DOWN = %00000001
L_SHIFT_DOWN = %00000010
RELEASE_NXT = %00000100
EXTENDED_NXT = %00001000

; keyboard scancodes
K_RELEASE = $f0
K_ESC = $76
K_BACKSPACE = $66
K_CAPS_LOCK = $58
K_ENTER = $5a
K_L_SHIFT = $12
K_R_SHIFT = $59
K_F11 = $78
K_F12 = $07

K_EXTENDED = $e0
KX_DOWN = $72
KX_UP = $75
KX_LEFT = $6b
KX_RIGHT = $74

; Zero page addresses

NUM1 = $00                          ; two bytes
NUM2 = $02                          ; two bytes
REM = $04                           ; two bytes
NUM_TO_DEC = $06                    ; two bytes
DEC_REVERSE = $08                   ; five bytes
KB_READ_PTR = $0d                   ; one byte
KB_WRITE_PTR = $0e                  ; one byte
KB_FLAGS = $0f                      ; one byte
NIBBLE_STASH = $10                  ; one byte

VIDEO_PTR = $11                     ; two bytes

KB_BUFFER = $f0                     ; sixteen bytes (f0-ff)

; other RAM addresses


  .org $8000                          ; ROM starts at address $8000

reset:
  cli
  cld

  stz VIDEO_PTR                   ; initialize video pointer to $7000
  lda #$70
  sta VIDEO_PTR+1

  ldy #0

  lda #" "

loop:
  jsr write_ascii
  iny
  bne loop

loop2:
  jsr write_ascii
  iny
  bne loop2

  ldx #0
loop3:
  lda message,x
  beq done
  jsr write_ascii
  inx
  jmp loop3


done:
  jmp done


video_write_ascii:
  pha
  phy

  cmp #$60                        ; check if code is $60 or more
  bcc video_write                 ; if it's below $60, we can immediately write it
  and #%00011111                  ; otherwise, it's a lowercase letter. only keep bottom 5 bits

video_write:
  ldy #0
  sta (VIDEO_PTR),y               ; write six bit ascii to memory at address in VIDEO_PTR
  jsr inc_vid_txt_ptrs

  ply
  pla
  rts


inc_video_ptr:
  inc VIDEO_PTR                       ; increment the video pointer
  bne exit_inc_video_ptr              ; check if it became 0 when incremented. If not, we're good to return
  inc VIDEO_PTR+1                     ; if it became 0, carry to hi byte
  bbr1 VIDEO_PTR+1,exit_inc_video_ptr ; if 2s bit of hi byte is 0, we're good to return
  rmb1 VIDEO_PTR+1                    ; otherwise, we're passing 512 chars and need to reset to 0
exit_inc_video_ptr:
  rts

message:
  .string "Twas brillig, and the slithy toves Did gyre and gimble in the wabe: All mimsy were the borogoves And the mome raths outgrabe. Beware the Jabberwock, my son! The jaws that bite the claws that catch! Beware the Jubjub bird and shun The frumious Bandersnatch"

irq:
  rti

  .org $fffc                                ; the CPU reads address $fffc to read start of program address
  .word reset                               ; reset address
  .word irq                                 ; IRQ handler address
