.cpu _65c02
.encoding "ascii"
.filenamespace mini_asm

/*
Mini assembler for the KiT: a one-line-at-a-time 65C02 assembler in the style of
the Apple II mini-assembler. Type "addr: mnemonic operand" (the address is optional),
and the bytes are written to memory and the address advances.
See README.md for the syntax.
*/

#define PCB

#import "video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"


.const LINE_MAX = 26                                // chars that fit after the "xxxx: " prompt
.const NAME_MAX = 16                                // KSF file name length
.const MAX_SAVE = $0eff                             // largest file that fits in one SSD sector
.const LIST_COL = 15                                // listing column for the normalized instruction

// Addressing modes
.const IMP = 0                                      // implied
.const ACC = 1                                      // accumulator
.const IMM = 2                                      // #$12
.const ZP  = 3                                      // $12
.const ZPX = 4                                      // $12,x
.const ZPY = 5                                      // $12,y
.const IZX = 6                                      // ($12,x)
.const IZY = 7                                      // ($12),y
.const IZP = 8                                      // ($12)
.const ABS = 9                                      // $1234
.const ABX = 10                                     // $1234,x
.const ABY = 11                                     // $1234,y
.const IND = 12                                     // ($1234)
.const IAX = 13                                     // ($1234,x)
.const REL = 14                                     // branch target
.const ZPR = 15                                     // $12,target (bbr/bbs)
.const NONE = $ff

// Listing format flags per mode
.const F_IMM = 1                                    // "#"
.const F_PAREN = 2                                  // "("
.const F_WORD = 4                                   // 16-bit value


// Opcode table, built at assembly time.
// op_mnem[opcode] = mnemonic index, op_mode[opcode] = addressing mode ($ff if undefined)
.var names = List()
.var op_mnem_list = List()
.var op_mode_list = List()
.for (var i = 0; i < 256; i++) {
    .eval op_mnem_list.add(NONE)
    .eval op_mode_list.add(NONE)
}

.function def(name, modes) {
    .var index = names.size()
    .eval names.add(name)
    .for (var i = 0; i < modes.size(); i += 2) {
        .eval op_mode_list.set(modes.get(i + 1), modes.get(i))
        .eval op_mnem_list.set(modes.get(i + 1), index)
    }
    .return index
}

// adc, and, cmp, eor, lda, ora, sbc share a layout relative to the (zp,x) opcode
.function alu(name, base) {
    .return def(name, List().add(IMM, base + $08, ZP, base + $04, ZPX, base + $14, ABS, base + $0c,
        ABX, base + $1c, ABY, base + $18, IZX, base, IZY, base + $10, IZP, base + $11))
}

// asl, lsr, rol, ror share a layout relative to the zp opcode
.function shift(name, base) {
    .return def(name, List().add(ACC, base + $04, ZP, base, ZPX, base + $10, ABS, base + $08, ABX, base + $18))
}

.eval alu("adc", $61)
.eval alu("and", $21)
.eval alu("cmp", $c1)
.eval alu("eor", $41)
.eval alu("lda", $a1)
.eval alu("ora", $01)
.eval alu("sbc", $e1)
.eval def("sta", List().add(ZP, $85, ZPX, $95, ABS, $8d, ABX, $9d, ABY, $99, IZX, $81, IZY, $91, IZP, $92))
.eval shift("asl", $06)
.eval shift("lsr", $46)
.eval shift("rol", $26)
.eval shift("ror", $66)
.eval def("dec", List().add(ACC, $3a, ZP, $c6, ZPX, $d6, ABS, $ce, ABX, $de))
.eval def("inc", List().add(ACC, $1a, ZP, $e6, ZPX, $f6, ABS, $ee, ABX, $fe))
.eval def("bit", List().add(IMM, $89, ZP, $24, ZPX, $34, ABS, $2c, ABX, $3c))
.eval def("cpx", List().add(IMM, $e0, ZP, $e4, ABS, $ec))
.eval def("cpy", List().add(IMM, $c0, ZP, $c4, ABS, $cc))
.eval def("ldx", List().add(IMM, $a2, ZP, $a6, ZPY, $b6, ABS, $ae, ABY, $be))
.eval def("ldy", List().add(IMM, $a0, ZP, $a4, ZPX, $b4, ABS, $ac, ABX, $bc))
.eval def("stx", List().add(ZP, $86, ZPY, $96, ABS, $8e))
.eval def("sty", List().add(ZP, $84, ZPX, $94, ABS, $8c))
.eval def("stz", List().add(ZP, $64, ZPX, $74, ABS, $9c, ABX, $9e))
.eval def("trb", List().add(ZP, $14, ABS, $1c))
.eval def("tsb", List().add(ZP, $04, ABS, $0c))
.eval def("jmp", List().add(ABS, $4c, IND, $6c, IAX, $7c))
.eval def("jsr", List().add(ABS, $20))

