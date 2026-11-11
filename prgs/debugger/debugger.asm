/*
KiT debugger: 65C02 disassembler, single stepper, and hex editor.
Loads at $4800. See README.md for keys and the memory map.
*/
.cpu _65c02
.encoding "ascii"
.filenamespace debugger

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"

.label MON_IRQ = irq                                // monitor IRQ/BRK handler
.label SCREEN = $6000
.label MODE_REG = $7901                             // vid.MODE_REG (VIA2 port A)
.label FLASH_BUF = $6200                            // 4 KB scratch for sector rewrites (graphics VRAM)
.label SSD_WINDOW = $8000
.label SSD_END_HI = $90
.label DBG_S = $4f                                  // debugger stack: $0100-$014f
.label ROWS = 13                                    // content rows (screen rows 2-14)
.label NUM_BPS = 8                                  // user breakpoints; slot 8 is the step-over temp
.label KB_BUF_LAST = 15
.label USER_PC = $1000
.label ZP_SECTOR = $42                              // zp.ssd_sector
.label ZP_IRQ = $1e                                 // zp.irq_addr

// Zero page scratch. These addresses are swapped with the user's copies, so
// their contents do not survive exec_tramp or a run.
.label ptr = $00                                    // peek/poke address
.label dpc = $02                                    // address being disassembled
.label scr = $04                                    // screen row pointer
.label op = $06                                     // decoded instruction: op, opnd, opnd+1
.label opnd = $07
.label mode = $09
.label len = $0a
.label val = $0b                                    // 16-bit result
.label tmp = $0d
.label aptr = $30                                   // alias pointer
.label sp = $32                                     // string pointer

// Addressing modes
.const M_IMP = 0
.const M_IMM = 1
.const M_ZP = 2
.const M_ZPX = 3
.const M_ZPY = 4
.const M_IZX = 5
.const M_IZY = 6
.const M_IZP = 7
.const M_ABS = 8
.const M_ABX = 9
.const M_ABY = 10
.const M_IND = 11
.const M_IAX = 12
.const M_REL = 13
.const M_ZPR = 14
.const M_U1 = 15
.const M_U2 = 16
.const M_U3 = 17


.macro print(str) {
    lda #<text
    ldy #>text
    jsr put_str
    jmp done
text:
    .text str
    .byte 0
done:
}

.macro set_msg(str) {
    lda #<text
    sta msg
    lda #>text
    sta msg+1
    jmp done
text:
    .text str
    .byte 0
done:
}


.segmentdef Vars [start=$5c00, virtual]

.segment Code [outPrg="debugger.prg", start=$4800]

start:
    ldx #DBG_S
    txs
    cld
    jsr swap_out                                    // the monitor's zp and screen become the user's

    lda #<USER_PC
    sta reg_pc
    lda #>USER_PC
    sta reg_pc+1
    stz reg_a
    stz reg_x
    stz reg_y
    lda #$20
    sta reg_p
    lda #$ff
    sta reg_s

    ldx #NUM_BPS
!:  stz bp_on,x
    dex
    bpl !-

    stz view
    stz pending
    stz msg+1
    stz htop
    stz htop+1
    stz line_lo
    stz line_hi
    mov2 reg_pc : cur
    mov2 reg_pc : top

    jsr flush_kb

main:
    jsr redraw
key_loop:
    jsr kb.get_press
    beq key_loop
    jsr handle_key
    jmp main


/* ---------------------------------------------------------------------------------------
Drop keys left over from the monitor (the load command, Enter, r)
*/
flush_kb:
    php
    sei
    stz zp.kb_flags
    ldx zp.kb_write_ptr
    stx zp.kb_read_ptr
    dex
    bpl !+
    ldx #KB_BUF_LAST
!:  lda zp.kb_buffer,x
    cmp #$f0                                        // a release is in flight: keep its flag
    bne !+
    lda #kb.RELEASE_NXT
    sta zp.kb_flags
!:  plp
    rts


/* ---------------------------------------------------------------------------------------
Keys
*/
handle_key:
    sta key
    cmp #'s'
    bne !+
    jsr do_step
    jmp follow_pc
!:  cmp #'n'
    bne !+
    jmp step_over
!:  cmp #'g'
    bne !+
    jmp do_go
!:  cmp #'p'
    bne !+
    mov2 cur : reg_pc
    rts
!:  cmp #'r'
    bne !+
    jmp edit_reg
!:  cmp #'j'
    bne !+
    jmp jump_to
!:  cmp #'k'
    bne !+
    jmp pick_sector
!:  cmp #'v'
    bne !+
    jmp view_user
!:  cmp #'.'
    bne !+
    jmp follow_pc
!:  cmp #kb.ASCII_TAB
    bne !+
    stz pending
    lda view
    eor #1
    sta view
    beq to_code
    jmp hex_fix_top
to_code:
    rts
!:  cmp #kb.ASCII_ESC
    bne !+
    brk                                             // enter the monitor; its x command returns here
    nop
    jmp flush_kb
!:  ldx view
    beq code_keys
    jmp hex_keys

code_keys:
    cmp #kb.K_DOWN
    bne !+
    mov2 cur : dpc
    jsr instr_len
    clc
    adc cur
    sta cur
    bcc nc
    inc cur+1
nc: lda dpc
    cmp line_lo+ROWS-1
    bne ck_done
    lda dpc+1
    cmp line_hi+ROWS-1
    bne ck_done
    lda line_lo+1                                   // cursor was on the last row: scroll
    sta top
    lda line_hi+1
    sta top+1
ck_done:
    rts
!:  cmp #kb.K_UP
    bne !+
    mov2 cur : dpc
    jsr prev_instr
    lda cur
    cmp top
    bne up_set
    lda cur+1
    cmp top+1
    bne up_set
    mov2 dpc : top
