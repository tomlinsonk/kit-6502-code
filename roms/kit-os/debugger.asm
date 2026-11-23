.filenamespace debugger

/*
Disassembler, single stepper, and hex editor (d command). See README.md for the keys.

Memory:
    $00-$0f             scratch (the user's values are in zp_reg_stash, as while the monitor runs)
    $0100-$014f         debugger stack; holds a copy of the breakpoints while user code runs
    debugger_ram        checksum, step trampoline, and values that must survive the stepped instruction
    debugger_scratch    the user's text screen, registers, breakpoints, view, temporaries
    $6200-$6dff, $7200-$75ff    sector copy while an SSD patch erases a sector

The user's zero page $00-$0f and IRQ vector stay in the monitor's stash (zp_reg_stash,
irq_addr_stash); the rest of zero page is shared. The user's registers are taken from and
left on the monitor's stack, so the monitor's s, u, and x commands work on them.
*/

.label SCREEN = $6000
.label SSD_WINDOW = $8000
.label SSD_END_HI = $90
.label DBG_S = $4f                                  // debugger stack: $0124-$014f
.label BP_SHADOW = $0100                            // breakpoint table while user code runs (36 bytes)
.label ROWS = 13                                    // content rows (screen rows 2-14)
.label NUM_BPS = 8                                  // user breakpoints; slot 8 is the step-over temp
.label BP_BYTES = 4 * (NUM_BPS + 1)
.label KB_BUF_LAST = 15
.label DEFAULT_PC = $1000
.label BP_MIN_HI = $03                              // breakpoints: user RAM $0300-$5fff
.label BP_END_HI = $60
.label FLASH_BUF_HI = $62                           // sector copy: pages $62-$6d, then $72-$75
.label FLASH_GAP_HI = >debugger_scratch
.label FLASH_SKIP = $72 - FLASH_GAP_HI

// Zero page scratch ($00-$0f). Not preserved across exec_tramp or a run.
.label ptr = zp.B                                   // peek/poke address
.label dpc = zp.D                                   // address being disassembled
.label scr = zp.F                                   // screen row pointer
.label aptr = zp.H                                  // alias pointer
.label sp = zp.J                                    // string pointer
.label val = zp.L                                   // 16-bit result
.label op = zp.N                                    // decoded instruction: op, opnd, opnd+1
.label opnd = zp.O
.label tmp = zp.Q

// debugger_ram: survives the user's code writing to debugger_scratch
.label chk = debugger_ram                           // 2: checksum of the session state
.label tramp = debugger_ram + 2                     // 9: single-step trampoline
.label kbw_before = tramp                           // while user code runs
.label stop_reason = tramp + 1
.label running = tramp + 3                          // RUN_MAGIC while user code runs with breakpoints in
.const RUN_MAGIC = $e5
.label dbg_s = debugger_ram + 11                    // debugger S during a step, user S at a stop
.label npc = debugger_ram + 12                      // 2: PC after the step
.label btarget = debugger_ram + 14                  // 2: branch target
.assert "debugger_ram holds 16 bytes", btarget + 2 - debugger_ram, 16

// Addressing modes
.const M_REL = OP_REL                               // addressing modes: see opcodes.asm
.const M_ZPR = OP_ZPR


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


/*
Start the debugger. Carry set: new session with the user PC at zp.mon_addr. Carry clear:
continue the last session with the user's registers from the monitor's stack, or start a
new one at $1000 if the session was lost.
The monitor's stack holds Y, A, X, P, PC lo, PC hi (from brk).
*/
start:
    cld
    php
    jsr finish_run
    plp
    bcs new_session
    jsr check_all
    bcs new_default

    tsx                                             // continue: registers from the monitor's stack
    inx
    lda $0100,x
    sta reg_y
    inx
    lda $0100,x
    sta reg_a
    inx
    lda $0100,x
    sta reg_x
    inx
    lda $0100,x
    and #$ef
    ora #$20
    sta reg_p
    inx
    lda $0100,x
    sta val
    inx
    lda $0100,x
    sta val+1
    stx reg_s
    lda val                                         // the PC moved (u, or a brk): show it
    cmp reg_pc
    bne pc_moved
    lda val+1
    cmp reg_pc+1
    beq enter
pc_moved:
    mov2 val : reg_pc
    jsr view_pc
    bra enter