.var branches = List().add("bcc", $90, "bcs", $b0, "beq", $f0, "bmi", $30, "bne", $d0,
    "bpl", $10, "bra", $80, "bvc", $50, "bvs", $70)
.for (var i = 0; i < branches.size(); i += 2) {
    .eval def(branches.get(i), List().add(REL, branches.get(i + 1)))
}

.var implied = List().add("brk", $00, "clc", $18, "cld", $d8, "cli", $58, "clv", $b8,
    "dex", $ca, "dey", $88, "inx", $e8, "iny", $c8, "nop", $ea,
    "pha", $48, "php", $08, "phx", $da, "phy", $5a,
    "pla", $68, "plp", $28, "plx", $fa, "ply", $7a,
    "rti", $40, "rts", $60, "sec", $38, "sed", $f8, "sei", $78, "stp", $db,
    "tax", $aa, "tay", $a8, "tsx", $ba, "txa", $8a, "txs", $9a, "tya", $98, "wai", $cb)
.for (var i = 0; i < implied.size(); i += 2) {
    .eval def(implied.get(i), List().add(IMP, implied.get(i + 1)))
}

// Bit instructions take a bit number 0-7 (rmb3, bbs7, ...), added to the opcode as bit << 4.
// Only the bit 0 opcode is in the table.
.const FIRST_BIT_MNEM = names.size()
.eval def("rmb", List().add(ZP, $07))
.eval def("smb", List().add(ZP, $87))
.eval def("bbr", List().add(ZPR, $0f))
.eval def("bbs", List().add(ZPR, $8f))
.const NUM_MNEMS = names.size()


.label ptr = zp.math0                               // 2 bytes: general pointer


.segment Code [outPrg="mini-asm.prg", start=$5000]
asm_start:
    jmp init


/* ---------------------------------------------------------------------------------------
Start (or restart) the assembler. Keeps the current address.
*/
init:
    cld
    sei
    lda zp.kb_write_ptr                             // drop keys left over from the monitor
    sta zp.kb_read_ptr
    cli
    set_vid_mode_text()

    jsr vid.shift_up_1_clear_bottom
    vid_write_string("mini-asm. esc: monitor")

prompt_loop:
    tsx
    stx error_sp                                    // errors unwind the stack to here

    jsr vid.shift_up_1_clear_bottom
    lda pc+1
    jsr vid.write_hex
    lda pc
    jsr vid.write_hex
    lda #':'
    jsr putc
    jsr vid.inc_vid_ptr

    mov2 pc : line_pc                               // errors restore the address
    lda #LINE_MAX
    sta maxlen
    jsr read_line
    bcs exit_to_monitor

    jsr assemble_line
    jmp prompt_loop

exit_to_monitor:
    brk                                             // monitor x (or g 5000) comes back here
    .byte 0
    jmp prompt_loop


/* ---------------------------------------------------------------------------------------
Read a line of up to maxlen chars into line (null terminated, length in len).
Carry set if esc was pressed.
*/
read_line:
    stz len
rl_wait:
    jsr kb.get_press
    bne rl_key
    blink_cursor #vid.CURSOR_ON : #' '
    jmp rl_wait