up_set:
    mov2 dpc : cur
    rts
!:  cmp #kb.K_RIGHT
    bne !+
    mov2 after : top
    mov2 after : cur
    rts
!:  cmp #kb.K_LEFT
    bne !+
    mov2 top : dpc
    ldx #ROWS-1
pg_up:
    phx
    jsr prev_instr
    plx
    dex
    bne pg_up
    mov2 dpc : top
    mov2 dpc : cur
    rts
!:  cmp #'b'
    bne !+
    jmp toggle_bp
!:  rts

hex_keys:
    cmp #kb.K_RIGHT
    bne !+
    inc2 cur
    jmp hex_moved
!:  cmp #kb.K_LEFT
    bne !+
    dec2 cur
    jmp hex_moved
!:  cmp #kb.K_DOWN
    bne !+
    lda #8
    clc
    adc cur
    sta cur
    bcc hk_moved
    inc cur+1
hk_moved:
    jmp hex_moved
!:  cmp #kb.K_UP
    bne !+
    sec
    lda cur
    sbc #8
    sta cur
    bcs hk_moved
    dec cur+1
    bra hk_moved
!:  cmp #kb.ASCII_BACKSPACE
    bne !+
    stz pending
    rts
!:  jsr hex_value
    bcs hk_done
    ldx pending
    bne low_nibble
    sta nib
    inc pending
hk_done:
    rts
low_nibble:
    stz pending
    sta tmp
    lda nib
    asl
    asl
    asl
    asl
    ora tmp
    sta newv
    mov2 cur : ptr
    lda newv
    jsr poke
    jsr peek
    bcs !+                                          // I/O: can't verify
    cmp newv
    beq !+
    set_msg("write failed")
    rts
!:  inc2 cur
hex_moved:
    stz pending
    jmp hex_fix_top


/* ---------------------------------------------------------------------------------------
Convert ASCII hex digit in A to 0-15. C=1 if not a hex digit.
*/
hex_value:
    cmp #'0'
    bcc hv_bad
    cmp #'9'+1
    bcs !+
    sbc #'0'-1                                      // C=0 here
    clc
    rts
!:  ora #$20                                        // allow upper case
    cmp #'a'
    bcc hv_bad
    cmp #'f'+1
    bcs hv_bad
    sbc #'a'-11
    clc
    rts
hv_bad:
    sec
    rts


/* ---------------------------------------------------------------------------------------
Commands
*/
follow_pc:
    mov2 reg_pc : cur
    lda view
    bne hex_fix_top
    ldx #ROWS-2                                     // keep the view if PC is on screen (not the last row)
!:  lda line_lo,x
    cmp cur
    bne fp_next
    lda line_hi,x
    cmp cur+1
    beq fp_done
fp_next:
    dex
    bpl !-
    mov2 cur : top
fp_done:
    rts

// Keep the hex cursor on screen
hex_fix_top:
    sec
    lda cur
    sbc htop
    sta tmp
    lda cur+1
    sbc htop+1
    bmi hf_below
    bne hf_above
    lda tmp
    cmp #ROWS*8
    bcc hf_done
hf_above:
    lda cur
    and #$f8
    sec
    sbc #(ROWS-1)*8
    sta htop
    lda cur+1
    sbc #0
    sta htop+1
    rts
hf_below:
    lda cur
    and #$f8
    sta htop
    lda cur+1
    sta htop+1
hf_done:
    rts

jump_to:
    jsr clear_line
    print("addr: ")
    ldx #4
    jsr read_hex
    bcs !+
    mov2 val : cur
    mov2 val : top
    lda cur
    and #$f8
    sta htop
    lda cur+1
    sta htop+1
!:  rts

pick_sector:
    jsr clear_line
    print("ssd sector: ")
    ldx #2
    jsr read_hex
    bcs !+
    lda val
    cmp #64
    bcs ps_bad
    sta user_zp+ZP_SECTOR
    jsr ssd.set_sector
!:  rts
ps_bad:
    set_msg("bad sector")
    rts

edit_reg:
    jsr clear_line
    print("reg (a x y p s): ")
    lda #15
    jsr blit
er_wait:
    jsr kb.get_press
    beq er_wait
    ldx #4
!:  cmp reg_names,x
    beq er_found
    dex
    bpl !-
    rts
er_found:
    phx
    jsr clear_line
    lda reg_names,x
    jsr put_ch
    lda #'='
    jsr put_ch
    ldx #2
    jsr read_hex
    plx
    bcs er_done
    lda val
    cpx #3
    bne !+
    and #$ef                                        // P: B is not a real flag
    ora #$20
!:  sta reg_a,x
er_done:
    rts

reg_names:
    .text "axyps"

view_user:
    ldx #0
!:  lda user_screen,x
    sta SCREEN,x
    lda user_screen+$100,x
    sta SCREEN+$100,x
    inx
    bne !-
    lda user_mode
    sta MODE_REG
vu_wait:
    jsr kb.get_press
    beq vu_wait
    lda #vid.MODE_TEXT
    sta MODE_REG
    rts

toggle_bp:
    mov2 cur : ptr
    jsr bp_addr_ok
    bcc !+
    set_msg("bp must be in $0200-$47ff")
    rts
!:  ldx #NUM_BPS-1
!:  lda bp_on,x
    beq tb_next
    lda bp_lo,x
    cmp cur
    bne tb_next
    lda bp_hi,x
    cmp cur+1
    bne tb_next
    stz bp_on,x                                     // already set: clear it
    rts
tb_next:
    dex
    bpl !-
    ldx #NUM_BPS-1
!:  lda bp_on,x
    beq tb_set
    dex
    bpl !-
    set_msg("no free breakpoints")
    rts