new_default:
    mov2 #DEFAULT_PC : zp.mon_addr
new_session:
    mov2 zp.mon_addr : reg_pc
    stz reg_a
    stz reg_x
    stz reg_y
    lda #$20
    sta reg_p
    lda #$ff
    sta reg_s
    jsr clear_bps
    jsr view_pc
    jsr save_screen                                 // the monitor's screen becomes the user's

enter:
    ldx #DBG_S
    txs
    lda #vid.MODE_TEXT
    sta vid.MODE_REG
    stz pending
    stz msg+1
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
    jmp esc_exit
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
    sta vid.MODE_REG
vu_wait:
    jsr kb.get_press
    beq vu_wait
    lda #vid.MODE_TEXT
    sta vid.MODE_REG
    rts

toggle_bp:
    mov2 cur : ptr
    jsr bp_addr_ok
    bcc !+
    set_msg("bp must be in $0300-$5fff")
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

// C=0 if ptr can hold a breakpoint: user RAM $0300-$5fff
bp_addr_ok:
    lda ptr+1
    cmp #BP_MIN_HI
    bcc bp_bad
    cmp #BP_END_HI
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
    jsr seal_sess
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
.assert "a trampoline never looks like a run", (<step_nt) != RUN_MAGIC && (>step_nt) != RUN_MAGIC, true
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
    jsr swap_out
    jsr check_sess
    bcc !+
    jsr clear_bps                                   // the step wrote over the debugger's memory
    jsr view_pc
    set_msg("debugger memory overwritten")
!:  rts

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

    ldx #BP_BYTES-1                                 // keep a copy where graphics can't overwrite it
!:  lda bp_lo,x
    sta BP_SHADOW,x
    dex
    bpl !-
    lda #RUN_MAGIC
    sta running
    jsr seal_all

    jsr swap_in
    lda zp.irq_addr                                 // catch brk/F12 if the monitor handler is in use
    cmp #<irq
    bne !+
    lda zp.irq_addr+1
    cmp #>irq
    bne !+
    lda #<dbg_irq
    sta zp.irq_addr
    lda #>dbg_irq
    sta zp.irq_addr+1
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
    inx
    inx
    inx
    lda $0100,x                                     // pushed P
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
    jmp irq
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
    phy                                             // user stack: Y, X, A, P, PC lo, PC hi
    tsx
    stx dbg_s
    ldx #DBG_S
    txs
    cld
    jsr restore_irq
    jsr save_zp
    jsr check_all                                   // before anything in debugger_scratch changes
    php
    ldx dbg_s
    inx
    lda $0100,x
    sta reg_y
    inx
    lda $0100,x
    sta reg_x
    inx
    lda $0100,x
    sta reg_a
    inx
    lda $0100,x
    and #$ef
    ora #$20
    sta reg_p
    inx
    lda $0100,x
    sta reg_pc
    inx
    lda $0100,x
    sta reg_pc+1
    stx reg_s
    jsr save_screen
    jsr finish_run
    ldx #BP_BYTES-1
!:  lda BP_SHADOW,x
    sta bp_lo,x
    dex
    bpl !-
    plp
    bcc !+
    jsr view_pc                                     // the program wrote over the debugger's memory

!:  lda stop_reason
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
Context switching. The user's $00-$0f and IRQ vector live in the monitor's stash while the
debugger runs; the user's text screen and video mode live in user_screen and user_mode.
The rest of zero page is shared.
*/

// Install the user's context. Returns with interrupts disabled.
swap_in:
    ldx #15
!:  lda zp_reg_stash,x
    sta $00,x
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
    sta vid.MODE_REG
    sei
    lda irq_addr_stash
    sta zp.irq_addr
    lda irq_addr_stash+1
    sta zp.irq_addr+1
    rts

// Save the user's context and install the debugger's. Returns with interrupts enabled.
swap_out:
    jsr restore_irq
    jsr save_zp
// Copy the screen and video mode to user_screen and user_mode, then show text mode
save_screen:
    lda vid.MODE_REG
    sta user_mode
    lda #vid.MODE_TEXT
    sta vid.MODE_REG
    ldx #0
!:  lda SCREEN,x
    sta user_screen,x
    lda SCREEN+$100,x
    sta user_screen+$100,x
    inx
    bne !-
    rts