rl_key:
    bmi rl_wait                                     // ignore arrows and other extended keys

    cmp #kb.ASCII_ESC
    bne !+
    jsr erase_cursor
    sec
    rts
!:
    cmp #kb.ASCII_NEWLINE
    bne !+
    jsr erase_cursor
    ldx len
    stz line,x
    clc
    rts
!:
    cmp #kb.ASCII_BACKSPACE
    bne !+
    ldx len
    beq rl_wait
    jsr erase_cursor
    jsr vid.dec_vid_ptr
    dec len
    force_cursor_update()
    jmp rl_wait
!:
    cmp #' '
    bcc rl_wait                                     // ignore tab and other control chars
    ldx len
    cpx maxlen
    bcs rl_wait
    sta line,x
    inc len
    jsr putc
    force_cursor_update()
    jmp rl_wait


erase_cursor:
    pha
    lda #' '
    jsr vid.write_ascii
    pla
    rts


/* ---------------------------------------------------------------------------------------
Wait for a key press (blinking the cursor), returned in A
*/
get_key:
    jsr kb.get_press
    bne gk_done
    blink_cursor #vid.CURSOR_ON : #' '
    jmp get_key
gk_done:
    jsr erase_cursor
    rts


/* ---------------------------------------------------------------------------------------
Output helpers. putc writes A and advances the video pointer.
*/
putc:
    jsr vid.write_ascii
    jmp vid.inc_vid_ptr

put_dollar_hex:                                     // "$" and the byte in A
    pha
    lda #'$'
    jsr putc
    pla
    jmp vid.write_hex

put_str:                                            // null-terminated string at ptr
    phy
    ldy #0
!:  lda (ptr),y
    beq !+
    jsr putc
    iny
    bne !-
!:  ply
    rts


/* ---------------------------------------------------------------------------------------
Report an error with the message whose address is in A (lo), Y (hi), and go back to the prompt
*/
.macro error(msg) {
    lda #<msg
    ldy #>msg
    jmp error_handler
}

error_handler:
    sta ptr
    sty ptr+1
    mov2 line_pc : pc
    jsr vid.shift_up_1_clear_bottom
    lda #'?'
    jsr putc
    jsr vid.inc_vid_ptr
    jsr put_str
    ldx error_sp
    txs
    jmp prompt_loop

err_mnemonic:   error(msg_mnemonic)
err_operand:    error(msg_operand)
err_mode:       error(msg_mode)
err_range:      error(msg_range)
err_overlap:    error(msg_overlap)
err_directive:  error(msg_directive)
err_sector:     error(msg_sector)
err_size:       error(msg_size)

msg_mnemonic:   .text "bad mnemonic" ; .byte 0
msg_operand:    .text "bad operand" ; .byte 0
msg_mode:       .text "bad address mode" ; .byte 0
msg_range:      .text "out of range" ; .byte 0
msg_overlap:    .text "overlaps mini-asm" ; .byte 0
msg_directive:  .text "bad directive" ; .byte 0
msg_sector:     .text "bad sector" ; .byte 0
msg_size:       .text "bad size" ; .byte 0


/* ---------------------------------------------------------------------------------------
Assemble the line in line
*/
assemble_line:
    jsr make_lowercase
    ldx #0
    jsr skip_spaces
    lda lc,x
    bne !+
    rts                                             // empty line
!:
    jsr try_origin                                  // "xxxx:" sets the address
    jsr skip_spaces
    lda lc,x
    bne !+
    rts                                             // nothing after the address
!:
    cmp #'.'
    bne !+
    jmp directive
!:

// Mnemonic: three letters, plus a bit number for rmb/smb/bbr/bbs
    stx tmp
    ldy #0
find_mnem:
    ldx tmp
    lda lc,x
    cmp names1,y
    bne next_mnem
    lda lc+1,x
    cmp names2,y
    bne next_mnem
    lda lc+2,x
    cmp names3,y
    beq found_mnem
next_mnem:
    iny
    cpy #NUM_MNEMS
    bne find_mnem
    jmp err_mnemonic