tb_set:
    lda cur
    sta bp_lo,x
    lda cur+1
    sta bp_hi,x
    lda #1
    sta bp_on,x
    rts

// C=0 if ptr can hold a breakpoint: RAM $0200-$47ff (below the debugger)
bp_addr_ok:
    lda ptr+1
    cmp #$02
    bcc bp_bad
    cmp #$48
    bcs bp_bad
    clc
    rts
bp_bad:
    sec
    rts

// C=1 if an enabled breakpoint is at dpc. X = number of slots to check
find_bp:
    dex
!:  lda bp_on,x
    beq fb_next
    lda bp_lo,x
    cmp dpc
    bne fb_next
    lda bp_hi,x
    cmp dpc+1
    bne fb_next
    sec
    rts
fb_next:
    dex
    bpl !-
    clc
    rts


/* ---------------------------------------------------------------------------------------
Read X hex digits into val on the status row. The prompt is already in line.
C=1 if cancelled with esc.
*/
read_hex:
    stx ndig
    stz ncount
    stz val
    stz val+1
rh_draw:
    lda #15
    jsr blit
rh_key:
    jsr kb.get_press
    beq rh_key
    cmp #kb.ASCII_ESC
    beq rh_cancel
    cmp #kb.ASCII_BACKSPACE
    bne rh_digit
    lda ncount
    beq rh_key
    dec ncount
    dec lp
    ldx lp
    lda #' '
    sta line,x
    ldx #4
!:  lsr val+1
    ror val
    dex
    bne !-
    bra rh_draw
rh_digit:
    sta key
    jsr hex_value
    bcs rh_key
    ldx #4
!:  asl val
    rol val+1
    dex
    bne !-
    ora val
    sta val
    lda key
    jsr put_ch
    inc ncount
    lda ncount
    cmp ndig
    bne rh_draw
    clc
    rts
rh_cancel:
    sec
    rts


/* ---------------------------------------------------------------------------------------
Single step. C=1 (with msg set) if the instruction can't be stepped.
*/
do_step:
    lda reg_pc+1
    cmp #$78
    bcc !+
    cmp #$80
    bcs !+
    set_msg("pc is in i/o space")
    sec
    rts
!:  mov2 reg_pc : dpc
    jsr decode
    lda op
    cmp #$db
    bne !+
    set_msg("stp would halt the cpu")
    sec
    rts
!:  clc
    lda reg_pc
    adc len
    sta npc
    lda reg_pc+1
    adc #0
    sta npc+1

    ldx #7
!:  lda op
    cmp emu_ops,x
    beq !+
    dex
    bpl !-
    jmp e_tramp
!:  txa
    asl
    tax
    jmp (emu_jumps,x)

emu_ops:
    .byte $00, $20, $40, $60, $4c, $6c, $7c, $cb
emu_jumps:
    .word e_brk, e_jsr, e_rti, e_rts, e_jmp, e_jind, e_jiax, set_pc  // wai steps as a nop

e_brk:
    clc
    lda reg_pc
    adc #2
    tax
    lda reg_pc+1
    adc #0
    jsr push_word
    lda reg_p
    ora #$30
    jsr push
    lda reg_p
    ora #$04
    and #$f7
    sta reg_p
    mov2 #$fffe : ptr
    bra e_vector
e_jsr:
    clc
    lda reg_pc
    adc #2
    tax
    lda reg_pc+1
    adc #0
    jsr push_word
e_jmp:
    mov2 opnd : npc
    jmp set_pc
e_rti:
    jsr pull
    and #$ef
    ora #$20
    sta reg_p
    jsr pull
    sta npc
    jsr pull
    sta npc+1
    jmp set_pc
e_rts:
    jsr pull
    sta npc
    jsr pull
    sta npc+1
    inc2 npc
    jmp set_pc
e_jind:
    mov2 opnd : ptr
    bra e_vector
e_jiax:
    clc
    lda opnd
    adc reg_x
    sta ptr
    lda opnd+1
    adc #0
    sta ptr+1
e_vector:
    jsr peek
    sta npc
    inc2 ptr
    jsr peek
    sta npc+1
    jmp set_pc

e_tramp:
    ldy #0
!:  lda op,y
    sta tramp,y
    iny
    cpy len
    bne !-
    lda mode
    cmp #M_REL
    beq e_branch
    cmp #M_ZPR
    bne e_jumps
e_branch:
    lda #3                                          // taken: skip over jmp step_nt
    sta tramp-1,y
    jsr branch_target
    mov2 val : btarget
e_jumps:
    lda #$4c
    sta tramp,y
    sta tramp+3,y
    lda #<step_nt
    sta tramp+1,y
    lda #>step_nt
    sta tramp+2,y
    lda #<step_tk
    sta tramp+4,y
    lda #>step_tk
    sta tramp+5,y
    jsr exec_tramp
    lda taken
    beq set_pc
    mov2 btarget : npc
set_pc:
    mov2 npc : reg_pc
    clc
    rts

// Run the trampoline in the user's context
exec_tramp:
    jsr swap_in
    tsx
    stx dbg_s
    ldx reg_s
    txs
    lda reg_p
    pha
    lda reg_a
    ldx reg_x
    ldy reg_y
    plp
    jmp tramp
step_nt:
    php
    sta reg_a
    stz taken
    bra step_save
step_tk:
    php
    sta reg_a
    lda #1
    sta taken
step_save:
    stx reg_x
    sty reg_y
    pla
    and #$ef
    ora #$20
    sta reg_p
    tsx
    stx reg_s
    ldx dbg_s
    txs
    cld
    jmp swap_out

// User stack helpers
push_word:                                          // push A (hi) then X (lo)
    phx
    jsr push
    pla
push:
    ldx reg_s
    sta $0100,x
    dec reg_s
    rts
pull:
    inc reg_s
    ldx reg_s
    lda $0100,x
    rts