// Save the user's IRQ vector and install the monitor's. Returns with interrupts enabled.
restore_irq:
    sei
    lda zp.irq_addr
    ldx zp.irq_addr+1
    cmp #<dbg_irq                                   // undo our run-time handler
    bne !+
    cpx #>dbg_irq
    bne !+
    lda #<irq
    ldx #>irq
!:  sta irq_addr_stash
    stx irq_addr_stash+1
    lda #<irq
    sta zp.irq_addr
    lda #>irq
    sta zp.irq_addr+1
    cli
    rts

save_zp:
    ldx #15
!:  lda $00,x
    sta zp_reg_stash,x
    dex
    bpl !-
    rts


/* ---------------------------------------------------------------------------------------
Session state. debugger_scratch is video RAM, so graphics can overwrite it. A checksum in
debugger_ram checks it after the user's code runs and when d continues a session.
*/

// Leave to the monitor with the user's registers on its stack (as if the user's code did a brk)
esc_exit:
    jsr seal_all
    ldx reg_s
    lda reg_pc+1
    sta $0100,x
    dex
    lda reg_pc
    sta $0100,x
    dex
    lda reg_p
    sta $0100,x
    dex
    lda reg_x
    sta $0100,x
    dex
    lda reg_a
    sta $0100,x
    dex
    lda reg_y
    sta $0100,x
    dex
    txs
    jmp app_exit

// If user code ran with breakpoints in (and maybe never came back), put the original bytes back
finish_run:
    lda running
    cmp #RUN_MAGIC
    bne fr_done
    stz running
    ldx #NUM_BPS                                    // reverse order, in case two share an address
fr_loop:
    lda BP_SHADOW+bp_on-bp_lo,x
    cmp #1
    bne fr_next
    lda BP_SHADOW+bp_lo-bp_lo,x
    sta ptr
    lda BP_SHADOW+bp_hi-bp_lo,x
    sta ptr+1
    jsr bp_addr_ok
    bcs fr_next
    lda (ptr)
    bne fr_next                                     // not our brk any more
    lda BP_SHADOW+bp_save-bp_lo,x
    sta (ptr)
fr_next:
    dex
    bpl fr_loop
fr_done:
    rts

clear_bps:
    ldx #NUM_BPS
!:  stz bp_on,x
    dex
    bpl !-
    rts

// Code view with the cursor at the PC
view_pc:
    stz view
    stz pending
    mov2 reg_pc : cur
    mov2 reg_pc : top
    lda cur
    and #$f8
    sta htop
    lda cur+1
    sta htop+1
    rts

seal_all:
    mov2 #session_all : aptr
    bra seal
seal_sess:
    mov2 #session : aptr
seal:
    jsr checksum
    mov2 val : chk
    rts

// C=0 if the state matches the last seal
check_all:
    mov2 #session_all : aptr
    bra check
check_sess:
    mov2 #session : aptr
check:
    jsr checksum
    lda val
    cmp chk
    bne ck_bad
    lda val+1
    cmp chk+1
    bne ck_bad
    clc
    rts
ck_bad:
    sec
    rts

// val = checksum of aptr up to session_end
checksum:
    lda #$5a
    sta val
    lda #$a5
    sta val+1
cs_loop:
    lda (aptr)
    clc
    adc val
    sta val
    clc
    adc val+1
    sta val+1
    inc2 aptr
    lda aptr
    cmp #<session_end
    bne cs_loop
    lda aptr+1
    cmp #>session_end
    bne cs_loop
    rts


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
    cpx #$10
    bcs !+
    lda zp_reg_stash,x
    bra pk_ok
!:  cpx #zp.irq_addr
    bcc pk_plain
    cpx #zp.irq_addr+2
    bcs pk_plain
    lda irq_addr_stash-zp.irq_addr,x
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
    cpx #$10
    bcs !+
    pla
    sta zp_reg_stash,x
    plx
    rts
!:  cpx #zp.irq_addr
    bcc po_plain
    cpx #zp.irq_addr+2
    bcs po_plain
    pla
    sta irq_addr_stash-zp.irq_addr,x
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

// Write A to the SSD at ptr in the current sector. Erases and rewrites the sector if a bit goes 0->1.
flash_poke:
    sta newv
    lda zp.ssd_sector
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
    stz aptr                                        // copy the sector to the buffer
    stz scr
    lda #>SSD_WINDOW
    sta aptr+1
    lda #FLASH_BUF_HI
    sta scr+1
    ldy #0