found_mnem:
    sty mnem
    inx
    inx
    inx
    stz has_bit
    lda lc,x
    sec
    sbc #'0'
    cmp #8
    bcs no_bit
    sta bitnum
    inc has_bit
    inx
no_bit:
    lda lc,x                                        // the mnemonic must end here
    beq !+
    cmp #' '
    beq !+
    jmp err_mnemonic
!:
    lda mnem                                        // bit number given iff it's a bit instruction
    cmp #FIRST_BIT_MNEM
    lda #0
    rol
    cmp has_bit
    beq !+
    jmp err_mnemonic
!:

    jsr parse_operand
    jsr find_opcode
    bcc !+
    jmp err_mode
!:
    sta obuf
    lda has_bit
    beq !+
    lda bitnum
    asl
    asl
    asl
    asl
    ora obuf
    sta obuf
!:
    ldy mode
    lda mode_size,y
    sta osize

    cpy #REL
    bne not_rel
    mov2 val : val2                                 // the branch target
    lda #2
    jsr branch_offset
    sta obuf+1
    jmp encoded
not_rel:

    lda val                                         // 1st operand byte
    sta obuf+1
    lda val+1
    sta obuf+2                                      // 2nd operand byte (for 3-byte modes)

    cpy #ZPR
    bne not_zpr
    lda val+1
    beq !+
    jmp err_range
!:  lda #3
    jsr branch_offset
    sta obuf+2
    jmp encoded
not_zpr:

    lda osize
    cmp #2
    bne encoded
    lda val+1                                       // 1-byte operands must fit in a byte
    beq encoded
    jmp err_range

encoded:
    lda #1
    sta is_instr
    jmp emit


/*
A = instruction size. Return in A the branch offset from pc+size to val2.
*/
branch_offset:
    clc
    adc pc
    sta tmp
    lda pc+1
    adc #0
    sta tmp+1

    lda val2
    sec
    sbc tmp
    sta tmp
    lda val2+1
    sbc tmp+1
    beq bo_forward
    cmp #$ff
    bne bo_bad
    lda tmp                                         // backward: offset must be $80-$ff
    bpl bo_bad
    rts
bo_forward:
    lda tmp                                         // forward: offset must be $00-$7f
    bmi bo_bad
    rts
bo_bad:
    jmp err_range


/*
Find the opcode for mnem in the first candidate mode that has one.
Returns the opcode in A and the mode in mode, or carry set if none.
*/
find_opcode:
    ldy #0
fo_cand:
    lda cands,y
    cmp #NONE
    beq fo_fail
    sta mode
    ldx #0
fo_scan:
    lda op_mnem,x
    cmp mnem
    bne fo_next
    lda op_mode,x
    cmp mode
    beq fo_found
fo_next:
    inx
    bne fo_scan
    iny
    cpy #3
    bne fo_cand
fo_fail:
    sec
    rts
fo_found:
    txa
    clc
    rts


/* ---------------------------------------------------------------------------------------
Parse the operand at lc,x into val (and val2 for bbr/bbs) and a list of candidate modes
*/
.macro set_cands(a, b, c) {
    lda #a
    sta cands
    lda #b
    sta cands+1
    lda #c
    sta cands+2
}

parse_operand:
    jsr skip_spaces
    lda lc,x
    bne po_not_empty
    set_cands(IMP, ACC, NONE)
    rts

po_not_empty:
    cmp #'a'                                        // lone "a" is the accumulator
    bne po_not_acc
    phx
    inx
    jsr skip_spaces
    lda lc,x
    plx
    cmp #0
    bne po_not_acc_a
    set_cands(ACC, NONE, NONE)
    rts
po_not_acc_a:
    lda lc,x
po_not_acc:

    cmp #'#'
    bne po_not_imm
    inx
    jsr parse_value
    jsr expect_end
    lda val+1
    beq !+
    jmp err_range
!:  set_cands(IMM, NONE, NONE)
    rts
po_not_imm:

    cmp #'('
    beq !+
    jmp po_not_ind