/* ---------------------------------------------------------------------------------------
Run until a breakpoint, brk, or F12
*/
step_over:
    mov2 reg_pc : ptr
    jsr peek
    cmp #$20
    bne so_step
    clc
    lda reg_pc
    adc #3
    sta ptr
    lda reg_pc+1
    adc #0
    sta ptr+1
    jsr bp_addr_ok
    bcs so_step
    lda ptr
    sta bp_lo+NUM_BPS
    lda ptr+1
    sta bp_hi+NUM_BPS
    lda #1
    sta bp_on+NUM_BPS
    bra do_go
so_step:
    jsr do_step
    jmp follow_pc

do_go:
    jsr do_step                                     // step off the current breakpoint first
    bcc !+
    stz bp_on+NUM_BPS
    rts
!:  ldx #0                                          // insert breakpoints
ib_loop:
    lda bp_on,x
    beq ib_next
    lda bp_lo,x
    sta ptr
    lda bp_hi,x
    sta ptr+1
    lda (ptr)
    sta bp_save,x
    lda #0
    sta (ptr)
ib_next:
    inx
    cpx #NUM_BPS+1
    bne ib_loop

    jsr swap_in
    lda ZP_IRQ                                      // catch brk/F12 if the monitor handler is in use
    cmp #<MON_IRQ
    bne !+
    lda ZP_IRQ+1
    cmp #>MON_IRQ
    bne !+
    lda #<dbg_irq
    sta ZP_IRQ
    lda #>dbg_irq
    sta ZP_IRQ+1
!:  ldx reg_s
    txs
    lda reg_pc+1
    pha
    lda reg_pc
    pha
    lda reg_p
    pha
    lda reg_a
    ldx reg_x
    ldy reg_y
    rti

// IRQ handler while the user program runs
dbg_irq:
    pha
    phx
    tsx
    lda $0103,x                                     // pushed P
    and #$10
    bne di_brk
    lda zp.kb_write_ptr
    sta kbw_before
    lda #>di_ret                                    // fake an IRQ frame so the monitor's rti returns here
    pha
    lda #<di_ret
    pha
    lda #$04
    pha
    jmp MON_IRQ
di_ret:
    ldx kbw_before
    cpx zp.kb_write_ptr
    beq di_out
    lda zp.kb_buffer,x
    cmp #$07                                        // F12 make code
    bne di_out
    dex
    bpl !+
    ldx #KB_BUF_LAST
!:  lda zp.kb_buffer,x
    cmp #$f0
    beq di_out
    lda zp.kb_write_ptr
    sta zp.kb_read_ptr
    lda #1
    sta stop_reason
    bra enter_from_run
di_out:
    plx
    pla
    rti
di_brk:
    stz stop_reason
enter_from_run:
    plx
    pla
    sta reg_a
    stx reg_x
    sty reg_y
    pla
    and #$ef
    ora #$20
    sta reg_p
    pla
    sta reg_pc
    pla
    sta reg_pc+1
    tsx
    stx reg_s
    ldx #DBG_S
    txs
    cld
    jsr swap_out

    ldx #NUM_BPS                                    // remove breakpoints in reverse order
rb_loop:
    lda bp_on,x
    beq rb_next
    lda bp_lo,x
    sta ptr
    lda bp_hi,x
    sta ptr+1
    lda bp_save,x
    sta (ptr)
rb_next:
    dex
    bpl rb_loop

    lda stop_reason
    beq !+
    set_msg("stopped")
    bra er_out
!:  sec                                             // brk pushes its address + 2
    lda reg_pc
    sbc #2
    sta reg_pc
    sta dpc
    lda reg_pc+1
    sbc #0
    sta reg_pc+1
    sta dpc+1
    ldx #NUM_BPS+1
    jsr find_bp
    bcc !+
    set_msg("breakpoint")
    bra er_out
!:  set_msg("brk")
er_out:
    stz bp_on+NUM_BPS
    jsr follow_pc
    jmp main


/* ---------------------------------------------------------------------------------------
Context switching. These zero page bytes are swapped (keyboard state is shared):
$00-$0f, $13-$1f, $30-$37, $40-$45. Interrupts stay enabled during the copies so no
keyboard bytes are lost; only the IRQ vector ($1e-$1f) is swapped with interrupts off.
*/

// Install the user's context. Returns with interrupts disabled.
swap_in:
    ldx #$4f
!:  lda swap_map,x
    cmp #1
    bne si_next
    lda user_zp,x
    sta $00,x
si_next:
    dex
    bpl !-
    ldx #0
!:  lda user_screen,x
    sta SCREEN,x
    lda user_screen+$100,x
    sta SCREEN+$100,x
    inx
    bne !-
    lda user_mode
    sta MODE_REG
    sei
    lda user_zp+ZP_IRQ
    sta ZP_IRQ
    lda user_zp+ZP_IRQ+1
    sta ZP_IRQ+1
    rts

// Save the user's context and install the debugger's. Returns with interrupts enabled.
swap_out:
    sei
    lda ZP_IRQ
    ldx ZP_IRQ+1
    cmp #<dbg_irq                                   // undo our run-time handler
    bne !+
    cpx #>dbg_irq
    bne !+
    lda #<MON_IRQ
    ldx #>MON_IRQ
!:  sta user_zp+ZP_IRQ
    stx user_zp+ZP_IRQ+1
    lda #<MON_IRQ
    sta ZP_IRQ
    lda #>MON_IRQ
    sta ZP_IRQ+1
    cli
    lda MODE_REG
    sta user_mode
    lda #vid.MODE_TEXT
    sta MODE_REG
    ldx #$4f
!:  lda swap_map,x
    cmp #1
    bne so_next
    lda $00,x
    sta user_zp,x