!:  lda (aptr),y
    sta (scr),y
    iny
    bne !-
    inc aptr+1
    jsr next_buf_page
    lda aptr+1
    cmp #SSD_END_HI
    bne !-
    lda ptr                                         // patch the byte in the buffer
    sta aptr
    lda ptr+1
    sec
    sbc #(>SSD_WINDOW) - FLASH_BUF_HI
    cmp #FLASH_GAP_HI
    bcc !+
    adc #FLASH_SKIP-1                               // C=1
!:  sta aptr+1
    lda newv
    sta (aptr)
    jsr ssd.erase_sector
    stz zp.ssd_write_addr                           // write back every byte that isn't $ff
    lda #>SSD_WINDOW
    sta zp.ssd_write_addr+1
    stz scr
    lda #FLASH_BUF_HI
    sta scr+1
fp_page:
    ldy #0
fp_byte:
    lda (scr),y
    cmp #$ff
    beq !+
    sty zp.ssd_write_addr
    jsr ssd.write_byte
!:  iny
    bne fp_byte
    inc zp.ssd_write_addr+1
    jsr next_buf_page
    lda zp.ssd_write_addr+1
    cmp #SSD_END_HI
    bne fp_page
    rts

// Advance scr to the next page of the sector buffer, skipping debugger_scratch
next_buf_page:
    inc scr+1
    lda scr+1
    cmp #FLASH_GAP_HI
    bne !+
    lda #FLASH_GAP_HI+FLASH_SKIP
    sta scr+1
!:  rts


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
    lda zp.ssd_sector
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
Operand formats for disassembly (opcode tables are in opcodes.asm)
*/
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
mode_fmt:                                           // indexed by OP_* mode
    .byte f_none-fmt_text, f_none-fmt_text, f_imm-fmt_text, f_zp-fmt_text, f_zpx-fmt_text
    .byte f_zpy-fmt_text, f_izx-fmt_text, f_izy-fmt_text, f_izp-fmt_text, f_abs-fmt_text
    .byte f_abx-fmt_text, f_aby-fmt_text, f_ind-fmt_text, f_iax-fmt_text, f_rel-fmt_text
    .byte f_zpr-fmt_text, f_none-fmt_text, f_none-fmt_text, f_none-fmt_text
.assert "mode_fmt has every mode", * - mode_fmt, OP_MODES

code_end:


/* ---------------------------------------------------------------------------------------
Data in debugger_scratch ($6e00-$71ff)
*/
*= debugger_scratch "debugger scratch" virtual
session_all:                                        // checked when d continues a session
user_screen:    .fill 512, 0                        // user's text screen while the debugger shows its own
reg_pc:         .word 0
reg_a:          .byte 0                             // reg_a, reg_x, reg_y, reg_p, reg_s: same order as reg_names
reg_x:          .byte 0
reg_y:          .byte 0
reg_p:          .byte 0
reg_s:          .byte 0
user_mode:      .byte 0
session:                                            // also checked after the user's code runs
bp_lo:          .fill NUM_BPS+1, 0                  // bp_lo, bp_hi, bp_save, bp_on: copied to BP_SHADOW
bp_hi:          .fill NUM_BPS+1, 0
bp_save:        .fill NUM_BPS+1, 0
bp_on:          .fill NUM_BPS+1, 0
view:           .byte 0                             // 0 = code, 1 = hex
cur:            .word 0
top:            .word 0
htop:           .word 0
session_end:
line:           .fill 32, 0
line_lo:        .fill ROWS, 0
line_hi:        .fill ROWS, 0
mode:           .byte 0
len:            .byte 0
taken:          .byte 0
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
target:         .word 0
prevd:          .word 0
back:           .byte 0
scratch_end:
.assert "user_screen is page aligned", <user_screen, 0
.assert "breakpoint table layout", bp_on + NUM_BPS + 1 - bp_lo, BP_BYTES
.assert "debugger data fits in debugger_scratch", scratch_end <= debugger_scratch + $400, true
.assert "debugger stack clears the breakpoint copy", BP_SHADOW + BP_BYTES <= $0100 + DBG_S - 32, true

*= code_end "kit-os"