!:  inx
    jsr parse_value
    jsr skip_spaces
    lda lc,x
    cmp #','
    bne po_not_izx
    inx                                             // (val,x)
    jsr expect_x
    jsr expect_close
    jsr expect_end
    lda short
    beq !+
    set_cands(IZX, IAX, NONE)
    rts
!:  set_cands(IAX, NONE, NONE)
    rts
po_not_izx:
    jsr expect_close
    jsr skip_spaces
    lda lc,x
    bne po_izy
    lda short                                       // (val)
    beq !+
    set_cands(IZP, IND, NONE)
    rts
!:  set_cands(IND, NONE, NONE)
    rts
po_izy:
    cmp #','                                        // (val),y
    bne po_bad
    inx
    jsr expect_y
    jsr expect_end
    set_cands(IZY, NONE, NONE)
    rts

po_bad:
    jmp err_operand

po_not_ind:
    jsr parse_value
    jsr skip_spaces
    lda lc,x
    bne po_indexed
    lda short                                       // val
    beq !+
    set_cands(ZP, ABS, REL)
    rts
!:  set_cands(ABS, REL, NONE)
    rts

po_indexed:
    cmp #','
    bne po_bad
    inx
    jsr skip_spaces
    lda lc,x
    cmp #'x'
    bne po_not_x
    inx                                             // val,x
    jsr expect_end
    lda short
    beq !+
    set_cands(ZPX, ABX, NONE)
    rts
!:  set_cands(ABX, NONE, NONE)
    rts
po_not_x:
    cmp #'y'
    bne po_zpr
    inx                                             // val,y
    jsr expect_end
    lda short
    beq !+
    set_cands(ZPY, ABY, NONE)
    rts
!:  set_cands(ABY, NONE, NONE)
    rts
po_zpr:
    mov2 val : val2                                 // zp,target
    jsr parse_value
    jsr expect_end
    lda val                                         // swap so val is the zp address
    ldy val2
    sta val2
    sty val
    lda val+1
    ldy val2+1
    sta val2+1
    sty val+1
    set_cands(ZPR, NONE, NONE)
    rts


expect_x:
    jsr skip_spaces
    lda lc,x
    cmp #'x'
    bne op_bad
    inx
    rts

expect_y:
    jsr skip_spaces
    lda lc,x
    cmp #'y'
    bne op_bad
    inx
    rts

expect_close:
    jsr skip_spaces
    lda lc,x
    cmp #')'
    bne op_bad
    inx
    rts

expect_end:
    jsr skip_spaces
    lda lc,x
    bne op_bad
    rts

op_bad:
    jmp err_operand


/*
Parse a value at lc,x: hex with an optional $ (1-4 digits), or 'c for a character.
Result in val. short = 1 if it was 1-2 digits or a character (prefer zero page).
*/
parse_value:
    jsr skip_spaces
    stz val
    stz val+1
    stz ndigits
    lda lc,x
    cmp #$27                                        // quote
    bne pv_not_char
    inx
    lda lc,x
    beq op_bad
    sta val
    inx
    lda #1
    sta short
    rts
pv_not_char:
    cmp #'$'
    bne pv_digits
    inx
pv_digits:
    lda lc,x
    jsr hex_digit
    bcs pv_done
    ldy ndigits
    cpy #4
    beq op_bad
    asl val
    rol val+1
    asl val
    rol val+1
    asl val
    rol val+1
    asl val
    rol val+1
    ora val
    sta val
    inc ndigits
    inx
    jmp pv_digits
pv_done:
    lda ndigits
    beq op_bad
    stz short
    cmp #3
    bcs !+
    inc short
!:  rts


/*
Convert the hex digit in A to its value. Carry set if not a hex digit.
*/
hex_digit:
    cmp #'0'
    bcc hd_bad
    cmp #'9'+1
    bcc hd_num
    cmp #'a'
    bcc hd_bad
    cmp #'f'+1
    bcs hd_bad
    sbc #'a'-11                                     // carry is clear, so this subtracts 'a'-10
    clc
    rts