so_next:
    dex
    bpl !-
    ldx #0
!:  lda SCREEN,x
    sta user_screen,x
    lda SCREEN+$100,x
    sta user_screen+$100,x
    inx
    bne !-
    rts

swap_map:
    .fill 16, 1                                     // $00-$0f
    .fill 3, 0                                      // $10-$12 keyboard
    .fill 11, 1                                     // $13-$1d
    .fill 2, 2                                      // $1e-$1f irq vector (swapped separately)
    .fill 16, 0                                     // $20-$2f keyboard buffer
    .fill 8, 1                                      // $30-$37
    .fill 8, 0                                      // $38-$3f
    .fill 6, 1                                      // $40-$45
    .fill 10, 0                                     // $46-$4f


/* ---------------------------------------------------------------------------------------
Read/write a byte at ptr as the user program sees it.
peek returns C=1 (and A=0) for I/O addresses, which are never read.
Both preserve X and Y.
*/
peek:
    phx
    lda ptr+1
    bne pk_hi
    ldx ptr
    cpx #$50
    bcs pk_plain
    lda swap_map,x
    beq pk_plain
    lda user_zp,x
    bra pk_ok
pk_hi:
    cmp #$62
    bcs pk_io
    cmp #$60
    bcc pk_plain
    jsr screen_alias
    lda (aptr)
    bra pk_ok
pk_io:
    cmp #$78
    bcc pk_plain
    cmp #$80
    bcs pk_plain
    plx
    lda #0
    sec
    rts
pk_plain:
    lda (ptr)
pk_ok:
    plx
    clc
    rts

poke:
    phx
    pha
    lda ptr+1
    bne po_hi
    ldx ptr
    cpx #$50
    bcs po_plain
    lda swap_map,x
    beq po_plain
    pla
    sta user_zp,x
    plx
    rts
po_hi:
    cmp #$62
    bcs po_flash
    cmp #$60
    bcc po_plain
    jsr screen_alias
    pla
    sta (aptr)
    plx
    rts
po_flash:
    cmp #>SSD_WINDOW
    bcc po_plain
    cmp #SSD_END_HI
    bcs po_plain
    pla
    jsr flash_poke
    plx
    rts
po_plain:
    pla
    sta (ptr)
    plx
    rts

screen_alias:
    lda ptr
    sta aptr
    lda ptr+1
    sec
    sbc #(>SCREEN) - (>user_screen)
    sta aptr+1
    rts

// Write A to the SSD at ptr in the user's sector. Erases and rewrites the sector if a bit goes 0->1.
flash_poke:
    sta newv
    lda user_zp+ZP_SECTOR
    jsr ssd.set_sector
    lda (ptr)
    cmp newv
    beq fp_out
    and newv
    cmp newv
    bne fp_erase
    mov2 ptr : zp.ssd_write_addr
    lda newv
    jmp ssd.write_byte
fp_out:
    rts
fp_erase:
    mov2 #SSD_WINDOW : aptr
    mov2 #FLASH_BUF : scr
    ldx #$10
    ldy #0
!:  lda (aptr),y
    sta (scr),y
    iny
    bne !-
    inc aptr+1
    inc scr+1
    dex
    bne !-
    lda ptr
    sta aptr
    lda ptr+1
    sec
    sbc #(>SSD_WINDOW) - (>FLASH_BUF)
    sta aptr+1
    lda newv
    sta (aptr)
    jsr ssd.erase_sector
    mov2 #SSD_WINDOW : zp.ssd_write_addr
    mov2 #FLASH_BUF : aptr
!:  lda (aptr)
    cmp #$ff
    beq fp_skip
    jsr ssd.write_byte
fp_skip:
    inc2 aptr
    inc2 zp.ssd_write_addr
    lda zp.ssd_write_addr+1
    cmp #SSD_END_HI
    bne !-
    rts


/* ---------------------------------------------------------------------------------------
Disassembler
*/

// Decode the instruction at dpc into op, opnd, mode, len
decode:
    mov2 dpc : ptr
    jsr peek
    bcc !+
    lda #$03                                        // unreadable: show as a 1-byte ???
!:  sta op
    tax
    lda op_mode,x
    sta mode
    tax
    lda mode_len,x
    sta len
    stz opnd
    stz opnd+1
    ldy #1
!:  cpy len
    bcs dc_done
    inc2 ptr
    jsr peek
    sta op,y
    iny
    bra !-
dc_done:
    rts

// A = length of the instruction at dpc. Preserves X.
instr_len:
    phx
    mov2 dpc : ptr
    jsr peek
    bcc !+
    lda #$03
!:  tax
    lda op_mode,x
    tax
    lda mode_len,x
    plx
    rts

// dpc = start of the instruction before dpc
prev_instr:
    mov2 dpc : target
    lda #8
    sta back
pv_try:
    sec
    lda target
    sbc back
    sta dpc
    lda target+1
    sbc #0
    sta dpc+1
pv_walk:
    mov2 dpc : prevd
    jsr instr_len
    clc
    adc dpc
    sta dpc
    bcc !+
    inc dpc+1
!:  lda dpc
    cmp target
    bne !+
    lda dpc+1
    cmp target+1
    beq pv_found
!:  sec                                             // keep walking while dpc is just before target
    lda target
    sbc dpc
    lda target+1
    sbc dpc+1
    beq pv_walk
    dec back
    bne pv_try
    sec
    lda target
    sbc #1
    sta dpc
    lda target+1
    sbc #0
    sta dpc+1
    rts
pv_found:
    mov2 prevd : dpc
    rts

// val = branch target of the decoded instruction at dpc. Preserves Y.
branch_target:
    ldx len
    lda op-1,x                                      // last operand byte
    sta tmp
    clc
    lda dpc
    adc len
    sta val
    lda dpc+1
    adc #0
    sta val+1
    lda tmp
    bpl !+
    dec val+1
!:  clc
    lda val
    adc tmp
    sta val
    bcc !+
    inc val+1
!:  rts

// Append the decoded instruction (mnemonic and operand) to line
fmt_instr:
    ldx op
    lda op_mnem,x
    tax
    lda mnem_text,x
    jsr put_ch
    lda mnem_text+1,x
    jsr put_ch
    lda mnem_text+2,x
    jsr put_ch
    lda op
    and #$07
    cmp #$07                                        // rmb/smb/bbr/bbs: append the bit number
    bne !+
    lda op
    lsr
    lsr
    lsr
    lsr
    and #$07
    ora #'0'
    jsr put_ch
!:  ldx mode
    ldy mode_fmt,x
    lda fmt_text,y
    beq fi_done
    lda #' '
    jsr put_ch
fi_loop:
    lda fmt_text,y
    beq fi_done
    cmp #'b'
    bne !+
    lda opnd
    jsr put_hex
    bra fi_next
!:  cmp #'w'
    bne !+
    lda opnd+1
    jsr put_hex
    lda opnd
    jsr put_hex
    bra fi_next
!:  cmp #'r'
    bne !+
    jsr branch_target
    lda val+1
    jsr put_hex
    lda val
    jsr put_hex
    bra fi_next
!:  jsr put_ch
fi_next:
    iny
    bra fi_loop
fi_done:
    rts

// Code view line for the instruction at dpc:
// col 0 '>' at PC, col 1 '*' at a breakpoint, address at col 3, bytes at col 8, instruction at col 17
code_line:
    jsr clear_line
    jsr decode
    lda dpc
    cmp reg_pc
    bne !+
    lda dpc+1
    cmp reg_pc+1
    bne !+
    lda #'>'
    sta line
!:  ldx #NUM_BPS
    jsr find_bp
    bcc !+
    lda #'*'
    sta line+1
!:  lda #3
    sta lp
    lda dpc
    cmp cur
    bne !+
    lda dpc+1
    cmp cur+1
    bne !+
    lda #$80
    sta inv
!:  ldx dpc+1
    lda dpc
    jsr put_word
    stz inv
    lda #8
    sta lp
    mov2 dpc : ptr
    ldy #0
cl_byte:
    jsr peek
    bcs !+
    jsr put_hex
    bra cl_next
!:  lda #'-'
    jsr put_ch
    jsr put_ch
cl_next:
    lda #' '
    jsr put_ch
    inc2 ptr
    iny
    cpy len
    bcc cl_byte
    lda #17
    sta lp
    jmp fmt_instr

// Hex view line for the 8 bytes at dpc
hex_line:
    jsr clear_line
    ldx dpc+1
    lda dpc
    jsr put_word
    mov2 dpc : ptr
    ldy #8
hl_loop:
    lda #' '
    jsr put_ch
    lda ptr
    cmp cur
    bne hl_byte
    lda ptr+1
    cmp cur+1
    bne hl_byte
    lda #$80
    sta inv
    lda pending
    beq hl_byte
    ldx nib
    lda hex_digits,x
    jsr put_ch
    lda #'.'
    jsr put_ch
    bra hl_next
hl_byte:
    jsr peek
    bcs !+
    jsr put_hex
    bra hl_next
!:  lda #'-'
    jsr put_ch
    jsr put_ch
hl_next:
    stz inv
    inc2 ptr
    dey
    bne hl_loop
    rts


/* ---------------------------------------------------------------------------------------
Screen
*/
redraw:
    jsr draw_regs
    lda view
    bne !+
    jsr draw_code
    bra draw_status
!:  jsr draw_hex

draw_status:
    jsr clear_line
    lda msg+1
    beq !+
    lda msg
    ldy msg+1
    jsr put_str
    stz msg+1
    bra ds_out
!:  lda view
    bne !+
    print("s n g b p r j k v . tab esc")
    bra ds_out
!:  mov2 cur : dpc
    jsr decode
    ldx cur+1
    lda cur
    jsr put_word
    lda #' '
    jsr put_ch
    jsr put_ch
    jsr fmt_instr
ds_out:
    lda #15
    jmp blit

draw_regs:
    jsr clear_line
    print("pc ")
    ldx reg_pc+1
    lda reg_pc
    jsr put_word
    ldx #0
!:  lda reg_names,x
    cmp #'p'
    beq dr_skip
    lda #' '
    jsr put_ch
    lda reg_names,x
    jsr put_ch
    lda #' '
    jsr put_ch
    lda reg_a,x
    jsr put_hex
dr_skip:
    inx
    cpx #5
    bne !-
    lda #0
    jsr blit

    jsr clear_line
    print("p ")
    lda reg_p
    jsr put_hex
    lda #' '
    jsr put_ch
    ldx #0
!:  lda reg_p
    and flag_bits,x
    cmp #1                                          // C=1 if the flag is set
    lda flag_chars,x
    bcc dr_flag
    and #$df                                        // upper case (inverted) when set
dr_flag:
    jsr put_ch
    inx
    cpx #6
    bne !-
    print("  ssd ")
    lda user_zp+ZP_SECTOR
    jsr put_hex
    lda #28
    sta lp
    lda view
    bne !+
    print("code")
    bra dr_out
!:  print(" hex")
dr_out:
    lda #1
    jmp blit

flag_bits:
    .byte $80, $40, $08, $04, $02, $01
flag_chars:
    .text "nvdizc"

draw_code:
    jsr fill_lines
    ldx #ROWS-1                                     // make sure the cursor is on screen
!:  lda line_lo,x
    cmp cur
    bne dcd_next
    lda line_hi,x
    cmp cur+1
    beq dcd_ok
dcd_next:
    dex
    bpl !-
    mov2 cur : top
    jsr fill_lines
dcd_ok:
    ldx #0
!:  stx row_i
    lda line_lo,x
    sta dpc
    lda line_hi,x
    sta dpc+1
    jsr code_line
    lda row_i
    clc
    adc #2
    jsr blit
    ldx row_i
    inx
    cpx #ROWS
    bne !-
    rts

fill_lines:
    mov2 top : dpc
    ldx #0
!:  lda dpc
    sta line_lo,x
    lda dpc+1
    sta line_hi,x
    jsr instr_len
    clc
    adc dpc
    sta dpc
    bcc fl_next
    inc dpc+1
fl_next:
    inx
    cpx #ROWS
    bne !-
    mov2 dpc : after
    rts

draw_hex:
    mov2 htop : dpc
    ldx #0
!:  stx row_i
    jsr hex_line
    lda row_i
    clc
    adc #2
    jsr blit
    clc
    lda dpc
    adc #8
    sta dpc
    bcc dh_next
    inc dpc+1
dh_next:
    ldx row_i
    inx
    cpx #ROWS
    bne !-
    rts


/* ---------------------------------------------------------------------------------------
Line buffer. Characters are ASCII; bit 7 marks inverse video.
*/
clear_line:
    ldx #31
    lda #' '
!:  sta line,x
    dex
    bpl !-
    stz lp
    stz inv
    rts

// Append A. Preserves A, X, Y.
put_ch:
    phx
    pha
    ora inv
    ldx lp
    cpx #32
    bcs !+
    sta line,x
    inc lp
!:  pla
    plx
    rts

put_hex:
    phx
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hex_digits,x
    jsr put_ch
    pla
    pha
    and #$0f
    tax
    lda hex_digits,x
    jsr put_ch
    pla
    plx
    rts

put_word:                                           // X = hi, A = lo
    pha
    txa
    jsr put_hex
    pla
    jmp put_hex

put_str:                                            // A/Y = zero-terminated string
    sta sp
    sty sp+1
    ldy #0
!:  lda (sp),y
    beq !+
    jsr put_ch
    iny
    bra !-
!:  rts

// Copy line to screen row A
blit:
    pha
    lsr
    lsr
    lsr
    clc
    adc #>SCREEN
    sta scr+1
    pla
    asl
    asl
    asl
    asl
    asl
    sta scr
    ldy #31
bl_loop:
    lda line,y
    cmp #$80                                        // C = inverse
    php
    and #$7f
    cmp #$60
    bcc !+
    and #$1f                                        // lower case letters
    bra bl_inv
!:  cmp #$40
    bcc !+
    and #$1f                                        // upper case: inverse letters
    ora #$40
    bra bl_inv
!:  cmp #$20
    bcs bl_inv
    lda #' '
bl_inv:
    plp
    bcc !+
    ora #$40
!:  sta (scr),y
    dey
    bpl bl_loop
    rts

hex_digits:
    .text "0123456789abcdef"


/* ---------------------------------------------------------------------------------------
Test hook: format the code line for dpc, then spin
*/
test_line:
    jsr code_line
test_done:
    bra test_done


/* ---------------------------------------------------------------------------------------
Opcode tables (WDC 65C02)
*/
.var opTable = List().add(
    "brk imp","ora izx","??? u2","??? u1","tsb zp","ora zp","asl zp","rmb zp","php imp","ora imm","asl imp","??? u1","tsb abs","ora abs","asl abs","bbr zpr",
    "bpl rel","ora izy","ora izp","??? u1","trb zp","ora zpx","asl zpx","rmb zp","clc imp","ora aby","inc imp","??? u1","trb abs","ora abx","asl abx","bbr zpr",
    "jsr abs","and izx","??? u2","??? u1","bit zp","and zp","rol zp","rmb zp","plp imp","and imm","rol imp","??? u1","bit abs","and abs","rol abs","bbr zpr",
    "bmi rel","and izy","and izp","??? u1","bit zpx","and zpx","rol zpx","rmb zp","sec imp","and aby","dec imp","??? u1","bit abx","and abx","rol abx","bbr zpr",
    "rti imp","eor izx","??? u2","??? u1","??? u2","eor zp","lsr zp","rmb zp","pha imp","eor imm","lsr imp","??? u1","jmp abs","eor abs","lsr abs","bbr zpr",
    "bvc rel","eor izy","eor izp","??? u1","??? u2","eor zpx","lsr zpx","rmb zp","cli imp","eor aby","phy imp","??? u1","??? u3","eor abx","lsr abx","bbr zpr",
    "rts imp","adc izx","??? u2","??? u1","stz zp","adc zp","ror zp","rmb zp","pla imp","adc imm","ror imp","??? u1","jmp ind","adc abs","ror abs","bbr zpr",
    "bvs rel","adc izy","adc izp","??? u1","stz zpx","adc zpx","ror zpx","rmb zp","sei imp","adc aby","ply imp","??? u1","jmp iax","adc abx","ror abx","bbr zpr",
    "bra rel","sta izx","??? u2","??? u1","sty zp","sta zp","stx zp","smb zp","dey imp","bit imm","txa imp","??? u1","sty abs","sta abs","stx abs","bbs zpr",
    "bcc rel","sta izy","sta izp","??? u1","sty zpx","sta zpx","stx zpy","smb zp","tya imp","sta aby","txs imp","??? u1","stz abs","sta abx","stz abx","bbs zpr",
    "ldy imm","lda izx","ldx imm","??? u1","ldy zp","lda zp","ldx zp","smb zp","tay imp","lda imm","tax imp","??? u1","ldy abs","lda abs","ldx abs","bbs zpr",
    "bcs rel","lda izy","lda izp","??? u1","ldy zpx","lda zpx","ldx zpy","smb zp","clv imp","lda aby","tsx imp","??? u1","ldy abx","lda abx","ldx aby","bbs zpr",
    "cpy imm","cmp izx","??? u2","??? u1","cpy zp","cmp zp","dec zp","smb zp","iny imp","cmp imm","dex imp","wai imp","cpy abs","cmp abs","dec abs","bbs zpr",
    "bne rel","cmp izy","cmp izp","??? u1","??? u2","cmp zpx","dec zpx","smb zp","cld imp","cmp aby","phx imp","stp imp","??? u3","cmp abx","dec abx","bbs zpr",
    "cpx imm","sbc izx","??? u2","??? u1","cpx zp","sbc zp","inc zp","smb zp","inx imp","sbc imm","nop imp","??? u1","cpx abs","sbc abs","inc abs","bbs zpr",
    "beq rel","sbc izy","sbc izp","??? u1","??? u2","sbc zpx","inc zpx","smb zp","sed imp","sbc aby","plx imp","??? u1","??? u3","sbc abx","inc abx","bbs zpr"
)
.assert "256 opcodes", opTable.size(), 256