hd_num:
    sbc #'0'-1                                      // carry is clear, so this subtracts '0'
    clc
    rts
hd_bad:
    sec
    rts


skip_spaces:
    lda lc,x
    cmp #' '
    bne !+
    inx
    bra skip_spaces
!:  rts


/*
Copy line to lc, lowercasing letters except the character after a quote
*/
make_lowercase:
    ldx #0
    stz tmp                                         // nonzero: next char is a literal
ml_loop:
    lda line,x
    sta lc,x
    beq ml_done
    ldy tmp
    stz tmp
    cpy #0
    bne ml_next                                     // literal char: keep it as is
    cmp #$27
    bne !+
    inc tmp
!:  cmp #'A'
    bcc ml_next
    cmp #'Z'+1
    bcs ml_next
    ora #$20
    sta lc,x
ml_next:
    inx
    bra ml_loop
ml_done:
    rts


/*
If lc,x starts with "[$]hex:" set pc to hex and move x past the colon. Otherwise leave x.
*/
try_origin:
    stx tmp
    lda lc,x
    cmp #'$'
    bne to_digits
    inx
to_digits:
    lda lc,x
    jsr hex_digit
    bcs !+
    inx
    bra to_digits
!:  jsr skip_spaces
    lda lc,x
    cmp #':'
    beq !+
    ldx tmp
    rts
!:  ldx tmp
    jsr parse_value
    jsr skip_spaces
    inx                                             // skip the colon
    mov2 val : pc
    rts


/* ---------------------------------------------------------------------------------------
Directives: .b bytes, .t text, .s sector start [end]
*/
directive:
    inx
    lda lc,x
    inx
    cmp #'b'
    beq dir_bytes
    cmp #'t'
    beq dir_text
    cmp #'s'
    bne !+
    jmp dir_save
!:  jmp err_directive

dir_bytes:
    ldy #0
db_loop:
    lda lc,x
    cmp #','
    bne !+
    inx
!:  jsr skip_spaces
    lda lc,x
    beq db_done
    phy
    jsr parse_value
    ply
    lda val+1
    beq !+
    jmp err_range
!:  lda val
    sta obuf,y
    iny
    bra db_loop
db_done:
    cpy #0
    bne !+
    jmp err_operand
!:  sty osize
    stz is_instr
    jmp emit

dir_text:
    lda line,x                                      // skip one space after .t
    cmp #' '
    bne !+
    inx
!:  ldy #0
dt_loop:
    lda line,x
    beq db_done
    sta obuf,y
    inx
    iny
    bra dt_loop


/* ---------------------------------------------------------------------------------------
Write the osize bytes in obuf at pc, list them, and advance pc
*/
emit:
    mov2 pc : ptr                                   // refuse to overwrite the assembler
    ldy osize
em_check:
    lda ptr+1
    cmp #>asm_start
    bcc em_ok
    bne !+
    lda ptr
    cmp #<asm_start
    bcc em_ok
!:  lda ptr+1
    cmp #>asm_end
    bcc em_overlap
    bne em_ok
    lda ptr
    cmp #<asm_end
    bcc em_overlap
em_ok:
    inc2 ptr
    dey
    bne em_check
    jmp em_write
em_overlap:
    jmp err_overlap

em_write:
    mov2 pc : ptr
    ldy #0
!:  lda obuf,y
    sta (ptr),y
    iny
    cpy osize
    bne !-

    jsr list_line

    lda pc
    clc
    adc osize
    sta pc
    bcc !+
    inc pc+1
!:  rts


/*
Replace the input line with "xxxx: bytes" and the normalized instruction
*/
list_line:
    ldy #31
    lda #' '
!:  sta vid.VRAM_START + 15*32,y
    dey
    bpl !-

    set_vid_ptr(15, 0)
    lda pc+1
    jsr vid.write_hex
    lda pc
    jsr vid.write_hex
    lda #':'
    jsr putc

    ldy #0
ll_bytes:
    cpy osize
    beq ll_bytes_done
    cpy #8
    bne !+
    lda #'+'                                        // more than 8 bytes
    jsr putc
    bra ll_bytes_done
!:  jsr vid.inc_vid_ptr
    lda obuf,y
    jsr vid.write_hex
    iny
    bra ll_bytes
ll_bytes_done:

    lda is_instr
    bne !+
    rts
!:  set_vid_ptr(15, LIST_COL)
    ldx mnem
    lda names1,x
    jsr putc
    lda names2,x
    jsr putc
    lda names3,x
    jsr putc
    lda has_bit
    beq !+
    lda bitnum
    ora #'0'
    jsr putc
!:
    ldy mode
    cpy #IMP
    bne !+
    rts
!:  jsr vid.inc_vid_ptr
    cpy #ACC
    bne !+
    lda #'a'
    jmp putc
!:
    cpy #ZPR
    bne ll_not_zpr
    lda val
    jsr put_dollar_hex
    lda #','
    jsr putc
    lda val2+1
    jsr put_dollar_hex
    lda val2
    jmp vid.write_hex
ll_not_zpr:
    cpy #REL
    bne !+
    mov2 val2 : val                                 // show the branch target
!:
    lda mode_flags,y
    and #F_IMM
    beq !+
    lda #'#'
    jsr putc
!:  lda mode_flags,y
    and #F_PAREN
    beq !+
    lda #'('
    jsr putc
!:  lda mode_flags,y
    and #F_WORD
    beq !+
    lda val+1
    jsr put_dollar_hex
    lda val
    jsr vid.write_hex
    bra ll_suffix
!:  lda val
    jsr put_dollar_hex
ll_suffix:
    lda mode_suffix,y
    tax
!:  lda suffixes,x
    beq !+
    jsr putc
    inx
    bra !-
!:  rts


/* ---------------------------------------------------------------------------------------
.s sector start [end]: save start up to (not including) end, or the current address, to an SSD
sector as a program that the monitor's f command can run.
*/
dir_save:
    jsr parse_value
    lda val+1
    bne ds_bad_sector
    lda val
    cmp #64
    bcs ds_bad_sector
    sta save_sector

    jsr parse_value
    mov2 val : save_start
    mov2 pc : val
    jsr skip_spaces
    lda lc,x
    beq !+
    jsr parse_value
    jsr expect_end
!:
    lda val                                         // save_size = end - start
    sec
    sbc save_start
    sta save_size
    lda val+1
    sbc save_start+1
    sta save_size+1
    bcc ds_bad_size                                 // end < start
    ora save_size
    beq ds_bad_size                                 // empty
    lda save_size+1
    cmp #>(MAX_SAVE+1)
    bcs ds_bad_size
    jmp ds_sizes_ok
ds_bad_sector:
    jmp err_sector
ds_bad_size:
    jmp err_size
ds_sizes_ok:

    lda save_sector
    jsr ssd.set_sector
    lda ssd.START_ADDR                              // $00 means the sector holds a file
    bne ds_name

    jsr vid.shift_up_1_clear_bottom
    vid_write_string("sector in use. overwrite? y/n ")
    jsr get_key
    ora #$20
    cmp #'y'
    beq ds_name
    jmp ds_cancel

ds_name:
    jsr vid.shift_up_1_clear_bottom
    vid_write_string("name: ")
    ldx #LINE_MAX                                   // zero the rest of the name
!:  stz line,x
    dex
    bpl !-
    lda #NAME_MAX
    sta maxlen
    jsr read_line
    bcs !+
    lda len
    bne ds_named
!:  jmp ds_cancel
ds_named:

    // Fletcher checksum, as computed by the serial loader
    stz sum1
    stz sum2
    mov2 save_start : ptr
    mov2 save_size : count
    ldy #0