.var modeIds = Hashtable().put(
    "imp",M_IMP,"imm",M_IMM,"zp",M_ZP,"zpx",M_ZPX,"zpy",M_ZPY,"izx",M_IZX,"izy",M_IZY,"izp",M_IZP,
    "abs",M_ABS,"abx",M_ABX,"aby",M_ABY,"ind",M_IND,"iax",M_IAX,"rel",M_REL,"zpr",M_ZPR,
    "u1",M_U1,"u2",M_U2,"u3",M_U3)
.var mnemNames = List()
.var mnemOffsets = Hashtable()
.var opMnem = List()
.var opMode = List()
.for (var i = 0; i < 256; i++) {
    .var entry = opTable.get(i)
    .var name = entry.substring(0, 3)
    .if (!mnemOffsets.containsKey(name)) {
        .eval mnemOffsets.put(name, mnemNames.size() * 3)
        .eval mnemNames.add(name)
    }
    .eval opMnem.add(mnemOffsets.get(name))
    .eval opMode.add(modeIds.get(entry.substring(4, entry.size())))
}
.assert "mnemonic table fits in 256 bytes", mnemNames.size() * 3 <= 256, true

op_mnem:
    .fill 256, opMnem.get(i)
op_mode:
    .fill 256, opMode.get(i)
mnem_text:
    .for (var i = 0; i < mnemNames.size(); i++) .text mnemNames.get(i)

mode_len:
    .byte 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 2, 3, 1, 2, 3

// Operand formats: b = byte, w = word, r = branch target
fmt_text:
f_none: .byte 0
f_imm:  .text "#$b"
        .byte 0
f_zp:   .text "$b"
        .byte 0
f_zpx:  .text "$b,x"
        .byte 0
f_zpy:  .text "$b,y"
        .byte 0
f_izx:  .text "($b,x)"
        .byte 0
f_izy:  .text "($b),y"
        .byte 0
f_izp:  .text "($b)"
        .byte 0
f_abs:  .text "$w"
        .byte 0
f_abx:  .text "$w,x"
        .byte 0
f_aby:  .text "$w,y"
        .byte 0
f_ind:  .text "($w)"
        .byte 0
f_iax:  .text "($w,x)"
        .byte 0
f_rel:  .text "$r"
        .byte 0
f_zpr:  .text "$b,$r"
        .byte 0
mode_fmt:
    .byte f_none-fmt_text, f_imm-fmt_text, f_zp-fmt_text, f_zpx-fmt_text, f_zpy-fmt_text
    .byte f_izx-fmt_text, f_izy-fmt_text, f_izp-fmt_text, f_abs-fmt_text, f_abx-fmt_text
    .byte f_aby-fmt_text, f_ind-fmt_text, f_iax-fmt_text, f_rel-fmt_text, f_zpr-fmt_text
    .byte f_none-fmt_text, f_none-fmt_text, f_none-fmt_text

code_end:
.assert "code ends before the data area", code_end <= $5c00, true


/* ---------------------------------------------------------------------------------------
Data ($5c00-$5fff, not saved in the prg)
*/
.segment Vars
user_screen:    .fill 512, 0                        // user's text screen while the debugger shows its own
user_zp:        .fill $50, 0                        // user's copy of the swapped zero page bytes
tramp:          .fill 12, 0                         // single-step trampoline
line:           .fill 32, 0
bp_lo:          .fill NUM_BPS+1, 0
bp_hi:          .fill NUM_BPS+1, 0
bp_save:        .fill NUM_BPS+1, 0
bp_on:          .fill NUM_BPS+1, 0
line_lo:        .fill ROWS, 0
line_hi:        .fill ROWS, 0
reg_pc:         .word 0
reg_a:          .byte 0                             // reg_a, reg_x, reg_y, reg_p, reg_s: same order as reg_names
reg_x:          .byte 0
reg_y:          .byte 0
reg_p:          .byte 0
reg_s:          .byte 0
user_mode:      .byte 0
dbg_s:          .byte 0
taken:          .byte 0
npc:            .word 0
btarget:        .word 0
view:           .byte 0                             // 0 = code, 1 = hex
cur:            .word 0
top:            .word 0
htop:           .word 0
after:          .word 0
pending:        .byte 0
nib:            .byte 0
newv:           .byte 0
msg:            .word 0
key:            .byte 0
ndig:           .byte 0
ncount:         .byte 0
lp:             .byte 0
inv:            .byte 0
row_i:          .byte 0
kbw_before:     .byte 0
stop_reason:    .byte 0
target:         .word 0
prevd:          .word 0
back:           .byte 0
vars_end:
.assert "user_screen is page aligned", <user_screen, 0
.assert "data fits below $6000", vars_end <= $6000, true