ds_sum:
    lda (ptr),y
    clc
    adc sum1
    sta sum1
    clc
    adc sum2
    sta sum2
    inc2 ptr
    jsr dec_count
    bne ds_sum

    lda save_sector
    jsr ssd.set_sector
    jsr ssd.erase_sector

    mov2 #ssd.START_ADDR : zp.ssd_write_addr
    lda #0
    jsr ssd_put                                     // $00: sector in use
    lda #ssd.PROGRAM
    jsr ssd_put                                     // file type
    lda save_start
    jsr ssd_put                                     // start address
    lda save_start+1
    jsr ssd_put
    lda save_size
    jsr ssd_put                                     // size
    lda save_size+1
    jsr ssd_put
    lda sum1
    jsr ssd_put                                     // checksum
    lda sum2
    jsr ssd_put
                                                    // next sector and video mode stay $ff
    mov2 #ssd.file_name_addr : zp.ssd_write_addr
    ldx #0
!:  lda line,x
    jsr ssd_put
    inx
    cpx #NAME_MAX+1                                 // name, then zeros up to $8020
    bne !-

    mov2 #ssd.file_start_addr : zp.ssd_write_addr
    mov2 save_start : ptr
    mov2 save_size : count
    ldy #0
ds_copy:
    lda (ptr),y
    jsr ssd_put
    inc2 ptr
    jsr dec_count
    bne ds_copy

    jsr vid.shift_up_1_clear_bottom
    vid_write_string("saved. run with f ")
    lda save_sector
    jmp vid.write_hex

ds_cancel:
    jsr vid.shift_up_1_clear_bottom
    vid_write_string("cancelled")
    rts


/*
Write A to the SSD at zp.ssd_write_addr and advance it
*/
ssd_put:
    jsr ssd.write_byte
    inc2 zp.ssd_write_addr
    rts

/*
Decrement count; Z set when it reaches 0
*/
dec_count:
    lda count
    bne !+
    dec count+1
!:  dec count
    lda count
    ora count+1
    rts


/* ---------------------------------------------------------------------------------------
Tables
*/
mode_size:
    .byte 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 2, 3

mode_flags:
    .byte 0, 0, F_IMM, 0, 0, 0, F_PAREN, F_PAREN, F_PAREN
    .byte F_WORD, F_WORD, F_WORD, F_PAREN | F_WORD, F_PAREN | F_WORD, F_WORD, 0

suffixes:
    .byte 0
sfx_x_close:    .text ",x)" ; .byte 0
sfx_close_y:    .text "),y" ; .byte 0
sfx_close:      .text ")" ; .byte 0
sfx_x:          .text ",x" ; .byte 0
sfx_y:          .text ",y" ; .byte 0

.var sx = sfx_x - suffixes
.var sy = sfx_y - suffixes
.var sxc = sfx_x_close - suffixes
.var scy = sfx_close_y - suffixes
.var sc = sfx_close - suffixes
mode_suffix:
    .byte 0, 0, 0, 0, sx, sy, sxc, scy, sc, 0, sx, sy, sc, sxc, 0, 0

names1: .fill NUM_MNEMS, names.get(i).charAt(0)
names2: .fill NUM_MNEMS, names.get(i).charAt(1)
names3: .fill NUM_MNEMS, names.get(i).charAt(2)
op_mnem: .fill 256, op_mnem_list.get(i)
op_mode: .fill 256, op_mode_list.get(i)


/* ---------------------------------------------------------------------------------------
Variables
*/
pc:         .word $1000                             // address of the next instruction
line_pc:    .word 0
error_sp:   .byte 0
len:        .byte 0
maxlen:     .byte 0
line:       .fill LINE_MAX+1, 0
lc:         .fill LINE_MAX+1, 0
mnem:       .byte 0
has_bit:    .byte 0
bitnum:     .byte 0
mode:       .byte 0
cands:      .fill 3, 0
val:        .word 0
val2:       .word 0
short:      .byte 0
ndigits:    .byte 0
tmp:        .word 0
is_instr:   .byte 0
osize:      .byte 0
obuf:       .fill 32, 0
save_sector: .byte 0
save_start: .word 0
save_size:  .word 0
count:      .word 0
sum1:       .byte 0
sum2:       .byte 0
asm_end:
